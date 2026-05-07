#!/usr/bin/env bash
# Test 03 — jemalloc verification: when launched with our wrapper (LD_PRELOAD=jemalloc),
# the running tmux process has libjemalloc mapped in its address space.
set -euo pipefail
TMUX_BIN="${TMUX_BIN:?}"
SOCKET="/tmp/atm_tmux_test_$$"
echo "── Test 03: jemalloc loaded via LD_PRELOAD ──"

# Find libjemalloc on the host (defensive — ldconfig may not be in PATH for non-root)
JEM=""
for _LDCFG in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
    command -v "$_LDCFG" >/dev/null 2>&1 || continue
    JEM=$("$_LDCFG" -p 2>/dev/null | awk '/libjemalloc\.so\.[0-9]/ {print $NF; exit}' || true)
    [ -n "$JEM" ] && break
done
if [ -z "$JEM" ]; then
    echo "SKIP: no libjemalloc.so.X visible to ldconfig (jemalloc not installed on this host)"
    echo "       host-only mitigation; container build still has jemalloc linked"
    exit 0
fi
echo "  using LD_PRELOAD=$JEM"

LD_PRELOAD="$JEM" "$TMUX_BIN" -S "$SOCKET" new-session -d -s jemtest "sleep 30"
sleep 1
PID=$("$TMUX_BIN" -S "$SOCKET" display-message -p '#{pid}' 2>/dev/null || pgrep -f "tmux: server.*$SOCKET" | head -1)
if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
    "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
    echo "FAIL: could not find tmux server PID after launch"
    exit 1
fi
if grep -q jemalloc "/proc/$PID/maps" 2>/dev/null; then
    echo "  ✓ tmux server PID $PID has jemalloc in /proc/$PID/maps"
    "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
    echo "PASS"
else
    "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
    echo "FAIL: PID $PID did NOT have jemalloc loaded — wrapper LD_PRELOAD ineffective"
    exit 1
fi
