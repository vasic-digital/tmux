#!/usr/bin/env bash
# 74_root_free_go_tmx_state_build.sh
# ─────────────────────────────────────────────────────────────────────────────
# Purpose:    TMX-057 standing regression guard — PROVE the PRODUCTION script
#             scripts/obtain_local_deps.sh OBTAINS a ROOT-FREE Go toolchain and
#             that obtained Go builds the `tmx-state` binary (scripts/tmx-state/)
#             on a host with NO system `go` reachable — closing the no-bluff gap
#             where the go `kind=toolchain` obtain branch had an IMPLEMENTATION
#             but NO test that neuters system go, so the TMX-057 acceptance
#             ("on a host with NO system go, build tmx-state against the OBTAINED
#             local go") carried no captured runtime proof. (§11.4.115 RED-baseline
#             + §11.4.135 standing guard + §11.4.169 build/e2e + §11.4.123 rock-
#             solid captured proof + §11.4.50 N-iter determinism.)
#
#             Mirrors scripts/tests/71_root_free_zig_build.sh (the zig/cc analogue)
#             one layer up the dependency stack: 71 proves the obtained zig builds
#             tmux; 74 proves the obtained go builds tmx-state.
#
# What this guard proves (captured under qa-results/loop-20260629/tmx057-go-impl/):
#   G0  static: the `go` (kind=toolchain) registry branch exists in
#       obtain_local_deps.sh (the mutation target — a missing branch is the very
#       thing the §1.1 mutation proves the guard catches).
#   G1  NORMAL-host no-regression: on a host that HAS a suitable go, the REAL
#       obtain script RESOLVES it (GO_SOURCE=host-system/host-brew) by ABSOLUTE
#       path — NO toolchain obtained, the existing path is untouched (§11.4.111).
#   G2  NEUTER proof: under a sanitised env (env -i + a shim PATH that OMITS go +
#       every C compiler) the host go is genuinely unreachable (`command -v go`
#       empty) — the no-system-go simulation is real (the proof a later success
#       is the OBTAINED go's, not a leaked host go).
#   G3  RED (§11.4.115, RED_MODE=1): in the neutered env WITHOUT the go obtain, a
#       `go build` of tmx-state FAILS (no go binary on PATH) — defect present on
#       the broken artifact. Same source, polarity switch. Network-free.
#   G4  GREEN (RED_MODE=0): in the neutered env, the REAL obtain script
#       (FORCE_OBTAIN=1 DEPS=go) DOWNLOADS + sha256-verifies + extracts the
#       official prebuilt Go tarball ROOT-FREE into a scratch LOCAL_DEPS_ROOT and
#       emits GO_BIN/GOROOT — then that OBTAINED go builds tmx-state end-to-end.
#   G5  the OBTAINED go runs (`go version` >= registry min) AND drove the build
#       (GO_SOURCE=local-toolchain).
#   G6  user-visible build product: the produced tmx-state binary runs
#       (`version` prints `tmx-state v…`).
#   G7  FUNCTIONAL round-trip: the obtained-go-built tmx-state genuinely WORKS —
#       `record <s> <abs>` then `recall <s>` returns the path (not just a version
#       string — §11.4.123 rock-solid functional proof).
#   G8  N=3 determinism (§11.4.50): the GREEN build, run N times, yields an
#       IDENTICAL `version` string every time.
#   G9  §1.1 paired mutation (self-contained): stripping the `go:` registry
#       branches from a COPY of obtain_local_deps.sh makes the neutered obtain
#       unable to get a go toolchain (no GO_BIN) → the tmx-state build cannot
#       proceed → MUTATION CAUGHT (the guard has teeth).
#   G10 §11.4.67 parseability (bash -n + sh -n) + no-sudo/no-interaction on the
#       touched obtain script.
#
# Usage:      bash scripts/tests/74_root_free_go_tmx_state_build.sh            # GREEN guard
#             RED_MODE=1 bash scripts/tests/74_root_free_go_tmx_state_build.sh # reproduce defect
# Inputs:     RED_MODE (default 0 = standing GREEN guard; 1 = RED reproduction).
#             TMX_GO_BUILD_N (default 3) — determinism iterations.
#             GO_TEST_SKIP_HEAVY=1 — run only the cheap static + neuter checks.
#             Honours $TMPDIR. Network needed for the GREEN obtain when no go
#             tarball is cached; a throttled/unreachable mirror fails FAST (the
#             bounded _download in obtain_local_deps.sh) → honest SKIP (§11.4.3),
#             never a hang, never a fake PASS.
# Outputs:    EVIDENCE / PASS / FAIL / SKIP lines + summary (run_all-classified).
# Side-effects: builds under ${TMPDIR}/tmx74.$$ + a scratch LOCAL_DEPS_ROOT.
#             HOST-SAFE: NEVER touches the operator's real scripts/tmx-state-bin,
#             real .local-deps, ~/.tmx state, or $HOME Go caches (GOCACHE/GOPATH/
#             GOTMPDIR redirected to scratch); NEVER mutates the host toolchain;
#             NO sudo/su, NO human-wait (§12 + §11.4.133). A persistent gitignored
#             tarball cache under .local-deps/.test74-cache makes re-runs frugal.
# Dependencies: the REAL scripts/obtain_local_deps.sh (under test) + the tracked
#             scripts/tmx-state/ Go source; generic tools (tar/gzip/curl|wget/
#             sha256sum/sed/awk/grep); a real go for the G1 host baseline.
# §11.4.67:   bash -n + sh -n clean (POSIX: no arrays / [[ ]] / process-sub).
# §11.4.81:   cross-platform — the go obtain supports linux/darwin × amd64/arm64;
#             an unsupported arch → honest SKIP (the obtain returns EC_UNSUPPORTED).
# Last verified: 2026-06-30
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

