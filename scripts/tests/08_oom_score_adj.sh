#!/usr/bin/env bash
# Test 08 — wrapper script applies oom_score_adj=-500 to tmux server.
#
# Three pass paths:
#   (a) running as root → wrapper writes directly → PASS
#   (b) /usr/local/bin/tmx-oom-set installed with cap_sys_resource → PASS
#   (c) neither → SKIP with note about how to install the helper
set -uo pipefail
TMUX_BIN="${TMUX_BIN:?}"
WRAPPER="${WRAPPER:?WRAPPER not set — must be the absolute path to tmx wrapper script}"
SOCKET="/tmp/tmx_test_$$"
echo "── Test 08: wrapper sets oom_score_adj=-500 ──"

if [ ! -x "$WRAPPER" ]; then
    echo "SKIP: wrapper $WRAPPER not yet generated (run setup.sh first)"
    exit 0
fi

OOM_HELPER="/usr/local/bin/tmx-oom-set"
HAVE_HELPER=0
[ -x "$OOM_HELPER" ] && HAVE_HELPER=1

if [ "$(id -u)" != "0" ] && [ "$HAVE_HELPER" -eq 0 ]; then
    echo "SKIP: oom_score_adj=-500 requires either (a) root, or (b) the setcap-enabled"
    echo "      $OOM_HELPER helper. Currently running as UID $(id -u) and helper is not installed."
    echo "      To enable Test 08 PASS:  sudo bash scripts/build_oom_set.sh --install"
    echo "      See docs/guides/TMUX_OPTIMIZED_BUILD.md §8 for full options."
    exit 0
fi

# Path (a) or (b) — wrapper should successfully apply -500
"$WRAPPER" -S "$SOCKET" new-session -d -s oomtest "sleep 30" 2>/dev/null &
WPID=$!
sleep 1.5
PID=$("$TMUX_BIN" -S "$SOCKET" display-message -p '#{pid}' 2>/dev/null || true)
if [ -z "$PID" ]; then
    echo "FAIL: tmux server PID not found"
    "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
    kill $WPID 2>/dev/null || true
    exit 1
fi
ACTUAL=$(cat "/proc/$PID/oom_score_adj" 2>/dev/null)
if [ "$HAVE_HELPER" -eq 1 ]; then
    echo "  PID $PID oom_score_adj: $ACTUAL  (via setcap helper $OOM_HELPER)"
else
    echo "  PID $PID oom_score_adj: $ACTUAL  (via root direct write)"
fi

"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
kill $WPID 2>/dev/null || true

if [ "$ACTUAL" = "-500" ]; then
    echo "PASS"
else
    echo "FAIL: expected -500, got '$ACTUAL'"
    exit 1
fi
