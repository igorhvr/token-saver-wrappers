#!/usr/bin/env bash
# End-to-end test: real hermes binary, run through hermes-token-saver in
# oneshot mode, with an ISOLATED HERMES_HOME using a CUSTOM openai-completions
# provider whose base_url is the mock upstream. This exercises the same path a
# real custom endpoint (e.g. an internal GenAI platform) takes: the wrapper's
# mitm sidecar intercepts the config's base_url host and rewrites
# /chat/completions to headroom, which forwards to the upstream. Verifies the
# reply is the mock marker and the API key passed through.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v hermes >/dev/null || { t_log "SKIP: hermes not installed"; exit 0; }

t_install_libs
t_start_mock

# Isolated hermes config: a custom provider aimed at the mock (reachable only
# from inside the pod), so a successful reply proves the request transited the
# mitm+headroom chain rather than going direct.
export HERMES_HOME="$TOKEN_SAVER_HOME/hermes"
mkdir -p "$HERMES_HOME"
cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  provider: custom
  default: mock-1
  base_url: http://$MOCK_HOST/v1
  api_key: test-key-123
  api_mode: chat_completions
  context_length: 65536
agent:
  max_turns: 4
EOF

t_log "running hermes-token-saver -z (brings up pod on first use)"
OUT="$(t_timeout 120 "$REPO_DIR/bin/hermes-token-saver" \
        -z "Say hello" 2>"$TOKEN_SAVER_HOME/hermes.err")" \
    || { t_log "hermes stderr:"; tail -30 "$TOKEN_SAVER_HOME/hermes.err" >&2; \
         t_fail "hermes-token-saver exited non-zero"; }

echo "$OUT" | grep -q "$MOCK_MARKER" \
    || { tail -30 "$TOKEN_SAVER_HOME/hermes.err" >&2; \
         t_fail "hermes output missing mock marker — traffic did not reach mock. Output: $OUT"; }

[ -s "$MOCK_LOG" ] || t_fail "mock upstream never received a request"
grep -q '"authorization": "Bearer test-key-123"' "$MOCK_LOG" \
    || t_fail "API key not passed through to upstream"

# The wrapper must have picked the config base_url host into the intercept list.
grep -qx "$MOCK_HOST" "$TOKEN_SAVER_HOME/mitm/intercept-hosts.txt" \
    || t_fail "wrapper did not add hermes config base_url host to intercept list"

STATS="$(curl -fsS "http://127.0.0.1:$TOKEN_SAVER_HEADROOM_PORT/stats" || true)"
echo "$STATS" | grep -qE '"(total_)?requests"[: ]*[1-9]' \
    || t_log "WARN: could not confirm request count in headroom stats: $STATS"

t_pass "test-hermes-token-saver"
