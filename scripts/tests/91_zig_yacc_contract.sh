#!/usr/bin/env bash
# 91_zig_yacc_contract.sh — build_native.sh's zig-path YACC value must satisfy
# BOTH real contracts it is fed into: tmux/configure's AC_CHECK_PROG resolution
# and tmux/etc/ylwrap's output-filename contract.
#
# ─── §11.4.18 documentation block ────────────────────────────────────────────
# Root cause (TMX-088, caught by independent review 2026-09-01, never shipped
# working): the zig path computed YACC via `command -v bison`, yielding an
# ABSOLUTE path. Two independent breakages, both measured:
#   1. tmux/configure's AC_CHECK_PROG does `set dummy $YACC; ac_word=$2` then
#      tests "$as_dir$ac_word" -- concatenating a PATH entry with a value that
#      already starts with '/'. "/usr/bin//usr/bin/bison" is never executable,
#      so configure aborts `"yacc not found"` ON A HOST THAT HAS BISON.
#   2. tmux/Makefile.in's .y.c rule drives etc/ylwrap, which requires the
#      program to emit y.tab.c. Plain `bison` emits cmd-parse.tab.c and ylwrap
#      still EXITS 0 -- a silent failure leaving make with no cmd-parse.c.
# `bison -y` satisfies both. cmd-parse.c is gitignored AND in CLEANFILES, so the
# broken branch is the one a fresh clone always takes.
#
# ─── RED_MODE POLARITY (§11.4.115) ───────────────────────────────────────────
# RED_MODE=1  feed the PRE-FIX value (absolute path) to both real contracts and
#             assert they BREAK -- proves the defect was real and this test sees it.
# RED_MODE=0  (default) feed the value build_native.sh ACTUALLY computes and
#             assert both contracts hold.
#
# Usage:   bash scripts/tests/91_zig_yacc_contract.sh   [RED_MODE=1]
# Deps:    bash, sed, tmux submodule (etc/ylwrap, cmd-parse.y), bison or yacc
# Cross-refs: scripts/build_native.sh (zig path), mutation M-ZIG-YACC-BARE-WORD
# Last verified: 2026-09-01
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"; REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
RED_MODE="${RED_MODE:-0}"
PASS=0; FAIL=0; SKIP=0
_pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }
_fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip(){ echo "SKIP: $*"; SKIP=$((SKIP+1)); }
_summary(){ echo "  -- Test 91 result: PASS=$PASS FAIL=$FAIL SKIP=$SKIP --"; }
echo "-- Test 91: zig-path YACC satisfies configure + ylwrap contracts (RED_MODE=$RED_MODE) --"

command -v bison >/dev/null 2>&1 || command -v yacc >/dev/null 2>&1 || {
    _skip "neither bison nor yacc on PATH — cannot exercise the yacc contracts (§11.4.3)"; _summary; exit 0; }
YLWRAP="$REPO_ROOT/tmux/etc/ylwrap"; SRCY="$REPO_ROOT/tmux/cmd-parse.y"
[ -f "$YLWRAP" ] && [ -f "$SRCY" ] || { _skip "tmux/etc/ylwrap or cmd-parse.y absent (§11.4.3)"; _summary; exit 0; }

# The value under test: what build_native.sh's zig branch actually computes.
if [ "$RED_MODE" = "1" ]; then
    UNDER_TEST="$(command -v bison 2>/dev/null || command -v yacc 2>/dev/null)"   # pre-fix shape
else
    # ATTRIBUTABILITY (§11.4.201(6)): DERIVE the value from the file under test,
    # never recompute it independently here. If this test computed 'bison -y' on
    # its own, mutating build_native.sh would not change what C1/C2 examine and
    # the guards would pass on broken source -- the exact false-null this project
    # has been bitten by. Extract the zig-branch assignment and expand it the way
    # the script would, so a mutation of that line is what C1/C2 actually test.
    # The assignment sits mid-line after a `then`, so match ZYACC=" anywhere.
    # Skip the ZYACC="true" pre-set (the cmd-parse.c-present branch) and the
    # empty else-arm; we want the bison/yacc branch the fresh-clone path takes.
    RAW="$(sed -n 's/.*ZYACC="\([^"]*\)".*/\1/p' "$REPO_ROOT/scripts/build_native.sh" \
           | grep -vx 'true' | grep -vx '' | head -1)"
    if [ -z "$RAW" ]; then
        _fail "0 could not extract the zig-path ZYACC assignment from build_native.sh"
        UNDER_TEST=""
    else
        UNDER_TEST="$(eval printf '%s' "\"$RAW\"")"
        echo "  derived from build_native.sh: ZYACC=[$UNDER_TEST]"
    fi
fi
[ -n "${UNDER_TEST:-}" ] || { _summary; [ "$FAIL" -eq 0 ]; exit $?; }

# C1 — tmux/configure's AC_CHECK_PROG resolution (verbatim logic).
set dummy $UNDER_TEST; ac_word=$2; found=no
IFS=:; for d in $PATH; do [ -z "$d" ] && d=.; [ -x "$d/$ac_word" ] && { found=yes; break; }; done; unset IFS
if [ "$RED_MODE" = "1" ]; then
    [ "$found" = "no" ] && _pass "C1 RED: pre-fix absolute path '$ac_word' fails AC_CHECK_PROG — defect reproduced" \
                        || _fail "C1 RED — pre-fix value resolved; defect NOT reproduced (test stale)"
else
    [ "$found" = "yes" ] && _pass "C1 configure's AC_CHECK_PROG resolves '$ac_word'" \
                         || _fail "C1 configure would abort 'yacc not found' for '$ac_word'"
fi

# C2 — etc/ylwrap must emit cmd-parse.c (not cmd-parse.tab.c). It exits 0 either way.
W="${TMPDIR:-/tmp}/tmx_t91_$$"; mkdir -p "$W" || { _skip "C2 scratch not writable (§11.4.3)"; _summary; exit 0; }
trap 'rm -rf "$W" 2>/dev/null || true' EXIT
cp "$SRCY" "$W/" && ( cd "$W" && sh "$YLWRAP" cmd-parse.y y.tab.c cmd-parse.c y.tab.h cmd-parse.h -- $UNDER_TEST >/dev/null 2>&1 )
if [ "$RED_MODE" = "1" ]; then
    [ -f "$W/cmd-parse.c" ] && _fail "C2 RED — pre-fix value produced cmd-parse.c; defect NOT reproduced" \
                            || _pass "C2 RED: pre-fix value left cmd-parse.c MISSING while ylwrap exited 0 — silent failure reproduced"
else
    [ -f "$W/cmd-parse.c" ] && _pass "C2 ylwrap emitted cmd-parse.c — make has a parser source" \
                            || _fail "C2 ylwrap did NOT emit cmd-parse.c (silent failure); make would have no parser source"
fi
_summary
[ "$FAIL" -eq 0 ]
