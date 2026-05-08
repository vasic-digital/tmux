#!/usr/bin/env bash
# meta_test_false_positive_proof.sh — §11.4.4 layer-4 paired-mutation harness.
#
# For each registered mutation:
#   1. Apply mutation  (break the feature)
#   2. Run the target test
#   3. Assert the test FAILs  (mutation correctly caught)
#   4. Revert mutation
#   5. Run the target test again
#   6. Assert the test PASSes  (feature restored)
#
# Constitution §1 anti-bluff: every PASS carries evidence that the
# mutation was applied and caught.
#
# Usage:  bash scripts/tests/meta_test_false_positive_proof.sh
#         SKIP if TMUX_BIN not built — tests 01-09/11-14 skipped gracefully.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"

MUT_PASS=0
MUT_FAIL=0
MUT_SKIP=0

echo "════════════════════════════════════════════════════════════════"
echo "  §11.4.4 meta-test paired-mutation harness"
echo "════════════════════════════════════════════════════════════════"

_pass() { echo "PASS: $*"; MUT_PASS=$((MUT_PASS + 1)); }
_fail() { echo "FAIL: $*"; MUT_FAIL=$((MUT_FAIL + 1)); }
_skip() { echo "SKIP: $*"; MUT_SKIP=$((MUT_SKIP + 1)); }

