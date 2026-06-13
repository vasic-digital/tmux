#!/bin/sh
# diagnose.sh — HelixCode tmx-session crash, operator-side forensic capture
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    Capture, READ-ONLY, everything needed to localise the crash the
#             operator hits when opening / selecting the `HelixCode` tmx
#             session (crashes iTerm2, Terminal.app, a Linux terminal, and
#             WezTerm). Headless investigation (docs/qa/2026-06-13-helixcode-
#             crash/forensic.md) DISPROVED H1-H5 in a synthetic session; the
#             surviving candidates require the operator's REAL runtime state.
#             This script records that state without modifying or killing any
#             live session.
#
# Usage:      sh docs/qa/2026-06-13-helixcode-crash/diagnose.sh HelixCode
#               (run from the repo root; arg = the crashing session name,
#                default "HelixCode")
#             Then, when the printed instruction tells you to, open a NEW
#             terminal and reproduce the crash UNDER `script` so the raw
#             attach byte stream is captured even though the terminal dies.
#
# Inputs:     $1 = session name (default HelixCode). Env: TMX_BIN to override
#             the tmux binary path; otherwise auto-detected.
# Outputs:    A timestamped directory docs/qa/2026-06-13-helixcode-crash/
#             operator_run_<ts>/ containing:
#               env.txt            — tmux -V, $TERM, $SHELL, uname, tput size
#               conf_active.txt    — the conf actually loaded + its sha
#               sockets.txt        — every tmx-* socket + which has a live server
#               session_state.txt  — pane_current_command, options, features
#               server_show.txt    — show -g allow-passthrough/extended-keys/...
#               attach_stream.bin  — (operator step) RAW bytes during the crash
#               typescript         — (operator step) `script` log of the crash
#             The script PRINTS exactly what to copy back.
# Side-effects: Creates the output dir. Runs ONLY read-only tmux queries
#             (-V, ls, has-session, display-message -p, show -g/-s). NEVER
#             kills, source-files, sets, or attaches a live session.
# Dependencies: sh (POSIX), the locally-built or system tmux, `script`
#             (BSD or util-linux), shasum/sha256sum (optional).
# Cross-refs: docs/qa/2026-06-13-helixcode-crash/forensic.md (H1-H5 verdicts);
#             scripts/tmx.template attach verb (the source-file+attach path);
#             scripts/tmux.conf.template (allow-passthrough/extended-keys).
# Last verified: 2026-06-13
# ─────────────────────────────────────────────────────────────────────────
set -u

SESSION="${1:-HelixCode}"

# Resolve the repo root from this script's location (works from anywhere).
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../../.." && pwd)
CONF="$REPO_ROOT/scripts/tmux.conf.template"

# Locate the SAME tmux the wrapper would use; allow override.
BIN="${TMX_BIN:-}"
if [ -z "$BIN" ]; then
    for cand in \
        "$REPO_ROOT/tmux/build-darwin/bin/tmux" \
        "$REPO_ROOT/tmux/build-linux/bin/tmux" \
        "$REPO_ROOT/tmux/build/bin/tmux"; do
        [ -x "$cand" ] && BIN="$cand" && break
    done
fi
[ -z "$BIN" ] && BIN=$(command -v tmux 2>/dev/null || true)
if [ -z "$BIN" ]; then
    echo "diagnose: no tmux binary found (set TMX_BIN=/path/to/tmux)" >&2
    exit 1
fi

# Sanitise the session name into the wrapper's socket label the SAME way
# scripts/tmx does (_sanitise: tr -c 'A-Za-z0-9._-' '_').
SAFE=$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9._-' '_')
SOCK="tmx-$SAFE"

TS=$(date +%Y%m%d-%H%M%S)
OUT="$SELF_DIR/operator_run_$TS"
mkdir -p "$OUT"

_sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null
    else echo "(no sha tool)"; fi
}

# ── 1. environment ────────────────────────────────────────────────────
{
    echo "session-name: $SESSION"
    echo "socket-label: $SOCK"
    echo "tmux-binary:  $BIN"
    echo "tmux-version: $("$BIN" -V 2>&1)"
    echo "which-tmux-on-PATH: $(command -v tmux 2>/dev/null || echo none)"
    echo "version-on-PATH:    $(tmux -V 2>/dev/null || echo none)"
    echo "TERM=${TERM:-unset}"
    echo "SHELL=${SHELL:-unset}"
    echo "uname: $(uname -a)"
    echo "tput cols/lines: $(tput cols 2>/dev/null)/$(tput lines 2>/dev/null)"
} > "$OUT/env.txt" 2>&1

