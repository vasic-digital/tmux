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

# ── inplace_sed — portable in-place sed ───────────────────────────────
# GNU `sed -i` and BSD `sed -i ''` (macOS) diverge; a bare `sed -i 's|…|'`
# fails on macOS, which silently degraded M1/M2/M3/M6 to SKIP there.
# Mutations call this instead of `sed -i`. $1 = sed script, $2 = file.
# Defined here so the eval'd mutation strings can reach it.
inplace_sed() {
    local _tmp
    _tmp="$(mktemp)" || return 1
    if sed "$1" "$2" > "$_tmp"; then
        cat "$_tmp" > "$2"
        rm -f "$_tmp"
        return 0
    fi
    rm -f "$_tmp"
    return 1
}

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
    "inplace_sed 's|echo \"\${PALETTE\[\$idx\]}\"|echo \"bogus-invalid\"|' \"\$target_abs\"" \
    "false" \
    "scripts/tests/10_hostname_color_algorithm.sh" \
    "FAIL.*T2"

# ── M2: hostname_color.sh — force hash to zero ──────────────────────
# Mutate: set h=0 after hash loop (all hostnames → same colour)
# Test 10 T3 should FAIL (spread < 12/16)
run_mutation \
    "M2: hostname_color hash forced to zero" \
    "scripts/hostname_color.sh" \
    "inplace_sed 's|^done$|done; h=0|' \"\$target_abs\"" \
    "false" \
    "scripts/tests/10_hostname_color_algorithm.sh" \
    "FAIL.*T3"

# ── M3: hostname_color.sh — collapse palette index to one entry ─────
# Mutate: change `h % ${#PALETTE[@]}` → `h % 1` so every hostname maps
# to PALETTE[0] — effectively a single-entry palette. Test 10 T3
# (colour spread across 16 hostnames) should FAIL: all 16 collapse to
# one colour. Portable `s|||` substitution — no BSD-incompatible `c\`
# range command (the old form silently SKIPped on macOS).
# Revert via false → falls through to backup restore in run_mutation.
run_mutation \
    "M3: hostname_color palette index collapsed to one entry" \
    "scripts/hostname_color.sh" \
    "inplace_sed 's|h % \${#PALETTE\[@\]}|h % 1|' \"\$target_abs\"" \
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
        "sed -i 's|MemoryMax|MemMax|g' \"\$target_abs\"" \
        "false" \
        "scripts/tests/15_per_session_cgroup_distinct.sh" \
        "FAIL.*T(1|3)"
else
    _skip "M5: no wrapper present"
fi

# ── M7: tmx-vm wrapper — remove the per-session -L SOCK_LABEL flag. ─
#        After the Fixed.md A13 per-session architecture refactor, the
#        old SOCK-empty bug class is structurally impossible (every
#        session derives its own SOCK_LABEL; there is no "default
#        socket bails" path anymore). M7 retargeted: strip the -L
#        wiring entirely → ALL sessions land on the same default
#        socket → test 11 T6 default-socket assertion FAILs because
#        the colour isn't applied via -L SOCK_LABEL (it's applied via
#        -S, but wrapper no longer reaches that path).
WRAPPER_PATH_VM="$REPO_ROOT/scripts/tmx-vm"
if [ -f "$WRAPPER_PATH_VM" ]; then
    run_mutation \
        "M7: strip _apply_host_color invocation from dispatch" \
        "scripts/tmx-vm" \
        "sed -i 's|_apply_host_color \"\$SOCK_LABEL\"||g' \"\$target_abs\"" \
        "false" \
        "scripts/tests/11_hostname_color_integration.sh" \
        "FAIL.*T4"
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

# ── M9: tmx-vm wrapper — strip per-session --unit=tmx-NAME.scope ────
#        Per-session isolation depends on EACH `tmx new -s NAME`
#        creating a distinct scope named `tmx-NAME.scope`. If the
#        wrapper is mutated to drop the --unit flag (or replace the
#        per-session naming with a generic anonymous scope), all
#        sessions land in one shared cgroup again → the Bug 2 §1
#        bluff returns. Test 15 T1 checks `systemctl --user is-active
#        tmx-NAME.scope` and must FAIL when the unit no longer exists.
if [ -f "$REPO_ROOT/scripts/tmx-vm" ]; then
    run_mutation \
        "M9: strip per-session --unit=tmx-NAME.scope" \
        "scripts/tmx-vm" \
        "sed -i 's|--unit=\"\$SCOPE_UNIT\"|--unit=tmx-anon.scope|' \"\$target_abs\"" \
        "false" \
        "scripts/tests/15_per_session_cgroup_distinct.sh" \
        "FAIL.*T1"