# ── run_mutation: apply, test-fail, revert, test-pass ─────────────────
# Usage: run_mutation <desc> <target_rel> <mutate_cmd> <revert_cmd> <test_rel> [expect_fail_regex]
run_mutation() {
    local desc="$1"
    local target="$2"
    local mutate_cmd="$3"
    local revert_cmd="$4"
    local test_script="$5"
    local expect_fail="${6:-FAIL}"

    local target_abs="$REPO_ROOT/$target"
    local test_abs="$REPO_ROOT/$test_script"
    local backup="${target_abs}.bak.meta"

    echo ""
    echo "--- MUTATION: $desc ---"

    # Pre-checks
    if [ ! -f "$target_abs" ]; then
        _skip "$desc: target file $target not found"
        return
    fi
    if [ ! -x "$test_abs" ] && [ ! -f "$test_abs" ]; then
        _skip "$desc: test script $test_script not found"
        return
    fi

    # If test requires TMUX_BIN and it's not available, skip
    if grep -q 'TMUX_BIN' "$test_abs" 2>/dev/null && [ ! -x "$TMUX_BIN" ]; then
        _skip "$desc: tmux binary not built — cannot run $test_script"
        return
    fi

    # ── Step 1: backup + apply mutation ──────────────────────────
    cp "$target_abs" "$backup" || { _skip "$desc: cannot backup $target"; return; }

    if ! eval "$mutate_cmd" 2>/dev/null; then
        cp "$backup" "$target_abs" 2>/dev/null || true
        rm -f "$backup" 2>/dev/null || true
        _skip "$desc: mutation command failed to apply"
        return
    fi

    # ── Step 2: run test — expect FAIL ───────────────────────────
    local test_out
    test_out=$(bash "$test_abs" 2>&1) || true
    local test_rc=$?

    if echo "$test_out" | grep -qE "$expect_fail"; then
        _pass "$desc MUTATION CAUGHT — test output contains '$expect_fail'"
    elif [ "$test_rc" -ne 0 ]; then
        _pass "$desc MUTATION CAUGHT — test exited $test_rc"
    else
        echo "  >>> WARNING: mutation DID NOT cause test failure <<<"
        echo "  >>> Test output: $(echo "$test_out" | head -5 | tr '\n' ';')"
        _fail "$desc MUTATION ESCAPED — test passed despite broken feature"
    fi

    # ── Step 3: revert ───────────────────────────────────────────
    eval "$revert_cmd" 2>/dev/null || {
        cp "$backup" "$target_abs" 2>/dev/null || true
    }
    rm -f "$backup" 2>/dev/null || true

    # ── Step 4: run test — expect PASS ───────────────────────────
    test_out=$(bash "$test_abs" 2>&1) || true
    test_rc=$?

    if echo "$test_out" | grep -qE '^PASS'; then
        _pass "$desc FEATURE RESTORED — test PASSes after revert"
    else
        echo "  >>> WARNING: test output after revert: $(echo "$test_out" | head -3 | tr '\n' ';')"
        _fail "$desc REVERT BROKEN — test did not PASS after revert"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# REGISTERED MUTATIONS
# ═══════════════════════════════════════════════════════════════════════

# ── M1: hostname_color.sh — break output format ──────────────────────
# Mutate: replace the echo line with invalid output
# Test 10 T2 should FAIL ("bogus-invalid" is not a valid colourNNN)
run_mutation \
    "M1: hostname_color output format" \
    "scripts/hostname_color.sh" \
    "sed -i 's|echo \"\${PALETTE\[\$idx\]}\"|echo \"bogus-invalid\"|' \"\$target_abs\"" \
    "sed -i 's|echo \"bogus-invalid\"|echo \"\${PALETTE\[\$idx\]}\"|' \"\$target_abs\"" \
    "scripts/tests/10_hostname_color_algorithm.sh" \
    "FAIL.*T2"

# ── M2: hostname_color.sh — force hash to zero ──────────────────────
# Mutate: set h=0 after hash loop (all hostnames → same colour)
# Test 10 T3 should FAIL (spread < 12/16)
run_mutation \
    "M2: hostname_color hash forced to zero" \
    "scripts/hostname_color.sh" \
    "sed -i 's|^done$|done; h=0|' \"\$target_abs\"" \
    "sed -i '/^done; h=0$/s//done/' \"\$target_abs\"" \
    "scripts/tests/10_hostname_color_algorithm.sh" \
    "FAIL.*T3"

# ── M3: hostname_color.sh — single-entry palette ────────────────────
# Mutate: replace multi-line palette with single entry
# Test 10 T4 should FAIL (colour not in truncated palette)
# Revert via false → falls through to backup restore in run_mutation
run_mutation \
    "M3: hostname_color single-entry palette" \
    "scripts/hostname_color.sh" \
    "sed -i '/^PALETTE=(/,/^)/c\PALETTE=(colour240)' \"\$target_abs\"" \
    "false" \
    "scripts/tests/10_hostname_color_algorithm.sh" \
    "FAIL.*T3"

# ── M4: tmx.template — remove systemd-run --user --scope ────────────
# Mutate: replace systemd-run invocation string
# Test 09 T2.1 should FAIL (wrapper no longer contains systemd-run)
# Only runs if tmx.template exists
if [ -f "$REPO_ROOT/scripts/tmx.template" ]; then
    run_mutation \
        "M4: tmx.template remove systemd-run flag" \
        "scripts/tmx.template" \
        "sed -i 's|systemd-run --user --scope|systemd-run-bogus --user --scope|' \"\$target_abs\"" \
        "sed -i 's|systemd-run-bogus --user --scope|systemd-run --user --scope|' \"\$target_abs\"" \
        "scripts/tests/09_crash_isolation_scope.sh" \
        "FAIL.*T2"
else
    _skip "M4: scripts/tmx.template not found — cannot test wrapper mutation"
fi

# ── M5: tmx.template — remove Delegate=yes invariant ────────────────
# Mutate: rename Delegate=yes to DelegateBogus=yes
# Test 09 T2.2 should FAIL (Delegate invariant missing)
# Uses timeout(1) to prevent systemd-run hangs on non-systemd hosts.
if [ -f "$REPO_ROOT/scripts/tmx.template" ]; then
    # Rewrite the mutation call as a script that applies timeout
    echo ""
    echo "--- MUTATION: M5: tmx.template remove Delegate=yes ---"
    TARGET_ABS5="$REPO_ROOT/scripts/tmx.template"
    BACKUP5="${TARGET_ABS5}.bak.meta"
    cp "$TARGET_ABS5" "$BACKUP5" 2>/dev/null || { _skip "M5: cannot backup"; }
    sed -i 's|Delegate=yes|DelegateBogus=yes|' "$TARGET_ABS5" 2>/dev/null || { _skip "M5: mutate failed"; cp "$BACKUP5" "$TARGET_ABS5"; rm -f "$BACKUP5"; }
    # Run test 09 with 20s timeout
    TEST_OUT5=$(timeout 20 bash "$REPO_ROOT/scripts/tests/09_crash_isolation_scope.sh" 2>&1) || true
    if echo "$TEST_OUT5" | grep -qE 'FAIL.*T2'; then
        _pass "M5: tmx.template Delegate mutation CAUGHT — test FAILs on T2"
    else
        echo "  >>> Output: $(echo "$TEST_OUT5" | head -10 | tr '\n' ';')"
        _fail "M5: Delegate mutation ESCAPED — T2 did not fail"
    fi
    # Revert
    sed -i 's|DelegateBogus=yes|Delegate=yes|' "$TARGET_ABS5" 2>/dev/null || true
    rm -f "$BACKUP5" 2>/dev/null || true
    TEST_OUT5=$(timeout 20 bash "$REPO_ROOT/scripts/tests/09_crash_isolation_scope.sh" 2>&1) || true
    if echo "$TEST_OUT5" | grep -qE '^PASS'; then
        _pass "M5: Delegate FEATURE RESTORED — test PASSes after revert"
    else
        echo "  >>> Output: $(echo "$TEST_OUT5" | head -5 | tr '\n' ';')"
        _fail "M5: REVERT BROKEN — test did not PASS after revert"
    fi
else
    _skip "M5: scripts/tmx.template not found"
fi

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  meta-test summary"
echo "════════════════════════════════════════════════════════════════"
echo "  MUTATIONS CAUGHT (PASS): $MUT_PASS"
echo "  MUTATIONS ESCAPED (FAIL): $MUT_FAIL"
echo "  MUTATIONS SKIPPED:       $MUT_SKIP"
echo ""
if [ "$MUT_FAIL" -gt 0 ]; then
    echo "  >>> $MUT_FAIL mutation(s) escaped detection — gates need hardening <<<"
    exit 1
fi
if [ "$MUT_PASS" -eq 0 ]; then
    echo "  >>> No mutations were tested — harness may need configuration <<<"
    exit 1
fi
echo "  GREEN: all tested mutations caught (layer 4 coverage active)"
exit 0
