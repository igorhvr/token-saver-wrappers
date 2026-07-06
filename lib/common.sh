# common.sh — shared library for token-saver wrappers.
# Sourced by pi-token-saver, hermes-token-saver, token-saver-ctl.
# All settings are overridable via TOKEN_SAVER_* environment variables.

set -euo pipefail

TOKEN_SAVER_HOME="${TOKEN_SAVER_HOME:-$HOME/.local/share/token-saver}"
TS_POD="${TOKEN_SAVER_POD_NAME:-token-saver}"
# Host ports: an explicit env override always wins; otherwise use the ports
# persisted for the current pod (ports.env), else the defaults. When the pod is
# (re)created and the defaults are busy — common, since headroom's own default
# is 8787 and a dev may already run one — ts_pick_free_ports shifts to a free
# pair and persists it. Inside the pod, headroom always listens on 8787.
TS_PORTS_FILE="$TOKEN_SAVER_HOME/ports.env"
[ -f "$TS_PORTS_FILE" ] && . "$TS_PORTS_FILE"
TS_HEADROOM_PORT="${TOKEN_SAVER_HEADROOM_PORT:-${TS_HEADROOM_PORT:-8787}}"
TS_MITM_PORT="${TOKEN_SAVER_MITM_PORT:-${TS_MITM_PORT:-8790}}"
TS_HEADROOM_INTERNAL_PORT=8787
# Default upstream for OpenAI-dialect requests that do NOT carry an
# x-headroom-base-url header (i.e. hermes traffic). pi traffic always carries
# the header, so this only affects hermes.
TS_OPENAI_UPSTREAM="${TOKEN_SAVER_OPENAI_UPSTREAM:-https://api.deepseek.com}"
# Upstream for Anthropic /v1/messages traffic (claude-token-saver). Claude Code
# points ANTHROPIC_BASE_URL straight at headroom, so its requests carry no
# per-host header — headroom forwards them here.
TS_ANTHROPIC_UPSTREAM="${TOKEN_SAVER_ANTHROPIC_UPSTREAM:-https://api.anthropic.com}"

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

# True (0) if a TCP listener is present on 127.0.0.1:$1.
ts_port_in_use() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    return 1
}

# Choose a free host port pair for a NEW pod and persist it so every later
# invocation (and token-saver-ctl) targets the same ports. An explicit env
# override is respected as-is (never shifted). Called only when creating a pod.
ts_pick_free_ports() {
    if [ -n "${TOKEN_SAVER_HEADROOM_PORT:-}" ] || [ -n "${TOKEN_SAVER_MITM_PORT:-}" ]; then
        return 0
    fi
    local h="$TS_HEADROOM_PORT" m="$TS_MITM_PORT"
    while ts_port_in_use "$h" || ts_port_in_use "$m"; do
        h=$((h + 2)); m=$((m + 2))
        [ "$h" -gt 8900 ] && ts_die "no free host port pair found near $TS_HEADROOM_PORT"
    done
    if [ "$h" != "$TS_HEADROOM_PORT" ]; then
        ts_log "ports $TS_HEADROOM_PORT/$TS_MITM_PORT busy; using $h/$m"
    fi
    TS_HEADROOM_PORT="$h"; TS_MITM_PORT="$m"
    mkdir -p "$TOKEN_SAVER_HOME"
    printf 'TS_HEADROOM_PORT=%s\nTS_MITM_PORT=%s\n' "$h" "$m" > "$TS_PORTS_FILE"
}

ts_pod_exists()      { podman pod exists "$TS_POD" 2>/dev/null; }

# The Anthropic upstream headroom forwards /v1/messages to is baked into the
# headroom container at creation (no per-request override exists for the
# Anthropic dialect). Echo the value the running container was created with.
ts_running_anthropic_target() {
    podman inspect "${TS_POD}-headroom" \
        --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n 's/^ANTHROPIC_TARGET_API_URL=//p' | head -1
}

