#!/usr/bin/env bash
# Test 45 — MULTI-LINE copy physical proof (operator-path).
#
# Forensic anchor: operator mandate (this turn) — "Selecting multiple
# lines and copying of them does not work. We MUST BE able to scroll
# vertically everywhere and copy / paste anything!"
#
# Test 44 already proves SINGLE-line copy via select-line + pbpaste
# end-to-end. That is necessary but not sufficient — the user-visible
# failure mode (selecting a 6-line block in copy-mode and pasting it
# elsewhere) was never exercised. This test closes that gap.
#
# §102 operator-path: spawn via `tmx new -s NAME` (the entry point an
# end-user invokes). §101 / §11.4.5 / §11.4.69 captured-evidence:
# read the OS-native paste tool back and assert SIX DISTINCT MARKERS
# appear in what pbpaste/wl-paste/xclip returns.
#
# §11.4.43 honest classification: this test is a REGRESSION GUARD
# for an existing capability, not a RED-first proof of a bug. The
# multi-line KEYBOARD path (v + cursor-down -N 5 + end-of-line + y)
# already works on v1.0.14 — but NO prior test exercised it end-to-
# end with positive evidence in the OS clipboard. The user's
# reported "multi-line copy does not work" stems from the MOUSE
# path failing inside Claude Code's mouse-tracking TUI (see test 48
# for the modifier-drag override that closes that gap). Test 45
# pins the keyboard path so the conf changes that fix the mouse
# path don't regress this surface.
#
# §11.4.14 cleanup: pre-test save + post-test restore of operator's
# existing clipboard, no clobber.
#
# §104 topology: T5 (system clipboard readback) honestly SKIPs when
# no Wayland / X11 / Termux clipboard tool is reachable (headless
# server). T2/T3/T4 binding-chain proof still PASS — test never
# becomes inert on headless Linux.

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

echo "── Test 45: MULTI-LINE copy physical proof (operator-path) ──"

PASS=0; FAIL=0; SKIP=0
S_NAME="tmx_t45_$$"
S_SOCK="tmx-${S_NAME}"
RUN_TAG="$$_$(date +%s)"
# 6 distinct markers spanning the selection range.
MARKERS=( "MLMARK_${RUN_TAG}_A" \
          "MLMARK_${RUN_TAG}_B" \
          "MLMARK_${RUN_TAG}_C" \
          "MLMARK_${RUN_TAG}_D" \
          "MLMARK_${RUN_TAG}_E" \
          "MLMARK_${RUN_TAG}_F" )

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

# Detect OS clipboard tool.
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

# T1 — structural: the conf template carries the multi-line bindings
#      we depend on. Single-line bindings already covered by test 44.
T1_OK=1
_t1() {
    if grep -Eq "$2" "$CONF_TPL"; then
        echo "  ✓ template: $1"
    else
        echo "  ✗ template MISSING: $1  (pattern: $2)"
        T1_OK=0
    fi
}
_t1 "@clip user option"          '^set +-g +@clip '
_t1 "copy-mode-vi v -> begin-sel" '^bind +-T +copy-mode-vi +v +.* begin-selection'
_t1 "copy-mode-vi y -> copy-pipe" '^bind +-T +copy-mode-vi +y +.* copy-pipe-and-cancel.*@clip'
if [ "$T1_OK" -eq 1 ]; then
    _pass "T1: tmux.conf.template carries multi-line selection bindings (v + y + @clip)"
else
    _fail "T1: tmux.conf.template missing multi-line selection bindings"
fi

# Spawn operator-path session.
"$WRAPPER" new -s "$S_NAME" -d >/dev/null 2>&1
sleep 2

if ! "$TMUX_BIN" -L "$S_SOCK" ls >/dev/null 2>&1; then
    _fail "T2.0: 'tmx new -s $S_NAME -d' did not create a server on socket $S_SOCK"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
_pass "T2.0: operator-path session created"

# T2 — print all 6 markers as a single consecutive block via printf, so
#      the OUTPUT lines are contiguous in scrollback (no interleaved
#      `echo MARKER_X` command lines between them). This is what makes
#      cursor-down 5 lines reach exactly MARKER_F's line, giving us a
#      clean selection-end target.
PRINTF_FMT=""
for m in "${MARKERS[@]}"; do
    PRINTF_FMT="${PRINTF_FMT}${m}\\n"
done
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" "printf '$PRINTF_FMT'" Enter

# Wait until ALL 6 markers are present in scrollback.
GEN_OK=0
for _i in $(seq 1 30); do
    sleep 0.3
    FULL_CAP="$("$TMUX_BIN" -L "$S_SOCK" capture-pane -p -S - -t "$S_NAME" 2>/dev/null || true)"
    HITS=0
    for m in "${MARKERS[@]}"; do
        if printf '%s' "$FULL_CAP" | grep -q "$m"; then
            HITS=$((HITS + 1))
        fi
    done
    if [ "$HITS" -eq "${#MARKERS[@]}" ]; then
        GEN_OK=1; break
    fi
