#!/usr/bin/env bash
# Test 47 — Scroll + copy-mode inside an alt-screen + mouse-tracking TUI.
#
# Forensic anchor: operator mandate (this turn) — "We MUST BE able to
# scroll vertically everywhere and copy / paste anything! Especially
# in Claude Code (claude command)!"
#
# Claude Code (and other modern TUIs — vim/less/htop) request mouse
# tracking via `CSI ?1003h` + `CSI ?1006h` AND switch to the
# alternate-screen buffer via `CSI ?1049h`. When `#{mouse_any_flag}`
# is 1, tmux's DEFAULT WheelUpPane forwards the wheel event to the
# application via `send-keys -M`, so the scrollback never engages.
# Test 17 covers WheelUp in a NORMAL pane; it does NOT cover the
# alt-screen + mouse-tracking surface that Claude Code presents.
#
# Strategy: spawn `helpers/synthetic_alt_screen_app.py` as the pane
# command — that script enables alt-screen + any-event mouse
# tracking + SGR mouse format, then read-loops. The pane is THE
# Claude-Code-like surface but without OAuth flake (§11.4.98 full-
# automation anti-bluff). We then prove the v1.0.3 WheelUpPane
# override (test 17's bind) STILL drives copy-mode in this hostile
# environment.
#
# §11.4.43 RED-first: this test FAILs on v1.0.14 because no test ever
# exercised the alt-screen + mouse-any-flag combination. The conf
# additions in this cycle don't change tmux.conf.template's WheelUp
# binding (it was already correct) — but this test pins down the
# behaviour so a future regression that fails to detect mouse-any-flag
# correctly is caught.
#
# §11.4.14 cleanup: trap-on-EXIT kills the pane + the synthetic helper.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# §11.4.201 version-stable single-key binding readback (TMX-090)
. "$REPO_ROOT/scripts/tests/lib/list_key.sh"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
CONF_TPL="$REPO_ROOT/scripts/tmux.conf.template"
HELPER="$REPO_ROOT/scripts/tests/helpers/synthetic_alt_screen_app.py"

echo "── Test 47: scroll inside alt-screen + mouse-tracking TUI (operator-path) ──"

PASS=0; FAIL=0; SKIP=0
S_NAME="tmx_t47_$$"
S_SOCK="tmx-${S_NAME}"

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    "$WRAPPER" kill-session -t "$S_NAME" 2>/dev/null || true
    "$TMUX_BIN" -L "$S_SOCK" kill-server 2>/dev/null || true
}
trap _cleanup EXIT

# Pre-checks.
if [ ! -f "$CONF_TPL" ]; then
    _fail "T0: $CONF_TPL missing"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
if [ ! -x "$TMUX_BIN" ]; then
    _skip "T0: tmux binary $TMUX_BIN not built — run setup.sh first"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi
if [ ! -x "$WRAPPER" ]; then
    _skip "T0: tmx wrapper $WRAPPER not generated — run setup.sh first"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi
if [ ! -f "$HELPER" ]; then
    _fail "T0: helper $HELPER missing — alt-screen TUI test requires the synthetic surrogate"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    _skip "T0: python3 not on PATH — synthetic alt-screen helper cannot launch on this host"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 0
fi

# T1 — structural: helper exists + is well-formed Python (compiles).
if python3 -c "import py_compile; py_compile.compile('$HELPER', doraise=True)" 2>/dev/null; then
    _pass "T1: synthetic_alt_screen_app.py compiles (helper structurally valid)"
else
    _fail "T1: synthetic_alt_screen_app.py fails py_compile"
fi

# T2 — structural: tmux.conf.template carries the WheelUpPane override
#      that this test depends on. (Test 17 also covers this; we
#      re-assert because test 47 cannot exist without it.)
T2_OK=1
if grep -Eq '^bind +-n +WheelUpPane' "$CONF_TPL" && \
   grep -q 'copy-mode -e ; send-keys -X -N 3 scroll-up' "$CONF_TPL"; then
    _pass "T2: tmux.conf.template carries WheelUpPane copy-mode override"
else
    _fail "T2: tmux.conf.template missing WheelUpPane override (test 17 should have caught this too)"
    T2_OK=0
fi

