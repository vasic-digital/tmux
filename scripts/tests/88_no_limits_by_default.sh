#!/usr/bin/env bash
# Test 88 — tmx sessions default to NO resource/lifetime limits; every cap
# is strictly opt-in (§11.4.115 RED/GREEN polarity).
#
# Forensic anchor (operator report, 2026-08-10): "sessions and processes get
# killed and wiped out ... on powerful hardware with enough resources".
# Root cause (systematic-debugging investigation, this commit): THREE
# defaults, each independently applying a cap/kill with no full opt-out:
#   1. tmx-recycler.sh idle-timeout watcher, wired into EVERY session by
#      default (TMX_RECYCLE_IDLE_SECS unset => 900s), tears down (kill-
#      session + scope-stop) ANY session with no client attached for >= 15
#      minutes — using #{session_attached}==0 as the SOLE idle signal
#      (explicitly NOT #{session_activity}), so a genuinely-active detached
#      background/autonomous job (the normal, project-mandated way to run
#      long tmx work) is killed regardless of whether it is doing anything.
#      This is the ONLY mechanism in the codebase that actually KILLS an
#      already-running session's processes irrespective of host capacity —
#      the dominant match for "killed and wiped out ... anyway".
#   2. CPUQuota applied unconditionally to every scope (host-adaptive since
#      v1.0.37, but still a hard throttle with no off switch).
#   3. TasksMax=4096 hardcoded per scope with NO override knob at all
#      (inconsistent with the TMX_MEM / TMX_CPU opt-in pattern) — a large
#      multi-agent fleet on a powerful host can legitimately need many
#      thousands of threads/processes (universal Constitution §12.12).
#
# Fix under test: memory was ALREADY fully elastic by default (Constitution
# §105/§106 "liquid" model, MemoryMax=infinity, no change needed) — CPU,
# Tasks, and session lifetime are brought into the SAME "elastic by default,
# opt-in cap" pattern:
#   TMX_CPU_EFFECTIVE="${TMX_CPU:-}"                (was "${TMX_CPU:-auto}")
#   TMX_TASKS_EFFECTIVE="${TMX_TASKS:-infinity}"    (was hardcoded 4096, no knob)
#   TMX_RECYCLE_WINDOW="${TMX_RECYCLE_IDLE_SECS:-0}" (was "${...:-900}")
# `auto` remains available on TMX_CPU / TMX_TASKS as an explicit OPT-IN to
# the previous host-adaptive / legacy-fixed values; an explicit numeric
# value on any of the three knobs still works exactly as before.
#
# Polarity (§11.4.115 — ONE source, TWO roles):
#   RED_MODE=1  reproduce-and-assert-DEFECT-PRESENT on the pre-fix artifact
#               (exit 0 iff all three unconditional-cap defaults are there).
#   RED_MODE=0  (default) regression GUARD: assert the opt-in-only defaults
#               are present, functionally correct, and (Linux) actually land
#               on a freshly-spawned session's cgroup + tmux hooks
#               (§11.4.108 layer 3) — AND that the opt-in knobs still work
#               when explicitly requested (§11.4.120 — the valuable
#               host-adaptive/legacy-fixed code paths are preserved, only
#               their DEFAULT-ON status changes).
#
# Env:
#   T88_TARGET     wrapper source to statically/functionally test
#                  (default $REPO_ROOT/scripts/tmx.template)
#   T88_RC_TARGET  recycler source (default $REPO_ROOT/scripts/tmx-recycler.sh)
#   T88_LIVE       1 (default) run the Linux live-scope spawn subtests; 0 skip
#   WRAPPER        executable wrapper for the live subtest (default scripts/tmx)

set -uo pipefail

