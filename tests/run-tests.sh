#!/usr/bin/env bash
# Run the token-saver test suite. Each test is a separate process with its own
# isolated pod/home (tests/lib.sh), run sequentially since they share the
# test pod name and ports.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILED=0
for t in test-hosts-gen.sh test-format-stats.sh test-warn-home.sh test-proxy-chain.sh \
         test-pi-token-saver.sh test-hermes-token-saver.sh \
         test-claude-token-saver.sh test-codex-token-saver.sh; do
    [ -f "$TESTS_DIR/$t" ] || continue
    echo "=== $t ==="
    if ! bash "$TESTS_DIR/$t"; then
        FAILED=1
    fi
done

if [ "$FAILED" = 1 ]; then
    echo "=== RESULT: FAILURES ==="
    exit 1
fi
echo "=== RESULT: ALL TESTS PASSED ==="
