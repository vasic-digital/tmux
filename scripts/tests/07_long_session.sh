#!/usr/bin/env bash
# Test 07 — sustained 30-second session with periodic activity, RSS doesn't
# grow unbounded. PASS if RSS at T+30s is no more than 50% above RSS at T+5s.
#
# Portable across Linux + macOS:
#  - jemalloc preload env-var: LD_PRELOAD (Linux) or DYLD_INSERT_LIBRARIES (Darwin)
#  - RSS reader: `ps -o rss= -p $PID` (portable; reads RSS in KB on both OSes)
set -uo pipefail
TMUX_BIN="${TMUX_BIN:?}"
SOCKET="/tmp/tmx_test_$$"
# §11.4.14 belt-and-suspenders cleanup: reap the server on EVERY exit path
# (early exit 1, set -e abort, signal) so no orphan tmux server is left behind.
trap '"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true; rm -f "$SOCKET" 2>/dev/null || true' EXIT
echo "── Test 07: 30s sustained session, no runaway growth ──"

# Defensive jemalloc lookup (skip on Darwin if we can't find it — test still meaningful w/o preload)
JEM=""
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin)
        if command -v brew >/dev/null 2>&1; then
            JEM_CANDIDATE="$(brew --prefix jemalloc 2>/dev/null)/lib/libjemalloc.dylib"
            [ -f "$JEM_CANDIDATE" ] && JEM="$JEM_CANDIDATE"
        fi
        ;;
    *)
        for _C in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
            command -v "$_C" >/dev/null 2>&1 || continue
            JEM=$("$_C" -p 2>/dev/null | awk '/libjemalloc\.so\.[0-9]/ {print $NF; exit}' || true)
            [ -n "$JEM" ] && break
        done
        ;;
esac

# Apply preload env-var per OS.
if [ -n "$JEM" ]; then
    case "$HOST_OS" in
        Darwin) export DYLD_INSERT_LIBRARIES="$JEM"; export DYLD_FORCE_FLAT_NAMESPACE=1 ;;
        *)      export LD_PRELOAD="$JEM" ;;
    esac
fi

"$TMUX_BIN" -S "$SOCKET" new-session -d -s longtest "while true; do echo tick \$(date +%s); sleep 0.5; done" 2>/dev/null
sleep 5
PID=$("$TMUX_BIN" -S "$SOCKET" display-message -p "#{pid}" 2>/dev/null)
if [ -z "$PID" ]; then
    echo "FAIL: tmux server PID not found"
    exit 1
fi
# Portable RSS reader: ps -o rss= prints KB on Linux + Darwin.
RSS_T5=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
echo "  RSS at T+5s: $RSS_T5 kB"

sleep 25
RSS_T30=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
echo "  RSS at T+30s: $RSS_T30 kB"

"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true

if [ -z "$RSS_T5" ] || [ -z "$RSS_T30" ]; then
    echo "FAIL: could not read RSS (T5='$RSS_T5' T30='$RSS_T30')"
    exit 1
fi

GROWTH=$((RSS_T30 - RSS_T5))
# Integer-only percent calc to avoid awk-portability issues on BSD awk.
if [ "$RSS_T5" -gt 0 ]; then
    GROWTH_PCT=$(( GROWTH * 100 / RSS_T5 ))
else
    GROWTH_PCT=999
fi
echo "  growth in 25 s: $GROWTH kB ($GROWTH_PCT%)"

if [ "$GROWTH_PCT" -lt 50 ]; then
    echo "PASS (growth < 50% over 25 s)"
else
    echo "FAIL: growth $GROWTH_PCT% > 50% — possible leak"
    exit 1
fi
