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

# Augment PATH from npm's reported prefix so the M22 codegraph mutation
# resolves `codegraph` (and runs CAUGHT rather than honest-SKIP) even when the
# meta-test is invoked from a NON-INTERACTIVE shell whose .bashrc adds
# ~/.npm-global/bin only behind an interactive-guard. Mirrors the A31 probe in
# setup.sh + run_all.sh. Idempotent: no-op when codegraph already on PATH.
if ! command -v codegraph >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    _NPM_PREFIX="$(npm config get prefix 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$_NPM_PREFIX" ] && [ -x "${_NPM_PREFIX}/bin/codegraph" ]; then
        export PATH="${_NPM_PREFIX}/bin:$PATH"
    fi
fi

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
# AUDIT-1 root-cause analysis (2026-05-21): M4/M5 target the Linux
# cgroup-v2 / systemd-run path of the tmx wrapper. On Darwin the
# wrapper uses POSIX rlimit instead (Fixed.md A4-A8 native dual-OS).
# Mutating `systemd-run` / `MemoryMax` on the Darwin wrapper either
# (a) hits unreachable code paths (no signal) or (b) hits the rlimit
# branch and silently leaves the test happy. The proper §11.4.3
# topology dispatch is to SKIP-with-reason on non-Linux hosts.
#
# Pre-AUDIT-1 the SKIP was implicit (raw `sed -i` failed on BSD sed)
# and reported with the WRONG reason ("mutation command failed to
# apply"). Post-AUDIT-1 the SKIP is explicit and §11.4.3-correct.
if [ "$(uname -s)" != "Linux" ]; then
    _skip "M4: scripts/tmx wrapper uses POSIX rlimit (not systemd-run) on $(uname -s) — Linux-only mutation per §11.4.3 topology dispatch"
    _skip "M5: scripts/tmx wrapper uses POSIX rlimit (not MemoryMax cgroup) on $(uname -s) — Linux-only mutation per §11.4.3 topology dispatch"
elif [ -n "$M4_TARGET" ]; then
    # On Linux, run with the portable inplace_sed helper (same parity
    # as M1/M2/M3/M6 already had — fixed in A17).
    run_mutation \
        "M4: tmx wrapper remove systemd-run flag" \
        "$M4_TARGET" \
        "inplace_sed 's|systemd-run --user --scope|systemd-run-bogus --user --scope|' \"\$target_abs\"" \
        "inplace_sed 's|systemd-run-bogus --user --scope|systemd-run --user --scope|' \"\$target_abs\"" \
        "scripts/tests/09_crash_isolation_scope.sh" \
        "SKIP.*T2"
    run_mutation \
        "M5: tmx wrapper corrupt MemoryMax" \
        "$M4_TARGET" \
        "inplace_sed 's|MemoryMax|MemMax|g' \"\$target_abs\"" \
        "false" \
        "scripts/tests/15_per_session_cgroup_distinct.sh" \
        "FAIL.*T(1|3)"
else
    _skip "M4: no wrapper present (neither scripts/tmx-vm nor scripts/tmx)"
    _skip "M5: no wrapper present"
fi

# ── M7-M10: RETIRED 2026-05-21 per v1.0.5 cycle ────────────────────
#        These four mutations targeted `scripts/tmx-vm`, the legacy
#        Linux-in-VM wrapper used before Fixed.md A4-A8 native dual-OS.
#        The VM path is DEAD CODE on the current architecture; the
#        wrapper isn't generated by setup.sh and the mutations
#        SKIP-without-coverage on every run.
#
#        Per §11.4.81 cross-platform-parity: the Darwin path now has
#        its own dedicated mutations (M20 + M21 below) that exercise
#        the POSIX rlimit wrapper, which IS the macOS equivalent of
#        the systemd-run + cgroup primitives M7-M10 originally
#        targeted. The Linux path is covered by M4 + M5 (with explicit
#        topology guards per §11.4.3).
#
#        Retiring M7-M10 cleanly is itself a §11.4 anti-bluff move —
#        dead-code mutations were inflating the "MUTATIONS SKIPPED"
#        count without providing real coverage signal.
_skip "M7: RETIRED — targeted dead scripts/tmx-vm (legacy VM path). Replaced by M20+M21 (Darwin rlimit) + M4+M5 (Linux cgroup, topology-guarded)."
_skip "M8: RETIRED — targeted dead scripts/tmx-vm (legacy VM path). Hostname-colour Darwin coverage retained by test 11 T4-T6."
_skip "M9: RETIRED — targeted dead scripts/tmx-vm (legacy VM path). Per-session isolation covered by M4 (Linux) + M20 (Darwin)."
_skip "M10: RETIRED — targeted dead scripts/tmx-vm (legacy VM path). MemoryMax-disable covered by M5 (Linux); macOS has no equivalent (XNU gap per §11.4.81 (C) + docs/guide/README.md §5.6)."

# ── M20: Darwin rlimit wrapper — strip `ulimit -t` (CPU cap) ────────
#        Per §11.4.81 cross-platform-parity: the macOS equivalent of
#        Linux's M5 (strip MemoryMax). XNU genuinely can't enforce
#        RLIMIT_AS for unprivileged, but it CAN and DOES enforce
#        RLIMIT_CPU. Stripping the `ulimit -t` line from the rlimit
#        wrapper breaks the only enforced memory-class invariant the
#        macOS path provides; test 15 T5 (TMX_CPU_HARD_SEC override
#        readback) FAILs because `ulimit -t` no longer reflects the
#        configured value.
#
#        Topology guard: Linux runs use cgroup, not rlimit; on Linux
#        the mutation is meaningful only if rlimit wrapper is also
#        used (currently Darwin-only). SKIP-with-reason on Linux.
RLIM_WRAP="$REPO_ROOT/scripts/tmx-rlimit-wrapper.sh"
if [ "$(uname -s)" != "Darwin" ]; then
    _skip "M20: scripts/tmx-rlimit-wrapper.sh is the Darwin isolation primitive — Linux uses cgroup (covered by M5). §11.4.3 / §11.4.81 topology dispatch."
elif [ ! -f "$RLIM_WRAP" ]; then
    _skip "M20: $RLIM_WRAP not present"
else
    run_mutation \
        "M20: strip 'ulimit -t' (CPU cap) from Darwin rlimit wrapper" \
        "scripts/tmx-rlimit-wrapper.sh" \
        "inplace_sed 's|^ulimit -t \"\$CPU_SEC\"|# disabled by M20|' \"\$target_abs\"" \
        "false" \
        "scripts/tests/15_per_session_cgroup_distinct.sh" \
        "FAIL.*T5"
fi

# ── M21: Darwin rlimit wrapper — clobber `ulimit -u` to value 1 ────
#        Per §11.4.81: prove RLIMIT_NPROC is wrapper-controlled, not
#        host-default. Substituting the `ulimit -u "$PROC_MAX"` value
#        with a literal `1` makes the session inherit RLIMIT_NPROC=1,
#        which both (a) makes ulimit -u readback show '1' (test 15 T3
#        regex `nproc=[0-9]+` still matches but T2 distinct-PIDs check
#        fails because forking a second tmux session at NPROC=1
#        cannot allocate the server's helper process), and (b) crashes
#        the session lifecycle at test 13 D-T1 because the session
#        cannot fork any child process.
#
#        Honest-§11.4 note: stripping the line ENTIRELY (the original
#        M21 design) does not change readback because the macOS host
#        default `ulimit -u` happens to equal the wrapper's configured
#        value (2666). Clobbering to 1 forces a value that cannot
#        match the host default, making the mutation observable.
if [ "$(uname -s)" != "Darwin" ]; then
    _skip "M21: Darwin-only NPROC rlimit; Linux uses cgroup TasksMax (covered by M5)."
elif [ ! -f "$RLIM_WRAP" ]; then
    _skip "M21: $RLIM_WRAP not present"
else
    run_mutation \
        "M21: clobber Darwin rlimit wrapper ulimit -u to a value of 1 (NPROC=1 breaks session lifecycle)" \
        "scripts/tmx-rlimit-wrapper.sh" \
        "inplace_sed 's|ulimit -u \"\$PROC_MAX\"|ulimit -u 1|' \"\$target_abs\"" \
        "false" \
        "scripts/tests/15_per_session_cgroup_distinct.sh" \
        "FAIL"
fi

# ── M22: .codegraph/config.json — re-exclude an own-org submodule ──
#        Per §11.4.79: own-org submodules MUST NOT be in CodeGraph's
#        exclude list. M22 mutates the config to add `Containers/**`
#        back to exclude (the v1.0.4 violation that v1.0.5 fixed) and
#        asserts codegraph_validate.sh V3 FAILs.
M22_CFG="$REPO_ROOT/.codegraph/config.json"
M22_TEST="$REPO_ROOT/scripts/codegraph_validate.sh"
# §11.4.3 topology dispatch — M22 requires the `codegraph` CLI on PATH
# to drive `codegraph_validate.sh` through its V1+V3 invariants. On
# hosts where the CLI is absent (e.g. nezha headless production-style
# host without npm-global PATH augmentation), V1 fails universally
# regardless of whether the mutation has been applied. The harness
# would then report ESCAPED for V3 even though the feature is intact
# — exactly the §11.4 PASS-bluff INVERSE (a false-negative on the
# mutation gate). v1.0.16 PWU-Q11 closes the asymmetry by SKIP-with-
# reason when the topology cannot support the assertion.
if [ ! -f "$M22_CFG" ] || [ ! -x "$M22_TEST" ]; then
    _skip "M22: codegraph config or validate not present"
elif ! command -v codegraph >/dev/null 2>&1; then
    _skip "M22: codegraph CLI not on PATH — topology cannot distinguish mutation-FAIL from environmental-FAIL at V1 (§11.4.3 honest SKIP per Q11)"
