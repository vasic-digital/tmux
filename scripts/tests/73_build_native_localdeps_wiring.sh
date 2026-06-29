#!/usr/bin/env bash
# 73_build_native_localdeps_wiring.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    ALWAYS-RUNNABLE anti-bluff RUNTIME coverage for the v1.0.30
#             build_native.sh local-dependency wiring (§11.4.77). Closes
#             coverage GAP D: scripts/build_native.sh sources resolved.env and,
#             for a libevent/ncurses that was source-built/obtained into the
#             LOCAL prefix (LIBEVENT_SOURCE/NCURSES_SOURCE = local-build/
#             local-deps), wires the local prefix's include + lib dirs into the
#             build as -I${..._INCDIR} / -L${..._LIBDIR} AND sets LOCAL_PKGCONFIG
#             (→ PKG_CONFIG_PATH) so tmux's ./configure finds the obtained deps.
#             That wiring was previously exercised end-to-end ONLY by the
#             env-gated zig test (71, SKIPs on capable hosts). THIS test proves
#             the wiring RUNS — with CAPTURED evidence (§11.4.5) — WITHOUT a full
#             tmux build, by extracting the REAL Linux wiring block VERBATIM from
#             scripts/build_native.sh (NOT a re-implementation — the exact bytes,
#             so gutting the real wiring is caught) and EXECUTING it against a
#             controlled resolved.env:
#               D1 libevent — CFLAGS gains -I<LIBEVENT_INCDIR>, LDFLAGS gains
#                  -L<LIBEVENT_LIBDIR>.
#               D2 ncurses  — CFLAGS gains -I<NCURSES_INCDIR>, LDFLAGS gains
#                  -L<NCURSES_LIBDIR>.
#               D3 PKG_CONFIG_PATH — LOCAL_PKGCONFIG resolves to
#                  <LOCAL_DEPS_PREFIX>/lib/pkgconfig.
#               D4 independent of the zig path — the wiring is computed with
#                  CC_KIND="" (the host-toolchain path, NOT zig) AND, in the real
#                  file, the wiring block PRECEDES the `CC_KIND = "zig"` branch
#                  and the host ./configure invocation consumes "$CFLAGS"
#                  "$LDFLAGS" + PKG_CONFIG_PATH from LOCAL_PKGCONFIG.
#
#             §11.4.115 polarity switch RED_MODE (default 0 = GREEN guard):
#               RED_MODE=1 reproduces the defect on a BROKEN copy of
#               build_native.sh whose libevent/ncurses -I/-L assignments are
#               gutted. The SAME extract-and-eval the GREEN guard uses then
#               produces CFLAGS/LDFLAGS WITHOUT the -I/-L → defect reproduced →
#               the guard has teeth (the paired §1.1 mutation, in-test).
#
#             §11.4.6 honest boundary: this proves build_native.sh COMPUTES the
#             local-deps build flags at runtime — not that a full tmux build
#             links (that is test 71's env-gated scope). Anchors that fail to
#             capture the real wiring block FAIL with a diagnostic, never a
#             false PASS.
#
# Usage:      bash scripts/tests/73_build_native_localdeps_wiring.sh
#             RED_MODE=1 bash scripts/tests/73_build_native_localdeps_wiring.sh
# Inputs:     RED_MODE (0|1, default 0). Honors $TMPDIR.
# Outputs:    [evidence …] ; PASS/FAIL/SKIP lines ; summary.
# Side-effects: a throwaway dir under ${TMPDIR:-/tmp}/tmx73wiring.$$ (trap-cleaned,
#             §11.4.14). NEVER edits scripts/build_native.sh (read-only extract).
# Dependencies: scripts/build_native.sh (the feature under test — SKIP if absent),
#             sed, bash (eval of the extracted POSIX wiring block).
# Cross-refs: scripts/build_native.sh (consumed, not edited) ;
#             scripts/obtain_local_deps.sh (emits the resolved.env this consumes) ;
#             scripts/tests/72_libevent_ncurses_obtain.sh (the obtain sibling) ;
#             scripts/tests/71_root_free_zig_build.sh (env-gated full build).
# §11.4.67:   sh -n + bash -n clean (no [[ ]] / arrays / process substitution).
# §11.4.115:  RED_MODE=1 gutting copy reproduces the no-wiring defect; RED_MODE=0
#             is the standing GREEN regression guard over the REAL wiring bytes.
# Last verified: 2026-06-30
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
BUILD_NATIVE="$REPO_ROOT/scripts/build_native.sh"
RED_MODE="${RED_MODE:-0}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 73: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 73: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 73: $*"; SKIP=$((SKIP + 1)); }

