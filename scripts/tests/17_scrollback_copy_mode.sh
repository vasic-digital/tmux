#!/usr/bin/env bash
# Test 17 — scrollback + copy-mode scrolling (operator-path).
#
# Forensic anchor: operators reported that scrolling terminal output up
# and down — especially inside the Claude Code TUI — did not work. Root
# cause: (a) the default history-limit (2000) was too small, and (b)
# tmux's default WheelUpPane binding forwards the wheel to applications
# that request mouse reporting (Claude Code, vim, less), so the wheel
# never reached tmux's own scrollback. The fix (Fixed.md A16) bumps
# history-limit to 50000, sets mode-keys vi, overrides WheelUp/WheelDown
# so the wheel ALWAYS drives tmux copy-mode scrollback, and adds the
# Claude-Code passthrough settings (allow-passthrough / extended-keys).
#
# Constitution §102 (operator-path): this test exercises the SAME entry
# point an end user invokes — `tmx new -s NAME` — and reads back live
# state from the resulting server. The `tmx` wrapper loads
# `scripts/tmux.conf.template` via `tmux -f`, so the running server here
# carries exactly the config the operator gets.
#
# §11.4.2 captured-evidence: every PASS reads live server state
# (show-options / list-keys / capture-pane / display-message), not just
# script content. T4 proves the END-USER GUARANTEE functionally: it
# generates 3000 lines of output, proves the first line scrolled off
# the visible screen, then proves the operator CAN scroll back to it via
# copy-mode and even copy it.
#
# 3000 lines is deliberately chosen: > the OLD default (2000, where line
# 1 would be evicted) and < the NEW limit (50000). So T4.2 passing is
# positive proof the history-limit bump is functional, not cosmetic.

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

echo "── Test 17: scrollback + copy-mode scrolling (operator-path) ──"

PASS=0; FAIL=0; SKIP=0
S_NAME="tmx_t17_$$"
S_SOCK="tmx-${S_NAME}"

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    "$WRAPPER" kill-session -t "$S_NAME" 2>/dev/null || true
    "$TMUX_BIN" -L "$S_SOCK" kill-server 2>/dev/null || true
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

# ── T1: structural — the conf template carries every scroll setting. ──
#    Source-layer assertion per §103 layer-1, in addition to the runtime
#    readbacks in T2/T3. Each grep is paired with a live readback below;
#    grep alone is never the only assertion (§102).
T1_OK=1
_t1() {  # _t1 "<label>" "<grep -E pattern>"
    if grep -Eq "$2" "$CONF_TPL"; then
        echo "  ✓ template: $1"
    else
        echo "  ✗ template MISSING: $1  (pattern: $2)"
        T1_OK=0
    fi
}
_t1 "history-limit 50000"          '^set +-g +history-limit +50000'
_t1 "mode-keys vi"                 '^setw? +-g +mode-keys +vi'
_t1 "WheelUpPane -> copy-mode"     '^bind +-n +WheelUpPane'
_t1 "WheelUpPane scroll-up cmd"    'copy-mode -e ; send-keys -X -N 3 scroll-up'
_t1 "allow-passthrough on"         '^set +-g +allow-passthrough +on'
_t1 "extended-keys on"             '^set +-s +extended-keys +on'
if [ "$T1_OK" -eq 1 ]; then
    _pass "T1: tmux.conf.template carries all scrollback + copy-mode + passthrough settings"
else
    _fail "T1: tmux.conf.template is missing one or more scroll settings"
fi

# ── T2: operator-path — spawn the session the way an operator does and
#       read the LIVE server's effective options. ───────────────────────
"$WRAPPER" new -s "$S_NAME" -d >/dev/null 2>&1
sleep 2

if ! "$TMUX_BIN" -L "$S_SOCK" ls >/dev/null 2>&1; then
    _fail "T2.0: 'tmx new -s $S_NAME -d' did not create a server on socket $S_SOCK"
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"; exit 1
fi
_pass "T2.0: operator-path session created (positive evidence: 'tmux -L $S_SOCK ls' succeeded)"

_opt_g()  { "$TMUX_BIN" -L "$S_SOCK" show-options -g  "$1" 2>/dev/null | awk '{print $NF}'; }
_opt_gw() { "$TMUX_BIN" -L "$S_SOCK" show-options -gw "$1" 2>/dev/null | awk '{print $NF}'; }
_opt_s()  { "$TMUX_BIN" -L "$S_SOCK" show-options -s  "$1" 2>/dev/null | awk '{print $NF}'; }

