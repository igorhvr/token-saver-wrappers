#!/usr/bin/env bash
# Integration test of the interception chain WITHOUT pi:
#   curl --proxy mitm → mitm addon rewrite → headroom → mock upstream
# Asserts the response is the mock's canned reply AND carries headroom's
# x-headroom-* response headers (proof the request transited headroom).

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

t_install_libs
t_start_mock

# Intercept list: the mock host (as pi's models.json would produce it).
mkdir -p "$TOKEN_SAVER_HOME/mitm"
echo "$MOCK_HOST" > "$TOKEN_SAVER_HOME/mitm/intercept-hosts.txt"

t_log "bringing up isolated test pod (headroom + mitm)"
. "$REPO_DIR/lib/common.sh"
ts_ensure_pod with-mitm

t_log "sending chat completion through mitm proxy"
RESP_HEADERS="$TOKEN_SAVER_HOME/resp-headers.txt"
BODY="$(curl -fsS -D "$RESP_HEADERS" \
    --proxy "http://127.0.0.1:$TOKEN_SAVER_MITM_PORT" \
    -H "Authorization: Bearer test-key-123" \
    -H "Content-Type: application/json" \
    -d '{"model":"mock-1","messages":[{"role":"user","content":"hello"}]}' \
    "http://$MOCK_HOST/v1/chat/completions")"

echo "$BODY" | grep -q "$MOCK_MARKER" || t_fail "mock reply did not come back through the chain: $BODY"
grep -qi "^x-headroom-tokens-before:" "$RESP_HEADERS" \
    || t_fail "response lacks x-headroom-* headers — request did NOT transit headroom: $(cat "$RESP_HEADERS")"
[ -s "$MOCK_LOG" ] || t_fail "mock upstream never received the request"
grep -q '"authorization": "Bearer test-key-123"' "$MOCK_LOG" \
    || t_fail "API key was not passed through to the upstream"

# Streaming variant: SSE must flow through mitm + headroom.
t_log "sending streaming chat completion"
SBODY="$(curl -fsS --no-buffer --max-time 30 \
    --proxy "http://127.0.0.1:$TOKEN_SAVER_MITM_PORT" \
    -H "Authorization: Bearer test-key-123" \
    -H "Content-Type: application/json" \
    -d '{"model":"mock-1","stream":true,"messages":[{"role":"user","content":"hello"}]}' \
    "http://$MOCK_HOST/v1/chat/completions")"
echo "$SBODY" | grep -q "$MOCK_MARKER" || t_fail "streaming reply missing marker: $SBODY"
echo "$SBODY" | grep -q "\[DONE\]" || t_fail "streaming reply missing [DONE]"

# Non-intercepted host must pass through untouched (not rewritten to headroom):
# the mock is reachable from inside the pod, so proxying to it with an empty
# match should hit the mock directly and return its 404 for a non-LLM path.
t_log "verifying non-LLM paths on intercepted hosts pass through"
CODE="$(curl -s -o /dev/null -w '%{http_code}' \
    --proxy "http://127.0.0.1:$TOKEN_SAVER_MITM_PORT" \
    -X POST -d '{}' "http://$MOCK_HOST/v1/embeddings")"
[ "$CODE" = "404" ] || t_fail "non-chat path should reach mock directly (got HTTP $CODE)"

t_pass "test-proxy-chain"
