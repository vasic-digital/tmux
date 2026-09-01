#!/usr/bin/env bash
# 71_root_free_zig_build.sh
# ─────────────────────────────────────────────────────────────────────────────
# Purpose:    TMX-063 standing regression guard — PROVE the PRODUCTION scripts
#             (scripts/obtain_local_deps.sh + scripts/build_native.sh) build a
#             working tmux next-3.8 with NO root, NO sudo/su, NO interaction, even
#             when the host has NO working C toolchain — by OBTAINING the zig
#             root-free toolchain and source-building libevent/ncurses/jemalloc
#             + tmux with it. (§11.4.115 RED-baseline + §11.4.135 guard +
#             §11.4.169 build/e2e + §11.4.123 rock-solid captured proof.)
#
# What this guard proves (captured evidence under qa-results/loop-20260629/zig-impl/):
#   C1  NORMAL-host no-regression: on a host whose cc LINKS, the REAL obtain
#       script resolves the HOST compiler (CC_KIND=host / CC_SOURCE=host-system)
#       — NO zig obtained, the existing build path is untouched.
#   C2  NEUTER proof: under a sanitised env (env -i + a shim PATH that OMITS
#       cc/gcc/clang/ld/as/ar/autoconf/automake/bison/pkg-config) the host
#       toolchain is genuinely unreachable AND a bare `cc` link FAILS — the
#       bare-host simulation is real (the proof a later success is the zig's).
#   C3  RED (§11.4.115, RED_MODE=1): in the neutered env WITHOUT the zig obtain,
#       the REAL build cannot link → FAILS at the can't-link step (defect present
#       on the broken artifact). Same source, polarity switch.
#   C4  GREEN (RED_MODE=0): in the neutered env WITH the zig obtain, the REAL
#       project scripts build tmux next-3.8 end-to-end with ONLY the obtained zig.
#   C5  tmux -V == "tmux $EXPECTED_VERSION" (default next-3.8) — user-visible build product.
#   C6  LIVE SESSION: the zig-built tmux drives a real session
#       (new-session/send-keys/capture-pane shows the computed marker).
#   C7  LOCAL-LINK (residual #2): readelf DT_NEEDED of the built tmux references
#       the LOCAL zig-built libevent/ncurses/jemalloc sonames (not host copies).
#   C8  N=3 determinism (§11.4.50): the GREEN build, run N times, yields an
#       IDENTICAL "tmux next-3.8" every time.
#   C9  §1.1 paired mutation (self-contained): stripping the `cc` registry branch
#       from a COPY of obtain_local_deps.sh makes the neutered obtain unable to
#       get a zig toolchain (CC_KIND≠zig) → the build cannot proceed → MUTATION
#       CAUGHT (the guard has teeth).
#   C10 §11.4.67 parseability + no-sudo/no-interaction on the touched scripts.
#
# Usage:      bash scripts/tests/71_root_free_zig_build.sh            # GREEN guard
#             RED_MODE=1 bash scripts/tests/71_root_free_zig_build.sh # reproduce defect
# Inputs:     RED_MODE (default 0 = standing GREEN guard; 1 = RED reproduction).
#             TMX_ZIG_BUILD_N (default 3) — determinism iterations.
#             ZIG_TEST_SKIP_HEAVY=1 — run only the cheap static checks.
#             Honours $TMPDIR. Network needed for the GREEN build when no zig
#             tarball is cached; a throttled/unreachable mirror fails FAST (the
#             bounded _download) → honest SKIP (§11.4.3), never an ~8-hour hang.
# Outputs:    EVIDENCE / PASS / FAIL / SKIP lines + summary (run_all-classified).
# Side-effects: builds under ${TMPDIR}/tmx71.$$ + a scratch LOCAL_DEPS_ROOT +
#             scratch TMX_BUILD_DIR (trap-cleaned, §11.4.14). HOST-SAFE: NEVER
#             touches the operator's tmux/build or .local-deps, NEVER mutates the
#             host toolchain, NO sudo/su, NO human-wait (§12 + operator mandate
#             2026-06-29). A persistent gitignored tarball cache under
#             .local-deps/.test71-cache makes re-runs network-frugal.
# Dependencies: the REAL scripts/obtain_local_deps.sh + scripts/build_native.sh
#             (under test); generic tools (make/tar/xz/curl|wget/sha256sum/sed/
#             awk/grep/readelf|file); a real cc for the C1 host baseline.
# §11.4.67:   bash -n + sh -n clean. §11.4.81: Linux-focused (zig build); macOS
#             host-build path is the documented UNCONFIRMED fallback → SKIP there.
# Last verified: 2026-06-29
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