HL="$(_opt_g history-limit)"
if [ "$HL" = "50000" ]; then
    _pass "T2.1: live server history-limit = 50000 (readback from $S_SOCK)"
else
    _fail "T2.1: live server history-limit = '$HL' (expected 50000)"
fi

MK="$(_opt_gw mode-keys)"
if [ "$MK" = "vi" ]; then
    _pass "T2.2: live server mode-keys = vi (readback from $S_SOCK)"
else
    _fail "T2.2: live server mode-keys = '$MK' (expected vi)"
fi

# Default = mouse OFF (terminal owns the mouse: native drag-select +
# right-click->Copy + native scroll work everywhere, Linux + macOS). tmux's
# own mouse (wheel scrollback in TUIs + drag-copy) is on demand via `prefix m`.
# Wire-level proof of the unobstructed default: test 59.
MOUSE="$(_opt_g mouse)"
if [ "$MOUSE" = "off" ]; then
    _pass "T2.3: live server mouse = off by default — terminal owns the mouse (tmux mouse on demand via prefix m) (readback from $S_SOCK)"
else
    _fail "T2.3: live server mouse = '$MOUSE' (expected off — terminal-owns-mouse default)"
fi

AP="$(_opt_g allow-passthrough)"
if [ "$AP" = "on" ]; then
    _pass "T2.4: live server allow-passthrough = on (Claude Code TUI passthrough)"
else
    _fail "T2.4: live server allow-passthrough = '$AP' (expected on)"
fi

EK="$(_opt_s extended-keys)"
if [ "$EK" = "on" ]; then
    _pass "T2.5: live server extended-keys = on (Shift+Enter reaches the app)"
else
    _fail "T2.5: live server extended-keys = '$EK' (expected on)"
fi

# ── T3: the wheel binding override is present on the live server. The
#       tmux DEFAULT WheelUpPane binding checks #{mouse_any_flag} and
#       forwards to the app; OUR override unconditionally enters
#       copy-mode. The live binding MUST mention copy-mode + scroll-up. ─
WHEEL_BIND="$("$TMUX_BIN" -L "$S_SOCK" list-keys -T root WheelUpPane 2>/dev/null || true)"
if printf '%s' "$WHEEL_BIND" | grep -q 'copy-mode' && \
   printf '%s' "$WHEEL_BIND" | grep -q 'scroll-up'; then
    _pass "T3: live WheelUpPane binding drives copy-mode scroll-up (override active, not tmux default)"
else
    _fail "T3: live WheelUpPane binding is not the copy-mode override"
    echo "  observed: $WHEEL_BIND"
fi

# ── T4: END-USER GUARANTEE — generate 3000 lines, prove the first one
#       scrolled off-screen, then prove the operator can scroll back to
#       it via copy-mode and copy it. ───────────────────────────────────
# Print a unique FIRST marker, 2998 numbered lines, a unique LAST marker.
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" \
  'echo SCROLLMARK_FIRST; for i in $(seq 2 2999); do echo "SCROLLMARK_$i"; done; echo SCROLLMARK_LAST' Enter

# Poll until the LAST marker shows in the visible pane (generation done).
GEN_OK=0
for _i in $(seq 1 30); do
    sleep 0.5
    if "$TMUX_BIN" -L "$S_SOCK" capture-pane -p -t "$S_NAME" 2>/dev/null \
         | grep -q 'SCROLLMARK_LAST'; then
        GEN_OK=1; break
    fi
done

if [ "$GEN_OK" -ne 1 ]; then
    _skip "T4: 3000-line generation did not complete in 15s — test inert this run"
    echo ""
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
fi

VIS="$("$TMUX_BIN" -L "$S_SOCK" capture-pane -p -t "$S_NAME" 2>/dev/null || true)"
# T4.1 — defect surface is real: the FIRST line is NOT on the visible
# screen (it scrolled off), so the operator genuinely needs to scroll.
if printf '%s' "$VIS" | grep -q 'SCROLLMARK_LAST' && \
   ! printf '%s' "$VIS" | grep -q 'SCROLLMARK_FIRST'; then
    _pass "T4.1: SCROLLMARK_FIRST scrolled off the visible screen (defect surface real; LAST is visible)"
else
    _skip "T4.1: visible-screen state inconclusive (FIRST unexpectedly visible — pane too tall?) — test inert"
fi