SCRATCH_BASE="${TMPDIR:-/tmp}"; SCRATCH_BASE="${SCRATCH_BASE%/}"
WORK="$SCRATCH_BASE/tmx73wiring.$$"
_cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap _cleanup EXIT
if ! mkdir -p "$WORK" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "SKIP 73: throwaway root $WORK not writable (disk full / RO) — §11.4.3"
    echo "── summary 73: PASS=0 FAIL=0 SKIP=1 ──"
    exit 0
fi

echo "── Test 73: build_native.sh local-deps -I/-L/PKG_CONFIG_PATH wiring (§11.4.77) [RED_MODE=$RED_MODE] ──"

if [ ! -f "$BUILD_NATIVE" ]; then
    _skip "scripts/build_native.sh absent — feature not built (§11.4.3)"
    echo "── summary 73: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 0
fi

# ── Extract the REAL Linux wiring block VERBATIM (content anchors, not line
#    numbers, so it survives edits above/below). START = the JEM_* init that
#    opens the block; END = the final LDFLAGS assignment that closes it (the
#    first such line AFTER START — the zig path's identical -ljemalloc tail is
#    later in the file, so the address range stops at the host LDFLAGS). ────────
START_ANCHOR='JEM_CPPFLAGS=""; JEM_LDFLAGS=""'
END_ANCHOR='-Wl,--no-as-needed -ljemalloc -Wl,--as-needed'

_extract_block() {
    sed -n "/${START_ANCHOR}/,/${END_ANCHOR}/p" "$1"
}

# ── controlled resolved.env: libevent + ncurses obtained into the LOCAL prefix
#    (local-build), jemalloc host-resolved (so JEM_* stay empty — proving the
#    LE/NC wiring is independent of jemalloc), CC_KIND ends "" (host path, NOT
#    zig — proving independence of the zig path). LOCAL_DEPS_PREFIX/lib/pkgconfig
#    is created so LOCAL_PKGCONFIG gets set. ─────────────────────────────────
LD_ROOT="$WORK/ld"
PFX="$LD_ROOT/Linux_x86_64"
INC_LE="$PFX/inc_le"; LIB_LE="$PFX/lib_le"
INC_NC="$PFX/inc_nc"; LIB_NC="$PFX/lib_nc"
PKGCFG_DIR="$PFX/lib/pkgconfig"
mkdir -p "$PFX" "$INC_LE" "$LIB_LE" "$INC_NC" "$LIB_NC" "$PKGCFG_DIR"
{
    printf 'LOCAL_DEPS_PREFIX=%s\n' "$PFX"
    printf 'JEMALLOC_SOURCE=%s\n'   "host-system"
    printf 'LIBEVENT_SOURCE=%s\n'   "local-build"
    printf 'LIBEVENT_INCDIR=%s\n'   "$INC_LE"
    printf 'LIBEVENT_LIBDIR=%s\n'   "$LIB_LE"
    printf 'NCURSES_SOURCE=%s\n'    "local-build"
    printf 'NCURSES_INCDIR=%s\n'    "$INC_NC"
    printf 'NCURSES_LIBDIR=%s\n'    "$LIB_NC"
} > "$PFX/resolved.env"

# Run the extracted wiring block against the controlled env and print the three
# computed outputs. Runs in a child bash with the build_native.sh-equivalent
# HOST_OS/HOST_ARCH/LOCAL_DEPS_ROOT set; set +e so a benign non-zero never
# aborts the capture. <block-file> is the extracted wiring.
_compute_flags() {
    _bf="$1"
    HOST_OS=Linux HOST_ARCH=x86_64 LOCAL_DEPS_ROOT="$LD_ROOT" \
    CPPFLAGS="" CFLAGS="" LDFLAGS="" \
    bash -c '
        set +e
        # shellcheck disable=SC1090
        block="$(cat "$1")"
        eval "$block"
        printf "===CFLAGS===%s\n" "${CFLAGS:-}"
        printf "===LDFLAGS===%s\n" "${LDFLAGS:-}"
        printf "===LOCAL_PKGCONFIG===%s\n" "${LOCAL_PKGCONFIG:-}"
    ' _ "$_bf"
}

# Helper: extract a "===KEY===value" line's value from captured output.
_field() { printf '%s\n' "$2" | sed -n "s/^===$1===//p" | head -1; }

