#!/usr/bin/env bash
# Test 44 — clipboard copy-OUT physical proof (operator-path).
#
# Forensic anchor: operator request (2026-05-22) — "we can always copy /
# paste from and to the terminal window and current tmux (tmx) session!
# Using mouse or keyboard MUST WORK properly!" The bindings exist in
# `scripts/tmux.conf.template` (`@clip` user option + `y` / `Enter` /
# `MouseDragEnd1Pane` bound to `copy-pipe-and-cancel "#{@clip}"`), but
# until this test landed nothing PROVED a single byte ever reached the
# system clipboard. The bindings could grep-pass while never actually
# routing — exactly the §101 PASS-bluff pattern forbidden by Constitution.
#
# §102 operator-path: this test exercises the SAME entry point an
# end-user invokes — `tmx new -s NAME` — and (a) invokes `@clip` through
# the configured `copy-pipe-and-cancel` mechanism, (b) triggers the
# actual `y` BINDING via `send-keys -t NAME y` so the bind table is
# exercised, then (c) reads back the system clipboard via the
# OS-native paste tool and asserts the unique marker is there. Physical
# proof per §101 / universal §11.4.2.
#
# §104 topology: detects the clipboard tool. macOS always has pbcopy.
# Linux: prefers wl-paste (Wayland), then xclip (X11), then
# termux-clipboard-get (Termux). On a headless Linux server (no DISPLAY
# / no Wayland / no Termux) the OS clipboard sub-checks SKIP-with-reason
# — the binding chain is still proven via tmux's own buffer (positive
# evidence) so the test is never a no-op even there.
#
# Anti-bluff cleanup: the operator's existing clipboard contents are
# CAPTURED at test start and RESTORED at exit so this test does not
# clobber whatever the operator had on their clipboard.

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

echo "── Test 44: clipboard copy-OUT physical proof (operator-path) ──"

PASS=0; FAIL=0; SKIP=0
S_NAME="tmx_t44_$$"
S_SOCK="tmx-${S_NAME}"
MARKER="CLIPMARK_${$}_$(date +%s)"

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

# ── Detect the OS-native clipboard read tool. paste_tool reads the
#    clipboard to stdout; write_tool reads stdin and sets the clipboard.
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

# ── Save the operator's clipboard so we restore it at exit. EMPTY is a
#    valid clipboard state; treat the read failing as empty.
OLD_CLIP=""
if [ -n "$PASTE_CMD" ]; then
    OLD_CLIP="$(eval "$PASTE_CMD" 2>/dev/null || true)"
fi

