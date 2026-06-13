#!/usr/bin/env bash
# Test 26 — uniform hostname-colour across all default-green tmux UI elements.
#
# Forensic anchor (operator mandate, 2026-05-21):
#   "Make sure that flying animated top decoration is colored in same
#    color as the bottom one in tmux / tmx!" — clarified to:
#   "Do coloring of all UI tmux parts with proper color we use instead
#    of default green. Anything colored with that green colors has to
#    become the color we have assigned to the bottom view we are
#    coloring."
#
# Pre-v1.0.8: _apply_host_color set only `status-style bg=$color`.
# Other default-green tmux UI surfaces (pane-active-border-style,
# clock-mode-colour, window-status-current-style) stayed green — so
# the active pane border + clock + selected-window highlight didn't
# match the hostname colour.
#
# v1.0.8 fix: _apply_host_color now sets all four. This test live-
# readbacks each setting from a real operator-path session.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
TMUX_BIN_OS="$(uname -s)"
case "$TMUX_BIN_OS" in
    Darwin) TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build-darwin/bin/tmux}" ;;
    Linux)  TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}" ;;
esac

if [ ! -x "$WRAPPER" ] || [ ! -x "$TMUX_BIN" ]; then
    _skip "T0: prerequisites not built ($WRAPPER / $TMUX_BIN)"
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    exit 0
fi

# Compute the expected hostname colour the same way the wrapper does.
HNAME=""
if [ -n "${TMX_HOSTNAME:-}" ]; then
    HNAME="$TMX_HOSTNAME"
elif [ "$TMUX_BIN_OS" = "Darwin" ] && command -v scutil >/dev/null 2>&1; then
    HNAME="$(scutil --get LocalHostName 2>/dev/null || true)"
fi
if [ -n "$HNAME" ]; then
    EXPECTED_COLOR="$(bash scripts/hostname_color.sh "$HNAME" 2>/dev/null)"
else
    EXPECTED_COLOR="$(bash scripts/hostname_color.sh 2>/dev/null)"
fi
echo "  expected colour: $EXPECTED_COLOR (from hostname $HNAME)"
if [ -z "$EXPECTED_COLOR" ]; then
    _fail "T0: could not compute expected colour from hostname"
    exit 1
fi

SESS="t26_ui_$$"
SOCK="tmx-${SESS}"
trap '
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
' EXIT

"$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1 || { _fail "T0: tmx new failed"; exit 1; }
# Wait for _apply_host_color to fire (it has its own 0.3s sleep + tmux
# may take time to settle). §11.4.1 source-layer hardening: under load
# the four `set -g` option writes land at slightly different times, so
# reading a single surface (status-style) early left T2/T3/T4 seeing the
# pre-fix default-green value ('' / 'fg=green'). Poll up to ~5s
# (25 × 0.2s) until ALL FOUR surfaces carry the expected colour, THEN run
# the four independent assertions below (which are UNCHANGED — a genuinely
# unrecoloured surface still fails after the full timeout).
for _i in $(seq 1 25); do
    LIVE_STATUS="$("$TMUX_BIN" -L "$SOCK" show -gv status-style 2>/dev/null || true)"
    LIVE_BORDER="$("$TMUX_BIN" -L "$SOCK" show -gv pane-active-border-style 2>/dev/null || true)"
    LIVE_CLOCK="$("$TMUX_BIN" -L "$SOCK" show -gv clock-mode-colour 2>/dev/null || true)"
    LIVE_WSC="$("$TMUX_BIN" -L "$SOCK" show -gv window-status-current-style 2>/dev/null || true)"
    if echo "$LIVE_STATUS" | grep -qE "bg=$EXPECTED_COLOR(,|$)" \
       && echo "$LIVE_BORDER" | grep -qE "fg=$EXPECTED_COLOR(,|$)" \
       && [ "$LIVE_CLOCK" = "$EXPECTED_COLOR" ] \
       && echo "$LIVE_WSC" | grep -qE "bg=$EXPECTED_COLOR(,|$)"; then
        break
    fi
    sleep 0.2
done

# T1 — status-style (the bottom bar; v1.0.7 baseline)
LIVE_STATUS="$("$TMUX_BIN" -L "$SOCK" show -gv status-style 2>/dev/null)"
if echo "$LIVE_STATUS" | grep -qE "bg=$EXPECTED_COLOR(,|$)"; then
    _pass "T1: status-style live carries bg=$EXPECTED_COLOR (positive evidence: '$LIVE_STATUS')"
else
    _fail "T1: status-style does not carry bg=$EXPECTED_COLOR — got '$LIVE_STATUS'"
fi

# T2 — pane-active-border-style (default fg=green pre-fix)
LIVE_BORDER="$("$TMUX_BIN" -L "$SOCK" show -gv pane-active-border-style 2>/dev/null)"
if echo "$LIVE_BORDER" | grep -qE "fg=$EXPECTED_COLOR(,|$)"; then
    _pass "T2: pane-active-border-style live carries fg=$EXPECTED_COLOR (positive evidence: '$LIVE_BORDER')"
else
    _fail "T2: pane-active-border-style does not carry fg=$EXPECTED_COLOR — got '$LIVE_BORDER'"
fi

# T3 — clock-mode-colour (default green pre-fix)
LIVE_CLOCK="$("$TMUX_BIN" -L "$SOCK" show -gv clock-mode-colour 2>/dev/null)"
if [ "$LIVE_CLOCK" = "$EXPECTED_COLOR" ]; then
    _pass "T3: clock-mode-colour live = $EXPECTED_COLOR (positive evidence: prefix+t clock face matches hostname colour)"
else
    _fail "T3: clock-mode-colour live = '$LIVE_CLOCK' ≠ $EXPECTED_COLOR"
fi

# T4 — window-status-current-style (selected-window highlight)
LIVE_WSC="$("$TMUX_BIN" -L "$SOCK" show -gv window-status-current-style 2>/dev/null)"
if echo "$LIVE_WSC" | grep -qE "bg=$EXPECTED_COLOR(,|$)"; then
    _pass "T4: window-status-current-style live carries bg=$EXPECTED_COLOR (positive evidence: '$LIVE_WSC')"
else
    _fail "T4: window-status-current-style does not carry bg=$EXPECTED_COLOR — got '$LIVE_WSC'"
fi

# T5 — uniformity invariant summary
if [ "$FAIL" -eq 0 ]; then
    _pass "T5: ALL four default-green tmux UI surfaces carry the hostname-derived $EXPECTED_COLOR — UI uniformly recoloured per operator mandate (positive evidence: four independent show -gv readbacks above)"
fi

echo ""
echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
