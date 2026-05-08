#!/usr/bin/env bash
# run_all.sh — execute all tmux validation tests in sequence.
# Reports PASS / FAIL / SKIP totals; exits non-zero on any FAIL.
#
# Classification: scans test output for ANY line beginning with PASS/FAIL/SKIP.
# Priority: FAIL > SKIP > PASS (a test that FAILs anywhere counts as FAIL even
# if a later line says PASS). This catches early-exit failures correctly AND
# multi-line SKIP messages that have trailing context lines.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
EXPECTED_VERSION="${EXPECTED_VERSION:-3.6a}"
export TMUX_BIN WRAPPER EXPECTED_VERSION

if [ ! -x "$TMUX_BIN" ]; then
    echo "ERROR: TMUX_BIN $TMUX_BIN not executable. Did you run build_tmux_containerized.sh?"
    exit 2
fi

PASS=0
FAIL=0
SKIP=0
FAIL_NAMES=""
SKIP_NAMES=""

echo "════════════════════════════════════════════════════════════════"
echo "  tmux validation suite (against $TMUX_BIN)"
echo "════════════════════════════════════════════════════════════════"

for t in "$REPO_ROOT/scripts/tests/"[0-9][0-9]_*.sh; do
    [ -f "$t" ] || continue
    name=$(basename "$t")
    echo ""
    out=$(bash "$t" 2>&1)
    echo "$out"
    # Classify: scan for first match of PASS/FAIL/SKIP at start of any line.
    # Priority: FAIL > SKIP > PASS.
    if echo "$out" | grep -qE '^FAIL'; then
        FAIL=$((FAIL+1)); FAIL_NAMES="$FAIL_NAMES $name"
    elif echo "$out" | grep -qE '^SKIP'; then
        SKIP=$((SKIP+1)); SKIP_NAMES="$SKIP_NAMES $name"
    elif echo "$out" | grep -qE '^PASS'; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1)); FAIL_NAMES="$FAIL_NAMES $name(unclassified)"
    fi
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  SUMMARY: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ -n "$SKIP_NAMES" ] && echo "  SKIPped:$SKIP_NAMES"
echo "════════════════════════════════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED tests:$FAIL_NAMES"
    exit 1
fi
exit 0
