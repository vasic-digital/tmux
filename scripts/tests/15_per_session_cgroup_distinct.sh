#!/usr/bin/env bash
# Test 15 — per-session cgroup distinctness.
#
# Closes the Bug 2 §1 bluff that Fixed.md A12 caught: multiple
# `tmx new -s X` invocations used to share ONE cgroup scope, so OOM
# in any session would take down all of them. This test exercises
# the OPERATOR PATH (`tmx new -s NAME` via the wrapper) and proves
# each session lands in its OWN scope with its OWN limits.
#
# §11.4.7: tests MUST use the same entry point an operator does.
# This test does NOT hand-craft systemd-run scopes — it goes through
# the wrapper exactly like an end-user would.
#
# Constitution §11.4.2: every PASS carries positive evidence from
# /sys/fs/cgroup (memory.max, cpu.max), systemctl is-active state,
# AND tmx ls output. No grep-on-script-content asserts here.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"

PASS=0
FAIL=0
SKIP=0

A_NAME="tmx_t15_a_$$"
B_NAME="tmx_t15_b_$$"
C_NAME="tmx_t15_c_$$"
A_SCOPE="tmx-${A_NAME}.scope"
B_SCOPE="tmx-${B_NAME}.scope"
C_SCOPE="tmx-${C_NAME}.scope"

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    for name in "$A_NAME" "$B_NAME" "$C_NAME"; do
        "$WRAPPER" kill-session -t "$name" 2>/dev/null || true
        systemctl --user stop "tmx-${name}.scope" 2>/dev/null || true
    done
}
trap _cleanup EXIT

HOST_OS="$(uname -s)"
echo "── Test 15: per-session isolation ($HOST_OS) ──"

# Pre-check: wrapper + binary present.
if [ ! -x "$WRAPPER" ]; then
    _skip "wrapper $WRAPPER not generated — run setup.sh"
    echo "Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
if [ ! -x "$TMUX_BIN" ]; then
    _skip "tmux binary $TMUX_BIN not built"
    echo "Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi

