#!/usr/bin/env bash
# Test 07 — sustained 30-second session with periodic activity, RSS doesn't grow unbounded.
# PASS if RSS at T+30s is no more than 50% above RSS at T+5s.
set -uo pipefail
TMUX_BIN="${TMUX_BIN:?}"
SOCKET="/tmp/tmx_test_$$"
echo "── Test 07: 30s sustained session, no runaway growth ──"

# Defensive jemalloc lookup
JEM=""
for _C in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
    command -v "$_C" >/dev/null 2>&1 || continue
    JEM=$("$_C" -p 2>/dev/null | awk '/libjemalloc\.so\.[0-9]/ {print $NF; exit}' || true)
    [ -n "$JEM" ] && break
done

LD_PRELOAD="$JEM" "$TMUX_BIN" -S "$SOCKET" new-session -d -s longtest "while true; do echo tick \$(date +%s); sleep 0.5; done" 2>/dev/null
sleep 5
PID=$("$TMUX_BIN" -S "$SOCKET" display-message -p "#{pid}" 2>/dev/null)
if [ -z "$PID" ]; then
    echo "FAIL: tmux server PID not found"
    exit 1
fi
RSS_T5=$(awk '/^VmRSS:/ {print $2}' "/proc/$PID/status")
echo "  RSS at T+5s: $RSS_T5 kB"

sleep 25
RSS_T30=$(awk '/^VmRSS:/ {print $2}' "/proc/$PID/status")
echo "  RSS at T+30s: $RSS_T30 kB"

"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true

GROWTH=$((RSS_T30 - RSS_T5))
GROWTH_PCT=$(awk "BEGIN { if ($RSS_T5==0) {print 999} else { printf \"%.1f\", ($GROWTH/$RSS_T5)*100 } }")
echo "  growth in 25 s: $GROWTH kB ($GROWTH_PCT%)"

if awk "BEGIN { exit !($GROWTH_PCT < 50.0) }"; then
    echo "PASS (growth < 50% over 25 s)"
else
    echo "FAIL: growth $GROWTH_PCT% > 50% — possible leak"
    exit 1
fi
