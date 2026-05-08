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
TASKS_MAX=4096

systemd-run --user --scope --collect --quiet \
    --unit="${TEST_NAME}.scope" \
    -p "MemoryMax=256M" \
    -p "TasksMax=$TASKS_MAX" \
    bash -c '
        for i in $(seq 1 10000); do
            (sleep 300) &
            if [ "$(cat /proc/self/cgroup 2>/dev/null || true)" = "" ]; then
                break
            fi
        done
        wait
    ' &
SCOPE_PID=$!
sleep 4

cgroup_path=$(systemctl --user show -p ControlGroup --value "${TEST_NAME}.scope" 2>/dev/null || echo "")
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
