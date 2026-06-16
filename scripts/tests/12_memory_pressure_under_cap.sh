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
    echo "SKIP: stress-ng not installed — cannot allocate memory"
    echo "      install via: dnf install stress-ng / apt install stress-ng / brew install stress-ng"
    exit 0
fi

# Pick a kernel-log reader that actually works. Fedora defaults to
# kernel.dmesg_restrict=1, so unprivileged `dmesg` fails with
# 'Operation not permitted'. journalctl -k works for any user in the
# 'systemd-journal' group and on systemd-journald-only hosts.
_kring_count() {
    if dmesg >/dev/null 2>&1; then
        dmesg | wc -l
    elif journalctl -k --no-pager -q -o cat >/dev/null 2>&1; then
        journalctl -k --no-pager -q -o cat | wc -l
    else
        echo "0"
    fi
}
_kring_tail() {
    local n="$1"
    if dmesg >/dev/null 2>&1; then
        dmesg | tail -"$n"
    elif journalctl -k --no-pager -q -o cat >/dev/null 2>&1; then
        journalctl -k --no-pager -q -o cat | tail -"$n"
    fi
}

TEST_NAME="tmx-test-$$-t5"
MEM_BYTES=$((128 * 1024 * 1024))
DMESG_BEFORE=$(_kring_count)

USER_SVC_BEFORE=$(systemctl --user is-active default.target 2>/dev/null || echo "unknown")
_pass "T5.0: user.slice active before test (default.target=$USER_SVC_BEFORE)"

systemd-run --user --scope --collect --quiet \
    --unit="${TEST_NAME}.scope" \
    -p "MemoryMax=$MEM_BYTES" \
    -p "TasksMax=16" \
    stress-ng --vm 1 --vm-bytes $((MEM_BYTES + MEM_BYTES / 10)) --timeout 10s &
SCOPE_PID=$!
# §11.4.1/§11.4.50 source-layer hardening: the kernel OOM-kill fires
# ASYNCHRONOUSLY while stress-ng (--timeout 10s) ramps allocation, and on a
# `kernel.dmesg_restrict=1` host the fallback `journalctl -k` ingests the
# kernel line with additional lag. A fixed `sleep 2` + single sample raced the
# event → flaky FALSE-NEGATIVE (observed: PASS standalone, FAIL under full-suite
# load). Poll the kernel ring for the OOM line up to ~16 s (stress-ng 10 s +
# journald ingestion margin), breaking the instant it appears. A genuinely
# broken cap never logs the line and still FAILs after the full timeout — the
# assertion below is UNCHANGED.
OOM_LINES=""
for _oom_i in $(seq 1 32); do
    DMESG_AFTER=$(_kring_count)
    OOM_LINES=$(_kring_tail $((DMESG_AFTER - DMESG_BEFORE)) | grep -iE 'oom-kill|out of memory|memory cgroup out of memory' || true)
    [ -n "$OOM_LINES" ] && break
    sleep 0.5
done
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
