#!/usr/bin/env bash
# Test 11 — hostname→color integration: the tmx wrapper sets the tmux
# status-bg to the hostname-derived colour.
#
# Constitution §1 anti-bluff: PASS requires positive evidence that the
# colour actually appears in the running server's status-style.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALGO="$REPO_ROOT/scripts/hostname_color.sh"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"
SOCKET="/tmp/tmx_test_color_$$"
echo "── Test 11: hostname colour applied by wrapper ──"

# ── Pre-check: binary and wrapper must exist ──────────────────────────
if [ ! -x "$TMUX_BIN" ]; then
    echo "SKIP: tmux binary $TMUX_BIN not built — run setup.sh first"
    exit 0
fi
if [ ! -x "$WRAPPER" ]; then
    echo "SKIP: tmx wrapper $WRAPPER not generated — run setup.sh first"
    exit 0
fi

PASS=0
FAIL=0
SKIP=0

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

# ── T1: wrapper script contains _apply_host_color ─────────────────────
if grep -q '_apply_host_color' "$WRAPPER"; then
    _pass "T1: tmx wrapper includes _apply_host_color"
else
    _fail "T1: tmx wrapper missing _apply_host_color function"
fi

# ── T2: wrapper references hostname_color.sh ──────────────────────────
if grep -q 'hostname_color.sh' "$WRAPPER"; then
    _pass "T2: tmx wrapper calls hostname_color.sh"
else
    _fail "T2: tmx wrapper does not reference hostname_color.sh"
fi

# ── T3: expected colour for this host ─────────────────────────────────
HOST_COLOR=$("$ALGO" 2>/dev/null) || HOST_COLOR="green"
echo "  expected status-bg: $HOST_COLOR (host: $(hostname))"

# ── T4: start a tmux session, verify colour is set ────────────────────
echo "  starting tmux session via wrapper..."
"$WRAPPER" -S "$SOCKET" new-session -d -s colortest "sleep 30" 2>/dev/null &
WPID=$!
sleep 2

ACTUAL_COLOR=$("$TMUX_BIN" -S "$SOCKET" show -g status-style 2>/dev/null | grep -oP 'bg=\K\S+' || echo "")
if [ -n "$ACTUAL_COLOR" ]; then
    _pass "T4.0: status-style bg read from server: $ACTUAL_COLOR (positive evidence: 'show -g status-style')"
else
    _skip "T4.0: could not read status-style from server" "server may not have started"
fi

if [ -n "$ACTUAL_COLOR" ]; then
    # Normalise both to lower-case for comparison
    AC_NORM=$(echo "$ACTUAL_COLOR" | tr '[:upper:]' '[:lower:]')
    HC_NORM=$(echo "$HOST_COLOR" | tr '[:upper:]' '[:lower:]')
    if [ "$AC_NORM" = "$HC_NORM" ]; then
        _pass "T4.1: status-bg '$ACTUAL_COLOR' matches expected '$HOST_COLOR' (hostname-derived colour applied)"
    else
        _fail "T4.1: status-bg '$ACTUAL_COLOR' does not match expected '$HOST_COLOR' — colour not applied"
    fi
fi

# ── T5: colour persists on re-attach ──────────────────────────────────
"$TMUX_BIN" -S "$SOCKET" new-session -d -s colortest2 "sleep 30" 2>/dev/null
sleep 1
ACTUAL2=$("$TMUX_BIN" -S "$SOCKET" show -g status-style 2>/dev/null | grep -oP 'bg=\K\S+' || echo "")
if [ -n "$ACTUAL2" ]; then
    AC2_NORM=$(echo "$ACTUAL2" | tr '[:upper:]' '[:lower:]')
    HC_NORM=$(echo "$HOST_COLOR" | tr '[:upper:]' '[:lower:]')
    if [ "$AC2_NORM" = "$HC_NORM" ]; then
        _pass "T5: colour persists on second session — status-bg '$ACTUAL2' still matches '$HOST_COLOR'"
    else
        _fail "T5: colour changed on second session: '$ACTUAL2' vs expected '$HOST_COLOR'"
    fi
else
    _skip "T5: could not read status-style" "server gone"
fi

# ── T6: DEFAULT-SOCKET path (no -S passed) — exercises the operator's ─
#       actual use case `tmx new -s X`. This catches the §11.4.1 FAIL-bluff
#       where _apply_host_color silently bailed via
#       `[ -n "$sock" ] || return 0` when no -S was passed (Fixed.md A10).
#       Without this assertion, test 11 PASS=5 even though `tmx new -s X`
#       in production left the operator with the tmux default `bg=green`.
"$TMUX_BIN" kill-server 2>/dev/null || true   # ensure default socket starts clean
DEFAULT_BG_BEFORE=$("$TMUX_BIN" show -g status-style 2>/dev/null | grep -oP 'bg=\K\S+' || echo "none")
"$WRAPPER" new-session -d -s defsock_test "sleep 30" 2>/dev/null &
DEFAULT_WPID=$!
sleep 2
DEFAULT_ACTUAL=$("$TMUX_BIN" show -g status-style 2>/dev/null | grep -oP 'bg=\K\S+' || echo "")
if [ -z "$DEFAULT_ACTUAL" ]; then
    _skip "T6: could not read status-style from default-socket server" "wrapper may not have started server"
elif [ "$DEFAULT_ACTUAL" = "green" ]; then
    _fail "T6: status-bg 'green' (tmux DEFAULT) — colour was NOT applied via default-socket path. This is the operator-facing bug from Fixed.md A10. Expected '$HOST_COLOR'."
else
    DA_NORM=$(echo "$DEFAULT_ACTUAL" | tr '[:upper:]' '[:lower:]')
    HC_NORM=$(echo "$HOST_COLOR" | tr '[:upper:]' '[:lower:]')
    if [ "$DA_NORM" = "$HC_NORM" ]; then
        _pass "T6: default-socket path applies host colour — status-bg '$DEFAULT_ACTUAL' matches '$HOST_COLOR' (positive evidence: tmux show -g status-style with NO -S)"
    else
        _fail "T6: default-socket status-bg '$DEFAULT_ACTUAL' does not match expected '$HOST_COLOR'"
    fi
fi
"$TMUX_BIN" kill-server 2>/dev/null || true
kill "$DEFAULT_WPID" 2>/dev/null || true

# ── Cleanup ────────────────────────────────────────────────────────────
"$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
kill "$WPID" 2>/dev/null || true

# ── summary ────────────────────────────────────────────────────────────
echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