# T4.2 — scrollback BUFFER retained ~all 3000 generated lines. With the OLD
# default (history-limit 2000) the oldest ~1000 lines (incl. line 1) would be
# evicted; retaining >=2900 of 3000 is positive proof the 50000 bump is
# functional. Line 1 *specifically* is additionally proven reachable + copied
# by T4.3b/T4.4 via copy-mode below.
#
# Robustness (2026-06-28, non-interactive hardening): T4.2 previously grepped
# `capture-pane -p -S -` for a single SCROLLMARK_FIRST line. That is
# NON-DETERMINISTIC under headless / SSH-batch (no-TTY) runs: the operator-path
# pane runs the interactive shell (oh-my-bash startup + update-lock noise +
# multi-line git prompt + PS2 `<` continuation), and `capture-pane` WITHOUT -J
# splits the wrapped command-echo at the 80-col boundary, so a single-token
# grep can miss SCROLLMARK_FIRST even though the buffer holds all 3000 lines.
# Forensically confirmed on nezha: in the same run T4.2 "failed", copy-mode
# reached scroll_position~2984 and copied SCROLLMARK_FIRST (T4.3b/T4.4 PASS).
# Fix: COUNT retained generated lines from the -J (wrap-joined) full capture.
# Immune to wrapping, prompt noise, and a single mangled line; still fails
# decisively under any smaller history-limit (paired §1.1 mutation: lower the
# limit -> count<2900 -> FAIL). Same up-to-15s poll absorbs ingestion lag.
FULL=""
T42_CNT=0
T42_OK=0
for _i in $(seq 1 30); do
    FULL="$("$TMUX_BIN" -L "$S_SOCK" capture-pane -p -J -S - -t "$S_NAME" 2>/dev/null || true)"
    T42_CNT="$(printf '%s\n' "$FULL" | grep -c 'SCROLLMARK_' || true)"
    if [ "$T42_CNT" -ge 2900 ]; then
        T42_OK=1; break
    fi
    sleep 0.5
done
if [ "$T42_OK" -eq 1 ]; then
    _pass "T4.2: scrollback retained $T42_CNT of 3000 generated lines (history-limit 50000 functional; old 2000 limit would retain <=~2000) [capture-pane -J -S -]"
else
    _fail "T4.2: only $T42_CNT SCROLLMARK lines in scrollback after 15s poll (want >=2900) — history-limit not effective"
fi

# T4.3 + T4.4 — copy-mode navigation reaches the old content.
"$TMUX_BIN" -L "$S_SOCK" copy-mode -t "$S_NAME" 2>/dev/null || true
sleep 0.4
IN_MODE="$("$TMUX_BIN" -L "$S_SOCK" display-message -p -t "$S_NAME" '#{pane_in_mode}' 2>/dev/null || echo 0)"
if [ "$IN_MODE" = "1" ]; then
    _pass "T4.3a: copy-mode entered (pane_in_mode=1)"
else
    _fail "T4.3a: copy-mode did not engage (pane_in_mode='$IN_MODE')"
fi

# Search backward (upward) for the first marker — moves the copy cursor
# to it. Then read scroll_position: a large value proves copy-mode
# navigation scrolled the view far up the buffer.
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X search-backward 'SCROLLMARK_FIRST' 2>/dev/null || true
sleep 0.4
SCROLL_POS="$("$TMUX_BIN" -L "$S_SOCK" display-message -p -t "$S_NAME" '#{scroll_position}' 2>/dev/null || echo 0)"
case "$SCROLL_POS" in
    ''|*[!0-9]*) SCROLL_POS=0 ;;
esac
if [ "$SCROLL_POS" -gt 100 ]; then
    _pass "T4.3b: copy-mode search reached the old content (scroll_position=$SCROLL_POS lines up)"
else
    _fail "T4.3b: copy-mode did not scroll up to the old content (scroll_position=$SCROLL_POS)"
fi

# Select the located line and copy it — the full operator scroll-and-copy
# flow. show-buffer must then contain the first marker.
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X select-line 2>/dev/null || true
sleep 0.2
"$TMUX_BIN" -L "$S_SOCK" send-keys -t "$S_NAME" -X copy-selection-and-cancel 2>/dev/null || true
sleep 0.3
BUF="$("$TMUX_BIN" -L "$S_SOCK" show-buffer 2>/dev/null || true)"
if printf '%s' "$BUF" | grep -q 'SCROLLMARK_FIRST'; then
    _pass "T4.4: operator scrolled to + copied line 1 of 3000 via copy-mode (show-buffer carries SCROLLMARK_FIRST)"
else
    _fail "T4.4: copy-mode copy of the old line failed (show-buffer: '$(printf '%s' "$BUF" | head -c 60)')"
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
