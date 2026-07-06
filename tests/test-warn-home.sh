#!/usr/bin/env bash
# Unit test for ts_warn_if_home — no containers needed.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"

t_fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# Isolated home so we don't depend on the real one, and a lib dir to source.
export TOKEN_SAVER_HOME="$(mktemp -d)"
export HOME="$(mktemp -d)"
trap 'rm -rf "$TOKEN_SAVER_HOME" "$HOME"' EXIT
mkdir -p "$TOKEN_SAVER_HOME/lib"
cp "$REPO_DIR"/lib/common.sh "$TOKEN_SAVER_HOME/lib/"

warn_from() {  # $1 = dir to run in; echoes stderr
    ( cd "$1" && bash -c '. "$TOKEN_SAVER_HOME/lib/common.sh"; ts_warn_if_home claude' 2>&1 )
}

# From $HOME → must warn.
OUT="$(warn_from "$HOME")"
echo "$OUT" | grep -qi "home directory"  || t_fail "no warning when run from \$HOME: $OUT"
echo "$OUT" | grep -qi "BYPASS"           || t_fail "warning missing bypass note: $OUT"

# From a non-home dir → must be silent.
SUB="$(mktemp -d)"; trap 'rm -rf "$SUB"' RETURN
OUT2="$(warn_from "$SUB")"
[ -z "$OUT2" ] || t_fail "unexpected warning from non-home dir: $OUT2"

# From a subdirectory of $HOME → must be silent (only $HOME itself warns).
mkdir -p "$HOME/proj"
OUT3="$(warn_from "$HOME/proj")"
[ -z "$OUT3" ] || t_fail "unexpected warning from a subdir of \$HOME: $OUT3"

printf '\033[1;32m[PASS]\033[0m test-warn-home\n' >&2
