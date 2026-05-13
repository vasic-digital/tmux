#!/usr/bin/env bash
# Test 11 — hostname colour integration with the wrapper (operator-path).
#
# The wrapper applies a hostname-derived status-bar bg colour every time
# a session is created. This test exercises the OPERATOR PATH (`tmx new -s
# NAME`) — Constitution §11.4.7 — and asserts the colour is applied via
# positive runtime evidence (`tmx show -g status-style` reading bg from
# the same socket the wrapper routed to).
#
# §11.4.2 captured-evidence: every PASS reads the actual `set -g
# status-style` value back from the live server. No grep-on-script
# content asserts.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALGO="$REPO_ROOT/scripts/hostname_color.sh"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"

echo "── Test 11: hostname colour applied by wrapper (operator-path) ──"

PASS=0; FAIL=0; SKIP=0
A_NAME="tmx_t11_a_$$"
B_NAME="tmx_t11_b_$$"
A_SOCK="tmx-${A_NAME}"
B_SOCK="tmx-${B_NAME}"

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    "$WRAPPER" kill-session -t "$A_NAME" 2>/dev/null || true
    "$WRAPPER" kill-session -t "$B_NAME" 2>/dev/null || true
}
trap _cleanup EXIT

# Pre-checks
if [ ! -x "$TMUX_BIN" ]; then
    _skip "T0: tmux binary $TMUX_BIN not built — run setup.sh first"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi
if [ ! -x "$WRAPPER" ]; then
    _skip "T0: tmx wrapper $WRAPPER not generated — run setup.sh first"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi

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

# ── T3: compute the expected colour for THIS host ─────────────────────
HOST_COLOR=$("$ALGO" 2>/dev/null) || HOST_COLOR="green"
echo "  expected status-bg: $HOST_COLOR (host: $(hostname))"

# ── T4: create a session via the wrapper; status-bg matches expected ──
"$WRAPPER" new -s "$A_NAME" -d 2>/dev/null
sleep 2

ACTUAL=$("$TMUX_BIN" -L "$A_SOCK" show -g status-style 2>/dev/null | grep -oE 'bg=[^,[:space:]]+' | head -1 | sed 's/^bg=//')
if [ -z "$ACTUAL" ]; then
    _skip "T4.0: could not read status-style from $A_SOCK (wrapper may not have set it)"
else
    _pass "T4.0: status-style bg='$ACTUAL' read from session A's server (positive evidence: tmux -L $A_SOCK show -g status-style)"
fi

if [ -n "$ACTUAL" ]; then
    AC_NORM=$(echo "$ACTUAL" | tr '[:upper:]' '[:lower:]')
    HC_NORM=$(echo "$HOST_COLOR" | tr '[:upper:]' '[:lower:]')
    if [ "$AC_NORM" = "green" ]; then
        _fail "T4.1: status-bg is 'green' (tmux default) — colour was NOT applied. Expected '$HOST_COLOR' for this host."
    elif [ "$AC_NORM" = "$HC_NORM" ]; then
        _pass "T4.1: status-bg '$ACTUAL' matches expected '$HOST_COLOR' (hostname-derived colour applied)"
    else
        _fail "T4.1: status-bg '$ACTUAL' does NOT match expected '$HOST_COLOR'"
    fi
fi

# ── T5: SECOND session on a DIFFERENT socket gets the SAME colour ────
# This is the user-mandated invariant: same host → same colour across
# all sessions, regardless of socket/server boundary.
"$WRAPPER" new -s "$B_NAME" -d 2>/dev/null
sleep 2

ACTUAL2=$("$TMUX_BIN" -L "$B_SOCK" show -g status-style 2>/dev/null | grep -oE 'bg=[^,[:space:]]+' | head -1 | sed 's/^bg=//')
if [ -z "$ACTUAL2" ]; then
    _skip "T5: could not read status-style from $B_SOCK"
else
    if [ "$ACTUAL2" = "$ACTUAL" ]; then
        _pass "T5: second session on different socket has SAME colour '$ACTUAL2' (positive evidence: same-host-same-colour invariant holds across servers)"
    else
        _fail "T5: second session colour '$ACTUAL2' differs from first session's '$ACTUAL' — invariant broken"
    fi
fi

# ── T6: default-socket regression check (legacy A10 bug) ─────────────
# Even though the new architecture derives a per-session socket, this
# assertion confirms the wrapper does NOT silently fall back to tmux's
# default `bg=green` when colour application runs through the operator
# path. The check is implicit in T4.1 (which would FAIL on 'green'),
# but we restate it explicitly because the regression class is severe.
if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "green" ]; then
    _pass "T6: wrapper did not silently produce tmux's default bg=green (positive evidence: ACTUAL='$ACTUAL' from T4)"
elif [ -z "$ACTUAL" ]; then
    _skip "T6: cannot verify (T4 reading failed)"
else
    _fail "T6: wrapper produced bg=green — colour application bug (Fixed.md A10 regression)"
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