else
    # Baseline gate: the test MUST PASS V3 BEFORE we mutate. If it
    # doesn't (e.g. CLI present but stale index, mid-update state), the
    # mutation+revert pair would falsely appear as ESCAPED. §11.4.3
    # honest SKIP per Q11.
    m22_baseline="$(bash "$M22_TEST" 2>&1)" || true
    if ! echo "$m22_baseline" | grep -qE '^PASS.*V3'; then
        _skip "M22: codegraph V3 baseline does not PASS pre-mutation — environmental issue (stale index / setup not run), not a feature regression"
    else
        echo ""
        echo "--- MUTATION: M22: own-org submodule re-excluded from CodeGraph ---"
        cp "$M22_CFG" "${M22_CFG}.bak.m22"
        python3 - <<PYEOF
import json
p = '$M22_CFG'
c = json.load(open(p))
ex = c.get('exclude', [])
if 'Containers/**' not in ex:
    ex.append('Containers/**')
c['exclude'] = ex
json.dump(c, open(p,'w'), indent=2)
PYEOF
        m22_out="$(bash "$M22_TEST" 2>&1)" || true
        if echo "$m22_out" | grep -qE '^FAIL.*V3'; then
            _pass "M22: MUTATION CAUGHT — codegraph_validate V3 FAILed on re-excluded Containers/** (§11.4.79 violation detected)"
        else
            echo "  >>> validate (mutated): $(echo "$m22_out" | grep -E '^(PASS|FAIL)' | tr '\n' ';')"
            _fail "M22: MUTATION ESCAPED — validate did not FAIL with Containers/** re-excluded"
        fi
        cp "${M22_CFG}.bak.m22" "$M22_CFG"
        rm -f "${M22_CFG}.bak.m22"
        m22_out="$(bash "$M22_TEST" 2>&1)" || true
        if echo "$m22_out" | grep -qE '^PASS.*V3'; then
            _pass "M22: FEATURE INTACT — validate V3 PASSes after revert"
        else
            _fail "M22: V3 does not PASS after revert"
        fi
    fi
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
#        readback) FAILs immediately; T4.2 also FAILs because the smaller
#        buffer pins the race-free `#{history_size}` counter at exactly 2000
#        (line 1 evicted), which drops below T4.2's >=2900 threshold —
#        positive proof the bump is FUNCTIONALLY load-bearing, not cosmetic.
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

# ── M16: .codegraph/config.json — strip the §11.4.10 secret exclusion ──
#        Mandate (§11.4.78 + user 2026-05-21 + §11.4.10): the codegraph
#        config MUST exclude credentials. Mutation removes one required
#        secret pattern from the exclude list and asserts test 20 T3
#        FAILs. We mutate via python JSON edit (the file is JSON, not
#        line-oriented — sed would be brittle and risk JSON corruption).
echo ""
echo "--- MUTATION: M16: .codegraph/config.json strip secret exclusion ---"
M16_CFG="$REPO_ROOT/.codegraph/config.json"
M16_TEST="$REPO_ROOT/scripts/tests/20_codegraph_installed.sh"
if [ ! -f "$M16_CFG" ] || [ ! -f "$M16_TEST" ]; then
    _skip "M16: codegraph config or test 20 not present"
else
    M16_BACKUP="${M16_CFG}.bak.m16"
    cp "$M16_CFG" "$M16_BACKUP" || { _skip "M16: cannot back up config.json"; }
    python3 - <<PYEOF
import json
p = '$M16_CFG'
c = json.load(open(p))
c['exclude'] = [e for e in c.get('exclude', []) if e != '**/*.pem']
json.dump(c, open(p,'w'), indent=2)
PYEOF
    m16_out="$(bash "$M16_TEST" 2>&1)" || true
    if echo "$m16_out" | grep -qE '^FAIL.*T3'; then
        _pass "M16: MUTATION CAUGHT — test 20 T3 FAILed on stripped secret exclusion"
    else
        echo "  >>> test 20 (mutated): $(echo "$m16_out" | grep -E '^(PASS|FAIL)' | tr '\n' ';')"
        _fail "M16: MUTATION ESCAPED — test 20 did not FAIL with **/*.pem stripped"
    fi
    cp "$M16_BACKUP" "$M16_CFG"
    rm -f "$M16_BACKUP"
    m16_out="$(bash "$M16_TEST" 2>&1)" || true
    if echo "$m16_out" | grep -qE '^PASS.*T3'; then
        _pass "M16: FEATURE INTACT — test 20 T3 PASSes after revert"
    else
        _fail "M16: test 20 T3 does not PASS after revert"
    fi
fi

# ── M17: .mcp.json — strip the codegraph entry ─────────────────────────
#        Mandate (§11.4.78): Claude Code's project-scoped MCP config
#        MUST carry the codegraph server. Mutation removes the entry
#        and asserts test 22 T1 FAILs.
echo ""
echo "--- MUTATION: M17: .mcp.json strip codegraph entry ---"
M17_CFG="$REPO_ROOT/.mcp.json"
M17_TEST="$REPO_ROOT/scripts/tests/22_codegraph_mcp_wired.sh"
if [ ! -f "$M17_CFG" ] || [ ! -f "$M17_TEST" ]; then
    _skip "M17: .mcp.json or test 22 not present"
else
    M17_BACKUP="${M17_CFG}.bak.m17"
    cp "$M17_CFG" "$M17_BACKUP"
    python3 - <<PYEOF
import json
p = '$M17_CFG'
c = json.load(open(p))
c.get('mcpServers', {}).pop('codegraph', None)
json.dump(c, open(p,'w'), indent=2)
PYEOF
    m17_out="$(bash "$M17_TEST" 2>&1)" || true
    if echo "$m17_out" | grep -qE '^FAIL.*T1'; then
        _pass "M17: MUTATION CAUGHT — test 22 T1 FAILed on stripped .mcp.json codegraph"
    else
        echo "  >>> test 22 (mutated): $(echo "$m17_out" | grep -E '^(PASS|FAIL)' | tr '\n' ';')"
        _fail "M17: MUTATION ESCAPED — test 22 did not FAIL with codegraph stripped from .mcp.json"
    fi
    cp "$M17_BACKUP" "$M17_CFG"
    rm -f "$M17_BACKUP"
    m17_out="$(bash "$M17_TEST" 2>&1)" || true
    if echo "$m17_out" | grep -qE '^PASS.*T1'; then
        _pass "M17: FEATURE INTACT — test 22 T1 PASSes after revert"
    else
        _fail "M17: test 22 T1 does not PASS after revert"
    fi
fi

# ── M19: scripts/tmx wrapper — strip the AUDIT-2 kill-shorthand alias ──
#        Mandate (AUDIT-2 + §102 operator-path): the documented
#        `tmx kill -t NAME` MUST translate to `kill-session`. Mutation
#        removes the translation block from the generated wrapper and
#        asserts test 23 T3 FAILs ("ambiguous" stderr returns).
echo ""
echo "--- MUTATION: M19: scripts/tmx strip kill→kill-session shorthand ---"
M19_WRAP="$REPO_ROOT/scripts/tmx"
M19_TEST="$REPO_ROOT/scripts/tests/23_tmx_kill_shorthand.sh"
if [ ! -f "$M19_WRAP" ] || [ ! -f "$M19_TEST" ]; then
    _skip "M19: scripts/tmx wrapper or test 23 not present"
else
    M19_BACKUP="${M19_WRAP}.bak.m19"
    cp "$M19_WRAP" "$M19_BACKUP"
    # Delete the entire AUDIT-2 translation block (between markers).
    # The block starts with the `if [ "$SUBCMD" = "kill" ]; then` line
    # and ends at the OUTER `fi`. We use a quoted heredoc so bash does
    # not expand `\$` and corrupt the regex; pass the file path via env.
    M19_WRAP_PATH="$M19_WRAP" python3 - <<'PYEOF'
import re, pathlib, os
p = pathlib.Path(os.environ['M19_WRAP_PATH'])
s = p.read_text()
# Match the AUDIT-2 if-block: from the SUBCMD-kill check through the
# outer closing `fi`. The block contains an inner if/else/fi so we
# anchor on the literal `set -- "${_new_args[@]}"\nfi\n` tail to be
# robust to whitespace changes inside.
pat = re.compile(
    r'if \[ "\$SUBCMD" = "kill" \]; then\n.*?\n    set -- "\$\{_new_args\[@\]\}"\nfi\n',
    re.DOTALL,
)
s2, n = pat.subn('', s, count=1)
if n != 1:
    raise SystemExit(f"M19: failed to find AUDIT-2 block (n={n})")
p.write_text(s2)
PYEOF
    m19_out="$(bash "$M19_TEST" 2>&1)" || true
    if echo "$m19_out" | grep -qE '^FAIL.*T3'; then
        _pass "M19: MUTATION CAUGHT — test 23 T3 FAILed on stripped kill-shorthand"
    else
        echo "  >>> test 23 (mutated): $(echo "$m19_out" | grep -E '^(PASS|FAIL)' | tr '\n' ';')"
        _fail "M19: MUTATION ESCAPED — test 23 did not FAIL with the kill-shorthand removed"
    fi
    cp "$M19_BACKUP" "$M19_WRAP"
    chmod +x "$M19_WRAP"
    rm -f "$M19_BACKUP"
    m19_out="$(bash "$M19_TEST" 2>&1)" || true
    if echo "$m19_out" | grep -qE '^PASS' && ! echo "$m19_out" | grep -qE '^FAIL'; then
        _pass "M19: FEATURE INTACT — test 23 PASSes after revert"
    else
        _fail "M19: test 23 does not PASS after revert"
    fi
fi

# ── M15: project CLAUDE.md — strip the verbatim anti-bluff covenant ────
#        Mandate (user, 2026-05-21): the verbatim 2026-04-28 covenant
#        MUST be literally present in every consumer governance file.
#        Mutation runs against a TEMP COPY so the real CLAUDE.md is
#        never touched — same pattern as CM-CONSTITUTION-INHERITANCE.
#        The test honors $CLAUDE_MD_TARGET so the harness can point it
#        at the mutated copy without source modification.
echo ""
echo "--- MUTATION: M15: project CLAUDE.md strip verbatim anti-bluff covenant (temp-copy) ---"
M15_SRC="$REPO_ROOT/CLAUDE.md"
M15_TEST="$REPO_ROOT/scripts/tests/19_covenant_propagation.sh"
M15_SENTINEL='We had been in position that all tests do execute with success'
if [ ! -f "$M15_SRC" ] || [ ! -f "$M15_TEST" ]; then
    _skip "M15: CLAUDE.md or test 19 not present"