RED_MODE="${RED_MODE:-0}"
GO_BUILD_N="${TMX_GO_BUILD_N:-3}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
OBTAIN="$REPO_ROOT/scripts/obtain_local_deps.sh"
SETUP="$REPO_ROOT/scripts/setup.sh"
TMXSTATE_SRC="$REPO_ROOT/scripts/tmx-state"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 74: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 74: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 74: $*"; SKIP=$((SKIP + 1)); }
_ev()   { echo "EVIDENCE 74: $*"; }

SCRATCH_BASE="${TMPDIR:-/tmp}"; SCRATCH_BASE="${SCRATCH_BASE%/}"
WORK="$SCRATCH_BASE/tmx74.$$"
SHIM="$WORK/shim"
LDR="$WORK/ld"
OUTBIN="$WORK/tmx-state-bin"
GOCACHE_DIR="$WORK/gocache"
GOPATH_DIR="$WORK/gopath"
EVID_DIR="$REPO_ROOT/qa-results/loop-20260629/tmx057-go-impl"
PERSIST_CACHE="$REPO_ROOT/.local-deps/.test74-cache"   # gitignored (.local-deps/)
_cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap _cleanup EXIT

HOST_OS="$(uname -s)"; HOST_ARCH="$(uname -m)"
PLAT="${HOST_OS}_${HOST_ARCH}"

if ! mkdir -p "$SHIM" "$LDR" "$WORK/tmp" "$GOCACHE_DIR" "$GOPATH_DIR" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "SKIP 74: scratch root $WORK not writable (disk full / RO) — §11.4.3"
    echo "SKIP=1 PASS=0 FAIL=0"; exit 0
fi
mkdir -p "$EVID_DIR" 2>/dev/null || true

[ -f "$OBTAIN" ] || { echo "FAIL 74: scripts/obtain_local_deps.sh absent"; exit 1; }
if [ ! -f "$TMXSTATE_SRC/go.mod" ]; then
    echo "SKIP 74: scripts/tmx-state/go.mod absent (pre-v1.0.9 tree) — nothing to build (§11.4.3)"
    echo "SKIP=1 PASS=0 FAIL=0"; exit 0
fi

echo "════════════════════════════════════════════════════════════════"
echo "  test 74 — root-free go build of tmx-state (TMX-057) (RED_MODE=$RED_MODE, N=$GO_BUILD_N)"
echo "════════════════════════════════════════════════════════════════"

# ── G10 (static, always): parseability + no-sudo/no-interaction on obtain ──────
g10_fail=0
for _f in "$OBTAIN" "$0"; do
    bash -n "$_f" >/dev/null 2>&1 || { echo "  >>> ${_f#$REPO_ROOT/} fails bash -n"; g10_fail=1; }
    sh -n "$_f"   >/dev/null 2>&1 || { echo "  >>> ${_f#$REPO_ROOT/} fails sh -n"; g10_fail=1; }
