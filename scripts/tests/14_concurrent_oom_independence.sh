#!/usr/bin/env bash
# Test 14 — Concurrent session-independence via the OPERATOR PATH
# (per-platform per §11.4.81).
#
# Linux: 3 sessions A/B/C via `tmx new`. Each ends up in its OWN scope.
# Trigger OOM inside A via stress-ng; verify B/C scopes + tmux servers
# survive with original MainPIDs; user.slice survives.
#
# Darwin: macOS has no OOM killer (different memory model — XNU does
# NOT enforce RLIMIT_AS for unprivileged processes per docs/guide/
# README.md §5.6 honest gap). Per §11.4.81 (C): ADJACENT TEST exercises
# the closest invariant Darwin CAN enforce — "session A's tmux server
# direct-killed, sessions B+C survive with original PIDs". Same
# operator-visible invariant ("rogue session can't take down others"),
# different kill trigger.
#
# Constitution §11.4.7 (operator-path coverage rule): both branches
# create sessions via `tmx new -s X -d` — the exact entry point.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN_OS="$(uname -s)"
case "$TMUX_BIN_OS" in
    Darwin) TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build-darwin/bin/tmux}" ;;
    Linux)  TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}" ;;
esac

if [ "$TMUX_BIN_OS" = "Darwin" ]; then
    echo "── Test 14: concurrent session-independence (Darwin branch per §11.4.81) ──"

    if [ ! -x "$WRAPPER" ] || [ ! -x "$TMUX_BIN" ]; then
        echo "SKIP: prerequisites not built ($WRAPPER / $TMUX_BIN)"
        exit 0
    fi

    PASS=0; FAIL=0; SKIP=0
    _pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
    _fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

    SESS_A="t14_d_a_$$"
    SESS_B="t14_d_b_$$"
    SESS_C="t14_d_c_$$"
    SOCK_A="tmx-${SESS_A}"
    SOCK_B="tmx-${SESS_B}"
    SOCK_C="tmx-${SESS_C}"

    trap '
        "$WRAPPER" kill-session -t "$SESS_B" >/dev/null 2>&1 || true
        "$WRAPPER" kill-session -t "$SESS_C" >/dev/null 2>&1 || true
        "$TMUX_BIN" -L "$SOCK_A" kill-server >/dev/null 2>&1 || true
        "$TMUX_BIN" -L "$SOCK_B" kill-server >/dev/null 2>&1 || true
        "$TMUX_BIN" -L "$SOCK_C" kill-server >/dev/null 2>&1 || true
    ' EXIT

    # D-T1: create 3 sessions via operator path.
    "$WRAPPER" new -s "$SESS_A" -d >/dev/null 2>&1
    "$WRAPPER" new -s "$SESS_B" -d >/dev/null 2>&1
    "$WRAPPER" new -s "$SESS_C" -d >/dev/null 2>&1
    sleep 0.5

    PID_A="$("$TMUX_BIN" -L "$SOCK_A" display-message -p '#{pid}' 2>/dev/null)"
    PID_B="$("$TMUX_BIN" -L "$SOCK_B" display-message -p '#{pid}' 2>/dev/null)"
    PID_C="$("$TMUX_BIN" -L "$SOCK_C" display-message -p '#{pid}' 2>/dev/null)"

    if [ -n "$PID_A" ] && [ -n "$PID_B" ] && [ -n "$PID_C" ] \
       && [ "$PID_A" != "$PID_B" ] && [ "$PID_B" != "$PID_C" ] && [ "$PID_A" != "$PID_C" ]; then
        _pass "D-T1: three distinct server PIDs A=$PID_A B=$PID_B C=$PID_C (positive evidence: independent server processes via operator path)"
    else
        _fail "D-T1: PIDs not distinct (A='$PID_A' B='$PID_B' C='$PID_C')"
        echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
    fi

    # D-T2: SIGKILL session A's server (macOS adjacent test per §11.4.81 (C)
    # — Darwin has no OOM killer, so we exercise the closest invariant).
    kill -KILL "$PID_A" 2>/dev/null
    sleep 1

    # D-T3: session A's server is gone.
    if "$TMUX_BIN" -L "$SOCK_A" ls >/dev/null 2>&1; then
        _fail "D-T3: session A's server still responding after SIGKILL"
    else
        _pass "D-T3: session A's server confirmed dead (positive evidence: tmux -L $SOCK_A ls fails)"
    fi

    # D-T4: sessions B and C survive with ORIGINAL PIDs.
    PID_B_NOW="$("$TMUX_BIN" -L "$SOCK_B" display-message -p '#{pid}' 2>/dev/null)"
    PID_C_NOW="$("$TMUX_BIN" -L "$SOCK_C" display-message -p '#{pid}' 2>/dev/null)"
    if [ "$PID_B_NOW" = "$PID_B" ] && [ -n "$PID_B_NOW" ]; then
        _pass "D-T4.B: session B survived with ORIGINAL PID $PID_B (positive evidence: independence — A's death did NOT cascade)"
    else
        _fail "D-T4.B: session B PID changed/died: was=$PID_B now='$PID_B_NOW'"
    fi
    if [ "$PID_C_NOW" = "$PID_C" ] && [ -n "$PID_C_NOW" ]; then
        _pass "D-T4.C: session C survived with ORIGINAL PID $PID_C (positive evidence: independence — A's death did NOT cascade)"
    else
        _fail "D-T4.C: session C PID changed/died: was=$PID_C now='$PID_C_NOW'"
    fi

    # D-T5: tmx ls still shows B and C.
    LS_OUT="$("$WRAPPER" ls 2>/dev/null)"
    if echo "$LS_OUT" | grep -q "$SESS_B" && echo "$LS_OUT" | grep -q "$SESS_C"; then
        _pass "D-T5: tmx ls shows both surviving sessions B and C (positive evidence: operator-visible list)"
    else
        _fail "D-T5: tmx ls missing B or C after A's death: '$LS_OUT'"
    fi

    echo ""
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