else
    M15_TMP="$(mktemp 2>/dev/null || mktemp -t m15claude)"
    grep -vF "$M15_SENTINEL" "$M15_SRC" > "$M15_TMP"
    if grep -qF "$M15_SENTINEL" "$M15_TMP"; then
        _fail "M15: mutation did not remove the covenant anchor from the temp copy"
    else
        m15_out="$(CLAUDE_MD_TARGET="$M15_TMP" bash "$M15_TEST" 2>&1)" || true
        if echo "$m15_out" | grep -qE '^FAIL.*T2'; then
            _pass "M15: MUTATION CAUGHT — test 19 T2 FAILed on the covenant-stripped CLAUDE.md copy"
        else
            echo "  >>> test 19 (mutated): $(echo "$m15_out" | grep -E '^(PASS|FAIL)' | tr '\n' ';')"
            _fail "M15: MUTATION ESCAPED — test 19 did not FAIL with a stripped covenant"
        fi
        # Restore-direction proof: real CLAUDE.md still passes.
        m15_out="$(bash "$M15_TEST" 2>&1)" || true
        if echo "$m15_out" | grep -qE '^PASS' && ! echo "$m15_out" | grep -qE '^FAIL'; then
            _pass "M15: FEATURE INTACT — test 19 PASSes against the real CLAUDE.md"
        else
            echo "  >>> test 19 (real): $(echo "$m15_out" | grep -E '^FAIL' | tr '\n' ';')"
            _fail "M15: test 19 does not PASS against the real CLAUDE.md"
        fi
    fi
    rm -f "$M15_TMP"
fi

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

# ── M23: hostname_color.sh — revert to pre-v1.0.7 orange-heavy palette
#        Forensic anchor (operator-reported, 2026-05-21): the pre-v1.0.7
#        palette had 7 orange-family colours, causing nezha + Mistborn
#        to both look "orange" even though they hashed to different
#        palette indices. v1.0.7 rebalanced the palette across the hue
#        spectrum. M23 mutates the palette back to the orange-heavy
#        version (via in-place sed swap) and asserts test 25 FAILs.
echo ""
echo "--- MUTATION: M23: hostname_color.sh revert to orange-heavy palette ---"
M23_SRC="$REPO_ROOT/scripts/hostname_color.sh"
M23_TEST="$REPO_ROOT/scripts/tests/25_hostname_color_perceptual_distance.sh"
if [ ! -f "$M23_SRC" ] || [ ! -f "$M23_TEST" ]; then
    _skip "M23: hostname_color.sh or test 25 not present"
else
    M23_BACKUP="${M23_SRC}.bak.m23"
    cp "$M23_SRC" "$M23_BACKUP"
    # Replace the entire PALETTE=(...) array with the orange-heavy
    # pre-v1.0.7 version. Python in-place so we don't lose other lines.
    M23_SRC="$M23_SRC" python3 <<'PYEOF'
import os, re
p = os.environ['M23_SRC']
with open(p) as f: src = f.read()
old_palette = """PALETTE=(
    colour1    colour3    colour4    colour5
    colour6    colour9    colour11   colour12
    colour13   colour14   colour52   colour88
    colour130  colour166  colour172  colour178
    colour190  colour196  colour198  colour199
    colour200  colour202  colour208  colour214
    colour220  colour226  colour240
)"""
new_src = re.sub(
    r'PALETTE=\(.*?\)',
    old_palette,
    src,
    count=1,
    flags=re.DOTALL,
)
with open(p, 'w') as f: f.write(new_src)
PYEOF
    m23_out="$(bash "$M23_TEST" 2>&1)" || true
    if echo "$m23_out" | grep -qE '^FAIL.*T(1|3)'; then
        _pass "M23: MUTATION CAUGHT — test 25 FAILed on orange-heavy palette (T1 or T3 caught the regression)"
    else
        echo "  >>> test 25 (mutated): $(echo "$m23_out" | grep -E '^(PASS|FAIL)' | tr '\n' ';')"
        _fail "M23: MUTATION ESCAPED — test 25 did not FAIL on orange-heavy palette"
    fi
    cp "$M23_BACKUP" "$M23_SRC"
    rm -f "$M23_BACKUP"
    m23_out="$(bash "$M23_TEST" 2>&1)" || true
    if echo "$m23_out" | grep -qE '^PASS.*T1' && echo "$m23_out" | grep -qE '^PASS.*T3'; then
        _pass "M23: FEATURE INTACT — test 25 PASSes against the v1.0.7 balanced palette after revert"
    else
        _fail "M23: test 25 does not PASS after revert"
    fi
fi

# ── M24: scripts/tmx — narrow _apply_host_color back to status-style only
#        Operator mandate (2026-05-21) requires all default-green tmux
#        UI surfaces to carry the hostname colour. v1.0.7 only set
#        status-style. v1.0.8 added pane-active-border-style + clock-
#        mode-colour + window-status-current-style. M24 strips the
#        three new `set -g ...` lines from the generated wrapper and
#        asserts test 26 FAILs (T2 OR T3 OR T4 will catch it).
echo ""
echo "--- MUTATION: M24: scripts/tmx narrow _apply_host_color to status-style only ---"
M24_WRAP="$REPO_ROOT/scripts/tmx"
M24_TEST="$REPO_ROOT/scripts/tests/26_ui_color_uniformity.sh"
if [ ! -f "$M24_WRAP" ] || [ ! -f "$M24_TEST" ]; then
    _skip "M24: scripts/tmx wrapper or test 26 not present"
else
    M24_BACKUP="${M24_WRAP}.bak.m24"
    cp "$M24_WRAP" "$M24_BACKUP"
    # Delete the three new set-lines added in v1.0.8. We anchor each
    # delete on the unique option name + the literal `set -g` prefix.
    M24_WRAP_PATH="$M24_WRAP" python3 - <<'PYEOF'
import os, re
p = os.environ['M24_WRAP_PATH']
with open(p) as f: src = f.read()
# Three lines to remove (the three v1.0.8 additions; status-style stays).
patterns = [
    r'^\s*"\$TMUX_BIN"\s+-L\s+"\$sock_label"\s+set\s+-g\s+pane-active-border-style\s+.*$\n',
    r'^\s*"\$TMUX_BIN"\s+-L\s+"\$sock_label"\s+set\s+-g\s+clock-mode-colour\s+.*$\n',
    r'^\s*"\$TMUX_BIN"\s+-L\s+"\$sock_label"\s+set\s+-g\s+window-status-current-style\s+.*$\n',
]
removed = 0
for pat in patterns:
    new_src, n = re.subn(pat, '', src, flags=re.MULTILINE)
    if n > 0:
        src = new_src; removed += n
with open(p, 'w') as f: f.write(src)
print(f"M24: stripped {removed} set-lines across all color functions")
PYEOF
    m24_out="$(bash "$M24_TEST" 2>&1)" || true
    if echo "$m24_out" | grep -qE '^FAIL.*T[234]'; then
        _pass "M24: MUTATION CAUGHT — test 26 T2/T3/T4 FAILed on the narrowed _apply_host_color (one or more default-green surfaces stayed green)"
    else
        echo "  >>> test 26 (mutated): $(echo "$m24_out" | grep -E '^(PASS|FAIL)' | tr '\n' ';')"
        _fail "M24: MUTATION ESCAPED — test 26 did not FAIL with the three set-lines removed"
    fi
    cp "$M24_BACKUP" "$M24_WRAP"
    chmod +x "$M24_WRAP"
    rm -f "$M24_BACKUP"
    m24_out="$(bash "$M24_TEST" 2>&1)" || true
    if echo "$m24_out" | grep -qE '^PASS.*T5'; then
        _pass "M24: FEATURE INTACT — test 26 PASSes (all four UI surfaces uniform) after revert"
    else
        _fail "M24: test 26 does not PASS after revert"
    fi
fi

# ── M44: tmx.conf.template — strip the @clip user-option definition. ─
#        The operator's copy-out flow (Fixed.md A35) is `y` /
#        MouseDragEnd1Pane → copy-pipe-and-cancel "#{@clip}". Removing
#        the @clip definition leaves `#{@clip}` undefined; tmux expands
#        it to empty, the pipe command becomes empty, and nothing ever
#        reaches the system clipboard. Test 44 catches this on TWO
#        layers: T1 (structural grep — template no longer carries `set
#        -g @clip`) fires on any host, even headless Linux. T5
#        (physical pbpaste / wl-paste / xclip readback) additionally
#        fires wherever a clipboard tool is reachable. Multi-layer
#        catch = no false ESCAPE on any topology.
#
#        Implementation: grep-out + atomic rename (portable BSD/GNU).
run_mutation \
    "M44: tmux.conf.template strip @clip user-option definition" \
    "scripts/tmux.conf.template" \
    "grep -v '^set -g @clip ' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\"" \
    "false" \
    "scripts/tests/44_clipboard_copy_out_physical.sh" \
    "FAIL.*T1"

# ── M46: tmx.conf.template — strip the @clip-read user-option (v1.0.15) ─
#        Test 46 proves PASTE-INTO from the OS clipboard via the
#        `prefix + P` binding, which routes through `#{@clip-read}` to
#        run pbpaste / wl-paste / xclip / termux-clipboard-get. Without
#        the @clip-read user-option, tmux expands `#{@clip-read}` to
#        empty; the bind's `load-buffer -` reads empty and paste-buffer
#        emits nothing. Test 46 catches this at T1 (template grep) on
#        every host. T3 (physical pbpaste-into-pane) catches it
#        wherever a clipboard tool is reachable. Multi-layer = no
#        false ESCAPE on any topology.
run_mutation \
    "M46: tmux.conf.template strip @clip-read user-option (v1.0.15 paste-IN)" \
    "scripts/tmux.conf.template" \
    "grep -v '^set -g @clip-read ' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\"" \
    "false" \
    "scripts/tests/46_paste_in_physical.sh" \
    "FAIL.*T1"

