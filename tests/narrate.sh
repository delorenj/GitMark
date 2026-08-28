#!/usr/bin/env bash
# Regression test for bin/gitmark-narrate (AI-narrated checkpoint messages).
#
# Covers, with NO network and NO real LLM:
#   FALLBACK    - deterministic diff-summary when candystore + LLM are absent
#   RESILIENCE  - candystore unreachable never hangs/crashes; still exits 0
#   EMPTY       - a clean tree yields a plain timestamp message
#   BLOODBANK   - with a MOCK candystore, prompts + tool calls are pulled into
#                 the LLM context, scoped to THIS repo, with secrets redacted.
#                 The mock serves BOTH event-type generations candystore really
#                 holds - the current 4-token bloodbank.<domain>.<entity>.<action>
#                 and the frozen historical 5-token bloodbank.v1.* rows - so the
#                 suite cannot go green against a shape the store no longer
#                 writes (which is exactly how the reader went deaf unnoticed).
#   ARGV        - provider credentials and narration context stay out of curl's
#                 process arguments while still reaching the provider.
#
# The LLM is disabled throughout via GITMARK_NARRATE_PROVIDER=none, so no tokens
# are spent and no key is required. The bloodbank path is exercised through
# GITMARK_NARRATE_PRINT_CONTEXT=1, which dumps the (redacted) assembled context
# and exits BEFORE any model call.
#
# Run:  bash tests/narrate.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/../bin" && pwd)"
NARRATE="$BIN/gitmark-narrate"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gm-narrate.XXXXXX")"
REAL_CURL="$(command -v curl || true)"

export NO_COLOR=1
export HOME="$ROOT/home"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main

# Default: no real service, no real LLM. Individual tests override as needed.
export GITMARK_NARRATE_PROVIDER=none
export GITMARK_CANDYSTORE_URL="http://127.0.0.1:1"   # refused -> bloodbank skipped

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

chmod +x "$NARRATE" 2>/dev/null || true

# --- A repo with one committed baseline and then some dirty work ---------------
REPO="$ROOT/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q
printf 'hello\n' > README.md
git add -A; git commit -qm "init"
# Dirty it: modify a tracked file and add a new untracked file.
printf 'hello\nworld\n' > README.md
printf 'export const answer = 42\n' > feature.ts

echo "== FALLBACK: deterministic message when candystore + LLM are unavailable =="
OUT="$(timeout 15 "$NARRATE" --repo "$REPO" --since 1970-01-01T00:00:00Z 2>/dev/null)"; RC=$?
[[ $RC -eq 0 ]] && ok "exit 0" || no "exit 0 (got $RC)"
[[ -n "$OUT" ]] && ok "non-empty message" || no "non-empty message"
grep -q "checkpoint:" <<<"$OUT" && ok "has a subject line" || no "has a subject line"
grep -Eq "README|feature" <<<"$OUT" && ok "references a changed file" || no "references a changed file"
grep -q "gitmark, no-narrative" <<<"$OUT" && ok "marks the no-narrative fallback" || no "marks the no-narrative fallback"

echo "== RESILIENCE: unreachable candystore returns quickly, no crash =="
START=$SECONDS
timeout 15 "$NARRATE" --repo "$REPO" --since 1970-01-01T00:00:00Z >/dev/null 2>&1; RC=$?
ELAPSED=$((SECONDS - START))
[[ $RC -eq 0 ]] && ok "exit 0 with service down" || no "exit 0 with service down (got $RC)"
[[ $ELAPSED -le 8 ]] && ok "returned promptly (${ELAPSED}s)" || no "returned promptly (${ELAPSED}s)"

echo "== EMPTY: a clean tree yields a plain timestamp message =="
CLEAN="$ROOT/clean"; mkdir -p "$CLEAN"; ( cd "$CLEAN"; git init -q; echo x>x; git add -A; git commit -qm init )
OUT="$(timeout 15 "$NARRATE" --repo "$CLEAN" 2>/dev/null)"
grep -Eq "checkpoint: .*auto-commit" <<<"$OUT" && ok "clean tree -> timestamp message" || no "clean tree -> timestamp message"

