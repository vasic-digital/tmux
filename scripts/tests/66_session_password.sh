#!/usr/bin/env bash
# Test 66 — per-session password protection (operator-path).
#
# Proves:
#   T1: tmx-state-bin set-password stores a hash (exit 0)
#   T2: tmx-state-bin verify-password accepts correct password (exit 0)
#   T3: tmx-state-bin verify-password rejects wrong password (exit 1)
#   T4: tmx-state-bin verify-password accepts any password when none set (exit 0)
#   T5: Empty password clears protection (verify-password accepts any → exit 0)
#
# Anti-bluff: every assertion is a binary exit code from the real tmx-state-bin,
# never a grep of stdout. §11.4.50: 3 iterations.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMX_STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"
SCRATCH="${TMPDIR:-/tmp}"

echo "── Test 66: per-session password protection ──"
PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

_cleanup() { rm -rf "$SCRATCH/tmx_t66_state_$$" 2>/dev/null || true; }
trap _cleanup EXIT

# §11.4.3 scratch preflight.
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 66: scratch root $SCRATCH not writable — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
rmdir "$_wtest" 2>/dev/null || true

# Binary must be present and executable.
if [ ! -x "$TMX_STATE_BIN" ]; then
    echo "SKIP 66: tmx-state-bin not present at $TMX_STATE_BIN"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi

export TMX_STATE_FILE="$SCRATCH/tmx_t66_state_$$_test.json"

_run_3_iters() {
    for _iter in 1 2 3; do
        # Clean state for each iteration.
        rm -f "$TMX_STATE_FILE" 2>/dev/null || true

        # T1: set-password stores a hash (exit 0).
        "$TMX_STATE_BIN" set-password "pwtest" "s3cret123" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 0 ]; then
            _pass "T1 iter=$_iter: set-password exit 0"
        else
            _fail "T1 iter=$_iter: set-password exit $rc (want 0)"
        fi

        # T2: verify-password accepts correct password (exit 0).
        "$TMX_STATE_BIN" verify-password "pwtest" "s3cret123" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 0 ]; then
            _pass "T2 iter=$_iter: verify-password correct → exit 0"
        else
            _fail "T2 iter=$_iter: verify-password correct → exit $rc (want 0)"
        fi

        # T3: verify-password rejects wrong password (exit 1).
        "$TMX_STATE_BIN" verify-password "pwtest" "wrong" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 1 ]; then
            _pass "T3 iter=$_iter: verify-password wrong → exit 1"
        else
            _fail "T3 iter=$_iter: verify-password wrong → exit $rc (want 1)"
        fi

        # T4: verify-password accepts any password when none set (exit 0).
        "$TMX_STATE_BIN" set-password "nopw" "" >/dev/null 2>&1
        "$TMX_STATE_BIN" verify-password "nopw" "anything" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 0 ]; then
            _pass "T4 iter=$_iter: no-password session → exit 0"
        else
            _fail "T4 iter=$_iter: no-password session → exit $rc (want 0)"
        fi

        # T5: empty password clears protection (verify-password accepts any → exit 0).
        "$TMX_STATE_BIN" set-password "pwtest" "s3cret123" >/dev/null 2>&1
        "$TMX_STATE_BIN" set-password "pwtest" "" >/dev/null 2>&1
        "$TMX_STATE_BIN" verify-password "pwtest" "any" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 0 ]; then
            _pass "T5 iter=$_iter: empty password clears → exit 0"
        else
            _fail "T5 iter=$_iter: empty password clears → exit $rc (want 0)"
        fi
    done
}

_run_3_iters

echo ""
echo "── Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
rm -f "$TMX_STATE_FILE" 2>/dev/null || true
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
