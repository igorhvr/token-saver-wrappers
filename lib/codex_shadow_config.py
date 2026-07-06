"""Transform a Codex config.toml so its active provider routes through headroom.

Reads the real config.toml on stdin, writes a shadow config.toml to stdout.
Two cases are handled:

1. Built-in "openai" provider / ChatGPT subscription — Codex only honors a
   base-URL override from the top-level ``openai_base_url`` key, so we set it.

2. A custom provider (``model_provider = "<name>"`` with a
   ``[model_providers.<name>]`` block that has its own ``base_url``, e.g. an
   internal GenAI platform) — we point that provider's ``base_url`` at headroom
   and inject ``x-headroom-base-url`` / ``x-headroom-original-path`` headers so
   headroom forwards to the real endpoint at the exact path (Codex's Responses
   or Chat wire path). The provider's own auth (``env_key``) and headers are
   preserved.

The user's config text is otherwise passed through verbatim (targeted line
edits only) so comments and unrelated settings are untouched. Only a few values
are needed, so a tiny regex fallback parser is used when ``tomllib`` is absent
(Python < 3.11), keeping the transform working everywhere.

Usage: python3 codex_shadow_config.py <headroom_port> < config.toml
"""

from __future__ import annotations

import re
import sys
from urllib.parse import urlsplit

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None


def _parse_inline_headers(raw: str) -> dict:
    return {k: v for k, v in re.findall(r'"([^"]+)"\s*=\s*"([^"]*)"', raw)}


def _active_provider(text: str):
    """Return (active_name, base_url, wire_api, headers_dict) for the config's
    active model_provider, or (None, None, None, {})."""
    if tomllib is not None:
        try:
            cfg = tomllib.loads(text)
            active = cfg.get("model_provider")
            prov = (cfg.get("model_providers", {}) or {}).get(active or "", {}) or {}
            return (active, prov.get("base_url"),
                    prov.get("wire_api"), prov.get("http_headers") or {})
        except (tomllib.TOMLDecodeError, ValueError):
            pass

    # Fallback: extract only what we need with line/regex scanning.
    active = None
    for line in text.splitlines():
        m = re.match(r'\s*model_provider\s*=\s*"([^"]+)"', line)
        if m:
            active = m.group(1)
            break
    if not active:
        return (None, None, None, {})
    base = wire = None
    headers: dict = {}
    in_section = False
    header = f"[model_providers.{active}]"
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_section = s == header
            continue
        if not in_section:
            continue
        mb = re.match(r'\s*base_url\s*=\s*"([^"]*)"', line)
        if mb:
            base = mb.group(1)
        mw = re.match(r'\s*wire_api\s*=\s*"([^"]*)"', line)
        if mw:
            wire = mw.group(1)
        if re.match(r'\s*http_headers\s*=', line):
            headers = _parse_inline_headers(line)
    return (active, base, wire, headers)


def _inline_headers(headers: dict) -> str:
    parts = [f'"{k}" = "{v}"' for k, v in headers.items()]
    return "http_headers = { " + ", ".join(parts) + " }"


def main() -> None:
    port = sys.argv[1]
    text = sys.stdin.read()
    hr = f"http://127.0.0.1:{port}/v1"

    active, prov_base, prov_wire, prov_headers = _active_provider(text)

    inject = None
    target_section = None
    if active and isinstance(prov_base, str) and not prov_base.startswith("http://127.0.0.1"):
        parsed = urlsplit(prov_base)
        wire = str(prov_wire or "chat").lower()
        suffix = "/responses" if wire == "responses" else "/chat/completions"
        inject = {
            "x-headroom-base-url": f"{parsed.scheme}://{parsed.netloc}",
            "x-headroom-original-path": parsed.path.rstrip("/") + suffix,
        }
        target_section = f"[model_providers.{active}]"

    out = [
        "# token-saver: route Codex through the local headroom proxy.",
        f'openai_base_url = "{hr}"',
        "",
    ]

    cur_section = None
    headers_done = False

    def _flush_headers_if_needed():
        nonlocal headers_done
        if target_section and cur_section == target_section and inject and not headers_done:
            merged = dict(prov_headers)
            merged.update(inject)
            out.append(_inline_headers(merged))
            headers_done = True

    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            _flush_headers_if_needed()
            cur_section = stripped
            out.append(line)
            continue
        if cur_section is None and stripped.startswith("openai_base_url"):
            continue  # drop existing top-level override; we set our own
        if target_section and cur_section == target_section and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key == "base_url":
                out.append(f'base_url = "{hr}"')
                continue
            if key == "http_headers":
                merged = dict(prov_headers)
                merged.update(inject or {})
                out.append(_inline_headers(merged))
                headers_done = True
                continue
        out.append(line)

    _flush_headers_if_needed()
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
