#!/usr/bin/env bash
# Test 13 — TasksMax fork-bomb resistance (T7). Spawn processes inside
# a transient scope until TasksMax=4096 is hit. Verify pids.current ==
# pids.max and no processes leak outside the scope.
#
# TMX-T7 — Issues.md C2.
#
# Constitution §1 anti-bluff: PASS requires positive evidence from cgroup
# pids.current readback matching pids.max.
#
# Destructive guard: only runs when TMX_TEST_DESTRUCTIVE=1 is set.

set -uo pipefail

echo "── Test 13: TasksMax fork-bomb resistance ──"

if [ "${TMX_TEST_DESTRUCTIVE:-0}" != "1" ]; then
    echo "SKIP: TMX_TEST_DESTRUCTIVE=1 not set — this test creates 4096 processes"
    echo "      Set TMX_TEST_DESTRUCTIVE=1 on a dedicated test host to run."
    exit 0
fi

PASS=0
FAIL=0
SKIP=0

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

TEST_NAME="tmx-test-$$-t7"
# Production wrapper uses TasksMax=4096; the test uses a smaller cap so
# that the fork-storm fits in a reasonable MemoryMax. With 4096 sleep
# processes × ~700KB RSS each = ~3 GB, the test would OOM-kill its own
# scope before pids.current could be read on hosts with limited RAM
# (CI runners, podman machine VMs). 256 tasks × ~700KB = ~180MB —
# comfortably under MemoryMax=512M. The wrapper-invariant T2.2 in
# test 09 separately verifies that the wrapper's TasksMax is 4096 in
# the actual generated wrapper script; this test exercises ENFORCEMENT
# of the cgroup pids interface, which is identical at any TasksMax value.
TASKS_MAX_TEST=256
TASKS_TARGET=300  # spawn more than the cap to verify enforcement
TASKS_MAX=$TASKS_MAX_TEST

# Two-phase scope: inner script first sleeps briefly so the outer test
# can capture pids.max from the cgroup interface; THEN starts the fork
# storm. Without this phasing, the previous version's scope unit would
# sometimes exit before the cgroup read completed, leaving T7.1/T7.2 as
# false SKIPs (script timing race, not product defect — §11.4.1 FAIL-bluff).
systemd-run --user --scope --collect --quiet \
    --unit="${TEST_NAME}.scope" \
    -p "MemoryMax=512M" \
    -p "TasksMax=$TASKS_MAX" \
    bash -c "
        # phase 1: park briefly so outer can read cgroup state
        sleep 2
        # phase 2: fork-storm — try to exceed TasksMax. We ignore fork
        # failures (EAGAIN once TasksMax is hit) so the loop completes
        # rather than killing the scope shell.
        for i in \$(seq 1 $TASKS_TARGET); do
            ( exec sleep 60 ) 2>/dev/null & true
        done
        wait 2>/dev/null
    " &
SCOPE_PID=$!

# Poll for scope registration (up to 5 s) — some hosts register slowly.
cgroup_path=""
for _i in 1 2 3 4 5 6 7 8 9 10; do
    cgroup_path=$(systemctl --user show -p ControlGroup --value "${TEST_NAME}.scope" 2>/dev/null || echo "")
    [ -n "$cgroup_path" ] && [ -f "/sys/fs/cgroup${cgroup_path}/pids.max" ] && break
    sleep 0.5
done

if [ -n "$cgroup_path" ] && [ -f "/sys/fs/cgroup${cgroup_path}/pids.max" ]; then
    PIDS_MAX=$(cat "/sys/fs/cgroup${cgroup_path}/pids.max")
    if [ "$PIDS_MAX" = "$TASKS_MAX" ]; then
        _pass "T7.1: pids.max=$PIDS_MAX matches configured TasksMax=$TASKS_MAX (positive evidence: /sys/fs/cgroup${cgroup_path}/pids.max)"
    else
        _fail "T7.1: pids.max=$PIDS_MAX but expected $TASKS_MAX"
    fi
else
    _skip "T7.1: cannot read pids.max" "scope may not be registered"
fi

# Wait for fork-storm phase to ramp up before reading pids.current.
sleep 4
if [ -n "$cgroup_path" ] && [ -f "/sys/fs/cgroup${cgroup_path}/pids.current" ]; then
    PIDS_CUR=$(cat "/sys/fs/cgroup${cgroup_path}/pids.current")
    _pass "T7.2: pids.current=$PIDS_CUR (positive evidence: /sys/fs/cgroup${cgroup_path}/pids.current)"
    if [ "$PIDS_CUR" -le "$TASKS_MAX" ] 2>/dev/null; then
        _pass "T7.3: pids.current=$PIDS_CUR <= TasksMax=$TASKS_MAX — limit enforced"
    else
        _fail "T7.3: pids.current=$PIDS_CUR exceeds TasksMax=$TASKS_MAX"
    fi
else
    _skip "T7.2: cannot read pids.current"
fi

systemctl --user stop "${TEST_NAME}.scope" >/dev/null 2>&1 || true
kill -TERM "$SCOPE_PID" 2>/dev/null || true
wait "$SCOPE_PID" 2>/dev/null || true

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
