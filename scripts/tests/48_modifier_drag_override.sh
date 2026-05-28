#!/usr/bin/env bash
# Test 48 — Alt-drag + Shift-drag override for selection inside
#           alt-screen + mouse-tracking TUI (operator-path).
#
# Forensic anchor: operator mandate (this turn) — "Selecting multiple
# lines and copying of them does not work … especially in Claude Code
# (claude command)!"
#
# tmux's DEFAULT MouseDrag1Pane forwards the drag to the application
# whenever `#{mouse_any_flag}` is 1. Inside Claude Code (or any TUI
# with mouse tracking), the user CANNOT initiate a tmux selection
# with a plain drag. Operator chose (this turn) to add BOTH modifier-
# drag overrides so either Alt+drag OR Shift+drag forces tmux to
# take the drag for selection:
#
#   bind -n M-MouseDrag1Pane copy-mode -M
#   bind -n S-MouseDrag1Pane copy-mode -M
#
# tmux CLI cannot synthesise a literal mouse drag event (no
# send-keys -Mouse syntax), so we exercise the binding's RESOLUTION
# (list-keys) AND drive the SAME code path the drag-then-release
# would trigger via the keyboard-equivalent flow:
#   begin-selection + cursor-down -N 5 + y → copy-pipe-and-cancel
#   "#{@clip}" → pbpaste returns the 6-marker block.
#
# §11.4.43 RED-first: this test FAILs on stock v1.0.14 (no
# M-MouseDrag1Pane / S-MouseDrag1Pane bind in conf). It GREENs once
# the conf adds the two overrides + the matching MouseDragEnd
# routing.
#
# §11.4.14 cleanup: pre-test clipboard save + post-test restore.
# §104: T5 (pbpaste readback) honestly SKIPs on headless Linux;
# binding-chain proof T1-T4 still PASS.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
CONF_TPL="$REPO_ROOT/scripts/tmux.conf.template"
HELPER="$REPO_ROOT/scripts/tests/helpers/synthetic_alt_screen_app.py"

echo "── Test 48: Alt-drag + Shift-drag override for selection (operator-path) ──"

PASS=0; FAIL=0; SKIP=0
S_NAME="tmx_t48_$$"
S_SOCK="tmx-${S_NAME}"
RUN_TAG="$$_$(date +%s)"
MARKERS=( "DRAGMARK_${RUN_TAG}_A" \
          "DRAGMARK_${RUN_TAG}_B" \
          "DRAGMARK_${RUN_TAG}_C" \
          "DRAGMARK_${RUN_TAG}_D" \
          "DRAGMARK_${RUN_TAG}_E" \
          "DRAGMARK_${RUN_TAG}_F" )

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

# Detect clipboard tool.
PASTE_CMD="" ; COPY_CMD="" ; CLIP_KIND="(none)"
case "$HOST_OS" in
    Darwin)
        if command -v pbpaste >/dev/null 2>&1 && command -v pbcopy >/dev/null 2>&1; then
            PASTE_CMD="pbpaste" ; COPY_CMD="pbcopy" ; CLIP_KIND="pbcopy/pbpaste"
        fi
        ;;
    Linux)
        if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1 \
            && command -v wl-copy >/dev/null 2>&1; then
            PASTE_CMD="wl-paste -n" ; COPY_CMD="wl-copy" ; CLIP_KIND="wl-copy (Wayland)"
        elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
            PASTE_CMD="xclip -o -selection clipboard"
            COPY_CMD="xclip -i -selection clipboard" ; CLIP_KIND="xclip (X11)"
        elif command -v termux-clipboard-get >/dev/null 2>&1 \
            && command -v termux-clipboard-set >/dev/null 2>&1; then
            PASTE_CMD="termux-clipboard-get" ; COPY_CMD="termux-clipboard-set"
            CLIP_KIND="termux-clipboard (Termux/Android)"
        fi
        ;;
esac

OLD_CLIP=""
if [ -n "$PASTE_CMD" ]; then
    OLD_CLIP="$(eval "$PASTE_CMD" 2>/dev/null || true)"
fi

