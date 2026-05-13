#!/usr/bin/env bash
# Test 08 — wrapper applies oom_score_adj=-500 to the spawned tmux server
# via the OPERATOR PATH (`tmx new -s NAME`).
#
# Three pass paths:
#   (a) running as root → wrapper writes directly → PASS
#   (b) /usr/local/bin/tmx-oom-set installed with cap_sys_resource → PASS
#   (c) neither → SKIP with note about how to install the helper
#
# Constitution §11.4.7 (operator-path coverage): this test does NOT pass
# `-S /tmp/socket` directly; it invokes `tmx new -s NAME -d` like an
# operator does, then reads `/proc/<server-pid>/oom_score_adj` from the
# resulting per-session server.

set -uo pipefail
TMUX_BIN="${TMUX_BIN:?}"
WRAPPER="${WRAPPER:?WRAPPER not set — must be the absolute path to tmx wrapper script}"
SESSION="tmx_t08_$$"
SOCK_LABEL="tmx-${SESSION}"
echo "── Test 08: wrapper sets oom_score_adj=-500 ──"

# Linux-only: oom_score_adj is a /proc interface that doesn't exist on
# Darwin or any non-Linux kernel. Skip cleanly per §11.4.3 topology
# dispatch when on a non-Linux host.
if [ "$(uname -s)" != "Linux" ]; then
    echo "SKIP: oom_score_adj is a Linux-specific /proc interface; not applicable on $(uname -s)"
    echo "       On macOS, sessions are bounded by POSIX rlimit (RLIMIT_AS) instead — see test 15."
    exit 0
fi

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

# Cleanup any prior state
"$WRAPPER" kill-session -t "$SESSION" 2>/dev/null || true
sleep 1

# Operator path: create the session through the wrapper.
"$WRAPPER" new -s "$SESSION" -d 2>/dev/null
sleep 2

# Read the server's PID via the same -L the wrapper derived.
PID=$("$TMUX_BIN" -L "$SOCK_LABEL" display-message -p '#{pid}' 2>/dev/null || true)
if [ -z "$PID" ]; then
    echo "FAIL: tmux server PID not found on socket -L $SOCK_LABEL"
    "$WRAPPER" kill-session -t "$SESSION" 2>/dev/null || true
    exit 1
fi
ACTUAL=$(cat "/proc/$PID/oom_score_adj" 2>/dev/null)
if [ "$HAVE_HELPER" -eq 1 ]; then
    echo "  PID $PID oom_score_adj: $ACTUAL  (via setcap helper $OOM_HELPER)"
else
    echo "  PID $PID oom_score_adj: $ACTUAL  (via root direct write)"
fi

# Cleanup
"$WRAPPER" kill-session -t "$SESSION" 2>/dev/null || true

if [ "$ACTUAL" = "-500" ]; then
    echo "PASS"
else
    echo "FAIL: expected -500, got '$ACTUAL'"
    exit 1
fi