RED_MODE="${RED_MODE:-0}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# §11.4.3/§11.4.50: this test asserts NO-LIMITS-BY-DEFAULT and reads session
# cgroups back, so ambient operator knobs would decide its verdict. With an
# exported TMX_SERVER_SPLIT=1, G6a reads the server scope's TasksMax=256
# instead of the opt-in 4096 (which correctly lands on the WORKLOAD SLICE)
# -> a §11.4.1 FAIL-bluff. Opt-in sub-tests set their knobs explicitly.
. "$(cd "$(dirname "$0")" && pwd)/lib/hermetic_env.sh"
TARGET="${T88_TARGET:-$REPO_ROOT/scripts/tmx.template}"
RC_TARGET="${T88_RC_TARGET:-$REPO_ROOT/scripts/tmx-recycler.sh}"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
T88_LIVE="${T88_LIVE:-1}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

echo "── Test 88: no resource/lifetime limits by default (RED_MODE=$RED_MODE) ──"
echo "  target: $TARGET"
echo "  recycler: $RC_TARGET"

[ -r "$TARGET" ] || { echo "FAIL: target $TARGET not readable"; exit 1; }
[ -r "$RC_TARGET" ] || { echo "FAIL: recycler target $RC_TARGET not readable"; exit 1; }

_has_cpu_auto_default=0
grep -q 'TMX_CPU_EFFECTIVE="\${TMX_CPU:-auto}"' "$TARGET" && _has_cpu_auto_default=1
_has_cpu_empty_default=0
grep -q 'TMX_CPU_EFFECTIVE="\${TMX_CPU:-}"' "$TARGET" && _has_cpu_empty_default=1
_has_tasks_knob=0
grep -q 'TMX_TASKS_EFFECTIVE' "$TARGET" && _has_tasks_knob=1
_has_hardcoded_tasksmax=0
grep -qE '^\s*-p "TasksMax=4096"' "$TARGET" && _has_hardcoded_tasksmax=1
_has_recycle_900_default=0
grep -q 'TMX_RECYCLE_WINDOW="\${TMX_RECYCLE_IDLE_SECS:-900}"' "$TARGET" && _has_recycle_900_default=1
_has_recycle_0_default=0
grep -q 'TMX_RECYCLE_WINDOW="\${TMX_RECYCLE_IDLE_SECS:-0}"' "$TARGET" && _has_recycle_0_default=1
_rc_has_900_default=0
grep -qE 'WINDOW="\$\{TMX_RC_WINDOW:-900\}"' "$RC_TARGET" && _rc_has_900_default=1

if [ "$RED_MODE" = "1" ]; then
    # Reproduce the defect: all three unconditional-cap defaults present.
    if [ "$_has_cpu_auto_default" -eq 1 ] && [ "$_has_hardcoded_tasksmax" -eq 1 ] && \
       [ "$_has_recycle_900_default" -eq 1 ] && [ "$_rc_has_900_default" -eq 1 ]; then
        _pass "RED: defect reproduced — CPU defaults to host-adaptive cap (not unlimited), TasksMax hardcoded 4096 with no knob, idle-recycle defaults ON at 900s in BOTH the wrapper and the recycler's own internal default"
    else
        _fail "RED: defect NOT present (cpu_auto=$_has_cpu_auto_default hardcoded_tasksmax=$_has_hardcoded_tasksmax recycle_900=$_has_recycle_900_default rc_900=$_rc_has_900_default) — artifact already carries the no-limits-by-default fix"
    fi
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

# ── GREEN guard mode ────────────────────────────────────────────────────
# G1: both wrappers parse (§11.4.67).
if bash -n "$TARGET" 2>/dev/null && bash -n "$RC_TARGET" 2>/dev/null; then
    _pass "G1: bash -n parse clean (tmx.template + tmx-recycler.sh)"
else
    _fail "G1: bash -n reports syntax errors"
fi

