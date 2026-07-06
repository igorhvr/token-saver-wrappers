# tests/lib.sh — shared test harness. Creates a fully isolated token-saver
# environment (own TOKEN_SAVER_HOME, pod name, ports) so tests never touch the
# user's real pod, config, or ~/.pi / ~/.hermes.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"

# Must live under $HOME: podman on macOS only bind-mounts the user's home dir
# into its VM, so container volume mounts under /tmp (or /var/folders) fail.
export TOKEN_SAVER_HOME="$(mktemp -d "$HOME/.token-saver-test.XXXXXX")"
export TOKEN_SAVER_POD_NAME="token-saver-test"
export TOKEN_SAVER_HEADROOM_PORT=18787
export TOKEN_SAVER_MITM_PORT=18790
MOCK_PORT=18099
MOCK_LOG="$TOKEN_SAVER_HOME/mock-requests.jsonl"
MOCK_PID=""
# Containers reach the host (where the mock runs) via this name; podman adds
# it to /etc/hosts inside every container.
MOCK_HOST="host.containers.internal:$MOCK_PORT"
MOCK_MARKER="TOKEN_SAVER_MOCK_REPLY_7391"

# Portable timeout: GNU `timeout`, Homebrew `gtimeout`, else a shell fallback
# (macOS ships no `timeout`). Usage: t_timeout SECONDS cmd args...
t_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        "$@" &
        local cmd_pid=$!
        ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) &
        local killer=$!
        local rc=0
        wait "$cmd_pid" 2>/dev/null || rc=$?
        kill -TERM "$killer" 2>/dev/null || true
        wait "$killer" 2>/dev/null || true
        return "$rc"
    fi
}

t_log()  { printf '\033[1;34m[test]\033[0m %s\n' "$*" >&2; }
t_pass() { printf '\033[1;32m[PASS]\033[0m %s\n' "$*" >&2; }
t_fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

t_install_libs() {
    mkdir -p "$TOKEN_SAVER_HOME/lib"
    cp "$REPO_DIR"/lib/*.sh "$REPO_DIR"/lib/*.py "$TOKEN_SAVER_HOME/lib/"
}

t_start_mock() {
    python3 "$TESTS_DIR/mock_upstream.py" "$MOCK_PORT" "$MOCK_LOG" &
    MOCK_PID=$!
    for _ in $(seq 1 20); do
        curl -fsS -o /dev/null "http://127.0.0.1:$MOCK_PORT/" 2>/dev/null && return 0
        sleep 0.5
    done
    t_fail "mock upstream did not start on port $MOCK_PORT"
}

t_cleanup() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
    podman pod rm -f "$TOKEN_SAVER_POD_NAME" >/dev/null 2>&1 || true
    rm -rf "$TOKEN_SAVER_HOME"
}
trap t_cleanup EXIT

# Remove any stale test pod left by a previously interrupted run so its port
# bindings are freed before we create ours.
podman pod rm -f "$TOKEN_SAVER_POD_NAME" >/dev/null 2>&1 || true