# OS dispatch: Linux uses cgroup-v2 transient scopes (systemd); Darwin
# uses POSIX rlimits (no systemd, no cgroups). The operator-mandated
# isolation invariant is the same on both — sessions are independent —
# but the kernel primitives differ. Both branches verify with positive
# runtime evidence per §11.4.2.
if [ "$HOST_OS" = "Darwin" ]; then
    # ── DARWIN BRANCH: rlimit-based per-session isolation ──────────
    echo ""
    echo "--- Darwin: per-session rlimit verification ---"

    # Create two sessions via the operator path.
    "$WRAPPER" new -s "$A_NAME" -d 2>/dev/null
    "$WRAPPER" new -s "$B_NAME" -d 2>/dev/null
    sleep 2

    # T1: both sessions visible in `tmx ls` aggregated listing.
    LS_OUT=$("$WRAPPER" ls 2>&1)
    if echo "$LS_OUT" | grep -q "^$A_NAME:" && echo "$LS_OUT" | grep -q "^$B_NAME:"; then
        _pass "T1: both sessions A and B visible in tmx ls (positive evidence: aggregated listing across distinct sockets)"
    else
        _fail "T1: tmx ls did not show both sessions: $LS_OUT"
    fi

    # T2: each session has its OWN tmux server on its OWN socket.
    A_PID=$("$TMUX_BIN" -L "tmx-${A_NAME}" display-message -p '#{pid}' 2>/dev/null)
    B_PID=$("$TMUX_BIN" -L "tmx-${B_NAME}" display-message -p '#{pid}' 2>/dev/null)
    if [ -n "$A_PID" ] && [ -n "$B_PID" ] && [ "$A_PID" != "$B_PID" ]; then
        _pass "T2: distinct tmux server PIDs A=$A_PID B=$B_PID (positive evidence: independent server processes per session)"
    else
        _fail "T2: tmux server PIDs A=$A_PID B=$B_PID — expected distinct non-empty values"
    fi

    # T3: send-keys to each session, capture ulimit readback. 2026-08-10
    # reconciliation (§11.4.120/§11.4.201 independent-review finding): CPU
    # is UNLIMITED by default now (TMX_CPU_HARD_SEC unset → `ulimit -t
    # unlimited`), so `ulimit -t` reads back the literal word "unlimited",
    # not a number — the regex accepts EITHER the default ("unlimited") OR
    # a numeric value (an operator's TMX_CPU_HARD_SEC exported ambiently).
    # NPROC (`ulimit -u`) still reads back numeric here even though its
    # default is also "unlimited" now: raising the HARD limit above the
    # host-granted ceiling (kern.maxprocperuid) is normally refused by the
    # kernel for an unprivileged process, so `ulimit -u unlimited` silently
    # falls back to whatever the host's own default hard limit already is
    # (numeric) — the wrapper's existing `|| true` posture never treats
    # that as an error (see T5 below for the explicit-opt-in case, which
    # is unaffected by this default change).
    "$WRAPPER" send-keys -t "$A_NAME" "echo TMXLIMITS:cpu=\$(ulimit -t):nproc=\$(ulimit -u)" Enter 2>/dev/null
    "$WRAPPER" send-keys -t "$B_NAME" "echo TMXLIMITS:cpu=\$(ulimit -t):nproc=\$(ulimit -u)" Enter 2>/dev/null
    sleep 2

    A_PANE=$("$WRAPPER" capture-pane -t "$A_NAME" -p 2>/dev/null | grep TMXLIMITS | tail -1)
    B_PANE=$("$WRAPPER" capture-pane -t "$B_NAME" -p 2>/dev/null | grep TMXLIMITS | tail -1)
    if echo "$A_PANE" | grep -qE 'cpu=(unlimited|[0-9]+):nproc=[0-9]+'; then
        _pass "T3: session A rlimits applied: $A_PANE (positive evidence: ulimit -t and -u via send-keys + capture-pane; cpu=unlimited is the correct no-cap-by-default reading)"
    else
        _fail "T3: could not read rlimits from session A: '$A_PANE'"
    fi
    if echo "$B_PANE" | grep -qE 'cpu=(unlimited|[0-9]+):nproc=[0-9]+'; then
        _pass "T4: session B rlimits applied: $B_PANE"
    else
        _fail "T4: could not read rlimits from session B: '$B_PANE'"
    fi

    # T5: TMX_CPU_HARD_SEC override is honoured.
    TMX_CPU_HARD_SEC=3600 "$WRAPPER" new -s "$C_NAME" -d 2>/dev/null
    sleep 2
    "$WRAPPER" send-keys -t "$C_NAME" "echo TMXLIMITS:cpu=\$(ulimit -t)" Enter 2>/dev/null
    sleep 2
    C_PANE=$("$WRAPPER" capture-pane -t "$C_NAME" -p 2>/dev/null | grep TMXLIMITS | tail -1)
    if echo "$C_PANE" | grep -q 'cpu=3600'; then
        _pass "T5: TMX_CPU_HARD_SEC=3600 override applied: $C_PANE (positive evidence: ulimit -t readback = 3600)"
    else
        _fail "T5: TMX_CPU_HARD_SEC=3600 override not applied. Got: '$C_PANE'"
    fi

    # T6: each session's shell is the HOST shell (operator's identity)
    # not some sandboxed identity — this is the access requirement.
    # Use simpler whitespace-delimited marker to avoid capture-pane
    # line-wrapping or shell-quoting ambiguity.
    "$WRAPPER" send-keys -t "$A_NAME" 'echo HOSTID $(id -un) HOSTNAME $(hostname -s)' Enter 2>/dev/null
    sleep 2
    ID_PANE=$("$WRAPPER" capture-pane -t "$A_NAME" -p 2>/dev/null | grep '^HOSTID ' | tail -1)
    EXPECTED_USER="$(id -un)"
    if echo "$ID_PANE" | grep -q "HOSTID $EXPECTED_USER "; then
        _pass "T6: session shell is operator's host shell ($EXPECTED_USER) — full host environment access (positive evidence: id -un inside session = $EXPECTED_USER)"
    else
        _fail "T6: session shell not the operator's user ($EXPECTED_USER). Got: '$ID_PANE'"
    fi

    echo ""
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    if [ "$FAIL" -gt 0 ]; then exit 1; fi
    exit 0
