"""Generate the mitmproxy intercept-host list for the token-saver wrappers.

Prints one host (or host:port for non-default ports) per line: the built-in
openai-completions provider endpoints plus every provider/model baseUrl found
in the config files passed as arguments. Loopback hosts are excluded (they are
covered by NO_PROXY and must never be re-routed into the pod).

Each argument is a config file:
  *.json  — a pi models.json (providers[].baseUrl + providers[].models[].baseUrl)
  *.yaml/*.yml — a hermes config.yaml (any base_url: value; scanned as URLs)

Usage: python3 gen_intercept_hosts.py [config-file ...]
"""

from __future__ import annotations

import json
import re
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

LOOPBACK = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}
DEFAULT_PORTS = {"http": 80, "https": 443}
_URL_RE = re.compile(r"https?://[^\s\"'`]+", re.IGNORECASE)


def host_of(base_url: str) -> str | None:
    try:
        parts = urlsplit(base_url.strip())
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


def _json_hosts(path: str) -> set[str]:
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


def _yaml_hosts(path: str) -> set[str]:
    # No YAML parser in the stdlib; hermes endpoints are plain URL scalars, so
    # scan the file text for http(s) URLs (base_url:, default_headers, etc.).
    hosts: set[str] = set()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return hosts
    for match in _URL_RE.findall(text):
        h = host_of(match.rstrip("\"'`,"))
        if h:
            hosts.add(h)
    return hosts


def config_hosts(path: str) -> set[str]:
    lower = path.lower()
    if lower.endswith(".json"):
        return _json_hosts(path)
    if lower.endswith((".yaml", ".yml")):
        return _yaml_hosts(path)
    return set()


def main() -> None:
    hosts = set(BUILTIN_HOSTS)
    for path in sys.argv[1:]:
        hosts |= config_hosts(path)
    print("\n".join(sorted(hosts)))


if __name__ == "__main__":
    main()
