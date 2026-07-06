#!/usr/bin/env bash
# End-to-end test: real Codex binary, run through codex-token-saver in exec
# mode, in API-key mode (OPENAI_API_KEY) so its Responses traffic goes
# /v1/responses → headroom → the mock upstream (subscription mode would hit
# headroom's hardcoded chatgpt.com backend, which a mock can't stand in for).
# Uses an isolated CODEX_HOME and a dummy key — no real config, no real tokens.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v codex >/dev/null || { t_log "SKIP: codex not installed"; exit 0; }

# Headroom forwards header-less OpenAI traffic (codex /v1/responses) to the mock.
export TOKEN_SAVER_OPENAI_UPSTREAM="http://$MOCK_HOST"

t_install_libs
t_start_mock

# Isolated Codex home: API-key mode (no chatgpt auth.json), a trusted cwd, and
# a model. The wrapper shadows THIS dir and adds the headroom openai_base_url.
export CODEX_HOME="$TOKEN_SAVER_HOME/codex"
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<EOF
model = "gpt-5.5"
[projects."$PWD"]
trust_level = "trusted"
EOF
export OPENAI_API_KEY="sk-test-key-123"

t_log "running codex-token-saver exec (brings up pod on first use)"
OUT="$(t_timeout 120 "$REPO_DIR/bin/codex-token-saver" exec --skip-git-repo-check \
        "Reply with exactly one word: pong" 2>"$TOKEN_SAVER_HOME/codex.err")" \
    || { t_log "codex stderr:"; tail -25 "$TOKEN_SAVER_HOME/codex.err" >&2; \
         t_fail "codex-token-saver exited non-zero"; }

echo "$OUT" | grep -q "$MOCK_MARKER" \
    || { tail -25 "$TOKEN_SAVER_HOME/codex.err" >&2; \
         t_fail "codex output missing mock marker — traffic did not reach mock. Output: $OUT"; }

[ -s "$MOCK_LOG" ] || t_fail "mock upstream never received a request"
grep -q '/responses' "$MOCK_LOG" \
    || t_fail "mock did not receive an OpenAI /responses request"

# The wrapper must not have touched the real ~/.codex, only its shadow.
grep -q "token-saver" "$TOKEN_SAVER_HOME/codex-home/config.toml" \
    || t_fail "shadow config.toml missing headroom override"

t_pass "test-codex-token-saver"
