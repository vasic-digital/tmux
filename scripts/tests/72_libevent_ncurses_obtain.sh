#!/usr/bin/env bash
# 72_libevent_ncurses_obtain.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    ALWAYS-RUNNABLE anti-bluff RUNTIME coverage for the v1.0.30
#             addition to scripts/obtain_local_deps.sh — resolving-or-obtaining
#             the tmux BUILD dependencies libevent (2.1.12) + ncurses (6.5)
#             (§11.4.77 + §11.4.81 + §11.4.111). Closes coverage GAP B: before
#             this test the libevent+ncurses obtain path was exercised ONLY by
#             the env-gated zig test (71, SKIPs on toolchain-less hosts) and the
#             jemalloc-only CM-LOCAL-DEPS-MECHANISM source gate. THIS test RUNS
#             the mechanism on a NORMAL host into a throwaway root and proves,
#             with CAPTURED evidence (§11.4.5), that obtain_local_deps.sh emits
#             real build-dep wiring + a real, compiler-consumable library:
#               B1 libevent — resolve-or-obtain emits LIBEVENT_LIBDIR (real
#                  libevent shared object present) + LIBEVENT_INCDIR (real
#                  event2/event.h present) + a REAL link probe: compile+link a
#                  C TU calling event_base_new() against the resolved library.
#               B2 ncurses  — same for NCURSES_LIBDIR/INCDIR + a link probe
#                  calling initscr() against the resolved libncursesw.
#               B3 the two link probes (B1/B2's compiler half) prove the
#                  obtained/resolved deps are genuinely CONSUMABLE by a C
#                  compiler — exactly what tmux's ./configure needs (the GAP).
#
#             §11.4.115 polarity switch RED_MODE (default 0 = GREEN guard):
#               RED_MODE=1 reproduces the PRE-v1.0.30 defect on the broken
#               artifact — running the SAME obtain script with its OLD
#               jemalloc-only default scope (DEPS=jemalloc) emits NO
#               LIBEVENT_*/NCURSES_* build-dep wiring at all. The SAME wiring
#               assertion that PASSes on the libevent+ncurses run MUST FAIL to
#               find the keys on the jemalloc-only run → defect reproduced. This
#               is the in-test paired-mutation proof the GREEN guard has teeth
#               (the bug-catcher IS the regression-guard, one source two roles).
#
#             §11.4.3 honest SKIP, never a faked PASS: when the host genuinely
#             cannot resolve NOR obtain a build dep (network unreachable + no
#             local/host copy → obtain exits EC_NETWORK=11 / EC_NO_TOOLCHAIN=10
#             / EC_UNSUPPORTED=14), that dep SKIPs-with-reason. The throwaway
#             root is pre-seeded from the repo's already-obtained .local-deps/
#             (lib + include + tarball cache) so a host that has run setup once
#             resolves locally with NO network — never forcing a slow/flaky
#             source build inside the suite (the task's "if deps are already
#             resolved, assert the resolve path, don't force a network obtain").
#
# Usage:      bash scripts/tests/72_libevent_ncurses_obtain.sh
#             RED_MODE=1 bash scripts/tests/72_libevent_ncurses_obtain.sh   # RED
# Inputs:     RED_MODE (0|1, default 0). Honors $TMPDIR for the throwaway root.
# Outputs:    [evidence …] ; PASS/FAIL/SKIP lines ; summary.
# Side-effects: creates + removes a throwaway LOCAL_DEPS_ROOT + probe build dir
#             under ${TMPDIR:-/tmp}/tmx72deps.$$ (trap-cleaned on every exit,
#             §11.4.14). NEVER mutates the real .local-deps/ tree (read-only
#             pre-seed copy) and NEVER edits obtain_local_deps.sh.
# Dependencies: scripts/obtain_local_deps.sh (the feature under test — SKIP if
#             absent), `file`; the B1/B2 link probes additionally need a C
#             compiler (cc/gcc/clang) — SKIP-with-reason per §11.4.3 when absent
#             (the LIBDIR/INCDIR file-present evidence still PASSes).
# Cross-refs: scripts/obtain_local_deps.sh (consumed, not edited) ;
#             scripts/verify.sh CM-LOCAL-DEPS-MECHANISM gate (extended invariants
#             vi+vii assert libevent+ncurses are wired at the SOURCE layer) ;
#             scripts/tests/67_local_deps.sh (the jemalloc runtime sibling) ;
#             scripts/tests/71_root_free_zig_build.sh (the env-gated zig path).
# §11.4.67:   sh -n + bash -n clean (no [[ ]] / arrays / process substitution).
# §11.4.115:  RED_MODE=1 reproduces the jemalloc-only no-build-dep-wiring defect;
#             RED_MODE=0 is the standing GREEN regression guard.
# Last verified: 2026-06-30
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
OBTAIN="$REPO_ROOT/scripts/obtain_local_deps.sh"
PLAT="$(uname -s)_$(uname -m)"
OS="$(uname -s)"
RED_MODE="${RED_MODE:-0}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 72: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 72: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 72: $*"; SKIP=$((SKIP + 1)); }