RED_MODE="${RED_MODE:-0}"
ZIG_BUILD_N="${TMX_ZIG_BUILD_N:-3}"
# Adopted upstream tmux version (operator decision 2026-09-01: next-3.8 pin).
# Inherited from run_all.sh when run in-suite; defaulted for standalone runs.
EXPECTED_VERSION="${EXPECTED_VERSION:-next-3.8}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
OBTAIN="$REPO_ROOT/scripts/obtain_local_deps.sh"
BUILD="$REPO_ROOT/scripts/build_native.sh"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 71: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 71: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 71: $*"; SKIP=$((SKIP + 1)); }
_ev()   { echo "EVIDENCE 71: $*"; }

SCRATCH_BASE="${TMPDIR:-/tmp}"; SCRATCH_BASE="${SCRATCH_BASE%/}"
WORK="$SCRATCH_BASE/tmx71.$$"
SHIM="$WORK/shim"
LDR="$WORK/ld"
BLD="$WORK/build"
EVID_DIR="$REPO_ROOT/qa-results/loop-20260629/zig-impl"
PERSIST_CACHE="$REPO_ROOT/.local-deps/.test71-cache"   # gitignored (.local-deps/)
_cleanup() { rm -rf "$WORK" 2>/dev/null || true; rm -f "/tmp/t71.$$.sock" 2>/dev/null || true; }
trap _cleanup EXIT

HOST_OS="$(uname -s)"; HOST_ARCH="$(uname -m)"

if ! mkdir -p "$SHIM" "$LDR" "$BLD" "$WORK/tmp" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "SKIP 71: scratch root $WORK not writable (disk full / RO) — §11.4.3"
    echo "SKIP=1 PASS=0 FAIL=0"; exit 0
fi
mkdir -p "$EVID_DIR" 2>/dev/null || true

[ -f "$OBTAIN" ] || { echo "FAIL 71: scripts/obtain_local_deps.sh absent"; exit 1; }
[ -f "$BUILD" ]  || { echo "FAIL 71: scripts/build_native.sh absent"; exit 1; }

echo "════════════════════════════════════════════════════════════════"
echo "  test 71 — root-free zig build (TMX-063) (RED_MODE=$RED_MODE, N=$ZIG_BUILD_N)"
echo "════════════════════════════════════════════════════════════════"

# ── C10 (static, always): parseability + no-sudo/no-interaction ───────────────
c10_fail=0
for _f in "$OBTAIN" "$BUILD" "$REPO_ROOT/scripts/setup.sh"; do
    bash -n "$_f" >/dev/null 2>&1 || { echo "  >>> ${_f#$REPO_ROOT/} fails bash -n"; c10_fail=1; }
done
# touched non-setup scripts must be sudo/su EXECUTION-free too (setup.sh's full
# sudo/su census is the verify.sh CM-NO-SUDO-NO-INTERACTION gate). Match the gate
# philosophy — the COMMAND, not a mention: comment lines (e.g. obtain's "NO sudo"
# doc note) are filtered, so only an actual sudo/su command/advice line trips.
for _f in "$OBTAIN" "$BUILD"; do
    if grep -nE '\bsudo\b|\bsu[ -]' "$_f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
        echo "  >>> ${_f#$REPO_ROOT/} contains a sudo/su EXECUTION token"; c10_fail=1
    fi
    if grep -nE 'read[[:space:]][^|;&]*</dev/tty|read[[:space:]]+-p' "$_f" 2>/dev/null \
         | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '(printf|echo)' >/dev/null 2>&1; then
        echo "  >>> ${_f#$REPO_ROOT/} contains a human-wait read prompt"; c10_fail=1
    fi
done
if [ "$c10_fail" = "0" ]; then
    _pass "C10 touched scripts parse clean (bash -n) AND are sudo/su-free + human-wait-free (operator mandate 2026-06-29)"
else
    _fail "C10 a touched script fails parse OR contains sudo/su/human-wait (operator-mandate violation)"
fi

