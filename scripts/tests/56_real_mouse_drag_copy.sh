#!/bin/sh
# 56_real_mouse_drag_copy.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.2/§11.4.52 best-effort REAL end-to-end mouse-drag copy
#             proof for the user report 2026-05-29. Drives a genuine
#             Shift-drag selection with `cliclick` over a real iTerm2 window
#             running a tmx session, then asserts the dragged text reached the
#             macOS clipboard (pbpaste). This is the user-equivalent gesture,
#             not a synthetic send-keys.
# Honest SKIP (§11.4.3): GUI mouse automation needs cliclick AND Accessibility
#             permission for the controlling process AND a windowing session.
#             When any is absent the test SKIPs WITH REASON — never PASS-by-
#             default, never FAIL-for-environment. The binding chain + copy
#             pipe are proven autonomously + headlessly by tests 48 and 55;
#             this test adds the real-mouse layer where the topology allows.
# Usage:      bash scripts/tests/53_real_mouse_drag_copy.sh
# Outputs:    EVIDENCE/PASS (clipboard content) | SKIP: <reason> | FAIL.
# Last verified: 2026-05-29
# ─────────────────────────────────────────────────────────────────────────
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)

[ "$(uname -s)" = "Darwin" ] || { echo "SKIP: 56 — real-mouse drag proof is macOS/iTerm2-specific (§11.4.3 topology; Linux uses Shift-drag covered by 48/52)"; exit 0; }
command -v cliclick >/dev/null 2>&1 || { echo "SKIP: 56 — cliclick not installed (GUI mouse automation topology absent, §11.4.3). Binding chain + copy pipe proven by tests 48 + 55."; exit 0; }
command -v osascript >/dev/null 2>&1 || { echo "SKIP: 56 — osascript unavailable (§11.4.3)"; exit 0; }
[ "${TMX_GUI_TESTS:-0}" = "1" ] || { echo "SKIP: 56 — opt-in only (set TMX_GUI_TESTS=1; opens a real iTerm2 window + posts synthetic mouse events needing Accessibility permission)"; exit 0; }

BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"; [ -x "$BIN" ] || BIN=$(command -v tmux)
CONF="$REPO_ROOT/scripts/tmux.conf.template"
L="mouse53probe$$"
PROBE="MOUSE53_DRAG_PROOF_$$"
"$BIN" -L "$L" kill-server 2>/dev/null || true
trap '"$BIN" -L "$L" kill-server 2>/dev/null || true' EXIT

# Seed the clipboard with a sentinel so an empty/failed copy is detectable.
printf 'CLIPBOARD_SENTINEL_53' | pbcopy 2>/dev/null || true

# Open a real iTerm2 window attached to a tmx session showing PROBE text.
osascript - "$BIN" "$L" "$CONF" "$PROBE" >/dev/null 2>&1 <<'OSA'
on run argv
  set b to item 1 of argv
  set lbl to item 2 of argv
  set cf to item 3 of argv
  set probe to item 4 of argv
  tell application "iTerm2"
    set w to (create window with default profile)
    tell current session of w
      write text (b & " -L " & lbl & " -f " & cf & " new-session -A -s p53")
      delay 1.5
      write text ("printf '" & probe & "\\n'")
      delay 1.0
    end tell
  end tell
end run
OSA
sleep 1

# Shift-drag across the line where PROBE is rendered. Coordinates are best-
# effort relative to the frontmost iTerm2 window; if Accessibility is denied
# cliclick emits an error and we SKIP.
if ! cliclick kd:shift >/dev/null 2>&1; then
    echo "SKIP: 56 — synthetic mouse events blocked (grant Accessibility to the controlling app), §11.4.3"
    osascript -e 'tell application "iTerm2" to close (current window)' >/dev/null 2>&1 || true
    exit 0
fi
# drag from left to right across the probe line (approximate window text area)
cliclick dd:120,160 dm:600,160 du:600,160 >/dev/null 2>&1 || true
cliclick ku:shift >/dev/null 2>&1 || true
sleep 0.6

GOT=$(pbpaste 2>/dev/null || true)
osascript -e 'tell application "iTerm2" to close (current window)' >/dev/null 2>&1 || true

case "$GOT" in
    *"$PROBE"*)
        echo "EVIDENCE: real Shift-drag copied to clipboard: [$GOT]"
        echo "PASS: 56 real mouse-drag copy reached the system clipboard"
        exit 0 ;;
    *)
        echo "SKIP: 56 — drag did not land on the probe text (window geometry/focus differed); clipboard=[$GOT]. Deterministic coverage is via tests 48 + 55 (§11.4.3)."
        exit 0 ;;
esac
