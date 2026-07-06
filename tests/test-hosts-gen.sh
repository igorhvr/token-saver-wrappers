#!/usr/bin/env bash
# Unit test for lib/gen_intercept_hosts.py — no containers needed.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"

t_fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/models.json" <<'EOF'
{
  "providers": {
    "myllm": {
      "baseUrl": "https://llm.example.com:8443/api/v1",
      "api": "openai-completions",
      "apiKey": "k",
      "models": [
        {"id": "m1"},
        {"id": "m2", "baseUrl": "http://other.example.org/v1"}
      ]
    },
    "local-ollama": {
      "baseUrl": "http://127.0.0.1:11434/v1",
      "api": "openai-completions",
      "apiKey": "k",
      "models": [{"id": "m3"}]
    }
  }
}
EOF

OUT="$(python3 "$REPO_DIR/lib/gen_intercept_hosts.py" "$TMP/models.json")"

echo "$OUT" | grep -qx "llm.example.com:8443" || t_fail "custom provider host:port missing"
echo "$OUT" | grep -qx "other.example.org"    || t_fail "per-model baseUrl host missing"
echo "$OUT" | grep -qx "api.deepseek.com"     || t_fail "builtin host missing"
echo "$OUT" | grep -q  "127.0.0.1"            && t_fail "loopback host must be excluded"

# Missing models.json → builtins only, no crash
OUT2="$(python3 "$REPO_DIR/lib/gen_intercept_hosts.py" "$TMP/nonexistent.json")"
echo "$OUT2" | grep -qx "api.deepseek.com" || t_fail "builtins missing when models.json absent"

printf '\033[1;32m[PASS]\033[0m test-hosts-gen\n' >&2
