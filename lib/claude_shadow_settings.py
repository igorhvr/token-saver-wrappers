"""Transform a Claude Code settings.json so it routes through headroom.

Reads the real settings.json on stdin, writes the shadow settings.json to
stdout with ``env.ANTHROPIC_BASE_URL`` set to the local headroom proxy. Claude
Code applies its settings ``env`` block over the inherited environment, so a
plain ANTHROPIC_BASE_URL env var can't override a settings.json that pins a
custom endpoint (e.g. an internal GenAI platform) — only editing the setting
does. Everything else (custom headers, model mappings, apiKeyHelper, hooks,
permissions) is preserved. Headroom forwards to the real endpoint, which the
wrapper configures as the pod's ANTHROPIC_TARGET.

Usage: python3 claude_shadow_settings.py <headroom_base_url> < settings.json
"""

from __future__ import annotations

import json
import sys


def main() -> None:
    base_url = sys.argv[1]
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    env = data.get("env")
    if not isinstance(env, dict):
        env = {}
    env["ANTHROPIC_BASE_URL"] = base_url
    data["env"] = env
    json.dump(data, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