# Ensure the pod's headroom container targets $TS_ANTHROPIC_UPSTREAM; if an
# existing pod was created with a different target, remove it so ts_ensure_pod
# recreates it correctly (volumes persist, so nothing is lost).
ts_require_anthropic_target() {
    ts_pod_exists || return 0
    [ "$(ts_running_anthropic_target)" = "$TS_ANTHROPIC_UPSTREAM" ] && return 0
    ts_log "anthropic upstream changed; recreating pod for $TS_ANTHROPIC_UPSTREAM"
    ts_podman pod rm -f "$TS_POD" >/dev/null 2>&1 || true
}
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
    ts_pick_free_ports
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
    # Mount at a top-level path and set HOME/workspace there. With
    # --userns=keep-id on macOS the container user is remapped to a uid that
    # cannot traverse the image's 0700 /home/<user>, and has no /etc/passwd
    # home, so default ~/.headroom paths are both unreachable and unwritable.
    # A top-level dir (parent "/" is world-traversable) sidesteps both.
    ts_podman run -d --pod "$TS_POD" --name "${TS_POD}-headroom" \
        --restart unless-stopped \
        -v "$TS_HEADROOM_DIR:/headroom-data" \
        -e "HOME=/headroom-data" \
        -e "HEADROOM_WORKSPACE_DIR=/headroom-data" \
        -e "HEADROOM_CONFIG_DIR=/headroom-data/config" \
        -e "OPENAI_TARGET_API_URL=$TS_OPENAI_UPSTREAM" \
        -e "ANTHROPIC_TARGET_API_URL=$TS_ANTHROPIC_UPSTREAM" \
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
    # Mount the confdir at a top-level path (not under the image's 0700
    # /home/mitmproxy, which the keep-id-remapped uid cannot traverse on
    # macOS) and pin mitmproxy's confdir to it, so the CA is written there and
    # is readable back on the host.
    ts_podman run -d --pod "$TS_POD" --name "${TS_POD}-mitm" \
        --restart unless-stopped \
        -v "$TS_MITM_DIR:/mitm-confdir" \
        -v "$TS_LIB_DIR/mitm_addon.py:/addon.py:ro" \
        -e "HOME=/mitm-confdir" \
        -e "INTERCEPT_HOSTS_FILE=/mitm-confdir/intercept-hosts.txt" \
        -e "HEADROOM_INTERNAL_PORT=$TS_HEADROOM_INTERNAL_PORT" \
        --entrypoint mitmdump \
        "$TS_MITM_IMAGE" \
        --listen-host 0.0.0.0 --listen-port "$TS_MITM_PORT" \
            -s /addon.py \
            --set confdir=/mitm-confdir \
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

# Regenerate the intercept-host list (built-in provider hosts + hosts found in
# the given config files) and restart mitm if it changed so it re-reads the
# list. Args: config files (pi models.json and/or hermes config.yaml).
ts_refresh_intercept_hosts() {
    mkdir -p "$TS_MITM_DIR"
    local new old
    new="$(python3 "$TS_LIB_DIR/gen_intercept_hosts.py" "$@")"
    old="$(cat "$TS_HOSTS_FILE" 2>/dev/null || true)"
    if [ "$new" != "$old" ]; then
        printf '%s\n' "$new" > "$TS_HOSTS_FILE"
        ts_restart_mitm  # no-op if mitm isn't running yet
    fi
}

# Marker delimiting the token-saver-managed mitm CA block we append to a CA
# bundle. Kept stable so the block can be refreshed/removed idempotently.
TS_CA_MARKER="# >>> token-saver mitm CA (managed) >>>"
TS_CA_MARKER_END="# <<< token-saver mitm CA (managed) <<<"

# Echo the CA bundle path(s) that hermes pins via $HERMES_HOME/.env
# (SSL_CERT_FILE / REQUESTS_CA_BUNDLE / CURL_CA_BUNDLE) plus a conventional
# $HERMES_HOME/cacerts.pem. These are corporate bundles (e.g. a corporate TLS-inspecting proxy) whose
# use hermes forces regardless of our env, so they are both what we must fold
# into our combined bundle AND where the mitm CA must be injected.
ts_hermes_ca_bundles() {
    local home="${HERMES_HOME:-$HOME/.hermes}" envf="${HERMES_HOME:-$HOME/.hermes}/.env" b
    if [ -f "$envf" ]; then
        grep -E '^(SSL_CERT_FILE|REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE)=' "$envf" 2>/dev/null \
            | sed -E 's/^[^=]+=//; s/^"//; s/"$//; s/^'\''//; s/'\''$//'
    fi
    [ -f "$home/cacerts.pem" ] && printf '%s\n' "$home/cacerts.pem"
}

# Build a CA bundle = system/certifi roots + any hermes corporate bundle(s) +
# the mitmproxy CA, written to $TS_MITM_DIR/combined-ca.pem. hermes's httpx
# verify path does ssl.create_default_context(cafile=...), which trusts ONLY
# the given file, so a bare mitm CA would break TLS for hosts mitm tunnels
# without terminating (real upstream cert) and for corporate-MITM'd hosts.
# Folding in the corporate bundle keeps all three working. $1 is an optional
# python interpreter to source certifi from.
ts_build_combined_ca() {
    local py="${1:-python3}" base="" out="$TS_MITM_DIR/combined-ca.pem" cand b
    for cand in \
        "$("$py" -c 'import certifi;print(certifi.where())' 2>/dev/null)" \
        /etc/ssl/cert.pem \
        /etc/ssl/certs/ca-certificates.crt \
        /opt/homebrew/etc/openssl@3/cert.pem \
        /usr/local/etc/openssl@3/cert.pem; do
        if [ -n "$cand" ] && [ -f "$cand" ]; then base="$cand"; break; fi
    done
    : > "$out"
    if [ -n "$base" ]; then
        cat "$base" >> "$out"
    else
        ts_log "WARN: no system CA bundle found; only mitm + corporate CAs trusted"
    fi
    # Fold in hermes's corporate bundle(s) so clients honoring our combined
    # bundle still trust corporate-MITM'd hosts.
    while IFS= read -r b; do
        b="${b/#\~/$HOME}"
        [ -n "$b" ] && [ -f "$b" ] && cat "$b" >> "$out"
    done < <(ts_hermes_ca_bundles | sort -u)
    cat "$TS_CA_CERT" >> "$out"
    printf '%s\n' "$out"
}

