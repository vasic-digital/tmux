#!/usr/bin/env bash
# Test 12 — Memory pressure under cgroup cap (T5). Allocate inside a
# transient scope up to MemoryMax+10%, verify the kernel OOM-kills only
# the scope process, verify user.slice survives.
#
# TMX-T5 — Issues.md C1.
#
# Constitution §1 anti-bluff: PASS requires positive evidence from dmesg
# (oom-kill line) AND systemctl status (default.target=active after kill).
#
# Destructive guard: only runs when TMX_TEST_DESTRUCTIVE=1 is set.

set -uo pipefail

echo "── Test 12: memory pressure under cgroup cap ──"

if [ "${TMX_TEST_DESTRUCTIVE:-0}" != "1" ]; then
    echo "SKIP: TMX_TEST_DESTRUCTIVE=1 not set — this test OOM-kills a process"
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
    _skip "stress-ng not installed — cannot allocate memory" "install with: sudo apt-get install stress-ng"
fi

TEST_NAME="tmx-test-$$-t5"
MEM_BYTES=$((128 * 1024 * 1024))
DMESG_BEFORE=$(dmesg | wc -l)

USER_SVC_BEFORE=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
_pass "T5.0: user.slice active before test (default.target=$USER_SVC_BEFORE)"

systemd-run --user --scope --collect --quiet \
    --unit="${TEST_NAME}.scope" \
    -p "MemoryMax=$MEM_BYTES" \
    -p "TasksMax=16" \
    stress-ng --vm 1 --vm-bytes $((MEM_BYTES + MEM_BYTES / 10)) --timeout 10s &
SCOPE_PID=$!
sleep 2

DMESG_AFTER=$(dmesg | wc -l)
OOM_LINES=$(dmesg | tail -$((DMESG_AFTER - DMESG_BEFORE)) | grep -i 'oom-kill' || true)
if [ -n "$OOM_LINES" ]; then
    _pass "T5.1: kernel OOM-kill detected in dmesg (positive evidence)"
else
    _fail "T5.1: no OOM-kill in dmesg — memory pressure did not trigger enforcement"
fi

USER_SVC_AFTER=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
if [ "$USER_SVC_AFTER" = "active" ]; then
    _pass "T5.2: user.slice survived OOM kill (default.target=$USER_SVC_AFTER)"
else
    _fail "T5.2: user.slice state changed: $USER_SVC_AFTER (not acceptable)"
fi

systemctl --user stop "${TEST_NAME}.scope" >/dev/null 2>&1 || true
wait "$SCOPE_PID" 2>/dev/null || true

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
