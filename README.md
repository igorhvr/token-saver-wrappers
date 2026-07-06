# token-saver-wrappers

Token-saving wrappers for AI coding harnesses. `pi-token-saver`,
`hermes-token-saver`, `claude-token-saver`, and `codex-token-saver` behave
exactly like `pi`, `hermes`, `claude` (Claude Code), and `codex` (OpenAI
Codex), except every LLM API request passes through a local
[headroom](https://github.com/chopratejas/headroom) compression proxy —
**without touching any tool's real configuration**. Headroom compresses tool
outputs / context before they reach the provider (and keeps a local reversible
cache), typically cutting token spend significantly.

The exact headroom version used is vendored as a source tarball in
`vendor/headroom-src.tar.gz` (commit in `vendor/HEADROOM_COMMIT`) and built
into a local container image.

## Install

```sh
./build-and-install
```

This builds `localhost/headroom-token-saver:<commit>` from the vendored
tarball (first build compiles Rust — expect 10–30+ minutes), pulls the pinned
mitmproxy sidecar image, installs runtime libs to `~/.local/share/token-saver/`
and the commands `pi-token-saver`, `hermes-token-saver`, `token-saver-ctl` to
`~/.local/bin/`.

Requirements: `podman`, `python3`, `curl`, and whichever of the wrapped
commands you use (`pi`, `hermes`, `claude`, `codex`).
- **Linux:** rootless podman with `uidmap` installed (`sudo apt-get install -y
  uidmap`). On ZFS, also `fuse-overlayfs`. `build-and-install` checks for these.
- **macOS:** podman via Homebrew. `build-and-install` creates and starts a
  `podman machine` VM automatically if one isn't running. Behind a
  TLS-intercepting corporate proxy (e.g. a corporate TLS-inspecting proxy), it also prefetches the
  ONNX Runtime and trusts the corporate CA in the build (see below).

### Corporate TLS-intercepting proxies

Some networks (e.g. a corporate TLS-inspecting proxy) MITM outbound HTTPS. This breaks two
build-time downloads that don't use the system trust store: rustup's installer
and `ort`'s ONNX Runtime fetch. On macOS `build-and-install` handles both
automatically — it trusts the corporate CA (from the System keychain) inside
the build container and prefetches the ONNX Runtime on the host (which already
trusts the CA). On Linux behind such a proxy, pass `TOKEN_SAVER_CORP_CA=<pem>`
and `TOKEN_SAVER_ORT_PREFETCH=1`. Runtime LLM traffic is unaffected as long as
the provider endpoint isn't itself MITM'd.

## How it works

Both wrappers ensure a shared podman pod (`token-saver`) is running, then exec
the real command with environment-only overrides. The pod stays up after the
session ends (stop it with `token-saver-ctl stop`).

```
pod "token-saver"
├── headroom   127.0.0.1:8787  (built from vendor/headroom-src.tar.gz)
└── mitm       127.0.0.1:8790  (mitmproxy sidecar)
```

Both wrappers use the **same mechanism**: a mitmproxy sidecar intercepts the
known LLM API hosts and rewrites OpenAI-style `…/chat/completions` requests to
headroom, which compresses and forwards to the real upstream — preserving your
API key and any custom auth headers. This is provider-agnostic: it works with
built-in providers (deepseek, openrouter, …) and with **custom endpoints**
(e.g. an internal GenAI platform configured via `baseUrl`/`base_url`) alike.

1. On each launch the wrapper regenerates an intercept-host list from the
   built-in openai-completions provider endpoints plus the hosts found in the
   tool's own config — `~/.pi/agent/models.json` for pi, `~/.hermes/config.yaml`
   for hermes (loopback hosts excluded).
2. mitmproxy TLS-intercepts **only** those hosts; every other host is tunneled
   untouched (no TLS termination). The locally generated mitm CA is trusted per
   process via env only — nothing is installed system-wide.
3. The addon rewrites `…/chat/completions` (any base path) to headroom,
   carrying the real upstream in `x-headroom-base-url` / `x-headroom-original-
   path` headers, so one headroom instance serves any number of providers.
   Non-LLM paths on intercepted hosts (e.g. `/models`) pass through unmodified.

### pi-token-saver

Sets `HTTP(S)_PROXY` to the mitm sidecar and `NODE_EXTRA_CA_CERTS` to the mitm
CA (Node appends it to the system roots). pi routes all provider SDK traffic
through the global undici proxy dispatcher, so this covers every
openai-completions provider and pi's spawned subagents.

### hermes-token-saver

Sets `HTTP(S)_PROXY`/`ALL_PROXY` to the mitm sidecar. hermes builds an SSL
context from `HERMES_CA_BUNDLE`/`SSL_CERT_FILE` that *replaces* the system
roots, so the wrapper points those (and `REQUESTS_CA_BUNDLE`/`CURL_CA_BUNDLE`)
at a combined bundle = system roots + any corporate bundle + mitm CA, sourced
from hermes's own `certifi`. This covers the main model client, moa
members/aggregator, and auxiliary calls in one shot.

Some hermes builds (e.g. the `custom-hermes-fork` fork behind a corporate-proxy-style
corporate proxy) pin `SSL_CERT_FILE` to their own corporate CA bundle in
`$HERMES_HOME/.env`, which is loaded *after* our environment and so overrides
it. When the wrapper detects such a pinned bundle it adds the mitm CA into that
file inside a clearly-marked, idempotent block — the only way to reach hermes's
default clients — never removing the user's certs. `token-saver-ctl destroy`
removes that block again.

Caveats:
- `HTTP(S)_PROXY` is inherited by subprocesses the tools spawn (that's what
  makes their own subagents route correctly), so a `curl https://…` run inside
  a bash tool is also intercepted and would need `--cacert` to verify.
- Endpoints on `localhost`/`127.0.0.1` are intentionally **not** intercepted
  (excluded from the host list and via `NO_PROXY`); a local model server is
  used directly, uncompressed.

### claude-token-saver

Claude Code natively honors `ANTHROPIC_BASE_URL`, so the wrapper just points it
at headroom (which speaks the Anthropic Messages API and forwards to
`api.anthropic.com`). No mitm sidecar or CA trust needed — same mechanism as
`headroom wrap claude`. The API key / OAuth token is passed through untouched.

### codex-token-saver

Codex only honors a base-URL override from `config.toml`, not env vars. Editing
the real `~/.codex` would also redirect a plain `codex`, so the wrapper builds a
**shadow config dir** (via `CODEX_HOME`): every entry of the real dir is
symlinked — history, sessions, auth, memories, skills are all preserved and
written back — and only `config.toml` is replaced with a transformed copy
(`lib/codex_shadow_config.py`). The real `~/.codex` is never modified. Two
shapes are handled:

- **Built-in openai / ChatGPT subscription:** set the top-level
  `openai_base_url` to headroom. Headroom's `/backend-api/codex/*` routes handle
  the ChatGPT backend.
- **Custom provider** (`model_provider = "…"` with its own `base_url`, e.g. an
  internal GenAI platform on the Responses API): point that provider's
  `base_url` at headroom and inject `x-headroom-base-url` /
  `x-headroom-original-path` headers so headroom forwards to the real endpoint
  at the exact path, preserving the provider's auth (`env_key`) and headers.

## Commands

```sh
pi-token-saver     [any pi args...]
hermes-token-saver [any hermes args...]
claude-token-saver [any claude args...]
codex-token-saver  [any codex args...]
token-saver-ctl    status|start|stop|restart|destroy|logs [mitm]|stats [--full-raw-json]
```

`token-saver-ctl stats` prints a readable token-savings summary (add
`--full-raw-json` for the raw payload). The headroom dashboard is at
http://127.0.0.1:<port>/dashboard while the pod runs (the port is shown by
`token-saver-ctl status`).