# ── M48: tmx.conf.template — strip the M-MouseDrag1Pane override (v1.0.15) ─
#        Test 48 proves the modifier-drag overrides (Alt-drag /
#        Shift-drag) that allow tmux selection inside Claude-Code-like
#        TUIs where mouse_any_flag=1 forwards the plain drag to the
#        app. Stripping the M-MouseDrag1Pane bind means Alt-drag falls
#        back to the default (forward to app). Test 48 T1 (template
#        grep for the bind literal) catches this on every host. T2
#        (live readback of the bind) catches it whenever a session
#        spawns. Multi-layer catch.
run_mutation \
    "M48: tmux.conf.template strip M-MouseDrag1Pane override (v1.0.15 alt-drag selection)" \
    "scripts/tmux.conf.template" \
    "grep -v '^bind -n M-MouseDrag1Pane ' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\"" \
    "false" \
    "scripts/tests/48_modifier_drag_override.sh" \
    "FAIL.*T1"

# ── M75: build_native.sh — revert jemalloc link to bare -ljemalloc ──────
# §11.4.111 / §1.1 paired mutation for CM-JEMALLOC-LINK-BY-SONAME. Reverting
# the resolved-SONAME ${JEM_LINK} form back to bare -ljemalloc reintroduces the
# defect (install.sh exit 77 on a runtime-only-jemalloc host, forensic
# 2026-06-30). Test 72's mode-agnostic C2b standing invariant (current artifact
# carries the fix) then FAILs → MUTATION CAUGHT. The `\${JEM_LINK}` is escaped so
# the literal reaches sed at eval-time (not shell-expanded to empty here).
run_mutation \
    "M75: build_native.sh jemalloc link reverted to bare -ljemalloc (§11.4.111)" \
    "scripts/build_native.sh" \
    "inplace_sed 's|\${JEM_LINK}|-ljemalloc|g' \"\$target_abs\"" \
    "false" \
    "scripts/tests/75_jemalloc_link_soname.sh" \
    "FAIL.*C2b"

# ── M76: tmx.template — strip the top-level _ensure_terminfo_dirs call ───
# §11.4.108/§11.4.111 / §1.1 paired mutation for CM-TERMINFO-DIRS-RESOLVED.
# Removing the at-load call leaves the wrapper without the TERMINFO_DIRS export,
# so the static-tinfo tmux dies "can't find terminfo database" (forensic
# 2026-06-30). Test 76's C2 (top-level-call present) then FAILs → MUTATION CAUGHT.
run_mutation \
    "M76: tmx.template strip top-level _ensure_terminfo_dirs call (§11.4.111 terminfo)" \
    "scripts/tmx.template" \
    "inplace_sed '/^_ensure_terminfo_dirs[[:space:]]*\$/d' \"\$target_abs\"" \
    "false" \
    "scripts/tests/76_terminfo_database_resolves.sh" \
    "FAIL.*C2"

# ═══════════════════════════════════════════════════════════════════════
# v1.0.9 shell-session-resume PWUs (P5) — paired mutations
# ═══════════════════════════════════════════════════════════════════════
# Spec: docs/superpowers/specs/2026-05-22-tmx-shell-session-resume-design.md
#       §7 Layer 4 lists these as M20..M24. To avoid ID collision with
#       the v1.0.7/v1.0.8 pre-existing M20..M24 (Darwin rlimit, palette,
#       UI uniformity, etc.) this harness uses the P5-prefixed namespace
#       `P5-M20..P5-M24`. Spec→harness mapping is 1:1:
#         spec M20 → P5-M20 (non-TTY guard)
#         spec M21 → P5-M21 (cwd-capture hook)
#         spec M22 → P5-M22 (authorized_keys command= prefix)
#         spec M23 → P5-M23 (dispatcher session-name regex)
#         spec M24 → P5-M24 (cross-platform branch)
#
# Each mutation targets a P6 test that does not yet exist; until the test
# file is present, the mutation SKIPs cleanly (no FAIL). Once P6 lands its
# tests, the mutations activate. Pattern: safe-by-construction —
#   1. abort if working tree dirty on the target file
#   2. backup with cp -p (preserve mtime)
#   3. apply mutation
#   4. run target test, assert FAIL
#   5. restore (trapped on EXIT so even Ctrl-C cleans up)
#
# Constitution: §1.1 paired-mutation, §11.4 anti-bluff, §11.4.81 (P5-M24
# cross-platform branch coverage).

# ── v109_run_mutation: SKIP-if-test-absent variant of run_mutation ─────
# Usage: v109_run_mutation <mut_id> <desc> <target_rel> <mutate_cmd> \
#                          <test_rel> <expect_fail_regex>
# Differences from run_mutation:
#   - SKIPs (not FAILs) if the target TEST file is absent (P6 not landed).
#   - Refuses to mutate a dirty target file (uncommitted changes would be
#     destroyed by the cp-restore step).
#   - Uses `trap '_v109_restore' EXIT` so Ctrl-C / errexit still restores.
v109_run_mutation() {
    local mut_id="$1"
    local desc="$2"
    local target="$3"
    local mutate_cmd="$4"
    local test_script="$5"
    local expect_fail="${6:-FAIL}"
    local custom_revert="${7:-}"

    local target_abs="$REPO_ROOT/$target"
    local test_abs="$REPO_ROOT/$test_script"
    local backup="${target_abs}.bak.v109.${mut_id}"

    echo ""
    echo "--- MUTATION: ${mut_id}: ${desc} ---"

    # Target file must exist (the P1-P4 artefact).
    if [ ! -f "$target_abs" ]; then
        _skip "${mut_id}: target file ${target} not present"
        return 0
    fi
    # Target TEST must exist (P6 deliverable). SKIP cleanly until then.
    if [ ! -f "$test_abs" ]; then
        _skip "${mut_id}: target test ${test_script} not present yet"
        return 0
    fi
    # Refuse to mutate if the target file has uncommitted changes — the
    # cp-restore step would clobber them and corrupt the operator's tree.
    if git -C "$REPO_ROOT" status --porcelain -- "$target" 2>/dev/null \
        | grep -qE '^( M| A|MM|AM|UU)'; then
        echo "  >>> ABORT: $target has uncommitted changes (git status):"
        git -C "$REPO_ROOT" status --porcelain -- "$target" | sed 's/^/    /'
        _skip "${mut_id}: dirty working tree on ${target} — refusing to mutate"
        return 0
    fi

    # Backup + EXIT-trapped restore. Saves mtime via -p.
    cp -p "$target_abs" "$backup" || { _skip "${mut_id}: backup failed"; return 0; }
    # Compose a restore closure that runs on EXIT until we explicitly
    # disarm it after successful manual restore. Important: we use a
    # global to track which file the trap touches so the trap function
    # is reusable across mutations.
    _V109_BACKUP_FILE="$backup"
    _V109_CUSTOM_REVERT="$custom_revert"
    _V109_TARGET_FILE="$target_abs"
    # shellcheck disable=SC2064  # we want $-expansion now
    trap '_v109_restore' EXIT

    # Apply mutation.
    if ! eval "$mutate_cmd" 2>/dev/null; then
        _v109_restore
        _skip "${mut_id}: mutation command failed to apply"
        return 0
    fi

    # Run target test, expect FAIL.
    local test_out test_rc
    test_out=$(bash "$test_abs" 2>&1) || true
    test_rc=$?
    if echo "$test_out" | grep -qE "$expect_fail"; then
        _pass "${mut_id} MUTATION CAUGHT — test output contains '${expect_fail}'"
    elif [ "$test_rc" -ne 0 ]; then
        _pass "${mut_id} MUTATION CAUGHT — test exited ${test_rc}"
    else
        echo "  >>> WARNING: mutation DID NOT cause test failure <<<"
        echo "  >>> Test output: $(echo "$test_out" | head -5 | tr '\n' ';')"
        _fail "${mut_id} MUTATION ESCAPED — test passed despite broken feature"
    fi

    # Manual restore + disarm trap.
    _v109_restore
    trap - EXIT
}

# _v109_restore — restore the most-recent v109 backup to its source.
# Idempotent: NO-OP if backup file already removed.
_v109_restore() {
    if [ -n "${_V109_BACKUP_FILE:-}" ] && [ -f "${_V109_BACKUP_FILE}" ]; then
        cp -p "${_V109_BACKUP_FILE}" "${_V109_TARGET_FILE}" 2>/dev/null || true
        rm -f "${_V109_BACKUP_FILE}" 2>/dev/null || true
    fi
    # Run custom revert command if provided (e.g. rebuild a binary after
    # restoring Go source).
    if [ -n "${_V109_CUSTOM_REVERT:-}" ]; then
        eval "${_V109_CUSTOM_REVERT}" 2>/dev/null || true
    fi
    _V109_BACKUP_FILE=""
    _V109_TARGET_FILE=""
    _V109_CUSTOM_REVERT=""
}

# ── P5-M20: strip the distinctive non-TTY guard MARKER line from
#    tmx-shell-init template — closes the v1.0.15 escape via test 49.
#
# Rationale (v1.0.16 PWU-Q2): the v1.0.15 escape was a §11.4 PASS-bluff
# at the layer-4 level — stripping the [ -t 0 ] outer guard line did
# not actually FAIL test 30 because Darwin libc enforces POSIX TTY
# semantics independently. Test 49 (`49_tmx_shell_init_guard_specific.sh`)
# asserts the GUARD-FIRED marker is emitted (a TMX_INIT_DEBUG-gated
# stderr line). The mutation now strips that marker line specifically —
# the test FAILs because no marker means the guard didn't actually
# fire its distinctive behaviour.
v109_run_mutation \
    "P5-M20" \
    "strip the distinctive 'non-TTY guard fired' marker line from tmx-shell-init.sh.template (v1.0.16: test 49 catches universally)" \
    "scripts/tmx-shell-init.sh.template" \
    "grep -v 'non-TTY guard fired' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\" && chmod 644 \"\$target_abs\"" \
    "scripts/tests/49_tmx_shell_init_guard_specific.sh" \
    "FAIL"