# ── 2. active config ──────────────────────────────────────────────────
{
    echo "conf-path: $CONF"
    echo "conf-sha:  $(_sha "$CONF")"
    echo "--- allow-passthrough / extended-keys / terminal-features lines ---"
    grep -n -e allow-passthrough -e extended-keys -e terminal-features \
            -e automatic-rename-format "$CONF" 2>/dev/null
} > "$OUT/conf_active.txt" 2>&1

# ── 3. socket inventory (which tmx-* sockets exist, which are live) ────
{
    for rt in "${TMUX_TMPDIR:-}/tmux-$(id -u)" "/tmp/tmux-$(id -u)"; do
        [ -d "$rt" ] || continue
        echo "--- runtime dir: $rt ---"
        for s in "$rt"/tmx-*; do
            [ -e "$s" ] || continue
            label=$(basename "$s")
            if "$BIN" -L "$label" has-session 2>/dev/null; then
                live="LIVE"
            else
                live="dead-socket-file"
            fi
            echo "$label  [$live]  $(ls -l "$s" 2>/dev/null)"
        done
    done
} > "$OUT/sockets.txt" 2>&1

# ── 4. target session state (read-only) ───────────────────────────────
{
    if "$BIN" -L "$SOCK" has-session 2>/dev/null; then
        echo "session '$SESSION' is LIVE on socket $SOCK"
        echo "server-pid: $("$BIN" -L "$SOCK" display-message -p '#{pid}' 2>/dev/null)"
        echo "--- panes (cmd / title / size / in_mode / mouse_any_flag) ---"
        "$BIN" -L "$SOCK" list-panes -a -F \
          'win=#{window_index} pane=#{pane_index} cmd=[#{pane_current_command}] title=[#{pane_title}] #{pane_width}x#{pane_height} in_mode=#{pane_in_mode} mouse_any=#{mouse_any_flag}' \
          2>/dev/null
        echo "--- window names ---"
        "$BIN" -L "$SOCK" list-windows -a -F 'win=#{window_index} name=[#{window_name}]' 2>/dev/null
        echo "--- automatic-rename-format expansion right now ---"
        "$BIN" -L "$SOCK" display-message -p '#{s/\.exe$//:pane_current_command}' 2>/dev/null
    else
        echo "session '$SESSION' is NOT live on socket $SOCK"
        echo "(it may have already crashed/exited, or uses a different socket — see sockets.txt)"
    fi
} > "$OUT/session_state.txt" 2>&1

# ── 5. server options most relevant to the crash (read-only show) ─────
{
    if "$BIN" -L "$SOCK" has-session 2>/dev/null; then
        for opt in allow-passthrough extended-keys default-terminal \
                   set-clipboard mouse; do
            echo "-g $opt: $("$BIN" -L "$SOCK" show -g "$opt" 2>/dev/null)"
        done
        echo "-s extended-keys: $("$BIN" -L "$SOCK" show -s extended-keys 2>/dev/null)"
        echo "--- terminal-features ---"
        "$BIN" -L "$SOCK" show -g terminal-features 2>/dev/null
        "$BIN" -L "$SOCK" show -As terminal-features 2>/dev/null
        echo "--- terminal-overrides ---"
        "$BIN" -L "$SOCK" show -g terminal-overrides 2>/dev/null
    else
        echo "(session not live — cannot show server options)"
    fi
} > "$OUT/server_show.txt" 2>&1

# ── report + operator step ────────────────────────────────────────────
echo "diagnose: read-only state captured under:"
echo "  $OUT"
echo
echo "Files: env.txt conf_active.txt sockets.txt session_state.txt server_show.txt"
echo
echo "NOW capture the actual crash (this is the load-bearing artifact)."
echo "Open a NEW terminal window and run EXACTLY this one line — it records"
echo "the raw byte stream + a full typescript while you reproduce the crash"
echo "(the terminal may die; the capture survives because it is written to a"
echo "file by 'script' running OUTSIDE the doomed tmux client):"
echo
echo "  ──────────────────────────────────────────────────────────────────"
if [ "$(uname -s)" = "Darwin" ]; then
echo "  script -q \"$OUT/typescript\" sh -c '$REPO_ROOT/scripts/tmx attach -t $SESSION; true'"
else
echo "  script -q -c '$REPO_ROOT/scripts/tmx attach -t $SESSION || true' \"$OUT/typescript\""
fi
echo "  ──────────────────────────────────────────────────────────────────"
echo
echo "When it crashes: reopen any working terminal and send back the WHOLE"
echo "directory $OUT (it now also contains 'typescript' with the raw crash"
echo "bytes). To inspect the malformed/runaway sequence locally first:"
echo "  od -c \"$OUT/typescript\" | tail -40"
echo
echo "Safety: this script and the line above are READ-ONLY on your sessions —"
echo "they never kill, reconfigure, or source-file a live session."