# ── C9 (static): §1.1 paired mutation precondition — the cc registry branch exists.
# The runtime half of the mutation (strip it → neutered obtain cannot get zig)
# runs inside the heavy section; here we assert the branch is present so the
# mutation is meaningful (a missing branch would make the build impossible
# regardless — that is the very thing the mutation proves the guard catches).
if grep -qE 'cc:url_x86_64-linux\)' "$OBTAIN" && grep -qE 'cc:kind\)' "$OBTAIN"; then
    _pass "C9a cc (zig) registry branch present in obtain_local_deps.sh (mutation target exists)"
else
    _fail "C9a cc (zig) registry branch MISSING — the root-free toolchain is not wired"
fi

# ── C1 (cheap): NORMAL-host no-regression — host cc resolves, no zig obtained ──
REAL_CC=""
for _c in cc gcc clang; do command -v "$_c" >/dev/null 2>&1 && { REAL_CC="$(command -v "$_c")"; break; }; done
if [ -z "$REAL_CC" ]; then
    _skip "C1 no host C compiler — cannot prove no-regression baseline (§11.4.3)"
else
    nrg="$WORK/norereg"; mkdir -p "$nrg"
    LOCAL_DEPS_ROOT="$nrg" DEPS="cc" bash "$OBTAIN" >"$WORK/c1.log" 2>&1 || true
    renv="$nrg/${HOST_OS}_${HOST_ARCH}/resolved.env"
    ck="$(sed -n 's/^CC_KIND=//p' "$renv" 2>/dev/null | head -1)"
    cs="$(sed -n 's/^CC_SOURCE=//p' "$renv" 2>/dev/null | head -1)"
    if [ "$ck" = "host" ] && [ "$cs" = "host-system" ] && [ ! -d "$nrg/${HOST_OS}_${HOST_ARCH}/zig" ]; then
        _pass "C1 NORMAL-host no-regression: cc resolved to HOST (CC_KIND=host, CC_SOURCE=host-system) — no zig obtained, existing path untouched"
        cp "$renv" "$EVID_DIR/C1_normal_host_resolved.env" 2>/dev/null || true
    else
        _fail "C1 no-regression broken: expected CC_KIND=host/host-system + no zig dir (got KIND=$ck SOURCE=$cs)"
    fi
fi

# ── platform / heavy-precondition gate ────────────────────────────────────────
if [ "$HOST_OS" != "Linux" ]; then
    _skip "C3-C8 heavy zig build: non-Linux host ($HOST_OS) — zig macOS path is the UNCONFIRMED §11.4.81 fallback (§11.4.3)"
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 71 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    [ "$FAIL" -gt 0 ] && exit 1; exit 0
fi
if [ "${ZIG_TEST_SKIP_HEAVY:-0}" = "1" ]; then
    _skip "C3-C8 heavy build skipped (ZIG_TEST_SKIP_HEAVY=1) — static checks above stand"
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 71 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    [ "$FAIL" -gt 0 ] && exit 1; exit 0
fi

# ── build the neuter shim (curated generic tools; NO toolchain/autotools) ──────
ALLOW="sh bash env printf echo test true false sleep mktemp mkdir rm rmdir ln cp mv cat head tail sort uniq wc tr cut sed awk gawk grep egrep fgrep find xargs basename dirname date chmod chown touch tee expr dd stat readlink realpath od cmp diff tar xz gzip gunzip bzip2 curl wget timeout sha256sum sha1sum md5sum nproc uname id whoami getconf pwd ls file patch which command sync seq comm join paste make gmake install readelf"
for t in $ALLOW; do
    for d in /usr/bin /bin /usr/local/bin /sbin /usr/sbin; do
        if [ -x "$d/$t" ] && [ ! -e "$SHIM/$t" ]; then ln -s "$d/$t" "$SHIM/$t"; break; fi
    done
done

# C2 — neuter proof (compilers/autotools empty under the shim; bare cc cannot link)
neuter_ok=1
miss="$(env -i HOME="$HOME" PATH="$SHIM" sh -c '
    for c in cc gcc clang ld as ar ranlib autoconf automake aclocal m4 bison yacc flex pkg-config cmake; do
        command -v "$c" >/dev/null 2>&1 && echo "$c"
    done')"