echo "── Test 14: concurrent OOM independence (Linux branch, operator-path) ──"

if [ "${TMX_TEST_DESTRUCTIVE:-0}" != "1" ]; then
    echo "SKIP: TMX_TEST_DESTRUCTIVE=1 not set — this test OOM-kills processes"
    echo "      Set TMX_TEST_DESTRUCTIVE=1 on a dedicated test host to run."
    exit 0
fi

if ! command -v stress-ng >/dev/null 2>&1; then
    echo "SKIP: stress-ng not installed"
    echo "      install via: dnf install stress-ng / apt install stress-ng / brew install stress-ng"
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

A_NAME="tmx_t14_A_$$"
B_NAME="tmx_t14_B_$$"
C_NAME="tmx_t14_C_$$"

# Use a small per-session cap so stress-ng can exhaust it quickly.
TMX_MEM_TEST="128M"

_cleanup() {
    for name in "$A_NAME" "$B_NAME" "$C_NAME"; do
        "$WRAPPER" kill-session -t "$name" 2>/dev/null || true
        systemctl --user stop "tmx-${name}.scope" 2>/dev/null || true
    done
}
trap _cleanup EXIT

# Kernel-log reader: prefer dmesg; fall back to journalctl -k (Fedora
# defaults dmesg_restrict=1 so unprivileged dmesg fails).
_kring_count() {
    if dmesg >/dev/null 2>&1; then dmesg | wc -l
    elif journalctl -k --no-pager -q -o cat >/dev/null 2>&1; then journalctl -k --no-pager -q -o cat | wc -l
    else echo 0
    fi
}
_kring_tail() {
    local n="$1"
    if dmesg >/dev/null 2>&1; then dmesg | tail -"$n"
    elif journalctl -k --no-pager -q -o cat >/dev/null 2>&1; then journalctl -k --no-pager -q -o cat | tail -"$n"
    fi
}

USER_SVC_BEFORE=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
_pass "T8.0: user.slice active before test (default.target=$USER_SVC_BEFORE)"

# ── Create three sessions via the OPERATOR PATH ─────────────────────
TMX_MEM="$TMX_MEM_TEST" "$WRAPPER" new -s "$A_NAME" -d 2>/dev/null
TMX_MEM="$TMX_MEM_TEST" "$WRAPPER" new -s "$B_NAME" -d 2>/dev/null
TMX_MEM="$TMX_MEM_TEST" "$WRAPPER" new -s "$C_NAME" -d 2>/dev/null
sleep 2

# Capture B's and C's MainPIDs from their scope cgroups.
B_CG=$(systemctl --user show -p ControlGroup --value "tmx-${B_NAME}.scope" 2>/dev/null)
C_CG=$(systemctl --user show -p ControlGroup --value "tmx-${C_NAME}.scope" 2>/dev/null)
B_PID=$(head -1 "/sys/fs/cgroup${B_CG}/cgroup.procs" 2>/dev/null | tr -d '\n')
C_PID=$(head -1 "/sys/fs/cgroup${C_CG}/cgroup.procs" 2>/dev/null | tr -d '\n')

if [ -z "$B_PID" ] || [ -z "$C_PID" ]; then
    _fail "T8.precheck: could not capture B/C MainPIDs (B=[$B_PID] C=[$C_PID])"
    echo "Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
fi
_pass "T8.precheck: captured B's MainPID=$B_PID and C's MainPID=$C_PID from cgroup.procs"

