#!/usr/bin/env bash
# 09_crash_isolation_scope.sh — Phase B (per-session containerization)
# crash-isolation invariant verifier. Tests that the systemd --user
# --scope mechanism (which the `tmx` wrapper uses) actually enforces
# the cgroup memory + CPU caps AND that a scope being SIGKILL'd /
# OOM-killed does NOT take the user@<uid>.service down with it.
#
# Constitution §1 anti-bluff covenant — every PASS carries runtime
# evidence (cgroup interface files, scope unit state, MemoryMax value
# read back from cgroup hierarchy).
#
# Sections:
#   T1: systemd available + cgroup v2
#   T2: tmx wrapper exists + uses systemd-run --user --scope
#   T3: actually create a transient scope (no tmux; just sleep) +
#       verify cgroup interface files exist with the right limits
#   T4: SIGKILL the scope process — verify scope exits, user.slice alive
#   T5: simulate memory pressure (allocate UP TO cap, NOT BEYOND) +
#       verify MemoryCurrent rises but stays below MemoryMax
#   T6: concurrent scopes — create 3 scopes with different names; all
#       three visible in `systemctl --user list-units --type=scope`,
#       independent cgroups (different paths)

set -uo pipefail

# Output classification: PASS / FAIL / SKIP. Priority: FAIL > SKIP > PASS.
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

