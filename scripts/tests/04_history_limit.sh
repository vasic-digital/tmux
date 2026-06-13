#!/usr/bin/env bash
# Test 04 — history-limit setting: verify the config-file value is respected.
# Robust against libtinfo stderr pollution.
set -uo pipefail
TMUX_BIN="${TMUX_BIN:?}"
SOCKET="/tmp/tmx_test_$$"
CONFIG="/tmp/tmx_test_conf_$$"
# §11.4.14 belt-and-suspenders cleanup: reap the server + remove temp config on
# EVERY exit path (early exit 1, set -e abort, signal) so no orphan tmux server
# or stray temp file is left behind.
trap '"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true; rm -f "$CONFIG" "$SOCKET" 2>/dev/null || true' EXIT
echo "── Test 04: history-limit respect ──"
echo "set -g history-limit 1500" > "$CONFIG"
"$TMUX_BIN" -S "$SOCKET" -f "$CONFIG" new-session -d -s histtest "sleep 30" 2>/dev/null
sleep 0.3
ACTUAL=$("$TMUX_BIN" -S "$SOCKET" show-options -g history-limit 2>/dev/null | awk '{print $NF}')
"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
rm -f "$CONFIG"
if [ "$ACTUAL" = "1500" ]; then
    echo "  ✓ history-limit reports 1500 as configured"
    echo "PASS"
else
    echo "FAIL: configured 1500, got '$ACTUAL'"
    exit 1
fi