# ── P5-M21: strip cwd-capture tmux hook section from tmx.template ──────
# Targets new test 50 (`50_cwd_hook_autoinstall.sh`, v1.0.16 PWU-Q2)
# which asserts the hooks are AUTO-INSTALLED on the live server (via
# `tmux show-hooks`) — NOT by manual `tmux run-shell 'set-hook …'`
# injection (which the existing test 27 used, and is why P5-M21
# previously ESCAPED). Test 50 reads `show-hooks -g` and asserts both
# client-detached + session-closed are present referencing `tmx-state
# record`; stripping the auto-install block makes show-hooks empty →
# test FAILs.
v109_run_mutation \
    "P5-M21" \
    "strip cwd-capture tmux hook block (client-detached + session-closed) from scripts/tmx.template (v1.0.16: test 50 catches via show-hooks readback, not manual injection)" \
    "scripts/tmx.template" \
    "grep -v 'set-hook -g client-detached\\|set-hook -g session-closed' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\"" \
    "scripts/tests/50_cwd_hook_autoinstall.sh" \
    "FAIL"

# ── P5-M22: strip `command=` prefix from tmx-ssh-install.sh's AK_LINE ──
# Spec §7 Layer 4: the dispatcher only fires because the authorized_keys
# entry is `command="…/tmx-ssh-dispatch.sh"…`. Without the `command=`
# prefix, sshd treats the key as a regular login key and SSH_ORIGINAL_-
# COMMAND-based dispatch never engages. Mutate the line that constructs
# AK_LINE in scripts/tmx-ssh-install.sh to drop the prefix. Test 22
# (`22_ssh_dispatch_local.sh`, P6) runs the local-loopback SSH dispatch
# scenario; without the prefix the dispatch path does not fire and the
# test FAILs. Chose this target over modifying the dispatcher template
# itself because the prompt anchors on "command= prefix" specifically,
# and that string lives in the install script's AK_LINE construction.
v109_run_mutation \
    "P5-M22" \
    "strip command= prefix from tmx-ssh-install.sh authorized_keys line" \
    "scripts/tmx-ssh-install.sh" \
    "sed 's|AK_LINE=\"command=\\\\\"\$REMOTE_DISPATCH_PATH\\\\\",no-port-forwarding|AK_LINE=\"no-port-forwarding|' \"\$target_abs\" > \"\$target_abs.tmp\" && mv \"\$target_abs.tmp\" \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/31_ssh_dispatch_local.sh" \
    "FAIL"

# ── M-DBLPROMPT: strip the per-process idempotency guard from the
#    GENERATED tmx-shell-init.sh — closes the bash-login double-prompt.
# Forensic anchor: user report 2026-05-29; nezha `bash -l -i` reproduced
# PROMPT_COUNT=2 because .bash_profile sources tmx-shell-init AND sources
# .bashrc which sources it again (same process). The guard
# `_TMX_SHELL_INIT_PROMPTED` makes the prompt fire at most once per process.
# Target the GENERATED script (the real .bashrc/.zshrc-sourced artefact, and
# what test 51 sources). The sed range deletes the whole guard block (the
# `if [ -n "${_TMX_SHELL_INIT_PROMPTED:-}" ]` line through the
# `_TMX_SHELL_INIT_PROMPTED=1` assignment). With the guard gone the double-
# source re-prompts and test 51 reports prompt_count=2 → FAIL.
v109_run_mutation \
    "M-DBLPROMPT" \
    "strip per-process idempotency guard from generated tmx-shell-init.sh (test 54 catches the bash-login double-prompt)" \
    "scripts/tmx-shell-init.sh" \
    "inplace_sed '/_TMX_SHELL_INIT_PROMPTED:-/,/_TMX_SHELL_INIT_PROMPTED=1/d' \"\$target_abs\"" \
    "scripts/tests/54_double_prompt_idempotent.sh" \
    "FAIL"

# ── M-MOUSETOGGLE: strip the `prefix m` mouse-toggle from tmux.conf.template
# Forensic anchor: user report 2026-05-29 — mouse select/copy unusable,
# especially in Claude Code. `prefix m` is the terminal-agnostic copy escape
# hatch (mouse off -> native terminal selection works inside tracking apps).
# Delete the toggle binding and test 52's first assertion FAILs.
v109_run_mutation \
    "M-MOUSETOGGLE" \
    "strip the 'prefix m' mouse-toggle binding from tmux.conf.template (test 55 catches loss of the copy escape hatch)" \
    "scripts/tmux.conf.template" \
    "inplace_sed '/^bind m set -g mouse/d' \"\$target_abs\"" \
    "scripts/tests/55_mouse_toggle_and_copy.sh" \
    "FAIL"

# ── M-MOUSEDEFAULT: flip the shipped mouse DEFAULT from `off` back to `on`
# in tmux.conf.template. Forensic anchor: operator reports 2026-05-28 .. 06-13
# — "select/copy multi-line does not work … must scroll and always be
# selectable … right-click -> Copy". Root cause: `mouse on` emits mouse-tracking
# DECSETs (CSI ?1000h/?1002h/?1006h) that SUPPRESS native terminal selection +
# right-click->Copy. The new default `mouse off` lets the terminal own the
# mouse (native select/copy/scroll everywhere; tmux mouse on demand via
# prefix m). Flipping the default back to `on` is the exact regression; test 59
# captures the attach byte stream over a real PTY and FAILs because the default
# attach now emits mouse-enable DECSET (native selection re-suppressed). Anchored
# to `^set -g` so the comment lines that mention "mouse off" are untouched.
v109_run_mutation \
    "M-MOUSEDEFAULT" \
    "flip the mouse default off->on in tmux.conf.template (test 59 wire-level proof catches re-suppression of native terminal select + right-click->Copy)" \
    "scripts/tmux.conf.template" \
    "inplace_sed 's/^\\(set -g[[:space:]][[:space:]]*mouse[[:space:]][[:space:]]*\\)off/\\1on/' \"\$target_abs\"" \
    "scripts/tests/59_native_mouse_unobstructed.sh" \
    "FAIL"

# ── M-PLAINDRAG: strip the plain-drag copy-mode override from
#    tmux.conf.template — the PRIMARY fix for "cannot select/copy with the
#    mouse in Claude Code" (forensic anchor: user report 2026-05-29; the
#    prefix-m toggle alone was insufficient — a PLAIN drag must select+copy).
# Without the override, tmux's built-in root MouseDrag1Pane forwards the drag
# to the app when #{mouse_any_flag}=1, so a plain drag in a mouse-tracking app
# copies nothing. Test 56 injects a REAL SGR-1006 mouse drag with
# mouse_any_flag=1 and asserts the token reached the @clip sink — with the
# override stripped it FAILs (sink empty).
v109_run_mutation \
    "M-PLAINDRAG" \
    "strip plain-drag copy-mode override from tmux.conf.template (test 56 real SGR mouse-drag catches loss of select+copy in mouse-tracking apps)" \
    "scripts/tmux.conf.template" \
    "inplace_sed '/^bind -n MouseDrag1Pane if /d' \"\$target_abs\"" \
    "scripts/tests/56_real_mouse_drag_copy.sh" \
    "FAIL"

# ── M-PASTE: strip the POSIX `prefix P` paste binding from tmux.conf.template.
# Forensic anchor: user report 2026-05-29 — "we cannot paste … it gets a
# completely new value". The fixed binding pipes an inline clipboard probe to
# `tmux load-buffer -` (POSIX, no `<<<`, no #{@clip-read} nested-quote
# collision). Deleting it makes test 57 FAIL — (D) no exact-value paste and
# (E) the POSIX-binding regression guard both fire.
v109_run_mutation \
    "M-PASTE" \
    "strip the POSIX prefix-P paste binding from tmux.conf.template (test 57 catches loss of OS-clipboard paste-into-pane)" \
    "scripts/tmux.conf.template" \
    "inplace_sed \"/^bind P run -b 'sh -c/d\" \"\$target_abs\"" \
    "scripts/tests/57_reload_select_copy_paste.sh" \
    "FAIL"

# ── M-TMX-ATTACH-RELOAD: strip the source-file-on-attach line from the
# GENERATED scripts/tmx wrapper. Forensic anchor: user report 2026-05-29 —
# re-opening a session that predates the mouse-copy fix kept stale bindings
# ("select/copy not possible"). `tmx attach` now source-files the config so a
# pre-existing session always gets current bindings. Removing the line makes
# test 58(2) FAIL (stale binding not refreshed on attach).
v109_run_mutation \
    "M-TMX-ATTACH-RELOAD" \
    "strip source-file-on-attach from scripts/tmx (test 58 catches stale bindings on re-attach of an old session)" \
    "scripts/tmx" \
    "inplace_sed '/source-file \"\$TMUX_CONF_ATTACH\"/d' \"\$target_abs\"" \
    "scripts/tests/58_operator_path_select_copy_ls.sh" \
    "FAIL"

# ── M-WRAPPER-TMUXBIN: point the generated scripts/tmx TMUX_BIN at a
#    MISSING path — reproduces Issues.md F1 ("tmx new -s HelixCode crashed
#    the whole terminal on every emulator"). CAPTURED root cause: a stale
#    scripts/tmx carried TMUX_BIN=<non-existent prior-checkout path>; the
#    operator shell-init `exec sh -c 'tmx attach … || exec tmx new …'`
#    reached `exec "$TMUX_BIN"` (scripts/tmx ~396/430) on the missing binary
#    → exec failed (127, "No such file or directory") → the operator login
#    shell DIED → the terminal window closed. Test 60's T1 (static surface)
#    asserts TMUX_BIN exists+executable, and T2 (PTY) reproduces the exact
#    crash with the EXACT operator path; rewriting TMUX_BIN to a guaranteed-
#    missing path makes T1 FAIL → mutation CAUGHT. scripts/tmx is the
#    GENERATED (gitignored) artefact, so the cp-restore is clean.
v109_run_mutation \
    "M-WRAPPER-TMUXBIN" \
    "point scripts/tmx TMUX_BIN at a missing path (test 60 catches the F1 terminal-crash wrapper-points-at-missing-binary surface)" \
    "scripts/tmx" \
    "inplace_sed 's|^TMUX_BIN=.*|TMUX_BIN=\"/no/such/tmux/binary/M-WRAPPER-TMUXBIN\"|' \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/60_wrapper_tmux_bin_valid.sh" \
    "FAIL"