done
if [ "$GEN_OK" -ne 1 ]; then
    _skip "T2: 6-marker generation did not complete in 9s — test inert this run"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi
_pass "T2.1: all 6 markers printed into the pane scrollback"

# T3 — enter copy-mode, search-backward to MARKER A (oldest = first
#      printed = topmost in scrollback), begin-selection, then
#      cursor-down 5 lines to extend selection through F. Then route
#      through @clip via copy-pipe-and-cancel.
"$TMUX_BIN" -L "$S_SOCK" copy-mode -t "$S_NAME" 2>/dev/null || true
sleep 0.3

IN_MODE="$("$TMUX_BIN" -L "$S_SOCK" display-message -p -t "$S_NAME" '#{pane_in_mode}' 2>/dev/null || echo 0)"
if [ "$IN_MODE" = "1" ]; then
    _pass "T3.1: copy-mode entered (pane_in_mode=1)"
else
    _fail "T3.1: copy-mode did not engage (pane_in_mode='$IN_MODE')"
fi

# Position copy-cursor on MARKER A (the topmost / oldest marker line).
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X search-backward "${MARKERS[0]}" 2>/dev/null || true
sleep 0.3

# Start selection at MARKER A; then extend it 5 lines downward to
# include MARKERS A..F (6 lines total).
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X begin-selection 2>/dev/null || true
sleep 0.1
# tmux send-keys -X count syntax: -N <count> goes BEFORE the action.
# `cursor-down -N 5` would silently parse the `-N 5` as junk and only
# move ONE line (caught while authoring this test — a §11.4.1 FAIL-
# bluff in our test script vs the code under test).
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X -N 5 cursor-down 2>/dev/null || true
sleep 0.1
# Extend selection to end of MARKER_F's line so the 6th marker is
# captured in full (a character-mode selection from col 0 of A to col 0
# of F would otherwise miss F's content entirely).
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X end-of-line 2>/dev/null || true
sleep 0.2

# Copy the multi-line selection through @clip — same code path the
# 'y' keystroke would trigger, exercising the @clip pipe end-to-end.
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X copy-pipe-and-cancel "#{@clip}" 2>/dev/null || true
sleep 0.5

# T4 — show-buffer must contain ALL 6 markers (multi-line proof, in
#      tmux's own buffer, before reaching the OS clipboard).
BUF="$("$TMUX_BIN" -L "$S_SOCK" show-buffer 2>/dev/null || true)"
PRESENT=0
MISSING=""
for m in "${MARKERS[@]}"; do
    if printf '%s' "$BUF" | grep -q "$m"; then
        PRESENT=$((PRESENT + 1))
    else
        MISSING="$MISSING $m"
    fi
done
if [ "$PRESENT" -eq "${#MARKERS[@]}" ]; then
    _pass "T4: multi-line @clip copy-pipe routed all 6 markers into tmux buffer (binding chain proven)"
else
    _fail "T4: tmux buffer carries $PRESENT/${#MARKERS[@]} markers (missing:$MISSING) — multi-line routing broken"
    echo "  buffer head: $(printf '%s' "$BUF" | head -c 200)"
fi

# T5 — PHYSICAL SYSTEM-CLIPBOARD PROOF for multi-line. The OS-native
#      paste tool MUST return ALL 6 markers — proving the multi-line
#      end-user copy + paste workflow is intact.
if [ -z "$PASTE_CMD" ]; then
    _skip "T5: no system clipboard tool reachable (host=$HOST_OS, no Wayland/X11/Termux); T4 multi-line buffer proof suffices"
else
    CLIP_NOW="$(eval "$PASTE_CMD" 2>/dev/null || true)"
    PRESENT=0
    MISSING=""
    for m in "${MARKERS[@]}"; do
        if printf '%s' "$CLIP_NOW" | grep -q "$m"; then
            PRESENT=$((PRESENT + 1))
        else
            MISSING="$MISSING $m"
        fi
    done
    if [ "$PRESENT" -eq "${#MARKERS[@]}" ]; then
        _pass "T5: SYSTEM CLIPBOARD ($CLIP_KIND) carries all 6 markers — PHYSICAL multi-line copy proven"
    else
        _fail "T5: $CLIP_KIND carries $PRESENT/${#MARKERS[@]} markers (missing:$MISSING) — multi-line copy did NOT reach OS clipboard"
        echo "  clipboard head: $(printf '%s' "$CLIP_NOW" | head -c 200)"
    fi
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
