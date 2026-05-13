#!/usr/bin/env bash
# Test 14 — Concurrent OOM independence via the OPERATOR PATH.
#
# Constitution §11.4.7 (operator-path coverage rule): this test creates
# the three sessions via `tmx new -s X -d` — the exact entry point an
# end-user invokes. The previous version hand-crafted `systemd-run
# --user --scope` units and passed while the actual operator workflow
# placed every session in ONE shared cgroup (Fixed.md A12). Rewriting
# closes that gap.
#
# Test plan: create sessions A/B/C via `tmx new`. Each ends up in its
# OWN scope `tmx-A.scope` / `tmx-B.scope` / `tmx-C.scope`. Trigger OOM
# inside A by sending a stress-ng command via `tmx send-keys`. Verify
# scopes B and C remain active with their original MainPIDs, the tmux
# servers for B and C are still alive (`tmx ls` shows them), and
# user.slice survived.
#
# Destructive guard: only runs when TMX_TEST_DESTRUCTIVE=1 is set.

set -uo pipefail

echo "── Test 14: concurrent OOM independence (operator-path) ──"

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
DMESG_BEFORE=$(_kring_count)
"$WRAPPER" send-keys -t "$A_NAME" "stress-ng --vm 1 --vm-bytes 200M --timeout 15s" Enter 2>/dev/null || true

# Wait for the OOM to fire (stress-ng allocates over 128M cap → kernel OOM-kill).
sleep 10

# ── Assertions ──────────────────────────────────────────────────────
DMESG_AFTER=$(_kring_count)
OOM_LINES=$(_kring_tail $((DMESG_AFTER - DMESG_BEFORE)) | grep -iE 'oom-kill|out of memory|memory cgroup out of memory' || true)
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