# ── P5-M23: strip session-name regex validation from dispatcher template
# Spec §7 Layer 4: the POSIX `case "$session" in *[!A-Za-z0-9_.-]*)`
# block at lines 77-82 of tmx-ssh-dispatch.sh.template rejects names
# containing disallowed characters (spaces, `;`, `&`, `$()`, etc.).
# Without it, an attacker could pass `; rm -rf $HOME` as a session
# name and the dispatcher would forward it to tmx. Test 36
# (`36_dispatcher_rejects_multiword.sh`, P6) verifies the dispatcher rejects
# multi-word and special-char inputs; without the regex, the test FAILs.
# Mutation: drop the entire case-block (5 lines) by python regex
# substitution — sed cannot reliably express the multi-line block.
v109_run_mutation \
    "P5-M23" \
    "strip session-name regex validation case-block from tmx-ssh-dispatch.sh.template" \
    "scripts/tmx-ssh-dispatch.sh.template" \
    "python3 -c 'import re, sys; p=\"\$target_abs\"; s=open(p).read(); pat=re.compile(r\"case \\\"\\\\\$session\\\" in\\n.*?esac\\n\", re.DOTALL); s2,n=pat.subn(\"\", s, count=1); open(p,\"w\").write(s2)'" \
    "scripts/tests/36_dispatcher_rejects_multiword.sh" \
    "FAIL"

# ── P5-M24: strip a `case \"$(uname -s)\"` branch from a cross-platform test
# Spec §7 Layer 4 + §11.4.81 cross-platform parity: tests 18 and 31 will
# carry per-OS branches once P6 authors them. The mutation strips the
# Darwin branch from whichever exists. Until P6 lands either test, this
# mutation SKIPs cleanly. Strategy: prefer test 31 (parity test) when
# present, fall back to test 18, SKIP otherwise. We mutate the TEST
# itself (the cross-platform dispatch logic lives there per §11.4.81);
# stripping the Darwin branch makes the test silently miss positive
# evidence on macOS — a §11.4.81 violation the gate then catches.
M24_TARGET=""
if [ -f "$REPO_ROOT/scripts/tests/40_macos_linux_parity.sh" ]; then
    M24_TARGET="scripts/tests/40_macos_linux_parity.sh"
elif [ -f "$REPO_ROOT/scripts/tests/27_state_persistence.sh" ]; then
    M24_TARGET="scripts/tests/27_state_persistence.sh"
fi
if [ -z "$M24_TARGET" ]; then
    _skip "P5-M24: target test scripts/tests/40_macos_linux_parity.sh not present yet (and 18_state_persistence.sh also absent — both are P6 deliverables)"
else
    # The mutation strips the Darwin case-arm. We anchor on the literal
    # `Darwin)` arm head. The mutation succeeds only if the test
    # actually contains a `case "$(uname -s)"` block — if P6 ships the
    # file without one, the mutation SKIPs at the grep-not-found stage.
    if ! grep -qE 'case .*uname' "$REPO_ROOT/$M24_TARGET"; then
        _skip "P5-M24: $M24_TARGET present but contains no case \"\$(uname -s)\" block — mutation NO-OP"
    else
        v109_run_mutation \
            "P5-M24" \
            "strip Darwin) case-arm from $M24_TARGET (cross-platform parity per §11.4.81)" \
            "$M24_TARGET" \
            "python3 -c 'import re,sys; p=\"\$target_abs\"; s=open(p).read(); s2,n=re.subn(r\"\\s*Darwin\\)\\s*\\n.*?;;\\n\", \"\", s, count=1, flags=re.DOTALL); open(p,\"w\").write(s2)'" \
            "$M24_TARGET" \
            "FAIL"
    fi
fi

# ── M25: strip _apply_color from the generated wrapper → color test FAILs
# Spec §102 per-session color: _apply_color is the function that paints the
# 4 green surfaces with the explicit/persisted color. Without it the wrapper
# still resolves EFFECTIVE_COLOR but never applies it, so every colored
# session falls through to green/hostname and test 63's T1/T2/T3 (which read
# live status-style == the chosen color) FAIL. scripts/tmx is the GENERATED
# (gitignored) artefact test 63 runs, so cp-restore is clean (same pattern
# as M-WRAPPER-TMUXBIN).
v109_run_mutation \
    "M25" \
    "strip _apply_color from scripts/tmx (test 63 T1/T2/T3 read live status-style == chosen color)" \
    "scripts/tmx" \
    "inplace_sed '/^_apply_color()/,/^}/d' \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/63_session_color.sh" \
    "FAIL"

# ── M26: neutralize the set-color call in the generated wrapper → T4 FAILs
# Spec §102 decision #7: persisted color must win on a bare-name re-run. T4
# sets a color, kills, re-creates bare, asserts the persisted color
# re-applies. If _resolve_color never calls `tmx-state-bin set-color`, the
# state file never records the color → bare re-run falls back to hostname
# color → T4 FAILs. Mutates scripts/tmux (GENERATED, gitignored) so the
# cp-revert is clean + needs no binary rebuild (avoids the §11.4.84
# mutation-residue risk of a Go-source+rebuild mutation whose cp-only
# revert would leave tmx-state-bin broken).
v109_run_mutation \
    "M26" \
    "neutralize set-color call in scripts/tmux (test 63 T4 persisted-color-wins fails)" \
    "scripts/tmx" \
    "inplace_sed 's|\"\$TMX_DIR/tmx-state-bin\" set-color \"\$name\"|true #M26|' \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/63_session_color.sh" \
    "FAIL"

# ── M27: make verifyPassword always return true → test 66 T3 FAILs
# If verifyPassword always returns true, wrong passwords are accepted, so
# test 66 T3 (wrong password → exit 1) FAILs because verify-password
# returns exit 0 instead of exit 1. Mutates scripts/tmx-state/state.go
# (Go source), rebuilds the binary, tests, then reverts + rebuilds.
# Note: revert_cmd rebuilds the binary after restoring the source so the
# FEATURE-RESTORED step (Step 4) runs against a clean binary.
v109_run_mutation \
    "M27" \
    "make verifyPassword always return true (test 66 T3 wrong-password accepted)" \
    "scripts/tmx-state/state.go" \
    "inplace_sed 's|return hashPassword(password) == hash|return true //M27|' \"\$target_abs\" && cd \"\$REPO_ROOT/scripts/tmx-state\" && go build -o \"\$REPO_ROOT/scripts/tmx-state-bin\" . 2>/dev/null" \
    "scripts/tests/66_session_password.sh" \
    "FAIL" \
    "cd \"\$REPO_ROOT/scripts/tmx-state\" && go build -o \"\$REPO_ROOT/scripts/tmx-state-bin\" . 2>/dev/null"

# ── M82: neutralize whitespace-to-hyphen handling in the generated tmx wrapper
# Spec §11.4.4 layer-4 guard for test 82: `_sanitise()` trims/collapses
# whitespace before deleting disallowed characters. If the whitespace
# collapse is skipped, "hello world" becomes "helloworld" instead of
# "hello-world", so test 82's live session-name readback FAILs. The
# mutation targets scripts/tmx (the generated, gitignored artefact the live
# test executes), matching the M25/M26 cp-restore pattern.
m82_mutate() {
    python3 - "$1" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """    printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/-/g' | tr -cd 'A-Za-z0-9._-'"""
new = """    printf '%s' \"$raw\" | cat | tr -cd 'A-Za-z0-9._-'"""
if old not in s:
    sys.stderr.write('M82 target line not found\n')
    sys.exit(1)
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
}
v109_run_mutation \
    "M82" \
    "remove whitespace trim/collapse from scripts/tmx _sanitise (test 82 live readback fails)" \
    "scripts/tmx" \
    "m82_mutate \"\\\$target_abs\"" \
    "scripts/tests/82_session_name_sanitization_live.sh" \
    "FAIL"

# ── M-test67: obtain_local_deps.sh — make resolved.env emit a NONEXISTENT
#    JEMALLOC_SO → test 67 C1/C2 FAIL ("resolved lib does not exist").
#    §11.4.77/.81/.111/.115 per-host local-dependency obtaining mechanism.
#    The SOURCE-layer wiring is asserted by the verify.sh gate
#    CM-LOCAL-DEPS-MECHANISM; THIS mutation proves the RUNTIME guard (test 67)
#    has teeth: replacing the `%s_SO=` printf with an echo of a bogus absolute
#    path makes the script still exit 0 (it "succeeds") while writing a
#    JEMALLOC_SO that does not exist — exactly the §11.4 PASS-bluff (resolve
#    reported success, the lib is unusable). Test 67 C1's existence check
#    catches it → FAIL. scripts/obtain_local_deps.sh is consumed (never
#    edited) by Stream B; the cp-restore is clean.
v109_run_mutation \
    "M-test67" \
    "make obtain_local_deps.sh resolved.env emit a nonexistent JEMALLOC_SO (test 67 catches the resolved-lib-does-not-exist bluff)" \
    "scripts/obtain_local_deps.sh" \
    "inplace_sed 's#.*%s_SO=.*#        echo JEMALLOC_SO=/NONEXISTENT_M_TEST67/libjemalloc.so.2#' \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/67_local_deps.sh" \
    "^FAIL 67"

