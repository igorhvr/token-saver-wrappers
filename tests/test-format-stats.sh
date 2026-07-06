#!/usr/bin/env bash
# Unit test for lib/format_stats.py — no containers needed.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
FMT="$REPO_DIR/lib/format_stats.py"

t_fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STATS='{"summary":{"mode":"token","api_requests":18,"primary_model":"deepseek-v4-pro-official",
 "compression":{"requests_compressed":5,"best_detail":"24,760 → 24,638 tokens",
   "total_tokens_removed":511,"total_tokens_before_with_cli_filtering":620813},
 "uncompressed_requests":{"prefix_frozen":8,"no_compressible_content":5},
 "cost":{"total_saved_usd":0.0,"savings_pct":0.0}}}'

# Real-shaped input: summary numbers + computed percentage must appear.
OUT="$(printf '%s' "$STATS" | python3 "$FMT")"
echo "$OUT" | grep -q "deepseek-v4-pro-official"     || t_fail "model missing"
echo "$OUT" | grep -q "620,813"                       || t_fail "input tokens not formatted"
echo "$OUT" | grep -q "511  (0.08%)"                  || t_fail "saved tokens/percent wrong: $OUT"
echo "$OUT" | grep -q "24,760 → 24,638"               || t_fail "best-detail missing"
echo "$OUT" | grep -qi "Minimal compression"          || t_fail "low-savings note missing"

# With a /stats-history file: lifetime line appears.
echo '{"lifetime":{"requests":25,"tokens_saved":511,"total_input_tokens":693575}}' > "$TMP/hist.json"
OUT2="$(printf '%s' "$STATS" | python3 "$FMT" "$TMP/hist.json")"
echo "$OUT2" | grep -q "Lifetime saved"               || t_fail "lifetime line missing"
echo "$OUT2" | grep -q "693,575"                       || t_fail "lifetime total missing"

# Zero requests: friendly note, no crash.
OUT3="$(echo '{"summary":{"api_requests":0}}' | python3 "$FMT")"
echo "$OUT3" | grep -qi "No requests proxied yet"     || t_fail "empty-state note missing"

# Garbage input: non-zero exit, clear stderr.
if echo 'not json' | python3 "$FMT" >/dev/null 2>"$TMP/err"; then
    t_fail "garbage input should exit non-zero"
fi
grep -qi "could not parse" "$TMP/err"                 || t_fail "garbage input error message missing"

printf '\033[1;32m[PASS]\033[0m test-format-stats\n' >&2
