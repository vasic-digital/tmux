#!/usr/bin/env bash
# Test 02 — Session lifecycle: new-session detached, list-sessions sees it,
# kill-server cleans up. Robust against libtinfo stderr pollution.
set -uo pipefail
TMUX_BIN="${TMUX_BIN:?}"
SESSION="tmx_test_$$"
SOCKET="/tmp/tmx_test_$$"
# §11.4.14 belt-and-suspenders cleanup: reap the server on EVERY exit path
# (early exit 1, set -e abort, signal) so no orphan tmux server is left behind.
trap '"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true; rm -f "$SOCKET" 2>/dev/null || true' EXIT
echo "── Test 02: session lifecycle ──"
"$TMUX_BIN" -S "$SOCKET" new-session -d -s "$SESSION" "sleep 30" 2>/dev/null
sleep 0.3
LISTED=$("$TMUX_BIN" -S "$SOCKET" list-sessions 2>/dev/null | head -1)
echo "  listed: $LISTED"
if ! echo "$LISTED" | grep -q "$SESSION"; then
    "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
    echo "FAIL: session $SESSION did not appear in list-sessions"
    exit 1
fi
"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
echo "PASS"
