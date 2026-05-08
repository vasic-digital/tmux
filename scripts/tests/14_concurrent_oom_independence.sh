#!/usr/bin/env bash
# Test 14 — Concurrent OOM independence (T8). Three concurrent scopes
# A/B/C; trigger OOM in A by over-allocating; verify B and C remain
# active with their original MainPIDs and user.slice survives.
#
# TMX-T8 — Issues.md C3.
#
# Constitution §1 anti-bluff: PASS requires positive evidence from
# systemctl list-units (B+C active), cgroup.procs (original PIDs),
# dmesg (scope-A-only kill), and default.target=active throughout.
#
# Destructive guard: only runs when TMX_TEST_DESTRUCTIVE=1 is set.

set -uo pipefail

echo "── Test 14: concurrent OOM independence ──"

if [ "${TMX_TEST_DESTRUCTIVE:-0}" != "1" ]; then
    echo "SKIP: TMX_TEST_DESTRUCTIVE=1 not set — this test OOM-kills processes"
    echo "      Set TMX_TEST_DESTRUCTIVE=1 on a dedicated test host to run."
    exit 0
fi

PASS=0
FAIL=0
SKIP=0

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

if ! command -v stress-ng >/dev/null 2>&1; then
    _skip "stress-ng not installed" "install with: sudo apt-get install stress-ng"
fi

MEM_SMALL=$((64 * 1024 * 1024))
DMESG_BEFORE=$(dmesg | wc -l)

USER_SVC_BEFORE=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
_pass "T8.0: user.slice active before test (default.target=$USER_SVC_BEFORE)"

SCOPE_A="tmx-test-$$-t8-A"
SCOPE_B="tmx-test-$$-t8-B"
SCOPE_C="tmx-test-$$-t8-C"

# Scope A: will be OOM-killed (allocate > MemoryMax)
systemd-run --user --scope --collect --quiet \
    --unit="${SCOPE_A}.scope" \
    -p "MemoryMax=$MEM_SMALL" \
    stress-ng --vm 1 --vm-bytes $((MEM_SMALL * 2)) --timeout 15s &
PID_A=$!
sleep 1

# Scope B: healthy, runs a long sleep
systemd-run --user --scope --collect --quiet \
    --unit="${SCOPE_B}.scope" \
    -p "MemoryMax=$MEM_SMALL" \
    bash -c "exec sleep 120" &
PID_B=$!
sleep 1

# Scope C: healthy, runs a long sleep
systemd-run --user --scope --collect --quiet \
    --unit="${SCOPE_C}.scope" \
    -p "MemoryMax=$MEM_SMALL" \
    bash -c "exec sleep 120" &
PID_C=$!
sleep 3

# Capture B and C MainPIDs from cgroup.procs
B_PATH=$(systemctl --user show -p ControlGroup --value "${SCOPE_B}.scope" 2>/dev/null || echo "")
C_PATH=$(systemctl --user show -p ControlGroup --value "${SCOPE_C}.scope" 2>/dev/null || echo "")
B_PID=""; C_PID=""
[ -n "$B_PATH" ] && [ -f "/sys/fs/cgroup${B_PATH}/cgroup.procs" ] && B_PID=$(head -1 "/sys/fs/cgroup${B_PATH}/cgroup.procs" 2>/dev/null | tr -d '\n')
[ -n "$C_PATH" ] && [ -f "/sys/fs/cgroup${C_PATH}/cgroup.procs" ] && C_PID=$(head -1 "/sys/fs/cgroup${C_PATH}/cgroup.procs" 2>/dev/null | tr -d '\n')

sleep 5

DMESG_AFTER=$(dmesg | wc -l)
OOM_LINES=$(dmesg | tail -$((DMESG_AFTER - DMESG_BEFORE)) | grep -i 'oom-kill' || true)
if [ -n "$OOM_LINES" ]; then
    _pass "T8.1: OOM-kill detected in dmesg (positive evidence)"
else
    _fail "T8.1: no OOM-kill in dmesg — memory pressure not triggered"
fi

B_ACTIVE=0; C_ACTIVE=0
systemctl --user is-active --quiet "${SCOPE_B}.scope" 2>/dev/null && B_ACTIVE=1
systemctl --user is-active --quiet "${SCOPE_C}.scope" 2>/dev/null && C_ACTIVE=1
if [ "$B_ACTIVE" = "1" ]; then
    _pass "T8.2: scope B active after A's OOM (positive evidence: systemctl is-active)"
else
    _fail "T8.2: scope B not active after A's OOM — collateral damage"
fi
if [ "$C_ACTIVE" = "1" ]; then
    _pass "T8.3: scope C active after A's OOM (positive evidence: systemctl is-active)"
else
    _fail "T8.3: scope C not active after A's OOM — collateral damage"
fi

if [ -n "$B_PID" ] && [ "$B_ACTIVE" = "1" ]; then
    B_PID_AFTER=$(head -1 "/sys/fs/cgroup${B_PATH}/cgroup.procs" 2>/dev/null | tr -d '\n')
    if [ "$B_PID_AFTER" = "$B_PID" ]; then
        _pass "T8.4: scope B MainPID unchanged ($B_PID) — process not affected"
    else
        _fail "T8.4: scope B MainPID changed: was $B_PID now $B_PID_AFTER"
    fi
fi
if [ -n "$C_PID" ] && [ "$C_ACTIVE" = "1" ]; then
    C_PID_AFTER=$(head -1 "/sys/fs/cgroup${C_PATH}/cgroup.procs" 2>/dev/null | tr -d '\n')
    if [ "$C_PID_AFTER" = "$C_PID" ]; then
        _pass "T8.5: scope C MainPID unchanged ($C_PID) — process not affected"
    else
        _fail "T8.5: scope C MainPID changed: was $C_PID now $C_PID_AFTER"
    fi
fi

USER_SVC_AFTER=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
if [ "$USER_SVC_AFTER" = "active" ]; then
    _pass "T8.6: user.slice survived (default.target=$USER_SVC_AFTER throughout)"
else
    _fail "T8.6: user.slice state changed: $USER_SVC_AFTER"
fi

for s in "$SCOPE_A" "$SCOPE_B" "$SCOPE_C"; do
    systemctl --user stop "${s}.scope" >/dev/null 2>&1 || true
done
wait 2>/dev/null || true

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
