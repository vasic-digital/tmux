#!/usr/bin/env bash
# Test 63 — per-session color (operator-path, anti-bluff).
#
# §102: drives the SAME entry point an end user invokes — `tmx new -s …`.
# §11.4.2/§11.4.5: every PASS reads LIVE server state via show-options
# (status-style / pane-active-border-style / clock-mode-colour /
# window-status-current-style), never an exit code alone.
# Covers spec §9 table T1..T8.
set -uo pipefail
# §11.4.3/D2 TMPDIR-HARDCODE-001: route scratch through ${TMPDIR:-/tmp}.
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 63: scratch root $SCRATCH not writable — §11.4.3"
    rm -rf "$_wtest" 2>/dev/null || true; exit 77
fi
rmdir "$_wtest" 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"

echo "── Test 63: per-session color (operator-path) ──"
PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

if [ ! -x "$TMUX_BIN" ]; then _skip "tmux binary not built"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$STATE_BIN" ];  then _skip "tmx-state-bin not built"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$WRAPPER" ];    then _skip "scripts/tmx wrapper not generated (run setup.sh)"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi

# Isolated state file per run so persisted-color tests don't leak.
export TMX_STATE_FILE="$SCRATCH/tmx_t63_state.$$"
CLEAN=()
trap 'rm -f "$TMX_STATE_FILE"; for s in "${CLEAN[@]}"; do "$WRAPPER" kill-session -t "$s" 2>/dev/null || true; "$TMUX_BIN" -L "tmx-$s" kill-server 2>/dev/null || true; done' EXIT

# Helper: read a live global option value from a session's server.
_get_opt() { "$TMUX_BIN" -L "tmx-$1" show-options -gv "$2" 2>/dev/null; }

# T1: name:color (named) → status-style bg=red
N="t63w1"; CLEAN+=("$N")
"$WRAPPER" new -s "$N:red" -d >/dev/null 2>&1
[ "$(_get_opt "$N" status-style)" = "bg=red" ] && _pass "T1 name:red → bg=red" || _fail "T1 status-style='$(_get_opt "$N" status-style)'"

# T2: name:#hex → status-style bg=#3b82f6
N="t63w2"; CLEAN+=("$N")
"$WRAPPER" new -s "$N:#3b82f6" -d >/dev/null 2>&1
[ "$(_get_opt "$N" status-style)" = "bg=#3b82f6" ] && _pass "T2 name:#hex → bg=#3b82f6" || _fail "T2 status-style='$(_get_opt "$N" status-style)'"

# T3: all 4 surfaces reflect the color
N="t63w3"; CLEAN+=("$N")
"$WRAPPER" new -s "$N:blue" -d >/dev/null 2>&1
ok=1
[ "$(_get_opt "$N" status-style)"             = "bg=blue" ] || ok=0
[ "$(_get_opt "$N" pane-active-border-style)" = "fg=blue" ] || ok=0
[ "$(_get_opt "$N" clock-mode-colour)"        = "blue" ]    || ok=0
case "$(_get_opt "$N" window-status-current-style)" in bg=blue,fg=black) ;; *) ok=0;; esac
[ "$ok" = 1 ] && _pass "T3 all-4-surfaces blue" || _fail "T3 surfaces mismatch"

# T4: persistence — set, kill, bare re-run reuses color
N="t63w4"; CLEAN+=("$N")
"$WRAPPER" new -s "$N:magenta" -d >/dev/null 2>&1
"$WRAPPER" kill-session -t "$N" 2>/dev/null || true
"$TMUX_BIN" -L "tmx-$N" kill-server 2>/dev/null || true
"$WRAPPER" new -s "$N" -d >/dev/null 2>&1   # BARE name
[ "$(_get_opt "$N" status-style)" = "bg=magenta" ] && _pass "T4 persisted color wins on bare re-run" || _fail "T4 status-style='$(_get_opt "$N" status-style)'"

# T5: invalid color → non-zero exit AND no socket created
N="t63w5"
if "$WRAPPER" new -s "$N:notacolor" -d >/dev/null 2>&1; then
    _fail "T5 invalid color accepted"
else
    if "$TMUX_BIN" -L "tmx-$N" ls >/dev/null 2>&1; then
        _fail "T5 invalid color created a server anyway"; CLEAN+=("$N")
    else
        _pass "T5 invalid color rejected, no server created"
    fi
fi

# T6: escaped ':' in name → ':' is not a session-name character, so the
# name portion "t63w6:x" is sanitised to "t63w6x" and the colour applies.
# This reconciles the intentional safe-set change with the historical test.
SAFE="t63w6x"; CLEAN+=("$SAFE")
"$WRAPPER" new -s 't63w6\:x:cyan' -d >/dev/null 2>&1
[ "$(_get_opt "$SAFE" status-style)" = "bg=cyan" ] && _pass "T6 escaped colon → $SAFE bg=cyan" || _fail "T6 status-style='$(_get_opt "$SAFE" status-style)'"

# T7: extra fields ignored
N="t63w7"; CLEAN+=("$N")
"$WRAPPER" new -s "$N:green:x:y" -d >/dev/null 2>&1
[ "$(_get_opt "$N" status-style)" = "bg=green" ] && _pass "T7 extra fields ignored → bg=green" || _fail "T7 status-style='$(_get_opt "$N" status-style)'"

# T8: hostname fallback for a fresh name (no persisted color) — status-style
# equals what hostname_color.sh would produce. We assert it is a bg= token
# (the fallback path is intact + not empty).
N="t63w8"; CLEAN+=("$N")
TMX_HOSTNAME=t63fallback "$WRAPPER" new -s "$N" -d >/dev/null 2>&1
ss="$(_get_opt "$N" status-style)"
case "$ss" in bg=*) _pass "T8 hostname fallback → $ss" ;; *) _fail "T8 fallback status-style='$ss'" ;; esac

echo "── Test 63 result: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
