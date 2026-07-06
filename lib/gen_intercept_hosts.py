"""Generate the mitmproxy intercept-host list for pi-token-saver.

Prints one host (or host:port for non-default ports) per line: pi's built-in
openai-completions provider endpoints plus every provider/model baseUrl found
in the user's models.json. Loopback hosts are excluded (they are covered by
NO_PROXY and must never be re-routed into the pod).

Usage: python3 gen_intercept_hosts.py [path/to/models.json]
"""

from __future__ import annotations

import json
import sys
from urllib.parse import urlsplit

# Hosts of pi's built-in providers with api == "openai-completions".
# Extracted from pi's packages/ai/src/providers/*.ts (see README).
BUILTIN_HOSTS = [
    "api.ant-ling.com",
    "api.cerebras.ai",
    "api.deepseek.com",
    "api.fireworks.ai",
    "api.groq.com",
    "api.individual.githubcopilot.com",
    "api.moonshot.ai",
    "api.moonshot.cn",
    "api.together.ai",
    "api.x.ai",
    "api.xiaomimimo.com",
    "api.z.ai",
    "integrate.api.nvidia.com",
    "open.bigmodel.cn",
    "openrouter.ai",
    "router.huggingface.co",
    "token-plan-ams.xiaomimimo.com",
    "token-plan-cn.xiaomimimo.com",
    "token-plan-sgp.xiaomimimo.com",
]

LOOPBACK = {"localhost", "127.0.0.1", "::1"}
DEFAULT_PORTS = {"http": 80, "https": 443}


def host_of(base_url: str) -> str | None:
    try:
        parts = urlsplit(base_url)
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    host = parts.hostname.lower()
    if host in LOOPBACK:
        return None
    port = parts.port
    if port and port != DEFAULT_PORTS[parts.scheme]:
        return f"{host}:{port}"
    return host


def models_json_hosts(path: str) -> set[str]:
    hosts: set[str] = set()
    try:
        with open(path, encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, ValueError):
        return hosts
    providers = config.get("providers")
    if not isinstance(providers, dict):
        return hosts
    for pconf in providers.values():
        if not isinstance(pconf, dict):
            continue
        urls = [pconf.get("baseUrl")]
        models = pconf.get("models")
        if isinstance(models, list):
            urls += [m.get("baseUrl") for m in models if isinstance(m, dict)]
        for url in urls:
            if isinstance(url, str) and url:
                h = host_of(url)
                if h:
                    hosts.add(h)
    return hosts


def main() -> None:
    hosts = set(BUILTIN_HOSTS)
    if len(sys.argv) > 1:
        hosts |= models_json_hosts(sys.argv[1])
    print("\n".join(sorted(hosts)))


if __name__ == "__main__":
    main()