## Configuration (env vars)

| Variable | Default | Meaning |
|---|---|---|
| `TOKEN_SAVER_HOME` | `~/.local/share/token-saver` | state dir (CA, workspace, libs) |
| `TOKEN_SAVER_POD_NAME` | `token-saver` | podman pod name |
| `TOKEN_SAVER_HEADROOM_PORT` | `8787` | headroom host port (127.0.0.1) |
| `TOKEN_SAVER_MITM_PORT` | `8790` | mitm sidecar host port (127.0.0.1) |
| `TOKEN_SAVER_OPENAI_UPSTREAM` | `https://api.deepseek.com` | fallback upstream for OpenAI requests that lack an `x-headroom-base-url` header (normal traffic always carries one) |
| `TOKEN_SAVER_PI_BIN` / `TOKEN_SAVER_HERMES_BIN` | from `PATH` | real binary to exec |

Port/upstream changes take effect on pod (re)creation: `token-saver-ctl destroy`
then rerun a wrapper.

## Tests

```sh
tests/run-tests.sh
```

Fully isolated (own pod name, ports, temp `TOKEN_SAVER_HOME`, temp
`PI_CODING_AGENT_DIR`/`HERMES_HOME`); never touches your real config; spends no
real tokens — a mock OpenAI-compatible upstream on the host is reached from the
pod via `host.containers.internal`.

## Updating the vendored headroom

```sh
git -C ~/idm/headroom rev-parse HEAD > vendor/HEADROOM_COMMIT
git -C ~/idm/headroom archive --format=tar.gz --prefix=headroom/ \
    -o vendor/headroom-src.tar.gz HEAD
./build-and-install   # builds the new image tag
```

The built-in pi provider host list in `lib/gen_intercept_hosts.py` was
extracted from pi's `packages/ai/src/providers/*.ts` (api ==
"openai-completions"); refresh it when pi adds providers.
