#!/usr/bin/env bash
# Test 06 — concurrent panes don't leak: spawn 10 panes, send minor activity to each,
# measure tmux server RSS growth. PASS if growth is bounded (< 20 MB total).
set -uo pipefail
TMUX_BIN="${TMUX_BIN:?}"
SOCKET="/tmp/tmx_test_$$"
echo "── Test 06: 10 concurrent panes — RSS bounded ──"

# Defensive jemalloc lookup
JEM=""
for _C in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
    command -v "$_C" >/dev/null 2>&1 || continue
    JEM=$("$_C" -p 2>/dev/null | awk '/libjemalloc\.so\.[0-9]/ {print $NF; exit}' || true)
    [ -n "$JEM" ] && break
done

LD_PRELOAD="$JEM" "$TMUX_BIN" -S "$SOCKET" new-session -d -s pantest "sleep 60" 2>/dev/null
sleep 0.5
PID=$("$TMUX_BIN" -S "$SOCKET" display-message -p "#{pid}" 2>/dev/null)
if [ -z "$PID" ]; then
    echo "FAIL: tmux server PID not found"
    exit 1
fi
RSS_BEFORE=$(awk '/^VmRSS:/ {print $2}' "/proc/$PID/status")
echo "  RSS with 1 pane: $RSS_BEFORE kB"

# Spawn 9 more panes
for i in $(seq 2 10); do
    "$TMUX_BIN" -S "$SOCKET" split-window -t pantest "echo pane $i; sleep 60" 2>/dev/null
    "$TMUX_BIN" -S "$SOCKET" select-layout -t pantest tiled 2>/dev/null
done
sleep 1
RSS_AFTER=$(awk '/^VmRSS:/ {print $2}' "/proc/$PID/status")
GROWTH=$((RSS_AFTER - RSS_BEFORE))
echo "  RSS with 10 panes: $RSS_AFTER kB"
echo "  growth: $GROWTH kB"

"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true

if [ "$GROWTH" -lt 20480 ]; then
    echo "PASS (growth < 20 MB)"
else
    echo "FAIL: growth $GROWTH kB exceeds 20 MB threshold"
    exit 1
fi