# ════════════════════════════════════════════════════════════════════════
# RED_MODE=1 — reproduce the defect on a BROKEN copy of build_native.sh whose
# libevent/ncurses -I/-L assignments are gutted (the paired §1.1 mutation). The
# SAME extract-and-eval the GREEN guard uses then produces CFLAGS/LDFLAGS with
# NO -I<INCDIR>/-L<LIBDIR> for the obtained deps → defect reproduced.
# ════════════════════════════════════════════════════════════════════════
if [ "$RED_MODE" = "1" ]; then
    BROKEN="$WORK/build_native.broken.sh"
    sed -e 's#LE_CPPFLAGS="-I${LIBEVENT_INCDIR}"#LE_CPPFLAGS=""#' \
        -e 's#LE_LDFLAGS="-L${LIBEVENT_LIBDIR}"#LE_LDFLAGS=""#' \
        -e 's#NC_CPPFLAGS="-I${NCURSES_INCDIR}"#NC_CPPFLAGS=""#' \
        -e 's#NC_LDFLAGS="-L${NCURSES_LIBDIR}"#NC_LDFLAGS=""#' \
        "$BUILD_NATIVE" > "$BROKEN"
    # Prove the mutation actually changed the wiring lines (else the RED is blind).
    if ! diff -q "$BUILD_NATIVE" "$BROKEN" >/dev/null 2>&1; then
        : # changed — good
    else
        _fail "RED setup — the gutting sed did not change build_native.sh (the wiring assignment lines drifted); the RED would be blind (§11.4.115)"
        echo "── summary 73: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 1
    fi
    blk="$WORK/block.broken"; _extract_block "$BROKEN" > "$blk"
    out="$(_compute_flags "$blk")"
    cf="$(_field CFLAGS "$out")"; lf="$(_field LDFLAGS "$out")"
    le_gone=1; nc_gone=1
    printf '%s' "$cf" | grep -q -- "-I$INC_LE" && le_gone=0
    printf '%s' "$lf" | grep -q -- "-L$LIB_LE" && le_gone=0
    printf '%s' "$cf" | grep -q -- "-I$INC_NC" && nc_gone=0
    printf '%s' "$lf" | grep -q -- "-L$LIB_NC" && nc_gone=0
    echo "[evidence 73-RED] gutted-copy CFLAGS='$cf'"
    echo "[evidence 73-RED] gutted-copy LDFLAGS='$lf'"
    if [ "$le_gone" -eq 1 ] && [ "$nc_gone" -eq 1 ]; then
        _pass "RED reproduced — gutting build_native.sh's libevent/ncurses -I/-L assignments removes the local-deps flags from CFLAGS/LDFLAGS (the defect the GREEN guard catches; §11.4.115 paired mutation)"
    else
        _fail "RED did NOT reproduce — gutted copy still emitted local-deps flags (libevent-present=$((1-le_gone)) ncurses-present=$((1-nc_gone))); the guard would be blind"
    fi
    echo ""
    echo "── summary 73: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════
# RED_MODE=0 (default) — GREEN regression guard over the REAL wiring bytes.
# ════════════════════════════════════════════════════════════════════════
BLK="$WORK/block.real"; _extract_block "$BUILD_NATIVE" > "$BLK"

# Anchors must have captured the REAL wiring block, else FAIL honestly (never a
# false PASS): the block MUST contain the LE/NC/LOCAL_PKGCONFIG markers.
if [ ! -s "$BLK" ]; then
    _fail "D0 — extraction produced an EMPTY block (START/END anchors drifted in build_native.sh) — cannot verify wiring"
    echo "── summary 73: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 1
fi
miss=""
for marker in 'LIBEVENT_INCDIR' 'LIBEVENT_LIBDIR' 'NCURSES_INCDIR' 'NCURSES_LIBDIR' 'LOCAL_PKGCONFIG'; do
    grep -q "$marker" "$BLK" || miss="$miss $marker"
done
if [ -n "$miss" ]; then
    _fail "D0 — extracted block is missing expected wiring markers:$miss (anchors captured the wrong range)"
    echo "── summary 73: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 1
fi
echo "[evidence 73-D0] extracted $(wc -l < "$BLK" | tr -d ' ') real wiring lines from build_native.sh (markers LIBEVENT_*/NCURSES_*/LOCAL_PKGCONFIG present)"

