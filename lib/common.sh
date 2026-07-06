# common.sh — shared library for token-saver wrappers.
# Sourced by pi-token-saver, hermes-token-saver, token-saver-ctl.
# All settings are overridable via TOKEN_SAVER_* environment variables.

set -euo pipefail

TOKEN_SAVER_HOME="${TOKEN_SAVER_HOME:-$HOME/.local/share/token-saver}"
TS_POD="${TOKEN_SAVER_POD_NAME:-token-saver}"
TS_HEADROOM_PORT="${TOKEN_SAVER_HEADROOM_PORT:-8787}"
TS_MITM_PORT="${TOKEN_SAVER_MITM_PORT:-8790}"
# Inside the pod all containers share one network namespace; headroom always
# listens on its container-default port there.
TS_HEADROOM_INTERNAL_PORT=8787
# Default upstream for OpenAI-dialect requests that do NOT carry an
# x-headroom-base-url header (i.e. hermes traffic). pi traffic always carries
# the header, so this only affects hermes.
TS_OPENAI_UPSTREAM="${TOKEN_SAVER_OPENAI_UPSTREAM:-https://api.deepseek.com}"

TS_HEADROOM_IMAGE="${TOKEN_SAVER_HEADROOM_IMAGE:-localhost/headroom-token-saver:latest}"
TS_MITM_IMAGE="${TOKEN_SAVER_MITM_IMAGE:-docker.io/mitmproxy/mitmproxy:12.1.2}"

TS_MITM_DIR="$TOKEN_SAVER_HOME/mitm"
TS_HEADROOM_DIR="$TOKEN_SAVER_HOME/headroom"
TS_LIB_DIR="$TOKEN_SAVER_HOME/lib"
TS_CA_CERT="$TS_MITM_DIR/mitmproxy-ca-cert.pem"
TS_HOSTS_FILE="$TS_MITM_DIR/intercept-hosts.txt"

ts_log() { printf '[token-saver] %s\n' "$*" >&2; }
ts_die() { ts_log "ERROR: $*"; exit 1; }

# Silence the podman cgroups-v1 deprecation warning without a lingering
# process-substitution child (which would keep an fd open across our exec).
export PODMAN_IGNORE_CGROUPSV1_WARNING=1
ts_podman() { podman "$@"; }

# ---------------------------------------------------------------------------
# Pod / container lifecycle
# ---------------------------------------------------------------------------

ts_pod_exists()      { podman pod exists "$TS_POD" 2>/dev/null; }
ts_container_runs()  { [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

ts_headroom_ready() {
    curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${TS_HEADROOM_PORT}/readyz" 2>/dev/null
}

ts_wait_headroom_ready() {
    local timeout="${1:-180}" waited=0
    while ! ts_headroom_ready; do
        waited=$((waited + 2))
        [ "$waited" -ge "$timeout" ] && return 1
        [ $((waited % 20)) -eq 0 ] && ts_log "waiting for headroom to become ready (${waited}s)..."
        sleep 2
    done
    return 0
}

ts_create_pod() {
    ts_log "creating pod $TS_POD (headroom on 127.0.0.1:$TS_HEADROOM_PORT, mitm on 127.0.0.1:$TS_MITM_PORT)"
    ts_podman pod create --name "$TS_POD" \
        --userns=keep-id \
        -p "127.0.0.1:${TS_HEADROOM_PORT}:${TS_HEADROOM_INTERNAL_PORT}" \
        -p "127.0.0.1:${TS_MITM_PORT}:${TS_MITM_PORT}" \
        >/dev/null
}

ts_start_headroom() {
    mkdir -p "$TS_HEADROOM_DIR"
    if podman container exists "${TS_POD}-headroom" 2>/dev/null; then
        ts_container_runs "${TS_POD}-headroom" && return 0
        ts_podman start "${TS_POD}-headroom" >/dev/null
        return 0
    fi
    podman image exists "$TS_HEADROOM_IMAGE" \
        || ts_die "headroom image $TS_HEADROOM_IMAGE not found. Run build-and-install first."
    ts_log "starting headroom container"
    ts_podman run -d --pod "$TS_POD" --name "${TS_POD}-headroom" \
        --restart unless-stopped \
        -v "$TS_HEADROOM_DIR:/home/nonroot/.headroom" \
        -e "OPENAI_TARGET_API_URL=$TS_OPENAI_UPSTREAM" \
        -e "HEADROOM_UPDATE_CHECK=off" \
        "$TS_HEADROOM_IMAGE" >/dev/null
}

ts_start_mitm() {
    mkdir -p "$TS_MITM_DIR"
    touch "$TS_HOSTS_FILE"
    if podman container exists "${TS_POD}-mitm" 2>/dev/null; then
        ts_container_runs "${TS_POD}-mitm" && return 0
        ts_podman start "${TS_POD}-mitm" >/dev/null
        return 0
    fi
    [ -f "$TS_LIB_DIR/mitm_addon.py" ] || ts_die "mitm addon missing at $TS_LIB_DIR/mitm_addon.py. Run build-and-install."
    ts_log "starting mitm container"
    ts_podman run -d --pod "$TS_POD" --name "${TS_POD}-mitm" \
        --restart unless-stopped \
        -v "$TS_MITM_DIR:/home/mitmproxy/.mitmproxy" \
        -v "$TS_LIB_DIR/mitm_addon.py:/addon.py:ro" \
        -e "HEADROOM_INTERNAL_PORT=$TS_HEADROOM_INTERNAL_PORT" \
        --entrypoint mitmdump \
        "$TS_MITM_IMAGE" \
        --listen-host 0.0.0.0 --listen-port "$TS_MITM_PORT" \
            -s /addon.py \
            --set connection_strategy=lazy \
            --set upstream_cert=false \
        >/dev/null
}

# Restart mitm so it re-reads the intercept-hosts file.
ts_restart_mitm() {
    if podman container exists "${TS_POD}-mitm" 2>/dev/null; then
        ts_podman restart -t 2 "${TS_POD}-mitm" >/dev/null
    fi
}

ts_wait_ca() {
    local timeout="${1:-30}" waited=0
    while [ ! -s "$TS_CA_CERT" ]; do
        waited=$((waited + 1))
        [ "$waited" -ge "$timeout" ] && return 1
        sleep 1
    done
    return 0
}

# Bring up the pod with the requested components. Usage: ts_ensure_pod [with-mitm]
ts_ensure_pod() {
    local with_mitm="${1:-}"
    ts_pod_exists || ts_create_pod
    ts_start_headroom
    [ "$with_mitm" = "with-mitm" ] && ts_start_mitm
    ts_wait_headroom_ready 180 \
        || ts_die "headroom did not become ready on 127.0.0.1:$TS_HEADROOM_PORT (podman logs ${TS_POD}-headroom)"
    if [ "$with_mitm" = "with-mitm" ]; then
        ts_wait_ca 30 || ts_die "mitmproxy CA was not generated at $TS_CA_CERT (podman logs ${TS_POD}-mitm)"
    fi
    return 0
}