# Ensure the mitm CA is present in the CA bundle(s) hermes forces via its .env.
# hermes loads $HERMES_HOME/.env AFTER inheriting our environment and pins
# SSL_CERT_FILE there, so its default httpx clients verify against that bundle
# no matter what we export — the only way to make them trust the mitm proxy is
# to add the mitm CA to that file. We do it inside a marked, idempotent block
# (refreshed each run, never removing the user's certs) so it survives and can
# be cleaned up. No-op when the bundle already carries the current mitm CA.
ts_ensure_hermes_ca_trust() {
    local b mitm_line
    mitm_line="$(grep -m1 -v -e '-----' -e '^$' "$TS_CA_CERT" 2>/dev/null)"
    [ -n "$mitm_line" ] || return 0
    while IFS= read -r b; do
        b="${b/#\~/$HOME}"
        [ -n "$b" ] && [ -f "$b" ] && [ -w "$b" ] || continue
        # Current mitm CA already trusted (outside or inside our block)? skip.
        grep -qF "$mitm_line" "$b" 2>/dev/null && continue
        # Drop any stale managed block, then append the current mitm CA.
        local tmp; tmp="$(mktemp)"
        sed "/${TS_CA_MARKER}/,/${TS_CA_MARKER_END}/d" "$b" > "$tmp" 2>/dev/null || cp "$b" "$tmp"
        { printf '\n%s\n' "$TS_CA_MARKER"; cat "$TS_CA_CERT"; printf '%s\n' "$TS_CA_MARKER_END"; } >> "$tmp"
        cat "$tmp" > "$b" && rm -f "$tmp"
        ts_log "added mitm CA to hermes CA bundle $b"
    done < <(ts_hermes_ca_bundles | sort -u)
}

# Remove the token-saver-managed mitm CA block from any hermes CA bundle we
# modified. Called on teardown so we leave the user's bundles as we found them.
ts_remove_hermes_ca_trust() {
    local b
    while IFS= read -r b; do
        b="${b/#\~/$HOME}"
        [ -n "$b" ] && [ -f "$b" ] && [ -w "$b" ] || continue
        grep -qF "$TS_CA_MARKER" "$b" 2>/dev/null || continue
        local tmp; tmp="$(mktemp)"
        sed "/${TS_CA_MARKER}/,/${TS_CA_MARKER_END}/d" "$b" > "$tmp" && cat "$tmp" > "$b"
        rm -f "$tmp"
        ts_log "removed mitm CA from hermes CA bundle $b"
    done < <(ts_hermes_ca_bundles | sort -u)
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

# On macOS, podman runs containers in a VM that must be running first.
ts_ensure_machine() {
    [ "$(uname -s)" = "Darwin" ] || return 0
    podman machine inspect >/dev/null 2>&1 \
        || ts_die "no podman machine. Run build-and-install (or: podman machine init)."
    [ "$(podman machine inspect --format '{{.State}}' 2>/dev/null)" = "running" ] && return 0
    ts_log "starting podman machine"
    podman machine start >/dev/null 2>&1 \
        || ts_die "could not start podman machine (try: podman machine start)"
}

# Bring up the pod with the requested components. Usage: ts_ensure_pod [with-mitm]
ts_ensure_pod() {
    local with_mitm="${1:-}"
    ts_ensure_machine
    if ts_pod_exists; then
        # An existing pod may be stopped (after a reboot or `token-saver-ctl
        # stop`). Start the whole pod so its infra container comes up FIRST —
        # starting an individual app container while the pod infra is stopped
        # fails with "cannot get namespace path ... container is stopped". If
        # the pod is wedged in a partial/broken state, recreate it (the CA and
        # workspace live in host-mounted volumes, so nothing is lost).
        if ! ts_podman pod start "$TS_POD" >/dev/null 2>&1; then
            ts_log "pod $TS_POD would not start cleanly; recreating"
            ts_podman pod rm -f "$TS_POD" >/dev/null 2>&1 || true
            ts_create_pod
        fi
    else
        ts_create_pod
    fi
    ts_start_headroom
    [ "$with_mitm" = "with-mitm" ] && ts_start_mitm
    ts_wait_headroom_ready 180 \
        || ts_die "headroom did not become ready on 127.0.0.1:$TS_HEADROOM_PORT (podman logs ${TS_POD}-headroom)"
    if [ "$with_mitm" = "with-mitm" ]; then
        ts_wait_ca 30 || ts_die "mitmproxy CA was not generated at $TS_CA_CERT (podman logs ${TS_POD}-mitm)"
    fi
    return 0
}