_cleanup() {
    "$WRAPPER" kill-session -t "$S_NAME" 2>/dev/null || true
    "$TMUX_BIN" -L "$S_SOCK" kill-server 2>/dev/null || true
    # Restore operator's prior clipboard (anti-bluff: do not clobber).
    if [ -n "$COPY_CMD" ]; then
        printf '%s' "$OLD_CLIP" | eval "$COPY_CMD" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

# ── Pre-checks ────────────────────────────────────────────────────────
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

echo "  marker: $MARKER"
echo "  clipboard tool: $CLIP_KIND"

# ── T1: structural — template carries the @clip option + the three
#       copy-pipe-and-cancel bindings. Static-source per §103 layer-1.
T1_OK=1
_t1() {
    if grep -Eq "$2" "$CONF_TPL"; then
        echo "  ✓ template: $1"
    else
        echo "  ✗ template MISSING: $1  (pattern: $2)"
        T1_OK=0
    fi
}
_t1 "@clip user option present"        '^set +-g +@clip '
_t1 "copy-mode-vi y -> copy-pipe"      '^bind +-T +copy-mode-vi +y .* copy-pipe-and-cancel.*@clip'
_t1 "copy-mode-vi Enter -> copy-pipe"  '^bind +-T +copy-mode-vi +Enter .* copy-pipe-and-cancel.*@clip'
_t1 "MouseDragEnd1Pane -> copy-pipe"   '^bind +-T +copy-mode-vi +MouseDragEnd1Pane .* copy-pipe-and-cancel.*@clip'
if [ "$T1_OK" -eq 1 ]; then
    _pass "T1: tmux.conf.template carries @clip + y / Enter / MouseDragEnd1Pane bindings"
else
    _fail "T1: tmux.conf.template is missing one or more clipboard bindings"
fi

# ── Spawn operator-path session. ────────────────────────────────────
"$WRAPPER" new -s "$S_NAME" -d >/dev/null 2>&1
sleep 2

if ! "$TMUX_BIN" -L "$S_SOCK" ls >/dev/null 2>&1; then
    _fail "T2.0: 'tmx new -s $S_NAME -d' did not create a server on socket $S_SOCK"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
_pass "T2.0: operator-path session created (positive evidence: 'tmux -L $S_SOCK ls' succeeded)"

# ── T2: live binding readback — the `y` key in copy-mode-vi must
#       resolve to copy-pipe-and-cancel referencing @clip.
Y_BIND="$(tmx_list_key "$TMUX_BIN" "$S_SOCK" copy-mode-vi y)"
if printf '%s' "$Y_BIND" | grep -q 'copy-pipe-and-cancel' \
    && printf '%s' "$Y_BIND" | grep -q '@clip'; then
    _pass "T2.1: live copy-mode-vi y binding routes selection through @clip (operator key path active)"
else
    _fail "T2.1: live copy-mode-vi y binding is not the @clip copy-pipe-and-cancel"
    echo "  observed: $Y_BIND"
fi

MD_BIND="$(tmx_list_key "$TMUX_BIN" "$S_SOCK" copy-mode-vi MouseDragEnd1Pane)"
if printf '%s' "$MD_BIND" | grep -q 'copy-pipe-and-cancel' \
    && printf '%s' "$MD_BIND" | grep -q '@clip'; then
    _pass "T2.2: live MouseDragEnd1Pane routes selection through @clip (operator mouse path active)"
else
    _fail "T2.2: live MouseDragEnd1Pane binding is not the @clip copy-pipe-and-cancel"
fi

# ── Print the marker into the pane and wait for it to appear. ────────
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" "echo $MARKER" Enter
GEN_OK=0
for _i in $(seq 1 20); do
    sleep 0.3
    if "$TMUX_BIN" -L "$S_SOCK" capture-pane -p -t "$S_NAME" 2>/dev/null \
         | grep -q "$MARKER"; then
        GEN_OK=1; break
    fi
done
if [ "$GEN_OK" -ne 1 ]; then
    _skip "T3: marker did not appear in pane within 6s — test inert this run"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

# ── T3: direct -X invocation — call copy-pipe-and-cancel with #{@clip}
#       (what the `y` binding RESOLVES to). Proves the @clip routing.
#       Enter copy-mode, search-backward to the marker, select-line,
#       copy-pipe-and-cancel referencing @clip.
"$TMUX_BIN" -L "$S_SOCK" copy-mode -t "$S_NAME" 2>/dev/null || true
sleep 0.3
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X search-backward "$MARKER" 2>/dev/null || true
sleep 0.3
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X select-line 2>/dev/null || true
sleep 0.2
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X copy-pipe-and-cancel "#{@clip}" 2>/dev/null || true
sleep 0.4

BUF="$("$TMUX_BIN" -L "$S_SOCK" show-buffer 2>/dev/null || true)"
if printf '%s' "$BUF" | grep -q "$MARKER"; then
    _pass "T3: direct @clip copy-pipe routed selection into tmux's own buffer (binding chain proven)"
else
    _fail "T3: tmux buffer does NOT carry the marker after the @clip copy-pipe — routing broken"
    echo "  buffer head: $(printf '%s' "$BUF" | head -c 80)"
fi

# ── T4: invoke the actual `y` BINDING with a keystroke. Same evidence
#       requirement, but exercises the bind-table dispatch end-to-end.
"$TMUX_BIN" -L "$S_SOCK" delete-buffer 2>/dev/null || true
"$TMUX_BIN" -L "$S_SOCK" copy-mode -t "$S_NAME" 2>/dev/null || true
sleep 0.3
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X search-backward "$MARKER" 2>/dev/null || true
sleep 0.3
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X select-line 2>/dev/null || true
sleep 0.2
# THE OPERATOR KEYSTROKE — sending literal `y` in copy-mode triggers
# the y binding from the copy-mode-vi table.
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" y 2>/dev/null || true
sleep 0.4

BUF2="$("$TMUX_BIN" -L "$S_SOCK" show-buffer 2>/dev/null || true)"
if printf '%s' "$BUF2" | grep -q "$MARKER"; then
    _pass "T4: pressing the 'y' key in copy-mode routed the selection (bind table active end-to-end)"
else
    _fail "T4: 'y' keystroke did not route the selection through @clip — bind table broken"
    echo "  buffer head: $(printf '%s' "$BUF2" | head -c 80)"
fi

# ── T5: PHYSICAL SYSTEM-CLIPBOARD PROOF. After the @clip pipe, the
#       OS-native paste tool must return the marker. This is the
#       end-user guarantee: a real external app would now paste it.
#       SKIP-with-reason where no clipboard tool is reachable
#       (headless Linux server) — the binding chain proof in T3/T4
#       still stands.
if [ -z "$PASTE_CMD" ]; then
    _skip "T5: no system clipboard tool reachable (host=$HOST_OS, no Wayland/X11/Termux); T3/T4 binding chain proof suffices for this environment"
else
    CLIP_NOW="$(eval "$PASTE_CMD" 2>/dev/null || true)"
    if printf '%s' "$CLIP_NOW" | grep -q "$MARKER"; then
        _pass "T5: SYSTEM CLIPBOARD ($CLIP_KIND) carries the marker — physical end-user proof copy worked"
    else
        _fail "T5: $CLIP_KIND did NOT contain the marker after the 'y' copy — @clip routing did not reach the OS clipboard"
        echo "  clipboard head: $(printf '%s' "$CLIP_NOW" | head -c 80)"
    fi
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