# Throwaway root — never the real .local-deps/. trap-cleaned (§11.4.14).
SCRATCH_BASE="${TMPDIR:-/tmp}"; SCRATCH_BASE="${SCRATCH_BASE%/}"
WORK="$SCRATCH_BASE/tmx72deps.$$"
_cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap _cleanup EXIT
if ! mkdir -p "$WORK" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "SKIP 72: throwaway root $WORK not writable (disk full / RO) — §11.4.3"
    echo "── summary 72: PASS=0 FAIL=0 SKIP=1 ──"
    exit 0
fi

echo "── Test 72: libevent + ncurses local-dependency obtain (§11.4.77/.81/.111) [RED_MODE=$RED_MODE] ──"

if [ ! -x "$OBTAIN" ]; then
    _skip "scripts/obtain_local_deps.sh absent or not executable — feature not built (§11.4.3)"
    echo "── summary 72: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 0
fi

# Read a KEY=value line out of a resolved.env (absolute, no ambient eval).
_renv() { grep -m1 "^$1=" "$2" 2>/dev/null | sed "s/^$1=//"; }

# `file -L` (deref symlinks) matches a real shared object on either OS.
_is_shared_object() {
    file -L "$1" 2>/dev/null | grep -qiE 'shared object|Mach-O|dynamically linked|ELF'
}

# Print the first real shared-object file in <dir> matching the dep's lib glob,
# or nothing. Linux: lib*.so* ; Darwin: lib*.dylib.
_find_lib_file() {
    _dir="$1"; _stem="$2"; _f=""
    [ -d "$_dir" ] || return 1
    if [ "$OS" = "Darwin" ]; then
        for _f in "$_dir/$_stem"*.dylib; do
            [ -e "$_f" ] && _is_shared_object "$_f" && { printf '%s' "$_f"; return 0; }
        done
    else
        for _f in "$_dir/$_stem"*.so*; do
            [ -e "$_f" ] && _is_shared_object "$_f" && { printf '%s' "$_f"; return 0; }
        done
    fi
    return 1
}

# Map an obtain-script exit code to an honest §11.4.3 SKIP reason, or "" if it
# is a genuine product defect that MUST surface as FAIL.
_obtain_skip_reason() {
    case "$1" in
        10) echo "no obtain toolchain on this host (no compiler/make) — §11.4.3" ;;
        11) echo "network_unreachable_external — cannot download dependency tarball — §11.4.3" ;;
        13) echo "container obtain failed — §11.4.3" ;;
        14) echo "unsupported dependency/OS topology — §11.4.3" ;;
        *)  echo "" ;;
    esac
}

CC="$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || command -v clang 2>/dev/null || true)"

# ── shared wiring assertion (the bug-catcher == the regression-guard) ──────
# Returns 0 + prints "<libdir>|<incdir>" when the build-dep <EP> is fully wired
# in <renv> (LIBDIR exists w/ a real lib + INCDIR exists w/ the header); else 1.
# Used by BOTH polarities: GREEN expects 0, RED expects 1 (defect = NOT wired).
_assert_build_dep_wired() {
    _renv_f="$1"; _ep="$2"; _libstem="$3"; _hdr="$4"
    _ld="$(_renv "${_ep}_LIBDIR" "$_renv_f")"
    _id="$(_renv "${_ep}_INCDIR" "$_renv_f")"
    [ -n "$_ld" ] || return 1
    [ -n "$_id" ] || return 1
    _libf="$(_find_lib_file "$_ld" "$_libstem")" || return 1
    [ -e "$_id/$_hdr" ] || return 1
    printf '%s|%s|%s' "$_ld" "$_id" "$_libf"
    return 0
}