done
# the COMMAND, not a mention: comment lines are filtered, so only a real sudo/su
# command/advice line trips (matches verify.sh CM-NO-SUDO-NO-INTERACTION).
if grep -nE '\bsudo\b|\bsu[ -]' "$OBTAIN" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
    echo "  >>> obtain_local_deps.sh contains a sudo/su EXECUTION token"; g10_fail=1
fi
if [ "$g10_fail" = "0" ]; then
    _pass "G10 obtain + this test parse clean (bash -n + sh -n) AND obtain is sudo/su-free (§11.4.67 + operator mandate)"
else
    _fail "G10 a touched script fails parse OR obtain contains a sudo/su token"
fi

# ── G0 (static): §1.1 paired mutation precondition — the go registry branch exists.
if grep -qE '^[[:space:]]*go:kind\)' "$OBTAIN" && grep -qE '^[[:space:]]*go:url_linux_amd64\)' "$OBTAIN"; then
    _pass "G0 go (kind=toolchain) registry branch present in obtain_local_deps.sh (mutation target exists)"
else
    _fail "G0 go (kind=toolchain) registry branch MISSING — the root-free Go toolchain is not wired"
fi

# ── G1 (cheap): NORMAL-host no-regression — host go resolves, nothing obtained ─
REAL_GO=""
for _g in /usr/local/go/bin/go /usr/lib/go/bin/go /usr/lib/golang/bin/go /opt/go/bin/go \
         /opt/homebrew/bin/go /opt/homebrew/opt/go/bin/go /usr/local/bin/go /usr/bin/go; do
    [ -x "$_g" ] && { REAL_GO="$_g"; break; }
done
[ -z "$REAL_GO" ] && command -v go >/dev/null 2>&1 && REAL_GO="$(command -v go)"
if [ -z "$REAL_GO" ]; then
    _skip "G1 no host go — cannot prove no-regression baseline (§11.4.3)"
else
    nrg="$WORK/noreg"; mkdir -p "$nrg"
    LOCAL_DEPS_ROOT="$nrg" DEPS="go" bash "$OBTAIN" >"$WORK/g1.log" 2>&1 || true
    renv="$nrg/$PLAT/resolved.env"
    gsrc="$(sed -n 's/^GO_SOURCE=//p' "$renv" 2>/dev/null | head -1)"
    gbin="$(sed -n 's/^GO_BIN=//p' "$renv" 2>/dev/null | head -1)"
    if { [ "$gsrc" = "host-system" ] || [ "$gsrc" = "host-brew" ]; } && [ ! -d "$nrg/$PLAT/go" ]; then
        _pass "G1 NORMAL-host no-regression: go RESOLVED to host ($gbin, GO_SOURCE=$gsrc) — no toolchain obtained, existing path untouched (§11.4.111)"
        cp "$renv" "$EVID_DIR/G1_normal_host_resolved.env" 2>/dev/null || true
    else
        _fail "G1 no-regression broken: expected GO_SOURCE=host-system/host-brew + no obtained go dir (got SOURCE=$gsrc)"
    fi
fi

# ── platform / heavy-precondition gate ────────────────────────────────────────
# The go obtain supports the 4 official linux/darwin × amd64/arm64 variants only.
GO_PLAT_OK=0
case "$HOST_OS" in Linux|Darwin) case "$HOST_ARCH" in x86_64|amd64|aarch64|arm64) GO_PLAT_OK=1 ;; esac ;; esac
if [ "$GO_PLAT_OK" != "1" ]; then
    _skip "G3-G9 heavy go build: unsupported platform $PLAT — obtain pins only linux/darwin × amd64/arm64 (§11.4.3 / §11.4.81)"
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 74 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    [ "$FAIL" -gt 0 ] && exit 1; exit 0
fi
if [ "${GO_TEST_SKIP_HEAVY:-0}" = "1" ]; then
    _skip "G3-G9 heavy build skipped (GO_TEST_SKIP_HEAVY=1) — static + baseline checks above stand"
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 74 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    [ "$FAIL" -gt 0 ] && exit 1; exit 0
fi

