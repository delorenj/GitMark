#!/usr/bin/env bash
# Privacy regression for gitmark-route's provider request.
#
# Verifies without any external call that the provider still receives its auth
# header and staged-change context while neither appears in curl's argv.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTE="$(cd "$HERE/../bin" && pwd)/gitmark-route"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gm-route-privacy.XXXXXX")"
REAL_CURL="$(command -v curl || true)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "===== gitmark-route privacy regression ====="

if ! command -v python3 >/dev/null 2>&1 || [[ -z "$REAL_CURL" ]]; then
  echo "  ⚠️  python3 or curl not found; skipping route privacy test"
  exit 0
fi

TEST_REPO="$ROOT/repo"
mkdir -p "$TEST_REPO"
git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.name t
git -C "$TEST_REPO" config user.email t@t
printf 'base\n' > "$TEST_REPO/notes.md"
git -C "$TEST_REPO" add notes.md
git -C "$TEST_REPO" commit -qm init

CONTEXT_MARKER="ROUTE_ARGV_CONTEXT_MARKER"
printf 'staged route fixture\n' > "$TEST_REPO/$CONTEXT_MARKER.md"
git -C "$TEST_REPO" add "$CONTEXT_MARKER.md"

PROVIDER_KEY="test-route-$(printf 'k%.0s' $(seq 1 32))"
CONFIG="$ROOT/config.toml"
printf 'provider = "openrouter"\nmodel = "test-model"\napi_key = "%s"\n' "$PROVIDER_KEY" > "$CONFIG"

PORT_FILE="$ROOT/port"
BODY_FILE="$ROOT/body"
HEADER_FILE="$ROOT/header"
SERVER="$ROOT/server.py"
cat > "$SERVER" <<'PY'
import http.server
import sys

port_file, body_file, header_file = sys.argv[1:4]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        with open(body_file, "wb") as f:
            f.write(self.rfile.read(length))
        with open(header_file, "w") as f:
            f.write(self.headers.get("Authorization", ""))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(
            b'{"choices":[{"message":{"content":"{\\"route\\":\\"branch\\",'
            b'\\"slug\\":\\"safe-test\\",\\"reason\\":\\"test\\"}"}}]}'
        )

server = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

python3 "$SERVER" "$PORT_FILE" "$BODY_FILE" "$HEADER_FILE" >"$ROOT/server.out" 2>"$ROOT/server.err" &
SERVER_PID=$!
for _ in $(seq 1 30); do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.1
done

if [[ ! -s "$PORT_FILE" ]]; then
  kill "$SERVER_PID" 2>/dev/null || true
  no "mock provider started"
else
  FAKE_BIN="$ROOT/bin"
  ARGV_FILE="$ROOT/curl-argv.bin"
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/curl" <<'FAKECURL'
#!/bin/bash
printf '%s\0' "$@" > "$GITMARK_TEST_CURL_ARGV"
exec "$GITMARK_TEST_REAL_CURL" "$@"
FAKECURL
  chmod +x "$FAKE_BIN/curl"

  PORT="$(cat "$PORT_FILE")"
  OUT="$(
    PATH="$FAKE_BIN:$PATH" \
      GITMARK_CONFIG="$CONFIG" \
      GITMARK_ROUTE_API_URL="http://127.0.0.1:$PORT/v1/chat/completions" \
      GITMARK_TEST_REAL_CURL="$REAL_CURL" \
      GITMARK_TEST_CURL_ARGV="$ARGV_FILE" \
      timeout 15 "$ROUTE" --repo "$TEST_REPO" --default-branch main
  )"
  RC=$?
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true

  [[ $RC -eq 0 ]] && ok "router exits zero" || no "router exits zero (got $RC)"
  grep -q '"route":"branch"' <<<"$OUT" &&
    ok "provider response controls route" ||
    no "provider response controls route"
  grep -qF "Bearer $PROVIDER_KEY" "$HEADER_FILE" &&
    ok "provider received authorization header" ||
    no "provider received authorization header"
  grep -qF "$CONTEXT_MARKER" "$BODY_FILE" &&
    ok "provider received staged context in request body" ||
    no "provider received staged context in request body"
  ! grep -a -qF "$PROVIDER_KEY" "$ARGV_FILE" &&
    ok "provider key absent from curl argv" ||
    no "provider key absent from curl argv"
  ! grep -a -qF "$CONTEXT_MARKER" "$ARGV_FILE" &&
    ok "staged context absent from curl argv" ||
    no "staged context absent from curl argv"
fi

echo ""
echo "=== route privacy tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