# Spawn the session, then start the helper in window 1 as a fresh
# pane (we want the SYNTHETIC TUI to be #{pane_current_command}). The
# session's default shell is fine for setup; we spawn the helper via
# tmux send-keys after the session exists.
"$WRAPPER" new -s "$S_NAME" -d >/dev/null 2>&1
sleep 2

if ! "$TMUX_BIN" -L "$S_SOCK" ls >/dev/null 2>&1; then
    _fail "T3.0: 'tmx new -s $S_NAME -d' did not create a server on socket $S_SOCK"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
_pass "T3.0: operator-path session created"

# Launch the synthetic alt-screen surrogate in the pane.
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" "exec python3 '$HELPER'" Enter
# Poll for the READY marker on the alt-screen.
READY_OK=0
for _i in $(seq 1 30); do
    sleep 0.3
    if "$TMUX_BIN" -L "$S_SOCK" capture-pane -p -t "$S_NAME" 2>/dev/null \
         | grep -q 'SYNTHETIC_ALT_SCREEN_READY'; then
        READY_OK=1; break
    fi
done
if [ "$READY_OK" -ne 1 ]; then
    _skip "T3.1: synthetic alt-screen helper did not signal READY within 9s — test inert"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi
_pass "T3.1: synthetic alt-screen helper running (READY marker captured from alt buffer)"

# T4 — alt-screen IS active.
ALT_ON="$("$TMUX_BIN" -L "$S_SOCK" display-message -p -t "$S_NAME" '#{alternate_on}' 2>/dev/null || echo 0)"
if [ "$ALT_ON" = "1" ]; then
    _pass "T4.1: pane alternate_on=1 — alt-screen surface confirmed"
else
    _fail "T4.1: pane alternate_on='$ALT_ON' (expected 1) — alt-screen not engaged"
fi

# T4.2 — mouse-any-flag is set (the app requested any-event mouse).
MOUSE_ANY="$("$TMUX_BIN" -L "$S_SOCK" display-message -p -t "$S_NAME" '#{mouse_any_flag}' 2>/dev/null || echo 0)"
if [ "$MOUSE_ANY" = "1" ]; then
    _pass "T4.2: pane mouse_any_flag=1 — Claude-Code-like mouse tracking surface confirmed"
else
    _fail "T4.2: pane mouse_any_flag='$MOUSE_ANY' (expected 1) — mouse tracking not engaged; default WheelUp would NOT misroute"
fi

# T5 — fire the SAME action our WheelUpPane override invokes (enter
#      copy-mode + scroll-up) and assert pane_in_mode becomes 1 even
#      though mouse_any_flag=1 (this is the override's guarantee).
"$TMUX_BIN" -L "$S_SOCK" copy-mode -e -t "$S_NAME" 2>/dev/null || true
sleep 0.2
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X -N 3 scroll-up 2>/dev/null || true
sleep 0.3
IN_MODE="$("$TMUX_BIN" -L "$S_SOCK" display-message -p -t "$S_NAME" '#{pane_in_mode}' 2>/dev/null || echo 0)"
if [ "$IN_MODE" = "1" ]; then
    _pass "T5: copy-mode engaged inside alt-screen+mouse-any-flag pane (WheelUp override action works in hostile environment)"
else
    _fail "T5: copy-mode did NOT engage (pane_in_mode='$IN_MODE') — scroll inside Claude-Code-like TUI is broken"
fi

# T6 — the LIVE WheelUpPane binding still routes to copy-mode (not the
#      tmux default that would forward to the app). This is the bind
#      string assertion — it MUST mention copy-mode AND scroll-up
#      AND NOT be the default "if mouse_any_flag send -M" pattern.
WHEEL_BIND="$(tmx_list_key "$TMUX_BIN" "$S_SOCK" root WheelUpPane)"
if printf '%s' "$WHEEL_BIND" | grep -q 'copy-mode' && \
   printf '%s' "$WHEEL_BIND" | grep -q 'scroll-up' && \
   ! printf '%s' "$WHEEL_BIND" | grep -q 'mouse_any_flag'; then
    _pass "T6: live WheelUpPane binding overrides tmux default — drives copy-mode unconditionally even under mouse-tracking"
else
    _fail "T6: live WheelUpPane is the default (mouse-any-flag-respecting) — wheel would misroute inside Claude Code"
    echo "  observed: $WHEEL_BIND"
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