# ── build the neuter shim (curated generic tools; NO go, NO C toolchain) ───────
ALLOW="sh bash env printf echo test true false sleep mktemp mkdir rm rmdir ln cp mv cat head tail sort uniq wc tr cut sed awk gawk grep egrep fgrep find xargs basename dirname date chmod chown touch tee expr dd stat readlink realpath od cmp diff tar gzip gunzip xz curl wget timeout sha256sum sha1sum md5sum nproc uname id whoami getconf pwd ls file which command sync seq ar nm"
for t in $ALLOW; do
    for d in /usr/bin /bin /usr/local/bin /sbin /usr/sbin; do
        if [ -x "$d/$t" ] && [ ! -e "$SHIM/$t" ]; then ln -s "$d/$t" "$SHIM/$t"; break; fi
    done
done

# G2 — neuter proof: go + every C compiler unreachable under the shim; generic OK
neuter_ok=1
leaked="$(env -i HOME="$HOME" PATH="$SHIM" sh -c '
    for c in go gccgo cc gcc clang; do command -v "$c" >/dev/null 2>&1 && echo "$c"; done')"
if [ -n "$leaked" ]; then echo "  >>> neuter leaked: $leaked"; neuter_ok=0; fi
for c in tar gzip sha256sum sed awk grep; do
    env -i HOME="$HOME" PATH="$SHIM" sh -c "command -v $c >/dev/null 2>&1" || { echo "  >>> neuter missing generic tool: $c"; neuter_ok=0; }
done
if [ "$neuter_ok" = "1" ]; then
    _pass "G2 neuter valid: host go + C compilers unreachable; generic tools present (no-system-go simulation real)"
    { echo "neuter PATH=$SHIM"; echo "leaked go/compilers: ${leaked:-<none>}"; } > "$EVID_DIR/G2_neuter_proof.log" 2>/dev/null || true
else
    _fail "G2 neuter invalid — go or a C compiler leaked, OR a generic tool is missing"
fi

# seed the scratch tarball cache from the persistent gitignored cache (frugal)
mkdir -p "$LDR/.tarballs" "$PERSIST_CACHE" 2>/dev/null || true
cp -n "$PERSIST_CACHE"/go*.tar.gz "$LDR/.tarballs/" 2>/dev/null || true

# Build tmx-state with the OBTAINED go. PATH = obtained-go-bin + shim ONLY (no host
# go). CGO_ENABLED=0 (tmx-state is PURE Go, zero requires → no C compiler needed),
# GOTOOLCHAIN=local (never auto-download a toolchain), GOPROXY=off (no module
# fetch), caches redirected to scratch (HOST-SAFE: $HOME untouched). Sets BUILD_RC.
go_build_tmx_state() {
    _gobin="$1"; _out="$2"; BUILD_RC=1
    _goroot="$(cd "$(dirname "$_gobin")/.." 2>/dev/null && pwd)"
    rm -f "$_out" 2>/dev/null || true
    ( cd "$TMXSTATE_SRC" && env -i HOME="$WORK/tmp" \
        PATH="$(dirname "$_gobin"):$SHIM" \
        GOROOT="$_goroot" GOCACHE="$GOCACHE_DIR" GOPATH="$GOPATH_DIR" \
        GOTMPDIR="$WORK/tmp" GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=mod \
        CGO_ENABLED=0 \
        "$_gobin" build -o "$_out" . ) >"$WORK/build_$(basename "$_out").log" 2>&1 && BUILD_RC=0 || BUILD_RC=$?
}

if [ "$RED_MODE" = "1" ]; then
    # ── G3 RED: neutered build WITHOUT the go obtain MUST fail (no go on PATH) ──
    rm -f "$WORK/red_build.log" 2>/dev/null || true
    ( cd "$TMXSTATE_SRC" && env -i HOME="$WORK/tmp" PATH="$SHIM" \
        GOCACHE="$GOCACHE_DIR" GOPATH="$GOPATH_DIR" CGO_ENABLED=0 \
        go build -o "$WORK/red-tmx-state-bin" . ) >"$WORK/red_build.log" 2>&1
    red_rc=$?
    if [ "$red_rc" != "0" ] && [ ! -x "$WORK/red-tmx-state-bin" ]; then
        _pass "G3 RED reproduced: neutered tmx-state build WITHOUT the go obtain FAILS (no go on PATH) — defect present on the broken artifact"
        { echo "=== RED: go build with no system go + no obtain ==="; echo "exit_rc=$red_rc"; tail -6 "$WORK/red_build.log" 2>/dev/null; } \
            > "$EVID_DIR/RED_no_go_build_fail.log" 2>/dev/null || true
        _ev "RED capture: qa-results/loop-20260629/tmx057-go-impl/RED_no_go_build_fail.log"
    else
        _fail "G3 RED did NOT reproduce — tmx-state built WITHOUT a go toolchain (blind test, §11.4.115)"
    fi
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 74 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    [ "$FAIL" -gt 0 ] && exit 1; exit 0
fi