echo "== BLOODBANK: mock candystore -> prompts+tools in context, scoped+redacted =="
if command -v python3 >/dev/null 2>&1; then
  # Build fake secrets at RUNTIME so the committed source of THIS file contains
  # no literal secret pattern (GitMark's own secret_guard + the lefthook hook
  # would otherwise refuse to commit it). The runtime values still exercise
  # redaction inside gitmark-narrate.
  SECRET_TOKEN="ghp_$(printf 'A%.0s' $(seq 1 36))"          # fake 36-char GitHub PAT
  _fake_kv_val="sk-$(printf 'x%.0s' $(seq 1 30))"           # long fake value
  SECRET_KV="KIMI_API_KEY=${_fake_kv_val}"
  OTHER_MARKER="EVENT_FROM_A_DIFFERENT_REPO_SHOULD_BE_FILTERED"
  CURRENT_MARKER="PROMPT_ON_THE_CURRENT_FOUR_TOKEN_TYPE"
  LEGACY_MARKER="PROMPT_ON_A_FROZEN_HISTORICAL_ROW"
  EVENTS_JSON="$ROOT/events.json"
  # The mock serves what candystore ACTUALLY holds, which is two generations of
  # the event type at once:
  #   current  bloodbank.<domain>.<entity>.<action>      (4 tokens) - everything
  #            stored from the grammar cutover onward
  #   retired  bloodbank.v1.<domain>.<entity>.<action>   (5 tokens) - ~714k rows
  #            frozen in the archive forever; they are what a narration of an
  #            older commit reads, so the reader must still see them
  # Both directions are asserted below. The tool.completed row is a negative
  # probe: type normalization must not turn the .requested filter into a
  # wildcard that sweeps in every agent event.
  cat > "$EVENTS_JSON" <<JSON
{"events":[
  {"type":"bloodbank.conversation.turn.started","time":"2026-07-01T10:00:00Z",
   "data":{"working_directory":"$REPO","prompt_text":"$CURRENT_MARKER: add a feature.ts and wire it up; also my token is $SECRET_TOKEN"}},
  {"type":"bloodbank.agent.tool.requested","time":"2026-07-01T10:00:01Z",
   "data":{"working_directory":"$REPO","tool_name":"Bash","arguments":{"command":"export $SECRET_KV && npm test"}}},
  {"type":"bloodbank.agent.tool.requested","time":"2026-07-01T10:00:02Z",
   "data":{"working_directory":"$REPO","tool_name":"Write","arguments":{"file_path":"feature.ts"}}},
  {"type":"bloodbank.agent.tool.completed","time":"2026-07-01T10:00:03Z",
   "data":{"working_directory":"$REPO","tool_name":"ShouldNotAppearCompleted","arguments":{"command":"noop"}}},
  {"type":"bloodbank.v1.conversation.turn.started","time":"2026-06-01T09:00:00Z",
   "data":{"working_directory":"$REPO","prompt_text":"$LEGACY_MARKER: the original ask, recorded before the grammar cutover"}},
  {"type":"bloodbank.v1.agent.tool.requested","time":"2026-06-01T09:00:01Z",
   "data":{"working_directory":"$REPO","tool_name":"Grep","arguments":{"pattern":"legacy_shape_tool_call"}}},
  {"type":"bloodbank.conversation.turn.started","time":"2026-07-01T10:00:04Z",
   "data":{"working_directory":"/some/other/repo","prompt_text":"$OTHER_MARKER"}}
]}
JSON
  PORT=8791
  python3 - "$EVENTS_JSON" "$PORT" <<'PY' &
import sys, http.server
body = open(sys.argv[1],'rb').read()
port = int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith('/healthz'):
            self.send_response(204); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
  MOCK_PID=$!
  # wait for the mock to accept connections
  for _ in $(seq 1 20); do curl -sf --max-time 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done

  CTX="$(GITMARK_CANDYSTORE_URL="http://127.0.0.1:$PORT" GITMARK_NARRATE_PRINT_CONTEXT=1 \
        timeout 15 "$NARRATE" --repo "$REPO" --since 1970-01-01T00:00:00Z 2>/dev/null)"
  kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true

  grep -q "USER PROMPTS" <<<"$CTX" && ok "context includes user prompts" || no "context includes user prompts"
  grep -q "TOOL CALLS" <<<"$CTX" && ok "context includes tool calls" || no "context includes tool calls"
  grep -q "Bash:" <<<"$CTX" && ok "tool name surfaced" || no "tool name surfaced"
  # Both type generations must be read. Each of these two failing alone is the
  # "narration renders empty" bug, just aimed at a different half of the archive.
  grep -qF "$CURRENT_MARKER" <<<"$CTX" &&
    ok "current 4-token prompt read" || no "current 4-token prompt read"
  grep -qF "$LEGACY_MARKER" <<<"$CTX" &&
    ok "historical 5-token prompt read" || no "historical 5-token prompt read"
  grep -q "Grep:" <<<"$CTX" &&
    ok "historical 5-token tool call read" || no "historical 5-token tool call read"
  ! grep -q "ShouldNotAppearCompleted" <<<"$CTX" &&
    ok "tool.completed not swept into tool calls" || no "tool.completed not swept into tool calls"
  ! grep -qF "$SECRET_TOKEN" <<<"$CTX" && ok "GitHub token redacted" || no "GitHub token redacted"
  ! grep -qF "$_fake_kv_val" <<<"$CTX" && ok "API-key value redacted" || no "API-key value redacted"
  grep -q "REDACTED" <<<"$CTX" && ok "redaction marker present" || no "redaction marker present"
  ! grep -qF "$OTHER_MARKER" <<<"$CTX" && ok "other-repo event filtered out" || no "other-repo event filtered out"
