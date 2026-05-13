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
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"
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

echo "── Test 15: per-session cgroup distinctness ──"

# Pre-check: wrapper + binary present, systemd available.
if [ ! -x "$WRAPPER" ]; then
    _skip "wrapper $WRAPPER not generated — run setup.sh"
    echo "Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
if [ ! -x "$TMUX_BIN" ]; then
    _skip "tmux binary $TMUX_BIN not built"
    echo "Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
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

# ── T3: memory.max readback matches the configured cap ──────────────
echo ""
echo "--- T3: memory.max per session matches configured cap ---"
A_MEM_MAX=$(cat "/sys/fs/cgroup${A_CG}/memory.max" 2>/dev/null || echo "?")
B_MEM_MAX=$(cat "/sys/fs/cgroup${B_CG}/memory.max" 2>/dev/null || echo "?")
# Default cap is host-adaptive (max(MemTotal*0.6/4, 2GB)). Just assert
# non-empty + numeric + ≥ 2GB. T5 below tests the override path explicitly.
two_gib=$((2 * 1024 * 1024 * 1024))
if [ "$A_MEM_MAX" -ge "$two_gib" ] 2>/dev/null && [ "$B_MEM_MAX" -ge "$two_gib" ] 2>/dev/null; then
    _pass "T3: memory.max A=$A_MEM_MAX B=$B_MEM_MAX (both ≥ 2GB floor, positive evidence: /sys/fs/cgroup/.../memory.max)"
else
    _fail "T3: memory.max A=$A_MEM_MAX B=$B_MEM_MAX (expected ≥ $two_gib)"
fi

# ── T4: cpu.max readback present ────────────────────────────────────
echo ""
echo "--- T4: cpu.max present per session ---"
A_CPU_MAX=$(cat "/sys/fs/cgroup${A_CG}/cpu.max" 2>/dev/null || echo "?")
B_CPU_MAX=$(cat "/sys/fs/cgroup${B_CG}/cpu.max" 2>/dev/null || echo "?")
if echo "$A_CPU_MAX" | grep -qE '^[0-9]+ [0-9]+$' && echo "$B_CPU_MAX" | grep -qE '^[0-9]+ [0-9]+$'; then
    _pass "T4: cpu.max A='$A_CPU_MAX' B='$B_CPU_MAX' (positive evidence: cpu.max readback per session)"
else
    _fail "T4: cpu.max A='$A_CPU_MAX' B='$B_CPU_MAX' (expected '<quota> <period>' format)"
fi

# ── T5: TMX_MEM override per session ────────────────────────────────
echo ""
echo "--- T5: TMX_MEM=3G override produces memory.max = 3 GiB exactly ---"
TMX_MEM=3G "$WRAPPER" new -s "$C_NAME" -d 2>/dev/null
sleep 1
C_CG=$(systemctl --user show -p ControlGroup --value "$C_SCOPE" 2>/dev/null)
if [ -z "$C_CG" ]; then
    _fail "T5: scope $C_SCOPE not registered after TMX_MEM=3G override"
else
    C_MEM_MAX=$(cat "/sys/fs/cgroup${C_CG}/memory.max" 2>/dev/null || echo "?")
    expected=$((3 * 1024 * 1024 * 1024))
    if [ "$C_MEM_MAX" = "$expected" ]; then
        _pass "T5: TMX_MEM=3G → memory.max=$C_MEM_MAX (positive evidence: $C_MEM_MAX bytes = 3 GiB exactly)"
    else
        _fail "T5: TMX_MEM=3G → memory.max=$C_MEM_MAX (expected $expected)"
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