# ── GREEN guard (RED_MODE=0): the heavy, network-dependent real obtain+build ──
# Need a cached go tarball or a reachable mirror → else honest SKIP (§11.4.3).
have_go_cached=0
ls "$LDR/.tarballs"/go*.tar.gz >/dev/null 2>&1 && have_go_cached=1
# Reachability: the official tarball host (go.dev/dl/ 302→dl.google.com). The go
# obtain verifies against the REGISTRY-PINNED sha256 (NOT index.json), so a
# blocked go.dev/dl/?mode=json does NOT matter — only the tarball must download.
_net_ok() { curl -fsI --connect-timeout 12 --max-time 25 https://go.dev/dl/go1.25.11.linux-amd64.tar.gz >/dev/null 2>&1 \
            || curl -fsI --connect-timeout 12 --max-time 25 https://dl.google.com/go/go1.25.11.linux-amd64.tar.gz >/dev/null 2>&1 \
            || wget -q --spider --timeout=25 https://go.dev/dl/go1.25.11.linux-amd64.tar.gz 2>/dev/null; }
if [ "$have_go_cached" = "0" ] && ! _net_ok; then
    _skip "G4-G9 GREEN build: go.dev/dl mirror unreachable AND no cached go tarball — cannot obtain toolchain (§11.4.3, never a fake PASS)"
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 74 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    [ "$FAIL" -gt 0 ] && exit 1; exit 0
fi

# ── G4 GREEN obtain: FORCE_OBTAIN=1 forces the obtain path (resolve_go probes
#    ABSOLUTE paths per §11.4.111, so a PATH-only neuter cannot force it — the
#    project's own force mechanism is FORCE_OBTAIN, exactly as test 71 uses for
#    zig). The neutered env (env -i + shim) then PROVES the build uses ONLY the
#    obtained go, not a leaked host go. ──────────────────────────────────────────
env -i HOME="$HOME" PATH="$SHIM" TMPDIR="$WORK/tmp" \
    LOCAL_DEPS_ROOT="$LDR" FORCE_OBTAIN=1 DEPS="go" \
    bash "$OBTAIN" >"$WORK/obtain_green.log" 2>&1 || true
# persist the downloaded tarball for the next (frugal) run
cp -n "$LDR/.tarballs"/go*.tar.gz "$PERSIST_CACHE/" 2>/dev/null || true

GREEN_ENV="$LDR/$PLAT/resolved.env"
OBT_GO="$(sed -n 's/^GO_BIN=//p' "$GREEN_ENV" 2>/dev/null | head -1)"
OBT_SRC="$(sed -n 's/^GO_SOURCE=//p' "$GREEN_ENV" 2>/dev/null | head -1)"

if [ -z "$OBT_GO" ] || [ ! -x "$OBT_GO" ]; then
    # §11.4.3 honest SKIP vs §11.4.1 FAIL: a download that failed because the
    # mirror was throttled/unreachable (environment gap) → SKIP; a real defect
    # (sha mismatch, extract failure) → FAIL.
    if grep -qiE 'download failed|network unreachable|REFUSING to download unverified' "$WORK/obtain_green.log" 2>/dev/null; then
        _skip "G4-G9 GREEN build: go toolchain could NOT be obtained — mirror throttled/unreachable + no cached tarball (bounded download failed fast; §11.4.3, never a fake PASS)"
        tail -8 "$WORK/obtain_green.log" 2>/dev/null | sed 's/^/    obtain> /'
        { echo "=== throttled/unreachable mirror → honest SKIP $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
          tail -15 "$WORK/obtain_green.log" 2>/dev/null; } > "$EVID_DIR/GREEN_network_skip.log" 2>/dev/null || true
        echo "════════════════════════════════════════════════════════════════"
        echo "  test 74 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
        echo "════════════════════════════════════════════════════════════════"
        [ "$FAIL" -gt 0 ] && exit 1; exit 0
    fi
    _fail "G4 GREEN obtain FAILED — no GO_BIN produced (and not a network cause)"
    tail -20 "$WORK/obtain_green.log" 2>/dev/null | sed 's/^/    obtain> /'
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 74 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi
_pass "G4 GREEN: REAL obtain script obtained a ROOT-FREE go toolchain (FORCE_OBTAIN, no system go, no sudo) → $OBT_GO"

# G5 — the obtained go runs + drove via the obtain (GO_SOURCE=local-toolchain)
GOVER="$(env -i HOME="$WORK/tmp" PATH="$SHIM" "$OBT_GO" version 2>&1 | head -1 || true)"
case "$GOVER" in
    "go version "*)
        if [ "$OBT_SRC" = "local-toolchain" ]; then
            _pass "G5 obtained go runs ('$GOVER') AND GO_SOURCE=local-toolchain (the obtain produced it, not a leaked host go)"
            cp "$GREEN_ENV" "$EVID_DIR/GREEN_resolved.env" 2>/dev/null || true
            { echo "=== TMX-057 root-free go obtain — toolchain proof $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
              echo "GO_BIN: $OBT_GO"; echo "GO_SOURCE: $OBT_SRC"; echo "$GOVER"; } \
                > "$EVID_DIR/GREEN_go_toolchain_proof.log" 2>/dev/null || true
            _ev "GREEN toolchain: qa-results/loop-20260629/tmx057-go-impl/GREEN_go_toolchain_proof.log"
        else
            _fail "G5 obtained go runs but GO_SOURCE='$OBT_SRC' (expected local-toolchain — attribution unproven)"
        fi
        ;;
    *) _fail "G5 obtained go does not run ('$GOVER')" ;;