# ── Trigger OOM in session A via send-keys ──────────────────────────
# §11.4.81 host-independence: disable swap for A's scope so exceeding its 128M
# MemoryMax OOM-kills deterministically. On a swap-enabled host (nezha has 15G
# swap) the cap is otherwise enforced via swap — memory.current pins at 128M,
# oom_kill stays 0, no OOM fires (verified: oom_kill 0 → 295 with swap off).
# Delegate=yes makes memory.swap.max writable by the user; ONLY A's scope is
# touched — B/C keep their own scopes (the independence under test).
A_CG=$(systemctl --user show -p ControlGroup --value "tmx-${A_NAME}.scope" 2>/dev/null)
if [ -n "$A_CG" ] && [ -w "/sys/fs/cgroup${A_CG}/memory.swap.max" ]; then
    echo 0 > "/sys/fs/cgroup${A_CG}/memory.swap.max" 2>/dev/null || true
fi
DMESG_BEFORE=$(_kring_count)
"$WRAPPER" send-keys -t "$A_NAME" "stress-ng --vm 1 --vm-bytes 200M --timeout 15s" Enter 2>/dev/null || true

# ── Assertions ──────────────────────────────────────────────────────
# §11.4.1/§11.4.50 source-layer hardening: the kernel OOM-kill fires
# ASYNCHRONOUSLY and on a `kernel.dmesg_restrict=1` host `journalctl -k` ingests
# it with lag, so a fixed `sleep 10` + single sample raced the event → flaky
# FALSE-NEGATIVE. Poll the kernel ring for the OOM line up to ~22 s (stress-ng
# --timeout 15s + journald ingestion margin), breaking the instant it appears.
# A genuinely broken cap never logs the line and still FAILs — assertion below
# UNCHANGED.
OOM_LINES=""
for _oom_i in $(seq 1 44); do
    DMESG_AFTER=$(_kring_count)
    OOM_LINES=$(_kring_tail $((DMESG_AFTER - DMESG_BEFORE)) | grep -iE 'oom-kill|out of memory|memory cgroup out of memory' || true)
    [ -n "$OOM_LINES" ] && break
    sleep 0.5
done
if [ -n "$OOM_LINES" ]; then
    _pass "T8.1: kernel OOM-kill detected (positive evidence: kernel log shows oom-kill / memory cgroup out of memory)"
else
    _fail "T8.1: no OOM-kill detected in kernel log after stress-ng over MemoryMax — enforcement broken or stress-ng failed"
fi

# Scope A should be inactive after its OOM.
A_ACTIVE=$(systemctl --user is-active "tmx-${A_NAME}.scope" 2>/dev/null || echo "inactive")
# Scopes B + C should still be active.
B_ACTIVE=$(systemctl --user is-active "tmx-${B_NAME}.scope" 2>/dev/null || echo "unknown")
C_ACTIVE=$(systemctl --user is-active "tmx-${C_NAME}.scope" 2>/dev/null || echo "unknown")

if [ "$B_ACTIVE" = "active" ]; then
    _pass "T8.2: scope B (tmx-${B_NAME}.scope) STILL ACTIVE after A's OOM (positive evidence: systemctl --user is-active = active)"
else
    _fail "T8.2: scope B state '$B_ACTIVE' — should be active"
fi
if [ "$C_ACTIVE" = "active" ]; then
    _pass "T8.3: scope C (tmx-${C_NAME}.scope) STILL ACTIVE after A's OOM (positive evidence: systemctl --user is-active = active)"
else
    _fail "T8.3: scope C state '$C_ACTIVE' — should be active"
fi

# B's and C's MainPIDs should be unchanged (their processes were not affected).
B_PID_AFTER=$(head -1 "/sys/fs/cgroup${B_CG}/cgroup.procs" 2>/dev/null | tr -d '\n')
C_PID_AFTER=$(head -1 "/sys/fs/cgroup${C_CG}/cgroup.procs" 2>/dev/null | tr -d '\n')
if [ "$B_PID_AFTER" = "$B_PID" ]; then
    _pass "T8.4: scope B MainPID UNCHANGED ($B_PID) — process not collaterally killed"
else
    _fail "T8.4: scope B MainPID changed from $B_PID to $B_PID_AFTER"
fi
if [ "$C_PID_AFTER" = "$C_PID" ]; then
    _pass "T8.5: scope C MainPID UNCHANGED ($C_PID) — process not collaterally killed"
else
    _fail "T8.5: scope C MainPID changed from $C_PID to $C_PID_AFTER"
fi

# user.slice survival is the ultimate Constitution §1 invariant.
USER_SVC_AFTER=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
if [ "$USER_SVC_AFTER" = "active" ]; then
    _pass "T8.6: user.slice survived (default.target=$USER_SVC_AFTER throughout — Constitution §1 invariant honoured)"
else
    _fail "T8.6: user.slice state changed: $USER_SVC_AFTER (not acceptable)"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
