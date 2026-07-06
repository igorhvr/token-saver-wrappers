#!/usr/bin/env bash
# End-to-end test: real Claude Code binary, run through claude-token-saver in
# print mode, with headroom told to forward Anthropic /v1/messages traffic to
# the mock upstream. Uses an isolated CLAUDE_CONFIG_DIR and a dummy API key, so
# it touches no real config and spends no real tokens. Verifies the reply is
# the mock marker and the request transited headroom.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v claude >/dev/null || { t_log "SKIP: claude not installed"; exit 0; }

# Headroom forwards Anthropic traffic (no per-host header) to the mock; read at
# pod creation, so set before the wrapper runs.
export TOKEN_SAVER_ANTHROPIC_UPSTREAM="http://$MOCK_HOST"

t_install_libs
t_start_mock

# Isolated Claude config; dummy key so Claude uses api-key auth against our
# base URL instead of the user's real OAuth.
export CLAUDE_CONFIG_DIR="$TOKEN_SAVER_HOME/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
export ANTHROPIC_API_KEY="sk-ant-test-key-123"

t_log "running claude-token-saver -p (brings up pod on first use)"
OUT="$(t_timeout 120 "$REPO_DIR/bin/claude-token-saver" \
        -p "Reply with exactly one word: pong" 2>"$TOKEN_SAVER_HOME/claude.err")" \
    || { t_log "claude stderr:"; tail -20 "$TOKEN_SAVER_HOME/claude.err" >&2; \
         t_fail "claude-token-saver exited non-zero"; }

echo "$OUT" | grep -q "$MOCK_MARKER" \
    || { tail -20 "$TOKEN_SAVER_HOME/claude.err" >&2; \
         t_fail "claude output missing mock marker — traffic did not reach mock. Output: $OUT"; }

[ -s "$MOCK_LOG" ] || t_fail "mock upstream never received a request"
grep -q '/v1/messages' "$MOCK_LOG" \
    || t_fail "mock did not receive an Anthropic /v1/messages request"

STATS="$(curl -fsS "http://127.0.0.1:$TOKEN_SAVER_HEADROOM_PORT/stats" || true)"
echo "$STATS" | grep -qE '"(total_)?requests"[: ]*[1-9]' \
    || t_log "WARN: could not confirm request count in headroom stats: $STATS"

t_pass "test-claude-token-saver"
