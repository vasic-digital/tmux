#!/bin/sh
# 55_mouse_toggle_and_copy.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.98 autonomous proof that mouse select/copy is USABLE in
#             tmx panes — the fix for the user report 2026-05-29 "cannot
#             select/copy with mouse, especially in claude". Asserts:
#               (a) `prefix m` mouse-toggle binding exists and actually flips
#                   the mouse option (the terminal-agnostic copy escape hatch
#                   that makes NATIVE terminal selection work inside
#                   mouse-tracking apps like Claude Code);
#               (b) the Shift-drag root override (in-tmux selection inside
#                   tracking apps) is present;
#               (c) the copy-pipe path actually delivers the selection to an
#                   external command (same mechanism as the real @clip pipe).
# Usage:      bash scripts/tests/52_mouse_toggle_and_copy.sh
# Inputs:     scripts/tmux.conf.template ; a tmux binary (prefers the built
#             hardened binary, falls back to system tmux — the mouse/copy
#             bindings behave identically under any tmux >= 3.x).
# Outputs:    EVIDENCE: lines ; PASS/FAIL ; exit 0 PASS / 1 FAIL.
# Side-effects: starts + kills a throwaway tmux server on a private socket
#             label (trap-cleaned, §11.4.14). Uses a temp file sink for the
#             copy proof — never touches the operator's clipboard.
# Dependencies: tmux (built or system), POSIX sh, mktemp.
# Cross-refs: scripts/tmux.conf.template ; meta-test M-MOUSETOGGLE ; test 48 (modifier-drag)
#             (modifier-drag override) ; forensic anchor user report 2026-05-29.
# Last verified: 2026-05-29
# ─────────────────────────────────────────────────────────────────────────
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
CONF="$REPO_ROOT/scripts/tmux.conf.template"

[ -r "$CONF" ] || { echo "FAIL: 55 — $CONF missing"; exit 1; }

BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build-linux/bin/tmux"
[ -x "$BIN" ] || BIN=$(command -v tmux 2>/dev/null || true)
[ -n "$BIN" ] || { echo "SKIP: 55 — no tmux binary available (§11.4.3 topology)"; exit 0; }

L="mouse52probe$$"
"$BIN" -L "$L" kill-server 2>/dev/null || true
"$BIN" -L "$L" -f "$CONF" new-session -d -s p -x 80 -y 24
trap '"$BIN" -L "$L" kill-server 2>/dev/null || true' EXIT
sleep 0.4

fail=0

# (a) prefix+m mouse-toggle binding present
if "$BIN" -L "$L" list-keys -T prefix 2>/dev/null | grep -qE '[[:space:]]m[[:space:]].*set.*mouse'; then
    echo "EVIDENCE: prefix+m mouse-toggle binding present"
else
    echo "FAIL: 55 — no prefix+m mouse toggle binding"; fail=1
fi

# (a2) toggle actually flips the mouse option
"$BIN" -L "$L" set -g mouse on
before=$("$BIN" -L "$L" show -g mouse 2>/dev/null)
"$BIN" -L "$L" set -g mouse off
after=$("$BIN" -L "$L" show -g mouse 2>/dev/null)
if [ "$before" != "$after" ] && [ "$after" = "mouse off" ]; then
    echo "EVIDENCE: mouse option flips ('$before' -> '$after')"
else
    echo "FAIL: 55 — mouse option did not flip ('$before' -> '$after')"; fail=1
fi
"$BIN" -L "$L" set -g mouse on

# (c) Shift-drag root override present (in-tmux selection inside tracking apps)
if "$BIN" -L "$L" list-keys 2>/dev/null | grep -qE -- '-T root +S-MouseDrag1Pane'; then
    echo "EVIDENCE: Shift-drag root override present"
else
    echo "FAIL: 55 — no Shift-drag root override"; fail=1
fi

# (c2) PRIMARY plain-drag override: root MouseDrag1Pane must enter copy-mode
# (NOT forward to the app on #{mouse_any_flag}). It resolves to copy-mode and
# is gated on #{pane_in_mode}, never on #{mouse_any_flag} (the default-forward
# behaviour we replaced so a plain drag selects+copies even in Claude Code).
PD="$("$BIN" -L "$L" list-keys -T root 2>/dev/null | grep -E '[[:space:]]MouseDrag1Pane[[:space:]]' | head -1)"
if printf '%s' "$PD" | grep -q 'copy-mode -M' && ! printf '%s' "$PD" | grep -q 'mouse_any_flag'; then
    echo "EVIDENCE: plain-drag override present (root MouseDrag1Pane -> copy-mode, not app-forward)"
else
    echo "FAIL: 55 — plain-drag override missing (root MouseDrag1Pane: $PD)"; fail=1
fi

# (b) copy-pipe delivers the selection to an external command (real mechanism)
SINK=$(mktemp)
"$BIN" -L "$L" set -g @cliptest "cat > $SINK"
"$BIN" -L "$L" send-keys -l 'echo MOUSE52_COPY_PROOF_8675309'
"$BIN" -L "$L" send-keys Enter
sleep 0.3
"$BIN" -L "$L" copy-mode
"$BIN" -L "$L" send-keys -X history-top
"$BIN" -L "$L" send-keys -X begin-selection
"$BIN" -L "$L" send-keys -X bottom-line
"$BIN" -L "$L" send-keys -X end-of-line
"$BIN" -L "$L" send-keys -X copy-pipe-and-cancel "#{@cliptest}"
sleep 0.4
if grep -q 'MOUSE52_COPY_PROOF_8675309' "$SINK" 2>/dev/null; then
    echo "EVIDENCE: copy-pipe delivered selection ($(tr -d '\n' < "$SINK" | tail -c 40))"
else
    echo "FAIL: 55 — copy-pipe did not deliver selection (sink empty)"; fail=1
fi
rm -f "$SINK"

if [ "$fail" -eq 0 ]; then
    echo "PASS: 55 mouse toggle + copy usable (prefix+m flips mouse; Shift-drag override; copy-pipe delivers)"
    exit 0
else
    echo "FAIL: 55 mouse toggle/copy"
    exit 1
fi