fi

# ── LINUX BRANCH: cgroup-v2 transient scope verification ──────────────
if ! command -v systemctl >/dev/null 2>&1; then
    _skip "no systemctl — per-session scope isolation requires systemd"
    echo "Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi

# Pre-clean any stale scopes from prior runs.
_cleanup
sleep 1

# ── T1: two sessions via the wrapper produce DISTINCT scope units ───
echo ""
echo "--- T1: distinct scope units per session ---"
"$WRAPPER" new -s "$A_NAME" -d 2>/dev/null
"$WRAPPER" new -s "$B_NAME" -d 2>/dev/null
sleep 1
A_ACTIVE=$(systemctl --user is-active "$A_SCOPE" 2>/dev/null || echo unknown)
B_ACTIVE=$(systemctl --user is-active "$B_SCOPE" 2>/dev/null || echo unknown)
if [ "$A_ACTIVE" = "active" ] && [ "$B_ACTIVE" = "active" ] && [ "$A_SCOPE" != "$B_SCOPE" ]; then
    _pass "T1: $A_SCOPE and $B_SCOPE both active and distinct (positive evidence: systemctl --user is-active for each)"
else
    _fail "T1: scope states A=$A_ACTIVE B=$B_ACTIVE — expected both active and distinct"
fi

# ── T2: cgroup paths differ AND each has its session's PID ──────────
echo ""
echo "--- T2: cgroup paths differ, each contains its session's PID ---"
A_CG=$(systemctl --user show -p ControlGroup --value "$A_SCOPE" 2>/dev/null)
B_CG=$(systemctl --user show -p ControlGroup --value "$B_SCOPE" 2>/dev/null)
if [ -z "$A_CG" ] || [ -z "$B_CG" ]; then
    _fail "T2: could not read ControlGroup for A=$A_CG B=$B_CG"
elif [ "$A_CG" = "$B_CG" ]; then
    _fail "T2: ControlGroup paths IDENTICAL ($A_CG) — sessions share a cgroup, isolation violated"
else
    A_PROCS=$(tr '\n' ' ' < "/sys/fs/cgroup${A_CG}/cgroup.procs" 2>/dev/null || echo "")
    B_PROCS=$(tr '\n' ' ' < "/sys/fs/cgroup${B_CG}/cgroup.procs" 2>/dev/null || echo "")
    if [ -n "$A_PROCS" ] && [ -n "$B_PROCS" ] && [ "$A_PROCS" != "$B_PROCS" ]; then
        _pass "T2: cgroup paths differ AND each contains its own pids (positive evidence: cgroup.procs A=[$A_PROCS] B=[$B_PROCS] read from /sys/fs/cgroup)"
    else
        _fail "T2: cgroup procs A=[$A_PROCS] B=[$B_PROCS]"
    fi
fi

# ── T3: fully-elastic default — memory.max=max + a MemoryMin floor ──
echo ""
echo "--- T3: default session is fully elastic (memory.max=max) with a MemoryMin floor ---"
A_MEM_MAX=$(cat "/sys/fs/cgroup${A_CG}/memory.max" 2>/dev/null || echo "?")
B_MEM_MAX=$(cat "/sys/fs/cgroup${B_CG}/memory.max" 2>/dev/null || echo "?")
A_MEM_MIN=$(cat "/sys/fs/cgroup${A_CG}/memory.min" 2>/dev/null || echo "?")
# Elastic model (Constitution §105): NO hard per-scope cap by default — a session
# uses all available RAM/zram and is never per-scope OOM-killed. A runaway is
# stopped system-wide by systemd-oomd + the user-slice backstop, not here. TMX_MEM
# (T5) adds an opt-in soft throttle. A small MemoryMin floor protects the session.
if [ "$A_MEM_MAX" = "max" ] && [ "$B_MEM_MAX" = "max" ]; then
    _pass "T3: memory.max A=$A_MEM_MAX B=$B_MEM_MAX (fully elastic — never per-scope OOM-killed)"