else
    _skip "M9: scripts/tmx-vm not found — VM wrapper not yet generated (run setup.sh)"
fi

# ── M10: tmx-vm wrapper — hardcode MemoryMax=infinity (cap disabled) ─
#        If the operator-configured memory cap is silently replaced
#        with `infinity`, the §12.6 budget invariant is violated —
#        a single session can consume all host RAM, defeating the
#        protection. Test 15 T3 (memory.max readback) and T5 (TMX_MEM
#        override) both expect specific numeric values; either FAILs
#        when MemoryMax becomes 'infinity' (no readback constraint).
if [ -f "$REPO_ROOT/scripts/tmx-vm" ]; then
    run_mutation \
        "M10: hardcode MemoryMax=infinity (disable cap)" \
        "scripts/tmx-vm" \
        "sed -i 's|MemoryMax=\$TMX_MEM_EFFECTIVE|MemoryMax=infinity|' \"\$target_abs\"" \
        "false" \
        "scripts/tests/15_per_session_cgroup_distinct.sh" \
        "FAIL.*T[35]"
else
    _skip "M10: scripts/tmx-vm not found — VM wrapper not yet generated (run setup.sh)"
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
    "inplace_sed 's|^done\$|done; h=\$\$|' \"\$target_abs\"" \
    "false" \
    "scripts/tests/10_hostname_color_algorithm.sh" \
    "FAIL.*T1"

# ── M11: tmux.conf.template — remove `.exe` strip from rename-format ──
#        The clean-up that hides Claude Code v2.x's `claude.exe` window
#        name lives in scripts/tmux.conf.template as
#          set -g automatic-rename-format "#{s/\\.exe$//:pane_current_command}"
#        Mutation: drop every `automatic-rename*` line. Tmux then falls
#        back to its built-in rename format (which propagates `.exe`
#        verbatim). Test 16 T1 (structural conf-template check) and T2.2
#        (live #W readback) both FAIL — proving the gate catches the
#        regression.
#
#        Implementation: grep-out + atomic rename (portable across BSD and
#        GNU userlands; avoids `sed -i` flavor divergence and quote-hell
#        from a multi-backslash regex).
run_mutation \
    "M11: tmux.conf.template strip \`.exe\` substitution from rename-format" \
    "scripts/tmux.conf.template" \
    "grep -v automatic-rename \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\"" \
    "false" \
    "scripts/tests/16_window_name_strips_exe.sh" \
    "FAIL"

# ── M12: tmux.conf.template — remove the WheelUpPane copy-mode override ──
#        The scrolling fix (Fixed.md A16) overrides WheelUpPane so the
#        mouse wheel / touch-scroll ALWAYS drives tmux copy-mode
#        scrollback — even inside mouse-reporting TUIs like Claude Code.
#        Without that binding the wheel reverts to tmux's default
#        (forward-to-app) behaviour and the operator cannot scroll back
#        through output. Mutation: delete the single-line WheelUpPane
#        binding. Test 17 T1 (structural conf check) and T3 (live
#        `list-keys -T root WheelUpPane` readback — the default has no
#        `scroll-up`) both FAIL.
#
#        Implementation: grep-out + atomic rename (portable across BSD
#        and GNU userlands; avoids `sed -i` flavour divergence).
run_mutation \
    "M12: tmux.conf.template remove WheelUpPane copy-mode override" \
    "scripts/tmux.conf.template" \
    "grep -v 'WheelUpPane' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\"" \
    "false" \
    "scripts/tests/17_scrollback_copy_mode.sh" \
    "FAIL"

# ── M13: tmux.conf.template — revert history-limit to the old default ──
#        The fix bumps history-limit 2000 → 50000 so terminal output
#        survives in the scrollback buffer. Mutation: put it back to
#        2000. Test 17 T2.1 (live `show-options -g history-limit`
#        readback) FAILs immediately; T4.2 also FAILs because line 1 of
#        the 3000-line stream is then evicted from the buffer — positive
#        proof that the bump is FUNCTIONALLY load-bearing, not cosmetic.
#
#        Implementation: `sed` to a temp file + atomic rename (portable;
#        no `sed -i` flavour divergence between BSD and GNU).
run_mutation \
    "M13: tmux.conf.template revert history-limit to old 2000 default" \
    "scripts/tmux.conf.template" \
    "sed 's|history-limit       50000|history-limit       2000|' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\"" \
    "false" \
    "scripts/tests/17_scrollback_copy_mode.sh" \
    "FAIL"