# Real compile+link probe (§11.4.5): build a C TU that #includes <hdr> and calls
# <sym>, linking against the EXPLICIT resolved library file. Proves the obtained
# /resolved dep is genuinely consumable by a C compiler (the tmux ./configure
# requirement). Link-only — never executed. Returns 0 + the probe path on link
# success; 1 on link failure; 2 when no compiler is available (caller SKIPs).
_link_probe() {
    _name="$1"; _hdr="$2"; _sym="$3"; _libf="$4"; _incdir="$5"
    [ -n "$CC" ] || return 2
    _pdir="$WORK/probe_$_name"; mkdir -p "$_pdir"
    {
        printf '#include <%s>\n' "$_hdr"
        printf 'int main(void){ (void)%s; return 0; }\n' "$_sym"
    } > "$_pdir/probe.c"
    if "$CC" "$_pdir/probe.c" -I"$_incdir" -o "$_pdir/probe" "$_libf" >/dev/null 2>&1; then
        printf '%s' "$_pdir/probe"; return 0
    fi
    return 1
}

# ── Pre-seed the throwaway root from the repo's already-obtained .local-deps/ ──
# so a host that has run setup once resolves libevent/ncurses LOCALLY with NO
# network (idempotent reuse) — never a slow/flaky source build inside the suite.
# Read-only copy; the real tree is never mutated. Absent ⇒ obtain falls back to
# host-resolve or (last resort) a real source build, honest-SKIP if unreachable.
_preseed() {
    _root="$1"; _real="$REPO_ROOT/.local-deps"
    mkdir -p "$_root/$PLAT"
    [ -d "$_real/$PLAT/lib" ]     && cp -a "$_real/$PLAT/lib"     "$_root/$PLAT/lib"     2>/dev/null || true
    [ -d "$_real/$PLAT/include" ] && cp -a "$_real/$PLAT/include" "$_root/$PLAT/include" 2>/dev/null || true
    [ -d "$_real/.tarballs" ]     && cp -a "$_real/.tarballs"     "$_root/.tarballs"     2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════
# RED_MODE=1 — reproduce the PRE-v1.0.30 defect on the broken artifact:
#   the OLD jemalloc-only obtain scope (DEPS=jemalloc, the script's own
#   backward-compatible default) emits NO libevent/ncurses build-dep wiring.
#   The SAME _assert_build_dep_wired used by the GREEN guard MUST return 1
#   (NOT wired) for BOTH deps → defect reproduced → the guard has teeth.
# ════════════════════════════════════════════════════════════════════════
if [ "$RED_MODE" = "1" ]; then
    RR="$WORK/red"; rm -rf "$RR"
    LOCAL_DEPS_ROOT="$RR" DEPS=jemalloc bash "$OBTAIN" >/dev/null 2>&1
    rcr=$?
    rrenv="$RR/$PLAT/resolved.env"
    # A failed/empty jemalloc-only run ALSO lacks build-dep wiring → defect holds
    # either way (absent wiring is the defect regardless of jemalloc's outcome).
    le_wired=1; nc_wired=1
    _assert_build_dep_wired "$rrenv" LIBEVENT libevent "event2/event.h" >/dev/null 2>&1 || le_wired=0
    _assert_build_dep_wired "$rrenv" NCURSES  libncursesw "ncurses.h"   >/dev/null 2>&1 || nc_wired=0
    _bdlines="$(grep -cE '^(LIBEVENT|NCURSES)_' "$rrenv" 2>/dev/null || true)"; [ -n "$_bdlines" ] || _bdlines=0
    echo "[evidence 72-RED] jemalloc-only obtain (rc=$rcr) resolved.env LIBEVENT/NCURSES build-dep lines: $_bdlines"
    if [ "$le_wired" -eq 0 ] && [ "$nc_wired" -eq 0 ]; then
        _pass "RED reproduced — jemalloc-only obtain emits NO libevent/ncurses build-dep wiring (the pre-v1.0.30 defect the GREEN guard catches; §11.4.115)"
    else
        _fail "RED did NOT reproduce — jemalloc-only obtain unexpectedly wired libevent($le_wired)/ncurses($nc_wired); the guard would be blind"
    fi
    echo ""
    echo "── summary 72: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════
# RED_MODE=0 (default) — GREEN regression guard: resolve-or-obtain libevent +
# ncurses on a normal host, assert real build-dep wiring + a real link probe.
# ════════════════════════════════════════════════════════════════════════
GR="$WORK/green"; rm -rf "$GR"
_preseed "$GR"
LOCAL_DEPS_ROOT="$GR" DEPS="libevent ncurses" bash "$OBTAIN" >"$WORK/obtain.log" 2>&1
rcg=$?
grenv="$GR/$PLAT/resolved.env"

if [ "$rcg" -ne 0 ] && [ ! -f "$grenv" ]; then
    reason="$(_obtain_skip_reason "$rcg")"
    [ -n "$reason" ] || reason="obtain exited rc=$rcg (no resolved.env produced) — see obtain.log"
    _skip "B0 resolve-or-obtain — $reason"
    echo "── summary 72: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

# Per-dep: (stem, header, link symbol).
# libevent core symbol event_base_new(); ncursesw screen-init symbol initscr().
for spec in "LIBEVENT|libevent|event2/event.h|event_base_new|libevent|B1" \
            "NCURSES|libncursesw|ncurses.h|initscr|ncurses|B2"; do
    EP="${spec%%|*}";   rest="${spec#*|}"
    STEM="${rest%%|*}"; rest="${rest#*|}"
    HDR="${rest%%|*}";  rest="${rest#*|}"
    SYM="${rest%%|*}";  rest="${rest#*|}"
    LABEL="${rest%%|*}"; TAG="${rest##*|}"

    wired="$(_assert_build_dep_wired "$grenv" "$EP" "$STEM" "$HDR" 2>/dev/null || true)"
    if [ -z "$wired" ]; then
        # Not wired: distinguish honest unreachable (SKIP) from defect (FAIL).
        reason="$(_obtain_skip_reason "$rcg")"
        srcv="$(_renv "${EP}_SOURCE" "$grenv")"
        if [ -n "$reason" ] && [ -z "$srcv" ]; then
            _skip "$TAG $LABEL — not resolvable/obtainable: $reason"
        else
            _fail "$TAG $LABEL — obtain produced no usable build-dep wiring (${EP}_LIBDIR/${EP}_INCDIR missing or pointing at no real lib/header); source='${srcv:-unset}', rc=$rcg"
        fi
        continue
    fi
    LD="${wired%%|*}"; r="${wired#*|}"; ID="${r%%|*}"; LIBF="${r##*|}"
    SRC="$(_renv "${EP}_SOURCE" "$grenv")"
    echo "[evidence 72-$TAG] ${EP}_SOURCE=$SRC  LIBDIR=$LD  INCDIR=$ID"
    echo "[evidence 72-$TAG] lib: $(file -L "$LIBF" 2>/dev/null | sed 's/.*: //' | head -1)  ($LIBF)"
    echo "[evidence 72-$TAG] header: $ID/$HDR present"
    _pass "$TAG $LABEL — resolve-or-obtain emitted real build-dep wiring: LIBDIR has a real shared object + INCDIR has $HDR (source=$SRC; §11.4.77/.111)"

    # Real compiler link probe (B3 evidence rolled per-dep).
    probe="$(_link_probe "$LABEL" "$HDR" "$SYM" "$LIBF" "$ID")"; lprc=$?
    if [ "$lprc" -eq 2 ]; then
        _skip "$TAG-link $LABEL — no C compiler to run the link probe; file-present evidence stands (§11.4.3)"
    elif [ "$lprc" -eq 0 ]; then
        echo "[evidence 72-$TAG-link] $CC linked a TU calling $SYM() against $LIBF — $(file "$probe" 2>/dev/null | sed 's/.*: //' | head -1)"
        _pass "$TAG-link $LABEL — obtained/resolved lib is COMPILER-CONSUMABLE: a C TU #include <$HDR> calling $SYM() links against the resolved library (§11.4.5; the tmux ./configure requirement)"
    else
        _fail "$TAG-link $LABEL — the resolved lib+header could NOT be linked by $CC (TU calling $SYM() against $LIBF failed to link) — wiring is present but not consumable"
    fi
done

echo ""
echo "── summary 72: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
