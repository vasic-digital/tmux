#!/usr/bin/env bash
# run_all.sh — execute all tmux validation tests in sequence.
# Reports PASS / FAIL / SKIP totals; exits non-zero on any FAIL.
#
# Classification: scans test output for ANY line beginning with PASS/FAIL/SKIP.
# Priority: FAIL > SKIP > PASS (a test that FAILs anywhere counts as FAIL even
# if a later line says PASS). This catches early-exit failures correctly AND
# multi-line SKIP messages that have trailing context lines.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
EXPECTED_VERSION="${EXPECTED_VERSION:-3.6a}"
export TMUX_BIN WRAPPER EXPECTED_VERSION

# ── resolve obtained jemalloc for every raw-$TMUX_BIN test (NO patchelf) ──
# Each [0-9][0-9]_*.sh test runs the RAW binary directly (not via the tmx
# wrapper). On a host with NO system jemalloc and NO patchelf (amber: no
# sudo), the binary's DT_NEEDED libjemalloc.so.2 resolves ONLY if its libdir
# is on the loader search path. obtain_local_deps.sh wrote the resolved
# ABSOLUTE libdir into .local-deps/<plat>/resolved.env; export it so every
# child test inherits it (verify.sh exports the same — this is for the
# standalone `bash scripts/tests/run_all.sh` path). jemalloc STAYS DYNAMIC:
# this only adds a search dir, never a static link (§11.4.111; research
# Angle 2, docs/research/local_deps_20260628). No-op when resolved.env is
# absent or its libdir is already a default path (e.g. /lib64).
_LD_RESOLVED_ENV="$REPO_ROOT/.local-deps/$(uname -s)_$(uname -m)/resolved.env"
if [ -f "$_LD_RESOLVED_ENV" ]; then
    # shellcheck disable=SC1090
    . "$_LD_RESOLVED_ENV"
    if [ -n "${JEMALLOC_LIBDIR:-}" ]; then
        case "$(uname -s)" in
            Darwin) export DYLD_LIBRARY_PATH="${JEMALLOC_LIBDIR}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" ;;
            *)      export LD_LIBRARY_PATH="${JEMALLOC_LIBDIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
        esac
    fi
fi

# Augment PATH from npm's reported prefix so the codegraph tests (20/22) and
# codegraph_reindex.sh resolve `codegraph` even when run_all.sh is invoked from
# a NON-INTERACTIVE shell (SSH-batch, cron, CI). On hosts whose .bashrc adds
# ~/.npm-global/bin only AFTER an interactive-guard (`case $- in *i*) ;; *)
# return ;;`), a non-interactive shell never reaches that line, so codegraph is
# invisible and tests 20/22 FAIL spuriously while real (interactive) agent
# usage works. Mirrors the same A31 probe in setup.sh (Nezha fix 2026-05-21,
# generalised to run_all.sh 2026-05-29). Idempotent: no-op if already resolved.
if ! command -v codegraph >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    NPM_PREFIX="$(npm config get prefix 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$NPM_PREFIX" ] && [ -x "${NPM_PREFIX}/bin/codegraph" ]; then
        export PATH="${NPM_PREFIX}/bin:$PATH"
        echo "[run_all] PATH augmented with ${NPM_PREFIX}/bin (codegraph resolved)"
    fi
fi

if [ ! -x "$TMUX_BIN" ]; then
    echo "ERROR: TMUX_BIN $TMUX_BIN not executable. Build first: scripts/build_native.sh (macOS/Linux native) or scripts/build_containerized.sh (Linux container)?"
    exit 2
fi

PASS=0
FAIL=0
SKIP=0
FAIL_NAMES=""
SKIP_NAMES=""

echo "════════════════════════════════════════════════════════════════"
echo "  tmux validation suite (against $TMUX_BIN)"
echo "════════════════════════════════════════════════════════════════"

for t in "$REPO_ROOT/scripts/tests/"[0-9][0-9]_*.sh; do
    [ -f "$t" ] || continue
    name=$(basename "$t")
    echo ""
    # §11.4.98 non-interactive guarantee: sever each test's stdin from the
    # launcher (terminal / pipe). No test can EVER block on terminal input,
    # regardless of how run_all.sh is invoked (interactive shell, SSH-batch,
    # cron, CI). Tests that need a controlling terminal open /dev/tty
    # explicitly and SKIP-with-reason when absent; closing stdin is orthogonal.
    out=$(bash "$t" </dev/null 2>&1)
    echo "$out"
    # Classify: scan for first match of PASS/FAIL/SKIP at start of any line.
    # Priority: FAIL > SKIP > PASS.
    if echo "$out" | grep -qE '^FAIL'; then
        FAIL=$((FAIL+1)); FAIL_NAMES="$FAIL_NAMES $name"
    elif echo "$out" | grep -qE '^SKIP'; then
        SKIP=$((SKIP+1)); SKIP_NAMES="$SKIP_NAMES $name"
    elif echo "$out" | grep -qE '^PASS'; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1)); FAIL_NAMES="$FAIL_NAMES $name(unclassified)"
    fi
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  SUMMARY: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ -n "$SKIP_NAMES" ] && echo "  SKIPped:$SKIP_NAMES"
echo "════════════════════════════════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED tests:$FAIL_NAMES"
    exit 1
fi
exit 0