_cleanup() {
    "$WRAPPER" kill-session -t "$S_NAME" 2>/dev/null || true
    "$TMUX_BIN" -L "$S_SOCK" kill-server 2>/dev/null || true
    if [ -n "$COPY_CMD" ]; then
        printf '%s' "$OLD_CLIP" | eval "$COPY_CMD" 2>/dev/null || true
    fi
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

echo "  markers: ${MARKERS[*]}"
echo "  clipboard tool: $CLIP_KIND"

# T1 — structural: both modifier-drag binds AND their drag-end pair
#      are present in the conf template.
T1_OK=1
_t1() {
    if grep -Eq "$2" "$CONF_TPL"; then
        echo "  ✓ template: $1"
    else
        echo "  ✗ template MISSING: $1  (pattern: $2)"
        T1_OK=0
    fi
}
_t1 "M-MouseDrag1Pane override"  '^bind +-n +M-MouseDrag1Pane +.*copy-mode -M'
_t1 "S-MouseDrag1Pane override"  '^bind +-n +S-MouseDrag1Pane +.*copy-mode -M'
_t1 "M-MouseDragEnd1Pane pipe"   '^bind +-T +copy-mode-vi +M-MouseDragEnd1Pane +.*copy-pipe-and-cancel.*@clip'
_t1 "S-MouseDragEnd1Pane pipe"   '^bind +-T +copy-mode-vi +S-MouseDragEnd1Pane +.*copy-pipe-and-cancel.*@clip'
if [ "$T1_OK" -eq 1 ]; then
    _pass "T1: tmux.conf.template carries Alt-drag + Shift-drag overrides (both modifier paths)"
else
    _fail "T1: tmux.conf.template missing one or more modifier-drag overrides"
fi

# Spawn operator-path session.
"$WRAPPER" new -s "$S_NAME" -d >/dev/null 2>&1
sleep 2

if ! "$TMUX_BIN" -L "$S_SOCK" ls >/dev/null 2>&1; then
    _fail "T2.0: 'tmx new -s $S_NAME -d' did not create a server on socket $S_SOCK"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
_pass "T2.0: operator-path session created"

# T2 — live readback for the four bindings.
M_BIND="$("$TMUX_BIN" -L "$S_SOCK" list-keys -T root M-MouseDrag1Pane 2>/dev/null || true)"
if printf '%s' "$M_BIND" | grep -q 'copy-mode'; then
    _pass "T2.1: live M-MouseDrag1Pane binding drives copy-mode"
else
    _fail "T2.1: live M-MouseDrag1Pane binding missing or wrong"
    echo "  observed: $M_BIND"
fi

S_BIND="$("$TMUX_BIN" -L "$S_SOCK" list-keys -T root S-MouseDrag1Pane 2>/dev/null || true)"
if printf '%s' "$S_BIND" | grep -q 'copy-mode'; then
    _pass "T2.2: live S-MouseDrag1Pane binding drives copy-mode"
else
    _fail "T2.2: live S-MouseDrag1Pane binding missing or wrong"
    echo "  observed: $S_BIND"
fi

ME_BIND="$("$TMUX_BIN" -L "$S_SOCK" list-keys -T copy-mode-vi M-MouseDragEnd1Pane 2>/dev/null || true)"
if printf '%s' "$ME_BIND" | grep -q 'copy-pipe-and-cancel' \
    && printf '%s' "$ME_BIND" | grep -q '@clip'; then
    _pass "T2.3: live M-MouseDragEnd1Pane binding routes selection through @clip"
else
    _fail "T2.3: live M-MouseDragEnd1Pane is not the @clip copy-pipe-and-cancel"
fi

SE_BIND="$("$TMUX_BIN" -L "$S_SOCK" list-keys -T copy-mode-vi S-MouseDragEnd1Pane 2>/dev/null || true)"
if printf '%s' "$SE_BIND" | grep -q 'copy-pipe-and-cancel' \
    && printf '%s' "$SE_BIND" | grep -q '@clip'; then
    _pass "T2.4: live S-MouseDragEnd1Pane binding routes selection through @clip"
else
    _fail "T2.4: live S-MouseDragEnd1Pane is not the @clip copy-pipe-and-cancel"
fi

# T3 — drive the SAME code path the modifier-drag would trigger via
#      the keyboard equivalent — begin-selection + cursor-down -N 5 +
#      copy-pipe-and-cancel "#{@clip}". This proves the SELECT path
#      a successful modifier-drag would land on actually works.
# Single-printf block for contiguous-line scrollback (see test 45).
PRINTF_FMT=""
for m in "${MARKERS[@]}"; do
    PRINTF_FMT="${PRINTF_FMT}${m}\\n"
done
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" "printf '$PRINTF_FMT'" Enter
# Wait for markers.
GEN_OK=0
for _i in $(seq 1 30); do
    sleep 0.3
    FULL_CAP="$("$TMUX_BIN" -L "$S_SOCK" capture-pane -p -S - -t "$S_NAME" 2>/dev/null || true)"
    HITS=0
    for m in "${MARKERS[@]}"; do
        if printf '%s' "$FULL_CAP" | grep -q "$m"; then HITS=$((HITS + 1)); fi
    done
    if [ "$HITS" -eq "${#MARKERS[@]}" ]; then GEN_OK=1; break; fi
done
if [ "$GEN_OK" -ne 1 ]; then
    _skip "T3: 6-marker generation did not complete in 9s — test inert this run"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

"$TMUX_BIN" -L "$S_SOCK" copy-mode -t "$S_NAME" 2>/dev/null || true
sleep 0.3
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X search-backward "${MARKERS[0]}" 2>/dev/null || true
sleep 0.3
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X begin-selection 2>/dev/null || true
sleep 0.1
# tmux count flag goes BEFORE the action; see test 45 for forensic note.
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X -N 5 cursor-down 2>/dev/null || true
sleep 0.1
# Extend selection to end of MARKER_F's line (see test 45 forensic note).
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X end-of-line 2>/dev/null || true
sleep 0.2
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X copy-pipe-and-cancel "#{@clip}" 2>/dev/null || true
sleep 0.5

BUF="$("$TMUX_BIN" -L "$S_SOCK" show-buffer 2>/dev/null || true)"
PRESENT=0
for m in "${MARKERS[@]}"; do
    if printf '%s' "$BUF" | grep -q "$m"; then PRESENT=$((PRESENT + 1)); fi
done
if [ "$PRESENT" -eq "${#MARKERS[@]}" ]; then
    _pass "T3: keyboard-equivalent of modifier-drag (v + cursor-down -N 5 + copy-pipe @clip) routes 6 markers into tmux buffer"
else
    _fail "T3: keyboard-equivalent route produced only $PRESENT/${#MARKERS[@]} markers in buffer"
fi

# T4 — synthetic alt-screen scenario: confirm that under
#      mouse_any_flag=1 the modifier-drag binds STILL exist (they are
#      `bind -n` root-table; mouse-any-flag does not gate them).
if [ -x "$HELPER" ] && command -v python3 >/dev/null 2>&1; then
    "$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" "exec python3 '$HELPER'" Enter
    sleep 1.5
    MOUSE_ANY="$("$TMUX_BIN" -L "$S_SOCK" display-message -p -t "$S_NAME" '#{mouse_any_flag}' 2>/dev/null || echo 0)"
    if [ "$MOUSE_ANY" = "1" ]; then
        # Re-readback the M-MouseDrag1Pane bind WHILE the app is in
        # mouse-tracking mode. Binds in the root table do not change;
        # this is a defensive assertion that the override survives.
        M_BIND2="$("$TMUX_BIN" -L "$S_SOCK" list-keys -T root M-MouseDrag1Pane 2>/dev/null || true)"
        if printf '%s' "$M_BIND2" | grep -q 'copy-mode'; then
            _pass "T4: M-MouseDrag1Pane override survives mouse_any_flag=1 surface (Claude-Code-like)"
        else
            _fail "T4: M-MouseDrag1Pane override LOST under mouse_any_flag=1 — modifier-drag broken inside Claude Code"
        fi
    else
        _skip "T4: synthetic helper did not establish mouse_any_flag=1 — alt-screen surface not engaged this run"
    fi
else
    _skip "T4: synthetic alt-screen helper or python3 unavailable — modifier-drag tested only against normal pane (T1-T3)"
fi

# T5 — PHYSICAL SYSTEM-CLIPBOARD: the same keyboard-equivalent flow
#      should land the 6-marker block in the OS clipboard. T3 already
#      proved the tmux buffer; T5 proves @clip reaches pbpaste.
if [ -z "$PASTE_CMD" ]; then
    _skip "T5: no system clipboard tool reachable (host=$HOST_OS); T3 multi-marker buffer proof suffices"
else
    CLIP_NOW="$(eval "$PASTE_CMD" 2>/dev/null || true)"
    PRESENT=0
    for m in "${MARKERS[@]}"; do
        if printf '%s' "$CLIP_NOW" | grep -q "$m"; then PRESENT=$((PRESENT + 1)); fi
    done
    if [ "$PRESENT" -eq "${#MARKERS[@]}" ]; then
        _pass "T5: SYSTEM CLIPBOARD ($CLIP_KIND) carries all 6 markers from the keyboard-equivalent modifier-drag flow"
    else
        _fail "T5: $CLIP_KIND carries $PRESENT/${#MARKERS[@]} markers — @clip routing did not reach OS clipboard for multi-line block"
    fi
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