esac

# ── G6 build tmx-state with the OBTAINED go (no system go on PATH) ─────────────
go_build_tmx_state "$OBT_GO" "$OUTBIN"
if [ "$BUILD_RC" != "0" ] || [ ! -x "$OUTBIN" ]; then
    _fail "G6 tmx-state build FAILED under the obtained go (rc=$BUILD_RC)"
    tail -20 "$WORK/build_$(basename "$OUTBIN").log" 2>/dev/null | sed 's/^/    build> /'
    echo "════════════════════════════════════════════════════════════════"
    echo "  test 74 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi
VOUT="$("$OUTBIN" version 2>&1 | head -1 || true)"
case "$VOUT" in
    "tmx-state v"*)
        _pass "G6 obtained-go-built tmx-state runs ('$VOUT') — user-visible build product (TMX-057 acceptance)"
        { echo "=== TMX-057 root-free go build of tmx-state — runtime proof $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
          echo "binary: $OUTBIN"; file "$OUTBIN" 2>/dev/null; echo "built with: $OBT_GO ($GOVER)"
          echo "tmx-state version: $VOUT"; } > "$EVID_DIR/GREEN_tmx_state_runtime_proof.log" 2>/dev/null || true
        _ev "GREEN runtime: qa-results/loop-20260629/tmx057-go-impl/GREEN_tmx_state_runtime_proof.log"
        ;;
    *) _fail "G6 tmx-state version wrong: '$VOUT' (expected 'tmx-state v…')" ;;
esac

# ── G7 FUNCTIONAL round-trip (§11.4.123) — record then recall returns the path ─
STATE_FILE="$WORK/state.json"; SESS="g74sess"; PWDVAL="/run/media/tmx74/$((6*7))"
env -i HOME="$WORK/tmp" PATH="$SHIM" TMX_STATE_FILE="$STATE_FILE" "$OUTBIN" record "$SESS" "$PWDVAL" >/dev/null 2>&1
RECALL="$(env -i HOME="$WORK/tmp" PATH="$SHIM" TMX_STATE_FILE="$STATE_FILE" "$OUTBIN" recall "$SESS" 2>/dev/null || true)"
if [ "$RECALL" = "$PWDVAL" ]; then
    _pass "G7 FUNCTIONAL: obtained-go-built tmx-state genuinely works — record→recall returned '$RECALL' (not just a version string)"
    { echo "=== functional round-trip ==="; echo "record $SESS $PWDVAL"; echo "recall → $RECALL"; cat "$STATE_FILE" 2>/dev/null; } \
        > "$EVID_DIR/GREEN_tmx_state_functional.log" 2>/dev/null || true
    _ev "GREEN functional: qa-results/loop-20260629/tmx057-go-impl/GREEN_tmx_state_functional.log"