OUT="$(_compute_flags "$BLK")"
CF="$(_field CFLAGS "$OUT")"
LF="$(_field LDFLAGS "$OUT")"
PC="$(_field LOCAL_PKGCONFIG "$OUT")"
echo "[evidence 73-run] CFLAGS=$CF"
echo "[evidence 73-run] LDFLAGS=$LF"
echo "[evidence 73-run] LOCAL_PKGCONFIG=$PC"

# D1 — libevent -I/-L.
if printf '%s' "$CF" | grep -q -- "-I$INC_LE" && printf '%s' "$LF" | grep -q -- "-L$LIB_LE"; then
    _pass "D1 libevent — build_native.sh wires -I$INC_LE into CFLAGS and -L$LIB_LE into LDFLAGS for the obtained (local-build) libevent (§11.4.77)"
else
    _fail "D1 libevent — CFLAGS missing -I$INC_LE OR LDFLAGS missing -L$LIB_LE (libevent local-deps NOT wired) — CFLAGS='$CF' LDFLAGS='$LF'"
fi

# D2 — ncurses -I/-L.
if printf '%s' "$CF" | grep -q -- "-I$INC_NC" && printf '%s' "$LF" | grep -q -- "-L$LIB_NC"; then
    _pass "D2 ncurses — build_native.sh wires -I$INC_NC into CFLAGS and -L$LIB_NC into LDFLAGS for the obtained (local-build) ncurses (§11.4.77)"
else
    _fail "D2 ncurses — CFLAGS missing -I$INC_NC OR LDFLAGS missing -L$LIB_NC (ncurses local-deps NOT wired) — CFLAGS='$CF' LDFLAGS='$LF'"
fi

# D3 — PKG_CONFIG_PATH source (LOCAL_PKGCONFIG → <prefix>/lib/pkgconfig).
if [ "$PC" = "$PKGCFG_DIR" ]; then
    _pass "D3 PKG_CONFIG_PATH — build_native.sh resolves LOCAL_PKGCONFIG to $PKGCFG_DIR (the obtained deps' .pc dir feeds tmux ./configure pkg-config; §11.4.77)"
else
    _fail "D3 PKG_CONFIG_PATH — LOCAL_PKGCONFIG='$PC', expected '$PKGCFG_DIR' (the local pkgconfig dir is NOT wired)"
fi

# D4 — independent of the zig path. The runtime eval above ran with CC_KIND=""
#      (host path, NOT zig) and STILL produced the flags — already proves
#      independence. This adds the STRUCTURAL confirmation that, in the real
#      file, the wiring PRECEDES the `CC_KIND = "zig"` branch AND the host
#      ./configure invocation consumes "$CFLAGS"/"$LDFLAGS" + the LOCAL_PKGCONFIG
#      PKG_CONFIG_PATH (so the host-toolchain path actually USES the wiring).
wire_ln="$(grep -n 'LE_LDFLAGS="-L${LIBEVENT_LIBDIR}"' "$BUILD_NATIVE" 2>/dev/null | head -1 | cut -d: -f1)"
zig_ln="$(grep -nE '=[[:space:]]*"zig"[[:space:]]*\]' "$BUILD_NATIVE" 2>/dev/null | head -1 | cut -d: -f1)"
host_cfg=0
grep -q 'CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"' "$BUILD_NATIVE" 2>/dev/null \
  && grep -q 'PKG_CONFIG_PATH="${LOCAL_PKGCONFIG:+${LOCAL_PKGCONFIG}:}${PKG_CONFIG_PATH:-}"' "$BUILD_NATIVE" 2>/dev/null \
  && host_cfg=1
if [ -n "$wire_ln" ] && [ -n "$zig_ln" ] && [ "$wire_ln" -lt "$zig_ln" ] && [ "$host_cfg" -eq 1 ]; then
    echo "[evidence 73-D4] wiring at line $wire_ln precedes the CC_KIND=\"zig\" branch at line $zig_ln; host ./configure consumes \"\$CFLAGS\"/\"\$LDFLAGS\" + LOCAL_PKGCONFIG PKG_CONFIG_PATH"
    _pass "D4 independent-of-zig — the local-deps wiring is computed on the host-toolchain path (CC_KIND=\"\", runtime-proven above) BEFORE the zig branch, and the host ./configure consumes it (§11.4.6)"
else
    _fail "D4 independent-of-zig — structural check failed: wire_ln='$wire_ln' zig_ln='$zig_ln' host_configure_consumes_flags=$host_cfg"
fi

echo ""
echo "── summary 73: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