# G2: static wiring — no unconditional CPU cap default, TasksMax uses a
# configurable variable (not hardcoded), idle-recycle defaults OFF in BOTH
# the wrapper's window resolution AND the recycler script's own internal
# default (defence in depth — the recycler must be safe even if invoked
# directly without TMX_RC_WINDOW set).
if [ "$_has_cpu_empty_default" -eq 1 ] && [ "$_has_cpu_auto_default" -eq 0 ] && \
   [ "$_has_tasks_knob" -eq 1 ] && [ "$_has_hardcoded_tasksmax" -eq 0 ] && \
   [ "$_has_recycle_0_default" -eq 1 ] && [ "$_has_recycle_900_default" -eq 0 ] && \
   [ "$_rc_has_900_default" -eq 0 ]; then
    _pass "G2: no unconditional CPU cap, TasksMax configurable (no hardcoded 4096), idle-recycle OFF by default in both wrapper and recycler"
else
    _fail "G2: wiring wrong (cpu_empty=$_has_cpu_empty_default cpu_auto=$_has_cpu_auto_default tasks_knob=$_has_tasks_knob hardcoded_tasksmax=$_has_hardcoded_tasksmax recycle_0=$_has_recycle_0_default recycle_900=$_has_recycle_900_default rc_900=$_rc_has_900_default)"
fi

# G3: FUNCTIONAL truth-table for TMX_CPU_EFFECTIVE / TMX_TASKS_EFFECTIVE
# expansion — extract the real assignment lines and RUN them (never
# grep-only, §11.4.201/§11.4.108).
_cpu_asn="$(grep -E '^\s*TMX_CPU_EFFECTIVE=|^\s*\[ "\$TMX_CPU_EFFECTIVE" = auto \]' "$TARGET" | sed 's/^[[:space:]]*//')"
_tasks_asn="$(grep -E '^\s*TMX_TASKS_EFFECTIVE=|^\s*\[ "\$TMX_TASKS_EFFECTIVE" = auto \]' "$TARGET" | sed 's/^[[:space:]]*//')"

# unset FIRST in both helpers (§11.4.201 independent-review finding,
# 2026-08-10): the inner `bash -c` otherwise INHERITS any TMX_CPU/TMX_TASKS
# the operator's own shell rc has exported (e.g. per this fix's own
# documented opt-in `TMX_CPU=auto` / `TMX_TASKS=auto`) — the UNSET case
# would then spuriously read the ambient value instead of genuinely-unset,
# producing a false FAIL on exactly the opt-in configuration this fix is
# meant to keep working.
_expand_cpu() {  # _expand_cpu <TMX_CPU value or UNSET> → effective value
    bash -c "
        unset TMX_CPU
        _default_cpu_pct() { echo 777; }
        if [ '$1' != UNSET ]; then TMX_CPU='$1'; fi
        $_cpu_asn
        printf '%s' \"\$TMX_CPU_EFFECTIVE\"
    " 2>/dev/null
}
_expand_tasks() {  # _expand_tasks <TMX_TASKS value or UNSET> → effective value
    bash -c "
        unset TMX_TASKS
        if [ '$1' != UNSET ]; then TMX_TASKS='$1'; fi
        $_tasks_asn
        printf '%s' \"\$TMX_TASKS_EFFECTIVE\"
    " 2>/dev/null
}

if [ -n "$_cpu_asn" ]; then
    c_unset="$(_expand_cpu UNSET)"; c_auto="$(_expand_cpu auto)"; c_num="$(_expand_cpu 400)"
    if [ "$c_unset" = "" ] && [ "$c_auto" = "777" ] && [ "$c_num" = "400" ]; then
        _pass "G3a: TMX_CPU expansion — unset→'' (no cap), auto→adaptive(opt-in), explicit 400 preserved"
    else
        _fail "G3a: TMX_CPU expansion wrong: unset→'$c_unset' (want '') auto→'$c_auto' (want 777) 400→'$c_num' (want 400)"
    fi
else
    _fail "G3a: could not extract TMX_CPU_EFFECTIVE assignment from $TARGET"
fi