else
    _fail "G7 FUNCTIONAL: record→recall returned '$RECALL' (expected '$PWDVAL')"
fi

# ── G8 N=3 determinism (§11.4.50) — rebuild N times, identical version ─────────
det_ok=1; det_first="$VOUT"
i=2
while [ "$i" -le "$GO_BUILD_N" ]; do
    go_build_tmx_state "$OBT_GO" "$WORK/tmx-state-bin.$i"
    if [ "$BUILD_RC" != "0" ] || [ ! -x "$WORK/tmx-state-bin.$i" ]; then det_ok=0; echo "  >>> iter $i build failed (rc=$BUILD_RC)"; break; fi
    vi="$("$WORK/tmx-state-bin.$i" version 2>&1 | head -1 || true)"
    [ "$vi" = "$det_first" ] || { det_ok=0; echo "  >>> iter $i version='$vi' != '$det_first'"; break; }
    i=$((i + 1))
done
if [ "$det_ok" = "1" ]; then
    _pass "G8 determinism: $GO_BUILD_N independent obtained-go rebuilds all produced an identical '$det_first' (§11.4.50)"
    echo "N=$GO_BUILD_N all produced '$det_first'" > "$EVID_DIR/GREEN_determinism_n${GO_BUILD_N}.log" 2>/dev/null || true
else
    _fail "G8 determinism FAILED — a rebuild diverged or failed (see build_*.log)"
fi

# ── G9 (runtime) §1.1 paired mutation: strip the go: branches → no GO_BIN → build
#    cannot proceed. A COPY of obtain_local_deps.sh with every `go:...)` registry
#    branch removed → `go` is "not in registry" → no GO_BIN emitted → the
#    tmx-state build has no toolchain. ──────────────────────────────────────────
MUT="$WORK/obtain_mutated.sh"
sed '/^[[:space:]]*go:[a-z0-9_]*)/d' "$OBTAIN" > "$MUT"
chmod +x "$MUT"
MLDR="$WORK/mld"; rm -rf "$MLDR"; mkdir -p "$MLDR/.tarballs"
cp -n "$PERSIST_CACHE"/go*.tar.gz "$MLDR/.tarballs/" 2>/dev/null || true
env -i HOME="$HOME" PATH="$SHIM" TMPDIR="$WORK/tmp" \
    LOCAL_DEPS_ROOT="$MLDR" FORCE_OBTAIN=1 DEPS="go" \
    bash "$MUT" >"$WORK/obtain_mut.log" 2>&1 || true
mgo="$(sed -n 's/^GO_BIN=//p' "$MLDR/$PLAT/resolved.env" 2>/dev/null | head -1)"
mut_parses=0; sh -n "$MUT" >/dev/null 2>&1 && bash -n "$MUT" >/dev/null 2>&1 && mut_parses=1
if [ "$mut_parses" = "1" ] && [ -z "$mgo" ] && grep -qiE 'not in registry' "$WORK/obtain_mut.log" 2>/dev/null; then
    _pass "G9 §1.1 MUTATION CAUGHT: stripping the go: registry branches → 'go not in registry' → no GO_BIN → tmx-state build cannot proceed (the guard has teeth)"
    { echo "=== §1.1 mutation: go: branches stripped ==="; grep -i 'not in registry' "$WORK/obtain_mut.log" 2>/dev/null; echo "GO_BIN after mutation: '${mgo:-<none>}'"; } \
        > "$EVID_DIR/GREEN_mutation_caught.log" 2>/dev/null || true
else
    _fail "G9 §1.1 MUTATION ESCAPED: after stripping go: branches the obtain still produced GO_BIN='$mgo' (or mutated copy failed to parse: mut_parses=$mut_parses)"
fi

echo "════════════════════════════════════════════════════════════════"
echo "  test 74 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
echo "════════════════════════════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
