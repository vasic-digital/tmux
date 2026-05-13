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
    # Capture original mode so we can restore exec bit after sed -i
    # (sed -i creates a new file with default mode 0600, dropping exec
    # permission — would cause downstream test pre-checks to FAIL as
    # "not executable" even though the script content is correct).
    local orig_mode
    orig_mode=$(stat -c '%a' "$target_abs" 2>/dev/null || stat -f '%Lp' "$target_abs" 2>/dev/null || echo "755")

    if ! eval "$mutate_cmd" 2>/dev/null; then
        cp "$backup" "$target_abs" 2>/dev/null || true
        chmod "$orig_mode" "$target_abs" 2>/dev/null || true
        rm -f "$backup" 2>/dev/null || true
        _skip "$desc: mutation command failed to apply"
        return
    fi
    chmod "$orig_mode" "$target_abs" 2>/dev/null || true
    if [ "${TMX_META_DEBUG:-0}" = "1" ]; then
        echo "  [debug] mutate_cmd: $mutate_cmd"
        echo "  [debug] target after mutate: mode=$(stat -c '%a' "$target_abs" 2>/dev/null) head: $(grep -E 'MemoryMax|MemMax' "$target_abs" | head -1)"
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
    chmod "$orig_mode" "$target_abs" 2>/dev/null || true
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

# ── M4: tmx wrapper — remove systemd-run --user --scope ─────────────
# Mutate: rename systemd-run in generated wrapper
# Test 09 T2.1 should SKIP (wrapper no longer contains systemd-run)
# Target priority: scripts/tmx-vm (Darwin install) > scripts/tmx (Linux).
# On Darwin host the scripts/tmx is the SSH bridge, not the wrapper —
# mutating it doesn't change what test 09 sees. test_vm.sh sets WRAPPER=
# scripts/tmx-vm so the mutation must target that file.
if [ -f "$REPO_ROOT/scripts/tmx-vm" ]; then
    M4_TARGET="scripts/tmx-vm"
elif [ -f "$REPO_ROOT/scripts/tmx" ]; then
    M4_TARGET="scripts/tmx"
else
    M4_TARGET=""
fi
if [ -n "$M4_TARGET" ]; then
    run_mutation \
        "M4: tmx wrapper remove systemd-run flag" \
        "$M4_TARGET" \
        "sed -i 's|systemd-run --user --scope|systemd-run-bogus --user --scope|' \"\$target_abs\"" \
        "sed -i 's|systemd-run-bogus --user --scope|systemd-run --user --scope|' \"\$target_abs\"" \
        "scripts/tests/09_crash_isolation_scope.sh" \
        "SKIP.*T2"
else
    _skip "M4: no wrapper present (neither scripts/tmx-vm nor scripts/tmx)"
fi

# ── M5: tmx wrapper — corrupt MemoryMax option name ─────────────────
# Mutate: rename "MemoryMax=" → "MemMax=" in the wrapper. Same target
# priority as M4 — must mutate the file that test 09 actually reads
# (scripts/tmx-vm on Darwin install, scripts/tmx on Linux).
if [ -n "$M4_TARGET" ]; then
    run_mutation \
        "M5: tmx wrapper corrupt MemoryMax" \
        "$M4_TARGET" \
        "sed -i 's|MemoryMax=|MemMax=|' \"\$target_abs\"" \
        "sed -i 's|MemMax=|MemoryMax=|' \"\$target_abs\"" \
        "scripts/tests/09_crash_isolation_scope.sh" \
        "FAIL.*T2"
else
    _skip "M5: no wrapper present"
fi

# ── M7: tmx-vm wrapper — re-introduce empty-SOCK early return in ────
#        _apply_host_color (the Fixed.md A10 bug). Mutation rewrites the
#        new code `[ -n "$sock" ] && target=(-S "$sock")` back to the
#        broken `[ -n "$sock" ] || return 0` so the wrapper silently bails
#        for the default-socket path. Test 11 T6 must FAIL.
#        Delimiter `#` chosen over `|` because the replacement contains
#        `||` which would collide with `|` as the sed s-command delimiter.
WRAPPER_PATH_VM="$REPO_ROOT/scripts/tmx-vm"
if [ -f "$WRAPPER_PATH_VM" ]; then
    run_mutation \
        "M7: re-introduce SOCK-empty early return" \
        "scripts/tmx-vm" \
        "sed -i 's#\\[ -n \"\$sock\" \\] && target=(-S \"\$sock\")#[ -n \"\$sock\" ] || return 0#g' \"\$target_abs\"" \
        "false" \
        "scripts/tests/11_hostname_color_integration.sh" \
        "FAIL.*T6"
else
    _skip "M7: scripts/tmx-vm not found — VM wrapper not yet generated (run setup.sh)"
fi

# ── M8: tmx-vm wrapper — hardcode bg=green in set status-style call. ─
#        Catches the case where the SET call fires but with a hardcoded
#        wrong colour. test 11 T4.1 (explicit-socket) and T6 (default-
#        socket) both compare against the deterministic hostname-derived
#        colour, so either path catches this mutation.
if [ -f "$WRAPPER_PATH_VM" ]; then
    run_mutation \
        "M8: hardcode bg=green in status-style" \
        "scripts/tmx-vm" \
        "sed -i 's|set -g status-style \"bg=\$color\"|set -g status-style \"bg=green\"|' \"\$target_abs\"" \
        "false" \
        "scripts/tests/11_hostname_color_integration.sh" \
        "FAIL.*T"
else
    _skip "M8: scripts/tmx-vm not found — VM wrapper not yet generated (run setup.sh)"
fi

# ── M6: hostname_color.sh — break determinism via $$ injection ──────
# Mutate: inject PID into hash after the loop so each invocation differs.
# Test 10 T1 (deterministic check — same hostname twice = same colour)
# should FAIL: two invocations of the algo are separate bash processes,
# so $$ differs, so the resulting colour differs.
# This closes the "same-host-same-color" invariant the user mandated:
# without this mutation, no explicit harness proved the algorithm could
# not be made non-deterministic.
# Revert via false → falls through to backup restore in run_mutation.
run_mutation \
    "M6: hostname_color non-deterministic via \$\$ injection" \
    "scripts/hostname_color.sh" \
    "sed -i 's|^done\$|done; h=\$\$|' \"\$target_abs\"" \
    "false" \
    "scripts/tests/10_hostname_color_algorithm.sh" \
    "FAIL.*T1"

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