if [ -n "$_tasks_asn" ]; then
    t_unset="$(_expand_tasks UNSET)"; t_auto="$(_expand_tasks auto)"; t_num="$(_expand_tasks 8192)"
    if [ "$t_unset" = "infinity" ] && [ "$t_auto" = "4096" ] && [ "$t_num" = "8192" ]; then
        _pass "G3b: TMX_TASKS expansion — unset→infinity (no cap), auto→4096(legacy opt-in), explicit 8192 preserved"
    else
        _fail "G3b: TMX_TASKS expansion wrong: unset→'$t_unset' (want infinity) auto→'$t_auto' (want 4096) 8192→'$t_num' (want 8192)"
    fi
else
    _fail "G3b: could not extract TMX_TASKS_EFFECTIVE assignment from $TARGET"
fi

# G4: FUNCTIONAL recycler window default — extract the internal WINDOW
# resolution from tmx-recycler.sh and run it with TMX_RC_WINDOW unset.
_rc_asn="$(grep -E '^\s*WINDOW=|^\s*case "\$WINDOW" in' "$RC_TARGET" | sed 's/^[[:space:]]*//')"
if [ -n "$_rc_asn" ]; then
    w_unset="$(bash -c "unset TMX_RC_WINDOW; $_rc_asn; printf '%s' \"\$WINDOW\"" 2>/dev/null)"
    if [ "$w_unset" = "0" ]; then
        _pass "G4: recycler's own internal WINDOW default (invoked directly, no env) → 0 (disabled)"
    else
        _fail "G4: recycler internal WINDOW default → '$w_unset' (want 0)"
    fi
else
    _fail "G4: could not extract WINDOW resolution from $RC_TARGET"
fi

# G5 (Linux, live): a session spawned with NONE of TMX_CPU / TMX_TASKS /
# TMX_RECYCLE_IDLE_SECS set carries NO cgroup CPU/task cap and installs NO
# idle-recycle hook — §11.4.108 RUNTIME layer, read back from the kernel
# cgroup tree + tmux's own hook table (never the tool's own claim).
if [ "$T88_LIVE" != "1" ]; then
    _skip "G5: live spawn disabled (T88_LIVE=$T88_LIVE)"
elif [ "$(uname -s)" != "Linux" ]; then
    _skip "G5: Linux-only (cgroup CPUQuota/TasksMax); Darwin uses RLIMIT_CPU/RLIMIT_NPROC (test 24)"
elif [ ! -x "$WRAPPER" ]; then
    _skip "G5: wrapper $WRAPPER not executable"
elif ! systemd-run --user --scope --collect --quiet bash -c "exit 0" 2>/dev/null; then
    _skip "G5: systemd-run --user --scope not functional on this host"
else
    SESS="t88d_$$"
    SOCK="tmx-${SESS}"
    SCOPE_UNIT="tmx-${SESS}.scope"
    TMUX_BIN_T88="$(sed -n 's/^TMUX_BIN="\(.*\)"$/\1/p' "$WRAPPER" | head -1)"
    trap '
        systemctl --user stop "$SCOPE_UNIT" >/dev/null 2>&1 || true
        [ -n "${TMUX_BIN_T88:-}" ] && "$TMUX_BIN_T88" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    ' EXIT
    env -u TMX_CPU -u TMX_CPU_BURST -u TMX_TASKS -u TMX_RECYCLE_IDLE_SECS -u TMX_MEM \
        "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1
    sleep 1
    CG="$(systemctl --user show "$SCOPE_UNIT" -p ControlGroup --value 2>/dev/null)"
    CPU_MAX=""; PIDS_MAX=""
    if [ -n "$CG" ]; then
        CPU_MAX="$(cut -d' ' -f1 "/sys/fs/cgroup${CG}/cpu.max" 2>/dev/null)"
        PIDS_MAX="$(cat "/sys/fs/cgroup${CG}/pids.max" 2>/dev/null)"
    fi
    if [ "$CPU_MAX" = "max" ] && [ "$PIDS_MAX" = "max" ]; then
        _pass "G5a: default session cgroup — cpu.max=max (no CPUQuota) AND pids.max=max (no TasksMax) — positive cgroup readback"
    else
        _fail "G5a: default session cgroup NOT unlimited — cpu.max='$CPU_MAX' (want max) pids.max='$PIDS_MAX' (want max)"
    fi
    HOOKS="$("$TMUX_BIN_T88" -L "$SOCK" show-hooks -g -t "$SESS" 2>/dev/null || true)"
    if ! printf '%s' "$HOOKS" | grep -q 'tmx-recycler.sh'; then
        _pass "G5b: default session installs NO idle-recycle hook (session cannot be auto-killed by tmx itself)"
    else
        _fail "G5b: default session STILL installed the idle-recycle hook — sessions remain killable by default"
    fi
    systemctl --user stop "$SCOPE_UNIT" >/dev/null 2>&1 || true
    [ -n "${TMUX_BIN_T88:-}" ] && "$TMUX_BIN_T88" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    trap - EXIT