# ── M-CM-LOCAL-DEPS-MECHANISM: remove the obtain_local_deps.sh invocation
#    from setup.sh → the verify.sh gate CM-LOCAL-DEPS-MECHANISM invariant
#    (iv) (`grep -q obtain_local_deps.sh setup.sh`) FAILs. This is the §1.1
#    paired mutation for Stream C's gate. setup.sh is owned by Stream A; this
#    block mutates the REAL setup.sh transiently (backup → delete the
#    obtain_local_deps lines → run verify.sh → assert the gate [FAIL] line →
#    restore from backup, EXIT-trapped). It SKIPs cleanly until BOTH the gate
#    (Stream C) AND the setup.sh invocation (Stream A) have landed — the
#    conductor runs the pair in the green post-merge tree (per the §11.4.84
#    no-mutation-residue + dirty-tree guards below).
echo ""
echo "--- MUTATION: M-CM-LOCAL-DEPS-MECHANISM (verify.sh gate; setup.sh invocation removed) ---"
LD_VERIFY="$REPO_ROOT/scripts/verify.sh"
LD_SETUP="$REPO_ROOT/scripts/setup.sh"
LD_GATE="CM-LOCAL-DEPS-MECHANISM"
if [ ! -f "$LD_VERIFY" ] || ! grep -q "$LD_GATE" "$LD_VERIFY" 2>/dev/null; then
    _skip "$LD_GATE: scripts/verify.sh absent or gate not present yet (Stream C) — conductor runs this after the gate lands"
elif [ ! -f "$LD_SETUP" ]; then
    _skip "$LD_GATE: scripts/setup.sh absent"
elif ! grep -q 'obtain_local_deps.sh' "$LD_SETUP" 2>/dev/null; then
    _skip "$LD_GATE: scripts/setup.sh does not yet invoke obtain_local_deps.sh (Stream A pending) — nothing to remove; conductor runs this after the setup wiring lands"
elif git -C "$REPO_ROOT" status --porcelain -- scripts/setup.sh 2>/dev/null | grep -qE '^( M| A|MM|AM|UU)'; then
    _skip "$LD_GATE: scripts/setup.sh has uncommitted changes — refusing to mutate (§11.4.84 quiescence)"
else
    LD_BAK="$LD_SETUP.bak.mldm"
    if ! cp -p "$LD_SETUP" "$LD_BAK" 2>/dev/null; then
        _skip "$LD_GATE: backup of setup.sh failed"
    else
        _MLDM_BAK="$LD_BAK"; _MLDM_TGT="$LD_SETUP"
        # EXIT-trapped restore guarantees no mutation residue even on error.
        trap 'cp -p "$_MLDM_BAK" "$_MLDM_TGT" 2>/dev/null; rm -f "$_MLDM_BAK" 2>/dev/null' EXIT
        # Delete every line referencing the obtaining script so invariant (iv)
        # `grep -q obtain_local_deps.sh setup.sh` finds nothing → gate FAILs.
        inplace_sed '/obtain_local_deps/d' "$LD_SETUP"
        if grep -q 'obtain_local_deps.sh' "$LD_SETUP" 2>/dev/null; then
            _fail "$LD_GATE: mutation did not remove the obtain_local_deps.sh invocation from setup.sh"
        else
            ld_out="$(bash "$LD_VERIFY" 2>&1)" || true
            if printf '%s\n' "$ld_out" | grep -q "\[FAIL\] $LD_GATE"; then
                echo "  [evidence] $(printf '%s\n' "$ld_out" | grep "\[FAIL\] $LD_GATE" | head -1)"
                _pass "$LD_GATE MUTATION CAUGHT — verify.sh reports [FAIL] $LD_GATE when setup.sh no longer invokes obtain_local_deps.sh (invariant iv)"
            elif ! printf '%s\n' "$ld_out" | grep -q "$LD_GATE"; then
                _skip "$LD_GATE: verify.sh exited before reaching the gate (an earlier gate FAILed in the current tree) — conductor runs this in a green post-merge tree"
            else
                echo "  >>> verify.sh gate lines: $(printf '%s\n' "$ld_out" | grep "$LD_GATE" | tr '\n' ';')"
                _fail "$LD_GATE MUTATION ESCAPED — gate did not [FAIL] despite setup.sh missing the obtain_local_deps.sh invocation"
            fi
        fi
        # Manual restore + disarm trap (§11.4.84 — leave no residue).
        cp -p "$_MLDM_BAK" "$_MLDM_TGT" 2>/dev/null || true
        rm -f "$_MLDM_BAK" 2>/dev/null || true
        trap - EXIT
        # Restore-direction proof (cheap, no full suite): invariant (iv) holds.
        if grep -q 'obtain_local_deps.sh' "$LD_SETUP" 2>/dev/null; then
            _pass "$LD_GATE FEATURE RESTORED — setup.sh invokes obtain_local_deps.sh again (invariant iv satisfied)"
        else
            _fail "$LD_GATE — setup.sh did not restore the obtain_local_deps.sh invocation after revert"
        fi
    fi
fi

# ── M-CM-NO-SUDO-NO-INTERACTION: prove the verify.sh gate's PROJECT-WIDE
#    invariant (C) catches a real privilege-escalation EXECUTION line injected
#    ANYWHERE under scripts/ (not only the install/build path), WHILE leaving
#    print-only "(as root)" advice untouched. §1.1 paired mutation for the
#    operator-mandate 2026-06-29 gate (DIRECT user authority: "There cannot be
#    any use of su or sudo inside our project full automation scripts or test").
#    We exercise the gate FUNCTION in isolation (sed-extract its body from
#    verify.sh -> source -> call) so an unrelated earlier-gate FAIL in the
#    working tree cannot mask this pair and no built binary is required. A
#    transient probe script carrying a command-position escalation is created
#    under scripts/tests/, the gate is run (expect [FAIL] CAUGHT), the probe
#    removed, the gate re-run (expect [PASS] — false-positive-free on the
#    "(as root)" advice that remains in the tree). EXIT-trapped cleanup leaves
#    NO residue (§11.4.84). The probe's escalation token is assembled via printf
#    so THIS harness source carries no command-position escalation line of its
#    own (the gate scans this file too).
echo ""
echo "--- MUTATION: M-CM-NO-SUDO-NO-INTERACTION (verify.sh gate (C); project-wide privilege-escalation EXECUTION detector) ---"
NS_VERIFY="$REPO_ROOT/scripts/verify.sh"
NS_GATE="CM-NO-SUDO-NO-INTERACTION"
NS_FN="_check_CM_NO_SUDO_NO_INTERACTION"
NS_PROBE="$REPO_ROOT/scripts/tests/nsni_exec_probe.sh"
if [ ! -f "$NS_VERIFY" ] || ! grep -q "$NS_GATE" "$NS_VERIFY" 2>/dev/null; then
    _skip "$NS_GATE: scripts/verify.sh absent or gate not present yet — conductor runs this after the gate lands"
elif ! grep -q "^${NS_FN}()" "$NS_VERIFY" 2>/dev/null; then
    _skip "$NS_GATE: gate function ${NS_FN}() not found in verify.sh"
elif [ -e "$NS_PROBE" ]; then
    _skip "$NS_GATE: probe path already exists ($NS_PROBE) — refusing to clobber (§11.4.84 quiescence)"
else
    NS_FNTMP="$(mktemp 2>/dev/null || mktemp -t nsnifn)"
    _NSNI_PROBE="$NS_PROBE"; _NSNI_FNTMP="$NS_FNTMP"
    # EXIT-trapped cleanup guarantees no probe / temp residue even on error.
    trap 'rm -f "$_NSNI_PROBE" "$_NSNI_FNTMP" 2>/dev/null' EXIT
    # Extract ONLY the gate function body (def line -> first column-0 `}`).
    sed -n "/^${NS_FN}()/,/^}/p" "$NS_VERIFY" > "$NS_FNTMP"
    # Run the gate in a subshell with REPO_ROOT set (the function reads it).
    _ns_run_gate() { ( REPO_ROOT="$REPO_ROOT"; . "$NS_FNTMP"; "$NS_FN" 2>&1 ); }
    # Baseline: the gate MUST be GREEN before we mutate (else the pair is moot).
    ns_base="$(_ns_run_gate)" || true
    if ! printf '%s\n' "$ns_base" | grep -q "\[PASS\] $NS_GATE"; then
        echo "  >>> baseline: $(printf '%s\n' "$ns_base" | grep -E "\[(PASS|FAIL)\] $NS_GATE" | head -3 | tr '\n' ';')"
        _skip "$NS_GATE: gate not GREEN pre-mutation (an unrelated escalation or human-wait already in tree) — conductor runs this in a clean tree"
    else
        # Inject a command-position privilege-escalation EXECUTION line into the
        # probe. printf keeps THIS source free of such a line (the gate scans us).
        printf '#!/usr/bin/env bash\nsudo true   # injected privilege escalation\n' > "$NS_PROBE"
        ns_mut="$(_ns_run_gate)" || true
        if printf '%s\n' "$ns_mut" | grep -q "\[FAIL\] $NS_GATE"; then
            echo "  [evidence] $(printf '%s\n' "$ns_mut" | grep "\[FAIL\] $NS_GATE" | head -1)"
            _pass "$NS_GATE MUTATION CAUGHT — gate (C) [FAIL]s on a command-position privilege-escalation EXECUTION injected anywhere under scripts/ (operator mandate 2026-06-29)"
        else
            echo "  >>> gate (mutated): $(printf '%s\n' "$ns_mut" | grep -E "\[(PASS|FAIL)\] $NS_GATE" | tr '\n' ';')"
            _fail "$NS_GATE MUTATION ESCAPED — gate did not [FAIL] despite an injected escalation EXECUTION line under scripts/"
        fi
        rm -f "$NS_PROBE" 2>/dev/null || true
        # Restore-direction proof: cleaned tree is GREEN — print-only advice
        # (incl. "(as root) setcap …") is false-positive-free.
        ns_rev="$(_ns_run_gate)" || true
        if printf '%s\n' "$ns_rev" | grep -q "\[PASS\] $NS_GATE"; then
            _pass "$NS_GATE FEATURE RESTORED — gate [PASS]es on the cleaned tree (print-only advice does not trip it)"
        else
            echo "  >>> gate (restored): $(printf '%s\n' "$ns_rev" | grep -E "\[(PASS|FAIL)\] $NS_GATE" | tr '\n' ';')"
            _fail "$NS_GATE — gate did not [PASS] after probe removal"
        fi
    fi
    rm -f "$NS_PROBE" "$NS_FNTMP" 2>/dev/null || true
    trap - EXIT