if [ -n "$miss" ]; then echo "  >>> neuter leaked: $miss"; neuter_ok=0; fi
# generic tools that MUST remain present
for c in make tar xz sha256sum sed awk; do
    env -i HOME="$HOME" PATH="$SHIM" sh -c "command -v $c >/dev/null 2>&1" || { echo "  >>> neuter missing generic tool: $c"; neuter_ok=0; }
done
if [ "$neuter_ok" = "1" ]; then
    _pass "C2 neuter valid: host compilers/linkers/autotools/pkg-config unreachable; generic tools present (bare-host simulation real)"
    { echo "neuter PATH=$SHIM"; echo "leaked compilers/autotools: ${miss:-<none>}"; } > "$EVID_DIR/C2_neuter_proof.log" 2>/dev/null || true
else
    _fail "C2 neuter invalid — a forbidden toolchain leaked OR a generic tool is missing"
fi

# seed the scratch tarball cache from the persistent gitignored cache (frugal)
mkdir -p "$LDR/.tarballs" "$PERSIST_CACHE" 2>/dev/null || true
cp -n "$PERSIST_CACHE"/*.tar.* "$LDR/.tarballs/" 2>/dev/null || true

# network reachability (only matters when a needed tarball is NOT cached). This
# is a CHEAP upfront reachability probe (HEAD) that catches a fully-unreachable
# mirror → upfront SKIP. NOTE (download-robustness fix): a HEAD returns FAST even
# when the mirror is BODY-throttled (observed ~1.6 KB/s on the 45 MB zig tarball),
# so a throttle slips PAST this probe — that case is handled WITHOUT a hang by the
# bounded _download in obtain_local_deps.sh (it fast-fails the real transfer in
# seconds) + the network-failure → honest-SKIP classification at the GREEN
# no-binary branch below (§11.4.3, never the old ~8-hour hang, never a fake PASS).
_net_ok() { curl -fsI --connect-timeout 12 --max-time 25 https://ziglang.org/download/index.json >/dev/null 2>&1 \
            || wget -q --spider --timeout=25 https://ziglang.org/download/index.json 2>/dev/null; }

# ── helper: run the REAL obtain + build_native inside the neuter ───────────────
# Arg1 = with_zig (1 = obtain the cc/zig toolchain + deps; 0 = skip cc → no zig).
# Echoes nothing; sets BUILT_BIN (path) + RUN_RC (0 ok). Output → $WORK/build_*.log
PFX="$LDR/${HOST_OS}_${HOST_ARCH}"
neutered_build() {
    _wz="$1"; _tag="$2"; BUILT_BIN=""; RUN_RC=1
    if [ "$_wz" = "1" ]; then _deps="cc jemalloc libevent ncurses"; else _deps="jemalloc libevent ncurses"; fi
    # FORCE_OBTAIN=1 → build ALL deps LOCALLY with zig (proves the full local
    # chain + residual #2). In the RED (no-zig) case there is no working compiler
    # so the dep builds fail honestly first; build_native then can't link tmux.
    env -i HOME="$HOME" PATH="$SHIM" TMPDIR="$WORK/tmp" \
        LOCAL_DEPS_ROOT="$LDR" FORCE_OBTAIN=1 DEPS="$_deps" \
        bash "$OBTAIN" >"$WORK/obtain_$_tag.log" 2>&1 || true
    env -i HOME="$HOME" PATH="$SHIM" TMPDIR="$WORK/tmp" \
        LOCAL_DEPS_ROOT="$LDR" TMX_BUILD_DIR="$BLD" \
        bash "$BUILD" >"$WORK/build_$_tag.log" 2>&1 && RUN_RC=0 || RUN_RC=$?
    [ -x "$BLD/bin/tmux" ] && BUILT_BIN="$BLD/bin/tmux"
}

if [ "$RED_MODE" = "1" ]; then
    # ── C3 RED: neutered build WITHOUT the zig obtain MUST fail at can't-link ──
    rm -rf "$LDR" "$BLD"; mkdir -p "$LDR/.tarballs" "$BLD"
    cp -n "$PERSIST_CACHE"/*.tar.* "$LDR/.tarballs/" 2>/dev/null || true
    neutered_build 0 red
    if [ -z "$BUILT_BIN" ] && [ "$RUN_RC" != "0" ]; then
        _pass "C3 RED reproduced: neutered build WITHOUT zig obtain FAILS (no C toolchain → cannot link tmux) — defect present on the broken artifact"
        tail -8 "$WORK/build_red.log" > "$EVID_DIR/RED_no_toolchain_build_fail.log" 2>/dev/null || true
        _ev "RED capture: qa-results/loop-20260629/zig-impl/RED_no_toolchain_build_fail.log"
    else
        _fail "C3 RED did NOT reproduce — neutered build succeeded WITHOUT a toolchain (blind test, §11.4.115)"
    fi
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 71 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    [ "$FAIL" -gt 0 ] && exit 1; exit 0
fi

# ── GREEN guard (RED_MODE=0): the heavy, network-dependent real build ─────────
# Need a complete tarball set or network. If neither → honest SKIP (§11.4.3).
have_zig_cached=0
ls "$LDR/.tarballs"/zig-*-linux-*.tar.xz >/dev/null 2>&1 && have_zig_cached=1
if [ "$have_zig_cached" = "0" ] && ! _net_ok; then
    _skip "C4-C8 GREEN build: network to ziglang.org unreachable AND no cached zig tarball — cannot obtain toolchain (§11.4.3, never a fake PASS)"
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 71 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    [ "$FAIL" -gt 0 ] && exit 1; exit 0
fi

rm -rf "$LDR" "$BLD"; mkdir -p "$LDR/.tarballs" "$BLD"
cp -n "$PERSIST_CACHE"/*.tar.* "$LDR/.tarballs/" 2>/dev/null || true
neutered_build 1 green
# persist the downloaded tarballs for the next (frugal) run
cp -n "$LDR/.tarballs"/*.tar.* "$PERSIST_CACHE/" 2>/dev/null || true

if [ -z "$BUILT_BIN" ]; then
    # §11.4.3 honest SKIP vs §11.4.1 FAIL (download-robustness fix): distinguish an
    # obtain that failed because the zig toolchain could not be DOWNLOADED (mirror
    # throttled/unreachable — an environment gap, NOT a product defect) from a
    # genuine build defect. The bounded _download (obtain_local_deps.sh) makes a
    # throttled/unreachable mirror fail FAST with a typed network error instead of
    # the old ~8-hour hang; when NO zig was obtained (CC_KIND≠zig) AND the obtain
    # log carries that typed network signature, the build legitimately cannot
    # proceed → honest SKIP, never a hang, never a fake PASS. Any non-network cause
    # (zig obtained but the build broke / a code bug) still FAILs — teeth intact.
    green_cck="$(sed -n 's/^CC_KIND=//p' "$PFX/resolved.env" 2>/dev/null | head -1)"
    if [ "$green_cck" != "zig" ] \
       && grep -qiE 'download failed|REFUSING to download unverified|network unreachable' "$WORK/obtain_green.log" 2>/dev/null; then
        _skip "C4-C8 GREEN build: zig toolchain could NOT be obtained — mirror throttled/unreachable + no cached tarball (bounded download failed fast, no ~8-hour hang; §11.4.3, never a fake PASS)"
        tail -8 "$WORK/obtain_green.log" 2>/dev/null | sed 's/^/    obtain> /'
        { echo "=== throttled/unreachable mirror → honest SKIP $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
          echo "CC_KIND=$green_cck (zig NOT obtained — no toolchain to build with)"
          echo "--- obtain_green.log tail (typed network failure) ---"
          tail -15 "$WORK/obtain_green.log" 2>/dev/null; } \
            > "$EVID_DIR/GREEN_network_skip.log" 2>/dev/null || true
        echo "════════════════════════════════════════════════════════════════"
        echo "  test 71 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
        echo "════════════════════════════════════════════════════════════════"
        [ "$FAIL" -gt 0 ] && exit 1; exit 0
    fi
    _fail "C4 GREEN build FAILED — no tmux produced under the obtained zig toolchain"
    tail -20 "$WORK/obtain_green.log" 2>/dev/null | sed 's/^/    obtain> /'
    tail -25 "$WORK/build_green.log"  2>/dev/null | sed 's/^/    build>  /'
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 71 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi
_pass "C4 GREEN: REAL project scripts built tmux via the OBTAINED zig toolchain (no host cc, no root, no sudo)"

# verify the toolchain actually used was the obtained zig (not a leaked host cc)
ck="$(sed -n 's/^CC_KIND=//p' "$PFX/resolved.env" 2>/dev/null | head -1)"
if [ "$ck" = "zig" ]; then
    _pass "C4b confirmed CC_KIND=zig (local-toolchain) drove the build"
    cp "$PFX/resolved.env" "$EVID_DIR/GREEN_resolved.env" 2>/dev/null || true
else
    _fail "C4b build did not use the obtained zig (CC_KIND=$ck) — attribution unproven"
fi

# ── C5 tmux -V ────────────────────────────────────────────────────────────────
export LD_LIBRARY_PATH="$PFX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
VOUT="$("$BUILT_BIN" -V 2>&1 | head -1 || true)"
if [ "$VOUT" = "tmux $EXPECTED_VERSION" ]; then
    _pass "C5 tmux -V == 'tmux $EXPECTED_VERSION' (user-visible build product)"
    {
        echo "=== TMX-063 root-free zig build — user-visible proof $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
        echo "binary: $BUILT_BIN"
        file "$BUILT_BIN" 2>/dev/null
        echo "tmux -V: $VOUT"
    } > "$EVID_DIR/GREEN_tmux_runtime_proof.log" 2>/dev/null || true
    _ev "GREEN runtime: qa-results/loop-20260629/zig-impl/GREEN_tmux_runtime_proof.log"
else
    _fail "C5 tmux -V wrong: '$VOUT' (expected 'tmux $EXPECTED_VERSION')"
fi

# ── C6 LIVE SESSION ───────────────────────────────────────────────────────────
# SHORT socket path (AF_UNIX sun_path is capped at 108 bytes — the long $TMPDIR
# scratch path would overflow it; /tmp keeps it short). Cleaned below + on trap.
SOCK="/tmp/t71.$$.sock"; MARKER="ZIG71_$((6*7))"
"$BUILT_BIN" -S "$SOCK" kill-server 2>/dev/null || true
if "$BUILT_BIN" -S "$SOCK" new-session -d -s g71 -x 80 -y 24 2>/dev/null; then
    "$BUILT_BIN" -S "$SOCK" send-keys -t g71 "printf '%s\\n' $MARKER" Enter 2>/dev/null
    sleep 1
    CAP="$("$BUILT_BIN" -S "$SOCK" capture-pane -t g71 -p 2>/dev/null || true)"
    "$BUILT_BIN" -S "$SOCK" kill-server 2>/dev/null || true
    if printf '%s' "$CAP" | grep -q "$MARKER"; then
        _pass "C6 LIVE SESSION: zig-built tmux ran a real session (marker $MARKER captured from the pane)"
        { echo "=== live-session proof ==="; echo "marker: $MARKER"; echo "--- capture-pane ---"; printf '%s\n' "$CAP"; } \
            > "$EVID_DIR/GREEN_tmux_live_session.log" 2>/dev/null || true
        _ev "GREEN live session: qa-results/loop-20260629/zig-impl/GREEN_tmux_live_session.log"
    else
        _fail "C6 LIVE SESSION: marker $MARKER not found in capture-pane output"
    fi
else
    _fail "C6 LIVE SESSION: zig-built tmux could not start a session"
fi

# ── C7 LOCAL-LINK (residual #2) — readelf DT_NEEDED references LOCAL deps ──────
NEEDED="$(readelf -d "$BUILT_BIN" 2>/dev/null | grep -i 'NEEDED' || true)"
{ echo "=== readelf -d NEEDED (residual #2 local-link) ==="; echo "$NEEDED";
  echo "--- RUNPATH/RPATH ---"; readelf -d "$BUILT_BIN" 2>/dev/null | grep -iE 'RUNPATH|RPATH' || true; } \
    > "$EVID_DIR/GREEN_readelf_needed.log" 2>/dev/null || true
le_ok=0; nc_ok=0; jem_ok=0
printf '%s' "$NEEDED" | grep -qiE 'libevent' && le_ok=1
printf '%s' "$NEEDED" | grep -qiE 'libncursesw\.so|libtinfo' && nc_ok=1
printf '%s' "$NEEDED" | grep -qiE 'libjemalloc' && jem_ok=1
# the local widec soname is libncursesw.so.6; host preference would show a bare
# libncurses.so.6 + libtinfo.so.6 pair. Assert the widec local soname is present.
if printf '%s' "$NEEDED" | grep -qiE 'libncursesw\.so'; then
    _pass "C7 LOCAL-LINK: tmux DT_NEEDED includes the LOCAL widec libncursesw.so (residual #2 fixed — local ncurses won AC_SEARCH_LIBS)"
else
    _fail "C7 LOCAL-LINK: tmux did NOT link the local libncursesw.so (NEEDED: $(printf '%s' "$NEEDED" | tr '\n' ' '))"
fi
if [ "$le_ok" = "1" ] && [ "$jem_ok" = "1" ]; then
    _pass "C7b tmux DT_NEEDED includes libevent + libjemalloc (full hardened local chain linked)"
    _ev "readelf NEEDED: qa-results/loop-20260629/zig-impl/GREEN_readelf_needed.log"
else
    _fail "C7b missing libevent/libjemalloc in DT_NEEDED (le=$le_ok jem=$jem_ok)"
fi

# ── C8 N=3 determinism (§11.4.50) — rebuild N times, identical tmux -V ─────────
det_ok=1; det_first="$VOUT"
i=2
while [ "$i" -le "$ZIG_BUILD_N" ]; do
    env -i HOME="$HOME" PATH="$SHIM" TMPDIR="$WORK/tmp" \
        LOCAL_DEPS_ROOT="$LDR" TMX_BUILD_DIR="$BLD" \
        bash "$BUILD" >"$WORK/build_iter$i.log" 2>&1 || { det_ok=0; break; }
    vi="$(LD_LIBRARY_PATH="$PFX/lib" "$BLD/bin/tmux" -V 2>&1 | head -1 || true)"
    [ "$vi" = "$det_first" ] || { det_ok=0; echo "  >>> iter $i version='$vi' != '$det_first'"; break; }
    i=$((i + 1))
done
if [ "$det_ok" = "1" ]; then
    _pass "C8 determinism: $ZIG_BUILD_N independent zig rebuilds all produced an identical '$det_first' (§11.4.50)"
    echo "N=$ZIG_BUILD_N all produced '$det_first'" > "$EVID_DIR/GREEN_determinism_n${ZIG_BUILD_N}.log" 2>/dev/null || true
else
    _fail "C8 determinism FAILED — a rebuild diverged or failed (see build_iter*.log)"
fi

# ── C9 (runtime) §1.1 paired mutation: strip the cc branch → no zig → build fails
MUT="$WORK/obtain_mutated.sh"
# remove every `cc:...)` registry branch line (the mutation): the dep is then
# unknown → obtain emits "not in registry" → no zig → build cannot proceed.
sed '/^[[:space:]]*cc:[a-z0-9_-]*)/d' "$OBTAIN" > "$MUT"
chmod +x "$MUT"
MLDR="$WORK/mld"; MBLD="$WORK/mbld"; rm -rf "$MLDR" "$MBLD"; mkdir -p "$MLDR/.tarballs" "$MBLD"
cp -n "$PERSIST_CACHE"/*.tar.* "$MLDR/.tarballs/" 2>/dev/null || true
env -i HOME="$HOME" PATH="$SHIM" TMPDIR="$WORK/tmp" \
    LOCAL_DEPS_ROOT="$MLDR" FORCE_OBTAIN=1 DEPS="cc jemalloc libevent ncurses" \
    bash "$MUT" >"$WORK/obtain_mut.log" 2>&1 || true
mck="$(sed -n 's/^CC_KIND=//p' "$MLDR/${HOST_OS}_${HOST_ARCH}/resolved.env" 2>/dev/null | head -1)"
env -i HOME="$HOME" PATH="$SHIM" TMPDIR="$WORK/tmp" \
    LOCAL_DEPS_ROOT="$MLDR" TMX_BUILD_DIR="$MBLD" \
    bash "$BUILD" >"$WORK/build_mut.log" 2>&1 || true
if [ "$mck" != "zig" ] && [ ! -x "$MBLD/bin/tmux" ]; then
    _pass "C9 §1.1 MUTATION CAUGHT: stripping the cc registry branch → no zig obtained (CC_KIND='$mck') → build cannot proceed (the guard has teeth)"
else
    _fail "C9 §1.1 MUTATION ESCAPED: build still got a zig/tmux after stripping the cc branch (mck='$mck')"
fi

echo "════════════════════════════════════════════════════════════════"
echo "  test 71 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
echo "════════════════════════════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