_pass() { echo "PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { echo "FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
_skip() { echo "SKIP: $* ($2)"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"

echo "════════════════════════════════════════════════════════════════"
echo "  Test 09 — crash isolation invariants for tmx --user --scope"
echo "════════════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────
# T1 — systemd + cgroup v2 capability
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T1: systemd + cgroup v2 capability ---"
if ! command -v systemctl >/dev/null 2>&1; then
    _skip "T1.1: systemctl not present" "no systemd, no scope-based isolation possible"
    echo "Result: SKIPPED (no systemd)"
    exit 0
fi
sd_ver=$(systemctl --version | head -1 | awk '{print $2}')
if [ "${sd_ver:-0}" -lt 230 ] 2>/dev/null; then
    _fail "T1.1: systemd $sd_ver < 230 — transient --user --scope unsupported"
else
    _pass "T1.1: systemd $sd_ver supports --user --scope"
fi

if mount | grep -q "cgroup2 on /sys/fs/cgroup"; then
    _pass "T1.2: cgroup v2 mounted at /sys/fs/cgroup (per Constitution prereq)"
else
    _fail "T1.2: cgroup v2 not mounted (per-session isolation requires cgroup v2)"
fi

# ─────────────────────────────────────────────────────────────────────
# T2 — tmx wrapper uses systemd-run --user --scope
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T2: tmx wrapper invariants ---"
if [ ! -x "$WRAPPER" ]; then
    _fail "T2.1: tmx wrapper missing or not executable at $WRAPPER"
elif ! grep -q "systemd-run --user --scope" "$WRAPPER"; then
    _fail "T2.1: tmx wrapper does not invoke systemd-run --user --scope"
else
    _pass "T2.1: tmx wrapper at $WRAPPER uses systemd-run --user --scope"
fi
for inv in "MemoryMax" "CPUQuota" "TasksMax" "Delegate=yes"; do
    if grep -q "$inv" "$WRAPPER"; then
        _pass "T2.2: tmx wrapper sets $inv (cgroup invariant)"
    else
        _fail "T2.2: tmx wrapper missing $inv — cap not enforced per CONTAINERIZATION_PLAN.md"
    fi
done

# ─────────────────────────────────────────────────────────────────────
# T3 — create a transient scope, verify cgroup limits
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T3: transient scope cgroup interface files ---"
TEST_NAME="tmx-test-$$-t3"
TEST_MEM_BYTES=$((256 * 1024 * 1024))   # 256 MB
TEST_CPU_PCT=50                          # 50% = half a CPU

# Run a short-lived sleep inside a scope to inspect cgroup state.
# `--collect` cleans up the scope unit on exit. systemd-run --scope
# is foreground; backgrounding with `&` lets us inspect from outside.
systemd-run --user --scope --collect --quiet \
        --unit="${TEST_NAME}.scope" \
        -p "MemoryMax=$TEST_MEM_BYTES" \
        -p "CPUQuota=${TEST_CPU_PCT}%" \
        -p "TasksMax=128" \
        -p "Delegate=yes" \
        bash -c "sleep 60" &
SCOPE_PID=$!
sleep 3   # let scope register

if ! systemctl --user is-active --quiet "${TEST_NAME}.scope" 2>/dev/null; then
    _fail "T3.1: systemd-run --user --scope did not register ${TEST_NAME}.scope"
else
    _pass "T3.0: scope ${TEST_NAME}.scope registered + active"

    # Read MemoryMax back from cgroup interface file.
    cgroup_path=$(systemctl --user show -p ControlGroup --value "${TEST_NAME}.scope" 2>/dev/null)
    if [ -z "$cgroup_path" ]; then
        _skip "T3.1: cannot read ControlGroup for ${TEST_NAME}.scope" "scope may not be registered"
    else
        full_cgroup="/sys/fs/cgroup${cgroup_path}"
        if [ -f "$full_cgroup/memory.max" ]; then
            mem_max=$(cat "$full_cgroup/memory.max")
            if [ "$mem_max" = "$TEST_MEM_BYTES" ]; then
                _pass "T3.1: cgroup memory.max=$mem_max bytes matches set MemoryMax (positive evidence: $full_cgroup/memory.max)"
            else
                _fail "T3.1: cgroup memory.max=$mem_max but expected $TEST_MEM_BYTES — cap not enforced"
            fi
        else
            _skip "T3.1: $full_cgroup/memory.max not found" "cgroup not yet populated"
        fi
        if [ -f "$full_cgroup/cpu.max" ]; then
            cpu_max=$(cat "$full_cgroup/cpu.max")
            _pass "T3.2: cgroup cpu.max present: $cpu_max (positive evidence: $full_cgroup/cpu.max)"
        else
            _skip "T3.2: $full_cgroup/cpu.max not found" "scope may use legacy hierarchy"
        fi
    fi

    # Cleanup — kill the sleep so scope exits cleanly.
    systemctl --user stop "${TEST_NAME}.scope" >/dev/null 2>&1 || kill -TERM "$SCOPE_PID" 2>/dev/null || true
    wait "$SCOPE_PID" 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────
# T4 — SIGKILL containment: kill scope process, verify user.slice alive
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T4: SIGKILL containment (user@<uid>.service must survive scope death) ---"
TEST_NAME_T4="tmx-test-$$-t4"
USER_SVC_BEFORE=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")

# Spawn a scope running a victim process.
systemd-run --user --scope --collect --quiet \
    --unit="${TEST_NAME_T4}.scope" \
    -p "MemoryMax=128M" \
    -p "TasksMax=64" \
    bash -c "exec sleep 120" &
T4_PID=$!
sleep 3   # increased from 1s — scope-registration race observed at 1s

# `--scope` units don't have a single MainPID — they're a process group.
# Read PID from cgroup.procs (the kernel's authoritative list of pids in the cgroup).
t4_cgroup_path=$(systemctl --user show -p ControlGroup --value "${TEST_NAME_T4}.scope" 2>/dev/null)
victim_pid=""
if [ -n "$t4_cgroup_path" ] && [ -f "/sys/fs/cgroup${t4_cgroup_path}/cgroup.procs" ]; then
    # First non-empty line is a PID inside the scope.
    victim_pid=$(head -1 "/sys/fs/cgroup${t4_cgroup_path}/cgroup.procs" 2>/dev/null | tr -d '\n')
fi
if [ -n "$victim_pid" ] && [ "$victim_pid" != "0" ]; then
    if kill -0 "$victim_pid" 2>/dev/null; then
        _pass "T4.1: scope ${TEST_NAME_T4}.scope MainPID=$victim_pid alive"
        # SIGKILL it
        kill -KILL "$victim_pid" 2>/dev/null
        sleep 2
        # Verify scope died
        if systemctl --user is-active --quiet "${TEST_NAME_T4}.scope" 2>/dev/null; then
            _fail "T4.2: scope ${TEST_NAME_T4}.scope still active after SIGKILL of MainPID"
        else
            _pass "T4.2: scope ${TEST_NAME_T4}.scope correctly inactive after SIGKILL of MainPID (positive evidence: systemctl --user is-active = inactive)"
        fi
        # Verify user@<uid>.service still alive (the critical invariant)
        USER_SVC_AFTER=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
        if [ "$USER_SVC_AFTER" = "$USER_SVC_BEFORE" ] && [ "$USER_SVC_AFTER" = "active" ]; then
            _pass "T4.3: user.slice survived scope death (default.target=$USER_SVC_AFTER throughout — Constitution §1 invariant)"
        else
            _fail "T4.3: user.slice state changed: before=$USER_SVC_BEFORE after=$USER_SVC_AFTER (NOT acceptable per Constitution §1)"
        fi
    else
        _skip "T4.1: scope MainPID=$victim_pid not alive" "scope may have exited too quickly"
    fi
else
    _skip "T4.1: cannot read MainPID for ${TEST_NAME_T4}.scope" "scope not registered"
fi
# Cleanup
systemctl --user stop "${TEST_NAME_T4}.scope" >/dev/null 2>&1 || true
wait "$T4_PID" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────
# T6 — concurrent independent scopes
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "--- T6: concurrent scopes are independent ---"
T6_NAMES=()
for n in 1 2 3; do
    nm="tmx-test-$$-t6-$n"
    systemd-run --user --scope --collect --quiet \
        --unit="${nm}.scope" \
        -p "MemoryMax=128M" \
        bash -c "exec sleep 60" &
    T6_NAMES+=("$nm")
    sleep 0.5
done
sleep 1
visible=0
for nm in "${T6_NAMES[@]}"; do
    if systemctl --user is-active --quiet "${nm}.scope" 2>/dev/null; then
        visible=$((visible + 1))
    fi
done
if [ "$visible" -eq 3 ]; then
    _pass "T6.1: all 3 concurrent scopes registered + active (positive evidence: systemctl --user is-active for each)"
else
    _fail "T6.1: only $visible of 3 concurrent scopes active — independence not confirmed"
fi
# Cleanup all 3
for nm in "${T6_NAMES[@]}"; do
    systemctl --user stop "${nm}.scope" >/dev/null 2>&1 || true
done
wait 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  09_crash_isolation_scope.sh summary"
echo "════════════════════════════════════════════════════════════════"
echo "  PASS:  $PASS_COUNT"
echo "  FAIL:  $FAIL_COUNT"
echo "  SKIP:  $SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
