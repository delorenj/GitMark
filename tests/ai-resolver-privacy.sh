#!/usr/bin/env bash
# Privacy/regression tests for git-ai-resolver.
#
# Verifies, with NO real external LLM:
#   OFFLINE  - GITMARK_AI_RESOLVER_OFFLINE=1 skips the LLM entirely and falls
#              back to heuristics/ABORT without network traffic.
#   REDACT   - conflict content sent to the configured API is scrubbed for
#              high-signal secrets before it leaves the machine.
#
# Run:  bash tests/ai-resolver-privacy.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/../bin" && pwd)"
RESOLVER="$BIN/git-ai-resolver"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gm-privacy.XXXXXX")"

export NO_COLOR=1
export HOME="$ROOT/home"; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }
q(){ "$@" >/dev/null 2>&1; }

# Build a repo with a simple text-file conflict (README.md).
build_text_conflict() {
  local W="$1"
  rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
  git init -q
  printf 'hello\n' > README.md
  git add README.md; git commit -qm "base"

  git checkout -q -b feature
  printf 'hello\nfeature line\n' > README.md
  git add README.md; git commit -qm "feature"

  git checkout -q main
  printf 'hello\nmain line\n' > README.md
  git add README.md; git commit -qm "main"

  git checkout -q feature
  git merge -q main --no-commit || true
}

# Config that points at a local provider so no real key is required.
CONFIG="$ROOT/config.toml"
cat > "$CONFIG" <<'TOML'
provider = "ollama"
model = "test-model"
TOML

export GITMARK_CONFIG="$CONFIG"
# Do not let the test accidentally fall back to real keys.
export OPENROUTER_API_KEY= OPENAI_API_KEY= KIMI_API_KEY= OLLAMA_HOST=

# Mock server that binds to an OS-assigned port to avoid collisions.
SERVER="$ROOT/server.py"
cat > "$SERVER" <<'PY'
import sys, http.server
port_file = sys.argv[1]
body_file = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0) or 0)
        payload = self.rfile.read(n).decode('utf-8', errors='replace')
        with open(body_file, 'w') as f: f.write(payload)
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(b'{"choices":[{"message":{"content":"STRATEGY: KEEP_THEIRS\\nREASON: mock"}}]}')
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
with open(port_file, 'w') as f: f.write(str(srv.server_address[1]))
srv.serve_forever()
PY

start_server() {
  local port_file="$1" body_file="$2"
  python3 "$SERVER" "$port_file" "$body_file" >"$ROOT/server.out" 2>"$ROOT/server.err" &
  echo $!
}

wait_for_port() {
  local port_file="$1"
  for _ in $(seq 1 30); do
    [[ -s "$port_file" ]] && return 0
    sleep 0.1
  done
  return 1
}

echo "===== git-ai-resolver privacy regression ====="

echo "── OFFLINE: no external LLM call is made ──"
if command -v python3 >/dev/null 2>&1; then
  W="$ROOT/offline"
  build_text_conflict "$W"
  cd "$W" || exit 1

  PORT_FILE="$ROOT/offline-port.txt"
  BODY_FILE="$ROOT/offline-body.txt"
  MOCK_PID=$(start_server "$PORT_FILE" "$BODY_FILE")
  if wait_for_port "$PORT_FILE"; then
    MOCK_PORT="$(cat "$PORT_FILE")"
    OUT="$(GITMARK_AI_RESOLVER_OFFLINE=1 \
           GITMARK_AI_RESOLVER_API_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions" \
           timeout 15 "$RESOLVER" 2>&1)"; RC=$?
    kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true

    [[ $RC -eq 0 ]] && ok "resolver exits 0 in offline mode" || no "resolver exits 0 in offline mode (got $RC)"
    grep -q "Offline mode" <<<"$OUT" && ok "offline log message present" || no "offline log message present"
    ! grep -q "Sending conflict details" <<<"$OUT" && ok "no external-API warning shown" || no "no external-API warning shown"
    [[ ! -s "$BODY_FILE" ]] && ok "mock server received no request" || no "mock server received no request"
  else
    kill "$MOCK_PID" 2>/dev/null || true
    echo "  ⚠️  mock server failed to start; skipping offline test"
    cat "$ROOT/server.err" 2>/dev/null || true
  fi
else
  echo "  ⚠️  python3 not found; skipping offline test"
fi

echo "── REDACT: secrets in conflict content are scrubbed before POST ──"
if command -v python3 >/dev/null 2>&1; then
  W="$ROOT/redact"
  build_text_conflict "$W"
  cd "$W" || exit 1
  # Inject a fake secret into the conflicted file so it appears in the prompt.
  SECRET="ghp_$(printf 'A%.0s' $(seq 1 36))"
  sed -i "s/feature line/feature line; token=$SECRET/" README.md

  PORT_FILE="$ROOT/redact-port.txt"
  BODY_FILE="$ROOT/redact-body.txt"
  MOCK_PID=$(start_server "$PORT_FILE" "$BODY_FILE")
  if wait_for_port "$PORT_FILE"; then
    MOCK_PORT="$(cat "$PORT_FILE")"
    GITMARK_AI_RESOLVER_API_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions" \
      timeout 15 "$RESOLVER" >/dev/null 2>&1 || true
    kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true

    if [[ -s "$BODY_FILE" ]]; then
      ! grep -qF "$SECRET" "$BODY_FILE" && ok "raw secret not present in request body" || no "raw secret not present in request body"
      grep -q '\[REDACTED\]' "$BODY_FILE" && ok "redaction marker present" || no "redaction marker present"
    else
      no "mock server received no request body"
    fi
  else
    kill "$MOCK_PID" 2>/dev/null || true
    echo "  ⚠️  mock server failed to start; skipping redaction test"
    cat "$ROOT/server.err" 2>/dev/null || true
  fi
else
  echo "  ⚠️  python3 not found; skipping redaction test"
fi

echo "── HOOK: GITMARK_HOOK=1 forces offline mode ──"
if command -v python3 >/dev/null 2>&1; then
  W="$ROOT/hook"
  build_text_conflict "$W"
  cd "$W" || exit 1

  PORT_FILE="$ROOT/hook-port.txt"
  BODY_FILE="$ROOT/hook-body.txt"
  MOCK_PID=$(start_server "$PORT_FILE" "$BODY_FILE")
  if wait_for_port "$PORT_FILE"; then
    MOCK_PORT="$(cat "$PORT_FILE")"
    OUT="$(GITMARK_HOOK=1 \
           GITMARK_AI_RESOLVER_API_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions" \
           timeout 15 "$RESOLVER" 2>&1)"; RC=$?
    kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true

    [[ $RC -eq 0 ]] && ok "resolver exits 0 in hook mode" || no "resolver exits 0 in hook mode (got $RC)"
    grep -q "Hook mode" <<<"$OUT" && ok "hook-mode warning shown" || no "hook-mode warning shown"
    [[ ! -s "$BODY_FILE" ]] && ok "mock server received no request in hook mode" || no "mock server received a request in hook mode"
  else
    kill "$MOCK_PID" 2>/dev/null || true
    echo "  ⚠️  mock server failed to start; skipping hook test"
    cat "$ROOT/server.err" 2>/dev/null || true
  fi
else
  echo "  ⚠️  python3 not found; skipping hook test"
fi

echo ""
echo "=== ai-resolver privacy tests: $PASS passed, $FAIL failed ==="
rm -rf "$ROOT"
[[ "$FAIL" -eq 0 ]]
