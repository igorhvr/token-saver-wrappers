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

# Per-model stats: cost.per_model with 2+ models → no Model: line, per-model tables appear.
STATS_PM='{"summary":{"api_requests":8,
 "compression":{"requests_compressed":6,"total_tokens_removed":152,"total_tokens_before_with_cli_filtering":63241},
 "uncompressed_requests":{"prefix_frozen":1,"no_compressible_content":1},
 "cost":{"total_saved_usd":0.0,"savings_pct":0.0,
  "per_model":{
   "gpt-5.5":{"requests":4,"tokens_sent":43520,"tokens_saved":152,"reduction_pct":0.3},
   "deepseek-v4-pro":{"requests":3,"tokens_sent":17376,"tokens_saved":0,"reduction_pct":0.0}
  }}}}'
OUT_PM="$(printf '%s' "$STATS_PM" | python3 "$FMT")"
# Model: line must be absent when per_model is present.
echo "$OUT_PM" | grep -q "Model:"                    && t_fail "Model: line should be absent when per_model present"
# Per-model section header.
echo "$OUT_PM" | grep -q "Per-model:"                 || t_fail "Per-model section missing"
# Both models appear.
echo "$OUT_PM" | grep -q "gpt-5.5"                     || t_fail "gpt-5.5 missing from per-model output"
echo "$OUT_PM" | grep -q "deepseek-v4-pro"            || t_fail "deepseek-v4-pro missing from per-model output"
# Model stats rendered.
echo "$OUT_PM" | grep -q "4 requests"                                          || t_fail "gpt-5.5 request count missing"
echo "$OUT_PM" | grep -q "43,520 input tokens"                                 || t_fail "gpt-5.5 input tokens missing"
echo "$OUT_PM" | grep -q "152 tokens saved (0.3%)"                             || t_fail "gpt-5.5 tokens saved missing"
echo "$OUT_PM" | grep -q "3 requests"                                          || t_fail "deepseek-v4-pro request count missing"
echo "$OUT_PM" | grep -q "17,376 input tokens"                                 || t_fail "deepseek-v4-pro input tokens missing"
echo "$OUT_PM" | grep -q "0 tokens saved (0.0%)"                               || t_fail "deepseek-v4-pro tokens saved missing"
# gpt-5.5 (4 requests) must appear before deepseek-v4-pro (3 requests) — descending sort.
GPT_IDX=$(echo "$OUT_PM" | grep -n "gpt-5.5" | head -1 | cut -d: -f1)
DS_IDX=$(echo "$OUT_PM" | grep -n "deepseek-v4-pro" | head -1 | cut -d: -f1)
[ "$GPT_IDX" -lt "$DS_IDX" ]                          || t_fail "per-model not sorted by request count descending"

# Per-model with missing or partial fields: must not crash.
STATS_PARTIAL='{"summary":{"api_requests":2,"cost":{"per_model":{"m1":{"requests":1,"tokens_sent":500}}}}}'
OUT_PARTIAL="$(printf '%s' "$STATS_PARTIAL" | python3 "$FMT")"
echo "$OUT_PARTIAL" | grep -q "Per-model:"             || t_fail "per-model section missing with partial fields"
echo "$OUT_PARTIAL" | grep -q "m1"                                              || t_fail "model m1 missing with partial fields"
echo "$OUT_PARTIAL" | grep -q "1 requests"                                      || t_fail "requests missing with partial fields"
echo "$OUT_PARTIAL" | grep -q "500 input tokens"                                || t_fail "input tokens missing with partial fields"
echo "$OUT_PARTIAL" | grep -q "0 tokens saved"                                  || t_fail "tokens_saved default missing"
echo "$OUT_PARTIAL" | grep -q "(0.0%)"                                          || t_fail "reduction_pct default missing"

# Empty per_model: fallback — Model: line still shown.
STATS_EMPTY_PM='{"summary":{"api_requests":2,"primary_model":"fallback","cost":{"per_model":{}}}}'
OUT_EMPTY_PM="$(printf '%s' "$STATS_EMPTY_PM" | python3 "$FMT")"
echo "$OUT_EMPTY_PM" | grep -q "Model:"               || t_fail "Model: line should appear when per_model is empty"
echo "$OUT_EMPTY_PM" | grep -q "fallback"              || t_fail "fallback model missing"
echo "$OUT_EMPTY_PM" | grep -q "Per-model:"            && t_fail "Per-model: should not appear when per_model is empty"

printf '\033[1;32m[PASS]\033[0m test-format-stats\n' >&2