fi

# G6 (Linux, live): the opt-in knobs still work exactly as before when the
# operator explicitly asks for them together (§11.4.120 — reconciliation
# preserves the valuable host-adaptive/legacy code paths; only their
# default-on status changed).
if [ "$T88_LIVE" != "1" ]; then
    _skip "G6: live spawn disabled (T88_LIVE=$T88_LIVE)"
elif [ "$(uname -s)" != "Linux" ]; then
    _skip "G6: Linux-only; Darwin covered by test 24"
elif [ ! -x "$WRAPPER" ]; then
    _skip "G6: wrapper $WRAPPER not executable"
elif ! systemd-run --user --scope --collect --quiet bash -c "exit 0" 2>/dev/null; then
    _skip "G6: systemd-run --user --scope not functional on this host"
else
    SESS="t88o_$$"
    SOCK="tmx-${SESS}"
    SCOPE_UNIT="tmx-${SESS}.scope"
    TMUX_BIN_T88="$(sed -n 's/^TMUX_BIN="\(.*\)"$/\1/p' "$WRAPPER" | head -1)"
    trap '
        systemctl --user stop "$SCOPE_UNIT" >/dev/null 2>&1 || true
        [ -n "${TMUX_BIN_T88:-}" ] && "$TMUX_BIN_T88" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    ' EXIT
    TMX_CPU=auto TMX_TASKS=auto TMX_RECYCLE_IDLE_SECS=5 "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1
    sleep 1
    CG="$(systemctl --user show "$SCOPE_UNIT" -p ControlGroup --value 2>/dev/null)"
    CPU_MAX=""; PIDS_MAX=""
    if [ -n "$CG" ]; then
        CPU_MAX="$(cut -d' ' -f1 "/sys/fs/cgroup${CG}/cpu.max" 2>/dev/null)"
        PIDS_MAX="$(cat "/sys/fs/cgroup${CG}/pids.max" 2>/dev/null)"
    fi
    if [ -n "$CPU_MAX" ] && [ "$CPU_MAX" != "max" ] && [ "$PIDS_MAX" = "4096" ]; then
        _pass "G6a: TMX_CPU=auto TMX_TASKS=auto — live scope cpu.max=$CPU_MAX (bounded, opt-in) AND pids.max=4096 (legacy opt-in value)"
    else
        _fail "G6a: opt-in knobs did not land — cpu.max='$CPU_MAX' (want a bounded value) pids.max='$PIDS_MAX' (want 4096)"
    fi
    HOOKS="$("$TMUX_BIN_T88" -L "$SOCK" show-hooks -g -t "$SESS" 2>/dev/null || true)"
    if printf '%s' "$HOOKS" | grep -q 'tmx-recycler.sh'; then
        _pass "G6b: TMX_RECYCLE_IDLE_SECS=5 — idle-recycle hook IS installed (opt-in mechanism still wired)"
    else
        _fail "G6b: TMX_RECYCLE_IDLE_SECS=5 was set but no idle-recycle hook was installed"
    fi
    systemctl --user stop "$SCOPE_UNIT" >/dev/null 2>&1 || true
    [ -n "${TMUX_BIN_T88:-}" ] && "$TMUX_BIN_T88" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    trap - EXIT
fi

echo ""
echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
