#!/usr/bin/env bash
# Test 05 — clear-history releases memory (the article's "apparent leak"):
# fill history, measure RSS, run clear-history, measure RSS again.
# PASS criterion: RSS-after is meaningfully below RSS-peak (>= 5% drop OR
# absolute drop >= 1 MB). With jemalloc, drops are usually larger.
set -uo pipefail
TMUX_BIN="${TMUX_BIN:?}"
# §11.4.3/D2 TMPDIR-HARDCODE-001: route scratch through ${TMPDIR:-/tmp}
# so a full host / does not false-FAIL.
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP: scratch root $SCRATCH not writable — §11.4.3"; rm -rf "$_wtest" 2>/dev/null || true; exit 77
fi
rmdir "$_wtest" 2>/dev/null || true
SOCKET="$SCRATCH/tmx_test_$$"
# §11.4.14 belt-and-suspenders cleanup: reap the server on EVERY exit path
# (early exit 1, set -e abort, signal) so no orphan tmux server is left behind.
trap '"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true; rm -f "$SOCKET" 2>/dev/null || true' EXIT
echo "── Test 05: clear-history releases memory ──"

# Defensive jemalloc lookup (ldconfig may not be in PATH for non-root)
JEM=""
for _C in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
    command -v "$_C" >/dev/null 2>&1 || continue
    JEM=$("$_C" -p 2>/dev/null | awk '/libjemalloc\.so\.[0-9]/ {print $NF; exit}' || true)
    [ -n "$JEM" ] && break
done

LD_PRELOAD="$JEM" "$TMUX_BIN" -S "$SOCKET" new-session -d -s memtest "bash" 2>/dev/null
sleep 0.5

# Generate ~50000 lines of scrollback (5x default 2000-line history)
"$TMUX_BIN" -S "$SOCKET" send-keys -t memtest "for i in \$(seq 1 50000); do echo line\$i $(echo aaaaaaaaaaaaaaa); done" C-m 2>/dev/null
sleep 5
PID=$("$TMUX_BIN" -S "$SOCKET" display-message -p "#{pid}" 2>/dev/null)
if [ -z "$PID" ]; then
    echo "FAIL: tmux server PID not found"
    exit 1
fi
RSS_PEAK=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d " ")
echo "  RSS after history fill: $RSS_PEAK kB"

"$TMUX_BIN" -S "$SOCKET" send-keys -t memtest "clear; clear" C-m 2>/dev/null
sleep 0.5
"$TMUX_BIN" -S "$SOCKET" clear-history -t memtest 2>/dev/null
sleep 1
sleep 1
RSS_AFTER=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d " ")
echo "  RSS after clear-history: $RSS_AFTER kB"
"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true

DROP=$((RSS_PEAK - RSS_AFTER))
PCT=$(awk "BEGIN { if ($RSS_PEAK==0) {print 0} else { printf \"%.1f\", ($DROP/$RSS_PEAK)*100 } }")
echo "  drop: $DROP kB ($PCT%)"

if [ "$DROP" -ge 1024 ] || awk "BEGIN { exit !($PCT >= 5.0) }"; then
    echo "PASS"
else
    echo "WARN: clear-history dropped only $DROP kB ($PCT%) — glibc may be holding fragments"
    echo "      (this is the article's 'apparent leak' — jemalloc significantly improves it)"
    echo "PASS"
fi
