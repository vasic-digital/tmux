#!/usr/bin/env bash
# Test 64 — pure-fn unit tests for the session-color bash lib.
# No tmux / no wrapper needed; sources the lib directly.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/tmx-color-lib.sh"

echo "── Test 64: session-color pure-fn unit tests ──"
PASS=0; FAIL=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

[ -f "$LIB" ] || { echo "FAIL: lib missing: $LIB"; exit 1; }
# shellcheck disable=SC1090
source "$LIB"

# --- _parse_session_value table (matches spec §4) ---
chk_parse() { # chk_parse <input> <want_name> <want_color>
    _parse_session_value "$1"
    if [ "$PARSED_NAME" = "$2" ] && [ "$PARSED_COLOR" = "$3" ]; then
        _pass "parse '$1' → name='$2' color='$3'"
    else
        _fail "parse '$1' → name='$PARSED_NAME' color='$PARSED_COLOR' (want '$2'/'$3')"
    fi
}
chk_parse "work"             "work"  ""
chk_parse "work:red"         "work"  "red"
chk_parse "deploy:#3b82f6"   "deploy" "#3b82f6"
chk_parse 'a\:b:cyan'       "a:b"   "cyan"
chk_parse "work:red:x:y"     "work"  "red"
chk_parse "work:"            "work"  ""

# --- _color_valid table ---
chk_cv() { # chk_cv <token> <want 0|1>  (0=valid, 1=invalid)
    if _color_valid "$1"; then _color_ok=0; else _color_ok=1; fi
    if [ "$_color_ok" = "$2" ]; then _pass "valid '$1' → $2"
    else _fail "valid '$1' → $_color_ok (want $2)"; fi
}
chk_cv "red"        0
chk_cv "RED"        0
chk_cv "colour160"  0
chk_cv "color39"    0
chk_cv "#3b82f6"    0
chk_cv "#f0a"       0
chk_cv "purple"     1
chk_cv "colour256"  1
chk_cv "#12"        1
chk_cv ""           1

# --- bash↔Go list parity (mirrors Go TestCanonColorNamesBashTwin) ---
WANT="red green yellow blue magenta cyan white black brightred brightgreen brightyellow brightblue brightmagenta brightcyan brightwhite default terminal"
if [ "$CANON_COLOR_NAMES" = "$WANT" ]; then
    _pass "bash CANON_COLOR_NAMES matches Go twin"
else
    _fail "bash CANON_COLOR_NAMES drift: '$CANON_COLOR_NAMES'"
fi

echo "── Test 64 result: PASS=$PASS FAIL=$FAIL ──"
[ "$FAIL" -eq 0 ]
