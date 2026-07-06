# token-saver-wrappers

Token-saving wrappers for AI coding harnesses. `pi-token-saver` and
`hermes-token-saver` behave exactly like `pi` and `hermes`, except every LLM
API request passes through a local [headroom](https://github.com/chopratejas/headroom)
compression proxy — **without touching either tool's configuration**. Headroom
compresses tool outputs / context before they reach the provider (and keeps a
local reversible cache), typically cutting token spend significantly.

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

Requirements: `podman` (rootless, with `uidmap` installed), `python3`, `curl`,
and the system-installed `pi` / `hermes` commands.

## How it works

Both wrappers ensure a shared podman pod (`token-saver`) is running, then exec
the real command with environment-only overrides. The pod stays up after the
session ends (stop it with `token-saver-ctl stop`).

```
pod "token-saver"
├── headroom   127.0.0.1:8787  (built from vendor/headroom-src.tar.gz)
└── mitm       127.0.0.1:8790  (mitmproxy sidecar, used by pi only)
```

### hermes-token-saver

hermes honors per-provider base-URL env vars, so the wrapper simply sets
`DEEPSEEK_BASE_URL=http://127.0.0.1:8787/v1`. That covers direct deepseek use,
the `moa` aggregator, and hermes's auxiliary LLM calls. Headroom forwards to
its configured OpenAI-dialect upstream (`api.deepseek.com` by default) and
passes your API key through without storing it. Currently only the deepseek
provider is routed; other providers work normally, just uncompressed.

### pi-token-saver

pi has no base-URL overrides, so the wrapper uses pi's `HTTPS_PROXY` support:

1. It regenerates an intercept-host list from pi's built-in
   openai-completions provider endpoints plus every `baseUrl` in your
   `~/.pi/agent/models.json` (loopback hosts excluded).
2. The mitmproxy sidecar TLS-intercepts **only** those hosts (everything else
   is tunneled untouched, no TLS termination). pi trusts the locally generated
   CA via `NODE_EXTRA_CA_CERTS` — nothing is installed system-wide.
3. The addon rewrites `…/chat/completions` requests to headroom, carrying the
   real upstream in `x-headroom-base-url` / `x-headroom-original-path` headers,
   so one headroom instance serves any number of providers. Non-LLM paths on
   intercepted hosts (e.g. `/models`) pass through unmodified.

Caveat: `HTTPS_PROXY` is inherited by subprocesses pi spawns (that's what makes
pi's own subagents work), so a `curl https://api.deepseek.com/...` run inside a
pi bash tool would also be intercepted and would need `--cacert` to verify.

## Commands

```sh
pi-token-saver [any pi args...]
hermes-token-saver [any hermes args...]
token-saver-ctl status|start|stop|restart|destroy|logs [mitm]|stats
```

`token-saver-ctl stats` shows headroom's token-savings counters. The dashboard
is at http://127.0.0.1:8787/dashboard while the pod runs.

## Configuration (env vars)

| Variable | Default | Meaning |
|---|---|---|
| `TOKEN_SAVER_HOME` | `~/.local/share/token-saver` | state dir (CA, workspace, libs) |
| `TOKEN_SAVER_POD_NAME` | `token-saver` | podman pod name |
| `TOKEN_SAVER_HEADROOM_PORT` | `8787` | headroom host port (127.0.0.1) |
| `TOKEN_SAVER_MITM_PORT` | `8790` | mitm sidecar host port (127.0.0.1) |
| `TOKEN_SAVER_OPENAI_UPSTREAM` | `https://api.deepseek.com` | default upstream for requests without `x-headroom-base-url` (hermes traffic) |
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