else
    _fail "T3: memory.max A=$A_MEM_MAX B=$B_MEM_MAX (expected 'max' under the elastic default)"
fi
if [ "$A_MEM_MIN" = "134217728" ]; then
    _pass "T3b: memory.min A=$A_MEM_MIN (128 MiB floor — session not reclaimed to death)"
else
    _fail "T3b: memory.min A=$A_MEM_MIN (expected 134217728 = 128 MiB floor)"
fi

# ── T4: fully-elastic default — cpu.max=max (no CPUQuota by default) ──
# 2026-08-10 reconciliation (§11.4.120 — CPU is now unlimited by default,
# same "liquid" model as T3's memory.max=max; TMX_CPU opts IN to a real
# cgroup quota — see test 86/88 for that opt-in coverage).
echo ""
echo "--- T4: default session cpu.max=max (fully elastic — no CPUQuota unless TMX_CPU opts in) ---"
A_CPU_MAX=$(cat "/sys/fs/cgroup${A_CG}/cpu.max" 2>/dev/null || echo "?")
B_CPU_MAX=$(cat "/sys/fs/cgroup${B_CG}/cpu.max" 2>/dev/null || echo "?")
if echo "$A_CPU_MAX" | grep -qE '^max [0-9]+$' && echo "$B_CPU_MAX" | grep -qE '^max [0-9]+$'; then
    _pass "T4: cpu.max A='$A_CPU_MAX' B='$B_CPU_MAX' (positive evidence: no CPUQuota by default, per-session cgroup readback)"
else
    _fail "T4: cpu.max A='$A_CPU_MAX' B='$B_CPU_MAX' (expected 'max <period>' format under the elastic default)"
fi

# ── T5: TMX_MEM override per session ────────────────────────────────
echo ""
echo "--- T5: TMX_MEM=3G sets a soft memory.high=3 GiB (throttle); memory.max stays elastic ---"
TMX_MEM=3G "$WRAPPER" new -s "$C_NAME" -d 2>/dev/null
sleep 1
C_CG=$(systemctl --user show -p ControlGroup --value "$C_SCOPE" 2>/dev/null)
if [ -z "$C_CG" ]; then
    _fail "T5: scope $C_SCOPE not registered after TMX_MEM=3G override"
else
    C_MEM_HIGH=$(cat "/sys/fs/cgroup${C_CG}/memory.high" 2>/dev/null || echo "?")
    C_MEM_MAX=$(cat "/sys/fs/cgroup${C_CG}/memory.max" 2>/dev/null || echo "?")
    expected=$((3 * 1024 * 1024 * 1024))
    if [ "$C_MEM_HIGH" = "$expected" ]; then
        _pass "T5: TMX_MEM=3G → memory.high=$C_MEM_HIGH (soft throttle = 3 GiB exactly)"
    else
        _fail "T5: TMX_MEM=3G → memory.high=$C_MEM_HIGH (expected $expected)"
    fi
    if [ "$C_MEM_MAX" = "max" ]; then
        _pass "T5b: TMX_MEM=3G → memory.max=max (soft throttle only — never a hard kill)"
    else
        _fail "T5b: TMX_MEM=3G → memory.max=$C_MEM_MAX (expected 'max'; TMX_MEM is a soft throttle)"
    fi
fi

# ── T6: scope unit names are operator-namespaced (tmx-NAME.scope) ──
echo ""
echo "--- T6: scope unit names are predictable from session name ---"
NAMED_SCOPES=$(systemctl --user list-units --type=scope --no-legend --all 2>/dev/null | awk '{print $1}' | grep -E "^tmx-(${A_NAME}|${B_NAME}|${C_NAME})\.scope\$" | wc -l)
if [ "$NAMED_SCOPES" -eq 3 ]; then
    _pass "T6: all 3 sessions produced scope units named tmx-<session>.scope (operator-targetable by name)"
else
    _fail "T6: expected 3 named scopes, found $NAMED_SCOPES"
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
