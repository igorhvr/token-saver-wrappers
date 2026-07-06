#!/usr/bin/env bash
# End-to-end test: real hermes binary, run through hermes-token-saver in
# oneshot mode, with an ISOLATED HERMES_HOME configured to use the deepseek
# provider. The wrapper points DEEPSEEK_BASE_URL at headroom; headroom is
# told (via TOKEN_SAVER_OPENAI_UPSTREAM) to forward to the mock upstream.
# Verifies the reply is the mock marker and the API key passed through.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v hermes >/dev/null || { t_log "SKIP: hermes not installed"; exit 0; }

# Headroom must forward hermes's (header-less) OpenAI traffic to the mock.
# This is read at pod creation, so it must be set before the wrapper runs.
export TOKEN_SAVER_OPENAI_UPSTREAM="http://$MOCK_HOST"

t_install_libs
t_start_mock

# Isolated hermes config: plain deepseek provider, no MoA, explicit context
# length so hermes never phones home to auto-detect it.
export HERMES_HOME="$TOKEN_SAVER_HOME/hermes"
mkdir -p "$HERMES_HOME"
cat > "$HERMES_HOME/config.yaml" <<'EOF'
model:
  provider: deepseek
  default: deepseek-chat
  context_length: 65536
agent:
  max_turns: 4
EOF
cat > "$HERMES_HOME/.env" <<'EOF'
DEEPSEEK_API_KEY=test-key-123
EOF
chmod 600 "$HERMES_HOME/.env"

t_log "running hermes-token-saver -z (brings up pod on first use)"
OUT="$(timeout 120 "$REPO_DIR/bin/hermes-token-saver" \
        --provider deepseek --model deepseek-chat -z "Say hello" 2>"$TOKEN_SAVER_HOME/hermes.err")" \
    || { t_log "hermes stderr:"; tail -30 "$TOKEN_SAVER_HOME/hermes.err" >&2; \
         t_fail "hermes-token-saver exited non-zero"; }

echo "$OUT" | grep -q "$MOCK_MARKER" \
    || { tail -30 "$TOKEN_SAVER_HOME/hermes.err" >&2; \
         t_fail "hermes output missing mock marker — traffic did not reach mock. Output: $OUT"; }

[ -s "$MOCK_LOG" ] || t_fail "mock upstream never received a request"
grep -q '"authorization": "Bearer test-key-123"' "$MOCK_LOG" \
    || t_fail "API key not passed through to upstream"

# Proof of headroom transit.
STATS="$(curl -fsS "http://127.0.0.1:$TOKEN_SAVER_HEADROOM_PORT/stats" || true)"
echo "$STATS" | grep -qE '"(total_)?requests"[: ]*[1-9]' \
    || t_log "WARN: could not confirm request count in headroom stats: $STATS"

t_pass "test-hermes-token-saver"