else
  echo "  ⚠️  python3 not found; skipping mock-candystore test"
fi

echo "== OP-KEY: config api_key='op://...' is resolved via op and sent as Bearer =="
if command -v python3 >/dev/null 2>&1; then
  # A fake `op` that ONLY resolves the exact reference (incl. the space in
  # 'API Keys') -> proves both op:// dereferencing AND space-preserving parsing.
  FAKEBIN="$ROOT/fakebin"; mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/op" <<'FAKEOP'
#!/bin/sh
if [ "$1" = "read" ] && [ "$2" = "op://DeLoSecrets/Test/API Keys/GitMark" ]; then
  echo "FAKEKEY-abc123"; exit 0
fi
exit 1
FAKEOP
  chmod +x "$FAKEBIN/op"
  cat > "$FAKEBIN/curl" <<'FAKECURL'
#!/bin/bash
printf '%s\0' "$@" > "$GITMARK_TEST_CURL_ARGV"
exec "$GITMARK_TEST_REAL_CURL" "$@"
FAKECURL
  chmod +x "$FAKEBIN/curl"

  OPCFG="$ROOT/op.toml"
  printf 'provider = "openrouter"\nmodel = "test-model"\napi_key = "op://DeLoSecrets/Test/API Keys/GitMark"\n' > "$OPCFG"

  OPORT=8792
  python3 - "$OPORT" <<'PY' &
import sys, http.server
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0) or 0)
        self.rfile.read(n)
        auth = self.headers.get('Authorization', '(none)')
        tok = auth.split(' ', 1)[1] if ' ' in auth else auth   # strip "Bearer " so
        self.send_response(200)                                 # redaction won't scrub it
        self.send_header('Content-Type','application/json'); self.end_headers()
        body = '{"choices":[{"message":{"content":"TOKENSEEN %s"}}]}' % tok
        self.wfile.write(body.encode())
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
  MOCK_PID=$!
  for _ in $(seq 1 20); do
    curl -sf --max-time 1 -X POST "http://127.0.0.1:$OPORT/v1/chat/completions" >/dev/null 2>&1 && break; sleep 0.1
  done

  # Empty the real provider keys so a resolution failure can't fall back to them
  # (and can't leak them into test output).
  OUT="$(PATH="$FAKEBIN:$PATH" \
      OPENROUTER_API_KEY= OPENAI_API_KEY= KIMI_API_KEY= \
      GITMARK_TEST_REAL_CURL="$REAL_CURL" \
      GITMARK_TEST_CURL_ARGV="$ROOT/narrate-curl-argv.bin" \
      GITMARK_CONFIG="$OPCFG" \
      GITMARK_NARRATE_PROVIDER=openrouter \
      GITMARK_NARRATE_API_URL="http://127.0.0.1:$OPORT/v1/chat/completions" \
      GITMARK_CANDYSTORE_URL="http://127.0.0.1:1" \
      timeout 15 "$NARRATE" --repo "$REPO" --since 1970-01-01T00:00:00Z 2>/dev/null)"
  kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true

  grep -q "FAKEKEY-abc123" <<<"$OUT" && ok "op:// ref resolved and used as Bearer token" || no "op:// ref resolved and used as Bearer token"
  grep -q "(gitmark)$" <<<"$OUT" && ok "took the LLM path (not the fallback)" || no "took the LLM path (not the fallback)"
  ! grep -a -qF "FAKEKEY-abc123" "$ROOT/narrate-curl-argv.bin" &&
    ok "provider key absent from curl argv" ||
    no "provider key absent from curl argv"
  ! grep -a -qF "feature.ts" "$ROOT/narrate-curl-argv.bin" &&
    ok "narration context absent from curl argv" ||
    no "narration context absent from curl argv"
else
  echo "  ⚠️  python3 not found; skipping op-key test"
fi

echo ""
echo "=== narrate tests: $PASS passed, $FAIL failed ==="
rm -rf "$ROOT"
[[ $FAIL -eq 0 ]]
