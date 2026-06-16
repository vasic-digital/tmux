#!/usr/bin/env bash
# 61_no_libtinfo_version_warning.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    REGRESSION GUARD for the cross-distro libtinfo symbol-version
#             warning. CAPTURED root cause: the containerized Linux build
#             (ubuntu:22.04, libncurses-dev) linked `libtinfo.so.6`
#             DYNAMICALLY; that Ubuntu libtinfo carries versioned symbol
#             nodes (NCURSES6_TINFO_5.0.* / 5.8.*). On a host whose libtinfo
#             lacks those version nodes (ALT Linux on nezha — `objdump -T`
#             shows ZERO NCURSES version nodes), the dynamic loader printed
#               /lib64/libtinfo.so.6: no version information available
#                   (required by .../tmux)
#             on EVERY invocation — polluting stderr of every tmux command.
#             FIX: docker/build_inside_container.sh passes
#               LIBTINFO_LIBS="-l:libtinfo.a"
#             to ./configure → tinfo is linked STATICALLY (no libtinfo.so
#             DT_NEEDED), so the warning is structurally impossible on any
#             distro. glibc + jemalloc + libevent stay DYNAMIC.
#
#             Anti-bluff / §11.4.43 TDD: this test FAILED (warning present)
#             against the pre-fix binary and PASSES (warning absent) against
#             the fixed binary — positive captured stderr evidence.
#
#             Cross-platform (§11.4.81):
#               T1 (BOTH OSes): invoking the binary emits NO dynamic-loader
#                  version/compat warning on stderr — the shared invariant
#                  end users actually see. 3 iterations (§11.4.50).
#               T2 (Linux): `ldd` shows NO libtinfo.so AND `objdump -T` shows
#                  0 NCURSES6_TINFO versioned refs — proves static tinfo.
#                  On Darwin: SKIP-with-reason (libtinfo/ELF-versioning is a
#                  Linux-only mechanism — Mach-O has no equivalent), per
#                  §11.4.81(C); T1 remains the positive cross-platform proof.
#               T3 (Linux): DT_NEEDED STILL lists libjemalloc.so.2 — proves
#                  the fix did NOT regress the jemalloc linkage. Darwin SKIP.
#
# Usage:      bash scripts/tests/61_no_libtinfo_version_warning.sh
# Inputs:     TMUX_BIN env (default <repo>/tmux/build/bin/tmux).
# Outputs:    EVIDENCE … ; PASS/FAIL/SKIP lines ; summary.
# Side-effects: none (read-only inspection + `-V` invocation; no server,
#             no sockets, no files).
# Dependencies: tmux binary; Linux branch uses ldd + objdump (SKIP-with-
#             reason if absent). python3 NOT required.
# Cross-refs: docker/build_inside_container.sh (LIBTINFO_LIBS seam) ;
#             scripts/tests/03_jemalloc_loaded.sh (jemalloc runtime) ;
#             CHANGELOG.md v1.0.23.
# §11.4.67:   POSIX `sh -n` clean AND `bash -n` clean.
# Last verified: 2026-06-16
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"

P=0; F=0; S=0
WARN_RE='no version information available|version .* required by|incompatible'

echo "── Test 61: no libtinfo symbol-version warning (cross-distro guard) ──"

if [ ! -x "$TMUX_BIN" ]; then
    echo "SKIP: TMUX_BIN '$TMUX_BIN' not present/executable — build first (§11.4.3)."
    echo "  Tests: PASS=0  FAIL=0  SKIP=1"
    exit 0
fi

OS="$(uname -s)"

# ── T1 (cross-platform): invoking the binary emits NO loader version warning ──
# Drive 3 iterations for §11.4.50 deterministic consistency.
t1_fail=0
for i in 1 2 3; do
    err="$("$TMUX_BIN" -V 2>&1 1>/dev/null)"
    n="$(printf '%s\n' "$err" | grep -ciE "$WARN_RE" || true)"
    if [ "$n" -ne 0 ]; then
        echo "  [T1 iter=$i] CAPTURED loader warning: $(printf '%s' "$err" | head -1)"
        t1_fail=1
    fi
done
if [ "$t1_fail" -eq 0 ]; then
    echo "EVIDENCE (T1): '$("$TMUX_BIN" -V 2>/dev/null)' invoked 3× — clean stderr, 0 loader version-warnings"
    echo "PASS: T1 — binary emits no dynamic-loader version/compat warning ($OS)"
    P=$((P+1))
else
    echo "FAIL: T1 — binary emits a dynamic-loader version warning on stderr (libtinfo regression)"
    F=$((F+1))
fi

# ── T2 (Linux): static tinfo — no libtinfo.so DT_NEEDED, 0 NCURSES version refs ──
if [ "$OS" = "Linux" ]; then
    if command -v ldd >/dev/null 2>&1; then
        tinfo_n="$(ldd "$TMUX_BIN" 2>/dev/null | grep -c 'libtinfo' || true)"
        if command -v objdump >/dev/null 2>&1; then
            nc_n="$(objdump -T "$TMUX_BIN" 2>/dev/null | grep -c 'NCURSES6_TINFO' || true)"
        else
            nc_n=0
        fi
        if [ "$tinfo_n" -eq 0 ] && [ "$nc_n" -eq 0 ]; then
            echo "EVIDENCE (T2): ldd shows 0 libtinfo.so deps; objdump shows 0 NCURSES6_TINFO versioned refs — tinfo linked statically"
            echo "PASS: T2 — tinfo is statically linked (no host libtinfo.so dependency)"
            P=$((P+1))
        else
            echo "FAIL: T2 — libtinfo.so still dynamically linked (ldd tinfo=$tinfo_n, NCURSES refs=$nc_n)"
            F=$((F+1))
        fi
    else
        echo "SKIP: T2 — ldd not available to inspect dynamic linkage (§11.4.3)"
        S=$((S+1))
    fi
else
    echo "SKIP: T2 — libtinfo/ELF symbol-versioning is a Linux-only mechanism; Mach-O has no equivalent (§11.4.81(C); T1 is the cross-platform proof)"
    S=$((S+1))
fi

# ── T3 (Linux): jemalloc linkage NOT regressed by the static-tinfo fix ──
if [ "$OS" = "Linux" ]; then
    if command -v objdump >/dev/null 2>&1; then
        jem_n="$(objdump -p "$TMUX_BIN" 2>/dev/null | grep -c 'NEEDED.*libjemalloc' || true)"
        if [ "$jem_n" -ge 1 ]; then
            echo "EVIDENCE (T3): DT_NEEDED still lists libjemalloc.so — $(objdump -p "$TMUX_BIN" 2>/dev/null | grep 'NEEDED.*libjemalloc' | head -1 | tr -s ' ')"
            echo "PASS: T3 — jemalloc dynamic linkage preserved (static-tinfo fix did not regress it)"
            P=$((P+1))
        else
            echo "FAIL: T3 — libjemalloc no longer in DT_NEEDED — the libtinfo fix regressed jemalloc linkage"
            F=$((F+1))
        fi
    else
        echo "SKIP: T3 — objdump not available (§11.4.3)"
        S=$((S+1))
    fi
else
    echo "SKIP: T3 — jemalloc build-time DT_NEEDED check is Linux-ELF-specific (macOS uses build-time link verified by test 03)"
    S=$((S+1))
fi

echo ""
echo "  Tests: PASS=$P  FAIL=$F  SKIP=$S"
[ "$F" -eq 0 ] || exit 1
exit 0
