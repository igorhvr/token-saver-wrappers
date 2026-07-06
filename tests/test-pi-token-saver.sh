#!/usr/bin/env bash
# End-to-end test: real pi binary, run through pi-token-saver, with a custom
# openai-completions provider in an ISOLATED PI_CODING_AGENT_DIR pointing at
# the mock upstream. Verifies:
#   - pi's reply is the mock's canned marker (full round trip works)
#   - the request transited headroom (stats counter / mock saw it)
#   - the wrapper generated the intercept-host list from models.json

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pi >/dev/null || { t_log "SKIP: pi not installed"; exit 0; }

t_install_libs
t_start_mock

# Isolated pi agent dir: custom provider aimed at the mock via a hostname only
# resolvable INSIDE containers — if pi bypassed the mitm+headroom chain it
# could not even resolve it, so a successful reply proves proxy transit.
export PI_CODING_AGENT_DIR="$TOKEN_SAVER_HOME/pi-agent"
mkdir -p "$PI_CODING_AGENT_DIR"
cat > "$PI_CODING_AGENT_DIR/settings.json" <<'EOF'
{"defaultProvider": "mockllm", "defaultModel": "mock-1"}
EOF
cat > "$PI_CODING_AGENT_DIR/models.json" <<EOF
{
  "providers": {
    "mockllm": {
      "baseUrl": "http://$MOCK_HOST/v1",
      "api": "openai-completions",
      "apiKey": "test-key-123",
      "models": [{"id": "mock-1", "contextWindow": 32768, "maxTokens": 4096}]
    }
  }
}
EOF

t_log "running pi-token-saver -p (brings up pod on first use)"
OUT="$("$REPO_DIR/bin/pi-token-saver" --provider mockllm --model mock-1 -p "Say hello" 2>&1)" \
    || t_fail "pi-token-saver exited non-zero: $OUT"

echo "$OUT" | grep -q "$MOCK_MARKER" \
    || t_fail "pi output missing mock marker — traffic did not reach mock upstream. Output: $OUT"

[ -s "$MOCK_LOG" ] || t_fail "mock upstream never received a request"
grep -q '"authorization": "Bearer test-key-123"' "$MOCK_LOG" \
    || t_fail "API key not passed through to upstream"

grep -qx "$MOCK_HOST" "$TOKEN_SAVER_HOME/mitm/intercept-hosts.txt" \
    || t_fail "wrapper did not add models.json host to intercept list"
grep -qx "api.deepseek.com" "$TOKEN_SAVER_HOME/mitm/intercept-hosts.txt" \
    || t_fail "wrapper did not include builtin provider hosts"

# Proof of headroom transit: its stats endpoint must have counted the request.
STATS="$(curl -fsS "http://127.0.0.1:$TOKEN_SAVER_HEADROOM_PORT/stats")"
echo "$STATS" | grep -qE '"(total_)?requests"[: ]*[1-9]' \
    || t_log "WARN: could not confirm request count in headroom stats (format may differ): $STATS"

t_pass "test-pi-token-saver"