fi

# ── M-MASK / M-LIVEFIRST / M-CONFIRM / M-SUFFIX (§11.4.120 reconciliation,
#    2026-07-05) — CORRECTED after the whole-branch independent review
#    (Task 12) found the original 4 entries were bluff gates: (1) they
#    mutated the .template SOURCE files, but the tests they gate execute
#    the separately-GENERATED, gitignored scripts/tmx / scripts/tmx-shell-
#    init.sh artefacts — no rebuild ran between mutate and test, so the
#    mutation never reached the code under test; (2) the bare "FAIL"
#    expect-regex tautologically matches every test's OWN passing summary
#    line ("... PASS=2 FAIL=0 SKIP=0 ..."), so "MUTATION CAUGHT" reported
#    true even when the mutation had zero effect. Independently
#    re-verified both defects before fixing (dry-run: bare grep -qE "FAIL"
#    matches "FAIL=0"; `file scripts/tmx` confirms it is a real generated
#    artefact, not a symlink; run_mutation() never calls setup.sh).
#    Fixed by switching to v109_run_mutation (the established pattern for
#    this exact situation — see M25/M26 above) targeting the GENERATED
#    scripts/tmx / scripts/tmx-shell-init.sh directly (cp-restore is clean,
#    matches source byte-for-byte since no placeholder substitution
#    touches these lines) with a precise per-test FAIL-prefix regex that
#    cannot match a clean summary line.
v109_run_mutation \
    "M-MASK" \
    "password masking echoes plaintext instead of '*' (test 77)" \
    "scripts/tmx" \
    "inplace_sed 's|printf .\\*. >/dev/tty|printf \"%s\" \"\$char\" >/dev/tty|' \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/77_password_masked_echo.sh" \
    "FAIL 77"

# NOTE: the has-session guard text is byte-identical to an UNRELATED,
# pre-existing check in the `new` verb (§11.4.108 create-failure detection,
# ~150 lines earlier) — a plain sed 's|...|...|' would silently mutate BOTH
# occurrences. Scoped to the `attach|attach-session|a)` case block (the
# ONLY unique anchor immediately preceding this task's occurrence) via a
# sed address range so the `new` verb's own check is never touched.
v109_run_mutation \
    "M-LIVEFIRST" \
    "attach verb no longer checks liveness before password prompt (test 84)" \
    "scripts/tmx" \
    "inplace_sed '/attach|attach-session|a)/,+15 s|if ! \"\$TMUX_BIN\" -L \"\$SOCK_LABEL\" has-session -t \"\$NAME\" 2>/dev/null; then|if false; then|' \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/84_attach_dead_session_no_prompt.sh" \
    "FAIL 84"

v109_run_mutation \
    "M-CONFIRM" \
    "new-password flow accepts without confirmation (test 80)" \
    "scripts/tmx" \
    "inplace_sed 's|if \\[ \"\$_pw1\" = \"\$_pw2\" \\]; then|if true; then|' \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/80_new_password_confirm_flow.sh" \
    "FAIL 80"

v109_run_mutation \
    "M-SUFFIX" \
    "wizard suffix generation forced to empty string (test 78)" \
    "scripts/tmx-shell-init.sh" \
    "inplace_sed 's|_suffix=\$(awk .*|_suffix=\"\"|' \"\$target_abs\" && chmod 755 \"\$target_abs\"" \
    "scripts/tests/78_wizard_suffix_appended.sh" \
    "FAIL 78"

# ── M-CSIU: strip extended-keys-format csi-u from tmux.conf.template
# (test 85 catches config template missing the setting).
# Kimi Code TUI recommendation 2026-07-17: "tmux extended-keys-format is
# xterm. Kimi Code works best with csi-u." The setting was added to
# scripts/tmux.conf.template; this mutation removes it and asserts test 85
# catches the missing config line.
v109_run_mutation \
    "M-CSIU" \
    "strip extended-keys-format csi-u from tmux.conf.template (test 85)" \
    "scripts/tmux.conf.template" \
    "inplace_sed '/extended-keys-format.*csi-u/d' \"\$target_abs\"" \
    "scripts/tests/85_extended_keys_format_csi_u.sh" \
    "FAIL 85"

# ── M-CPUADAPT: revert CPU-unlimited-by-default back to the (still
# broken, just differently-broken) "always apply a cap" behaviour (test 86
# catches the regression). §11.4.115(F): the canonical mutation for a
# landed fix is the fix-commit's revert. 2026-08-10 RECONCILED (§11.4.120)
# — the 2026-08-10 fix changed the DEFAULT from `${TMX_CPU:-auto}`
# (always-capped) to `${TMX_CPU:-}` (unlimited); this mutation now reverts
# THAT change (re-introduces the unconditional cap), which the ORIGINAL
# mutation's sed pattern could no longer even match once the fix landed
# (a silently-escaping paired mutation is itself a §1.1 bluff — caught and
# fixed in the same commit as the reconciliation). Test 86 G2 asserts CPU
# is unlimited by default; with the mutation applied G2 FAILs.
v109_run_mutation \
    "M-CPUADAPT" \
    "revert CPU-unlimited-by-default to an always-applied cap in tmx.template (test 86)" \
    "scripts/tmx.template" \
    "inplace_sed 's|TMX_CPU_EFFECTIVE=\"\${TMX_CPU:-}\"|TMX_CPU_EFFECTIVE=\"\${TMX_CPU:-auto}\"|' \"\$target_abs\"" \
    "scripts/tests/86_cpu_quota_host_adaptive.sh" \
    "FAIL: G2"

# ── M-NOLIMITS: revert the 2026-08-10 no-limits-by-default fix (test 88
# catches the regression). §11.4.115(F) canonical mutation = the fix-
# commit's revert. Forensic anchor: operator report "sessions and
# processes get killed and wiped out ... on powerful hardware with enough
# resources" — root-caused to the idle-recycler defaulting ON at 900s (the
# dominant cause) plus a hardcoded, unconfigurable TasksMax=4096. This
# mutation re-introduces BOTH: the recycler defaults back to 900s (in the
# wrapper's own window resolution) and TasksMax is hardcoded again in the
# shared-topology systemd-run invocation. Test 88 G2 asserts idle-recycle
# is off by default AND TasksMax is configurable (no hardcoded 4096); with
# the mutation applied G2 FAILs.
v109_run_mutation \
    "M-NOLIMITS" \
    "revert idle-recycle-off-by-default (900s) and TasksMax hardcode in tmx.template (test 88)" \
    "scripts/tmx.template" \
    "inplace_sed 's|TMX_RECYCLE_WINDOW=\"\${TMX_RECYCLE_IDLE_SECS:-0}\"|TMX_RECYCLE_WINDOW=\"\${TMX_RECYCLE_IDLE_SECS:-900}\"|' \"\$target_abs\" && inplace_sed 's|-p \"TasksMax=\${TMX_TASKS_EFFECTIVE}\"|-p \"TasksMax=4096\"|' \"\$target_abs\"" \
    "scripts/tests/88_no_limits_by_default.sh" \
    "FAIL: G2"

# ── M72: obtain_local_deps.sh — change libevent+ncurses envprefix so that
#    resolved.env emits variables under WRONG names (§1.1 paired mutation
#    for test 72). The dep still resolves correctly (exit 0), but the
#    resolved.env has BROKEN_LE_M72_LIBDIR instead of LIBEVENT_LIBDIR, so test
#    72's _assert_build_dep_wired finds no wiring → B1/B2 FAIL. This proves
#    the GREEN guard catches a drift in the dep→envprefix mapping — the
#    exact source-level error that would make tmux's ./configure link step
#    miss a local dep while reporting success.
v109_run_mutation \
    "M72" \
    "change libevent+ncurses envprefix in obtain_local_deps.sh dep catalog so resolved.env emits variables under wrong names (test 72 B1/B2 fails — no expected LIBEVENT_*/NCURSES_* wiring found)" \
    "scripts/obtain_local_deps.sh" \
    "inplace_sed '/libevent:envprefix)/s/LIBEVENT/BROKEN_LE_M72/' \"\$target_abs\" && inplace_sed '/ncurses:envprefix)/s/NCURSES/BROKEN_NC_M72/' \"\$target_abs\"" \
    "scripts/tests/72_libevent_ncurses_obtain.sh" \
    "^FAIL 72"

# ── M73: build_native.sh — replace the libevent/ncurses -I/-L wiring values
#    with bogus paths (§1.1 paired mutation for test 73). The LE_CPPFLAGS/LE_LDFLAGS
#    and NC_CPPFLAGS/NC_LDFLAGS assignments still execute (guards still fire because
#    resolved.env has the source variables), but produce -I/M73/broken instead of
#    -I<INC_LE>. The D0 marker check still passes (LIBEVENT_INCDIR text is preserved
#    in the guard), but D1/D2 FAIL because the computed CFLAGS/LDFLAGS lack the
#    expected include+lib dirs.
v109_run_mutation \
    "M73" \
    "replace libevent+ncurses -I/-L wiring values with bogus paths in build_native.sh (test 73 D1/D2 fails — no expected -I/-L flags in computed CFLAGS/LDFLAGS)" \
    "scripts/build_native.sh" \
    "inplace_sed 's#-I\${LIBEVENT_INCDIR}#-I/M73/broken#' \"\$target_abs\" && inplace_sed 's#-L\${LIBEVENT_LIBDIR}#-L/M73/broken#' \"\$target_abs\" && inplace_sed 's#-I\${NCURSES_INCDIR}#-I/M73/broken#' \"\$target_abs\" && inplace_sed 's#-L\${NCURSES_LIBDIR}#-L/M73/broken#' \"\$target_abs\"" \
    "scripts/tests/73_build_native_localdeps_wiring.sh" \
    "^FAIL 73"

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY (relocated post-M24 by P5 so v1.0.9 mutations count in totals)
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