# ── M14: project Constitution.md — strip the inheritance pointer ───────
#        The full-refactor governance model (Fixed.md A17) requires the
#        project Constitution.md to declare it extends
#        constitution/Constitution.md. Mutation: delete every line that
#        references constitution/Constitution.md → test 18 T5 (project-
#        side inheritance wiring) FAILs.
#
#        Implementation: grep-out + atomic rename (portable BSD/GNU).
run_mutation \
    "M14: project Constitution.md strip inheritance pointer" \
    "Constitution.md" \
    "grep -v 'constitution/Constitution.md' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\"" \
    "false" \
    "scripts/tests/18_constitution_inheritance.sh" \
    "FAIL.*T5"

# ── CM-CONSTITUTION-INHERITANCE — prove test 18 catches a WEAKENED
#    constitution, without ever touching the real, decoupled,
#    independent constitution/ submodule. The submodule files test 18
#    reads are copied to a temp dir; the §11.4 anchor is deleted in the
#    COPY; test 18 is run pointed at the copy via CONSTITUTION_DIR. The
#    real submodule is never written. This mirrors the intent of
#    constitution/meta_test_inheritance.sh while honoring the operator
#    directive that constitution/ stays untouched.
echo ""
echo "--- MUTATION: CM-CONSTITUTION-INHERITANCE (temp-copy; constitution/ untouched) ---"
CM_SRC="$REPO_ROOT/constitution"
CM_TEST="$REPO_ROOT/scripts/tests/18_constitution_inheritance.sh"
CM_SENTINEL='### §11.4 End-user quality guarantee — forensic anchor (User mandate, 2026-04-28)'
if [ ! -f "$CM_SRC/Constitution.md" ] || [ ! -f "$CM_TEST" ]; then
    _skip "CM-CONSTITUTION-INHERITANCE: constitution submodule or test 18 not present"
else
    CM_TMP="$(mktemp -d 2>/dev/null || mktemp -d -t cmconst)"
    cp "$CM_SRC/CLAUDE.md" "$CM_SRC/AGENTS.md" "$CM_TMP/" 2>/dev/null || true
    [ -f "$CM_SRC/QWEN.md" ] && cp "$CM_SRC/QWEN.md" "$CM_TMP/" 2>/dev/null || true
    # Mutate the COPY: remove the §11.4 anchor line.
    grep -vF "$CM_SENTINEL" "$CM_SRC/Constitution.md" > "$CM_TMP/Constitution.md"
    if grep -qF "$CM_SENTINEL" "$CM_TMP/Constitution.md"; then
        _fail "CM-CONSTITUTION-INHERITANCE: mutation did not remove the anchor from the temp copy"
    else
        cm_out="$(CONSTITUTION_DIR="$CM_TMP" bash "$CM_TEST" 2>&1)" || true
        if echo "$cm_out" | grep -qE '^FAIL.*T3'; then
            _pass "CM-CONSTITUTION-INHERITANCE MUTATION CAUGHT — test 18 T3 FAILed on the anchor-stripped copy"
        else
            echo "  >>> test 18 (mutated): $(echo "$cm_out" | grep -E '^(PASS|FAIL)' | tr '\n' ';')"
            _fail "CM-CONSTITUTION-INHERITANCE MUTATION ESCAPED — test 18 did not FAIL on a weakened constitution"
        fi
        # Restore-direction proof: the REAL submodule run must PASS.
        cm_out="$(bash "$CM_TEST" 2>&1)" || true
        if echo "$cm_out" | grep -qE '^PASS' && ! echo "$cm_out" | grep -qE '^FAIL'; then
            _pass "CM-CONSTITUTION-INHERITANCE FEATURE INTACT — test 18 PASSes against the real constitution/"
        else
            echo "  >>> test 18 (real): $(echo "$cm_out" | grep -E '^FAIL' | tr '\n' ';')"
            _fail "CM-CONSTITUTION-INHERITANCE — test 18 does not PASS against the real constitution/"
        fi
    fi
    rm -rf "$CM_TMP"
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
