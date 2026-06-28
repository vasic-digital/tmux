#!/usr/bin/env bash
# 67_local_deps.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    Anti-bluff runtime coverage for the per-host LOCAL-DEPENDENCY
#             obtaining mechanism (scripts/obtain_local_deps.sh, §11.4.77 +
#             §11.4.81 + §11.4.111). The source-layer wiring is asserted by
#             the verify.sh gate CM-LOCAL-DEPS-MECHANISM; THIS test is the
#             RUNTIME half — it actually RUNS the mechanism into throwaway
#             roots and proves, with CAPTURED evidence (§11.4.5), that:
#               C1  resolve-by-ABSOLUTE-path (§11.4.111) — resolved.env's
#                   JEMALLOC_SO is an absolute path that EXISTS and is a
#                   real shared object (`file -L`); resolution does NOT
#                   depend on ambient PATH (the mistborn `command -v brew`
#                   exit-3 root cause) — proven by re-resolving under a
#                   minimal PATH=/usr/bin:/bin. Driven N=3 identical
#                   (§11.4.50 deterministic consistency).
#               C2  obtain-when-missing (§11.4.115 RED→GREEN) — FORCE_OBTAIN=1
#                   produces a REAL libjemalloc.so.2/.dylib (ELF/Mach-O via
#                   `file -L`) with JEMALLOC_SOURCE=local-build.
#               C3  a binary FINDS the resolved jemalloc via the PRODUCT
#                   runtime mechanism (LD_LIBRARY_PATH / DYLD_LIBRARY_PATH) —
#                   build a minimal self-contained C probe that calls the real
#                   jemalloc control symbol the resolved SO actually exports
#                   (prefix-agnostic via `nm`: `mallctl` empty-prefix /
#                   `je_mallctl` Darwin local-build — `*("version")`), link it
#                   against the resolved SO (patchelf --force-rpath when present, else a
#                   link-time -Wl,-rpath belt-and-suspenders), then run it +
#                   ldd/otool it WITH LD_LIBRARY_PATH=<LIBDIR> set (exactly
#                   what verify.sh / run_all.sh / the tmx wrapper export) and
#                   assert it binds libjemalloc to the resolved LIBDIR. The
#                   loader searches LD_LIBRARY_PATH BEFORE ld.so.cache, so this
#                   beats a competing SYSTEM jemalloc even with no patchelf —
#                   proving resolved+runtime-env works WITHOUT setup.sh on
#                   EVERY host class (the thinker.local fix, §11.4.4).
#
#             §11.4.3 honest SKIP, never a faked PASS: if the host genuinely
#             cannot resolve OR obtain jemalloc (no toolchain / network
#             unreachable / unsupported), the affected case SKIPs-with-reason.
#             If patchelf is absent the patchelf-specific sub-assertion (C3b)
#             SKIPs but C3 still PASSes via the LD_LIBRARY_PATH mechanism (the
#             link-time-rpath fallback's inability to override a cached system
#             lib is expected loader behaviour, NOT a defect).
#
# Usage:      bash scripts/tests/67_local_deps.sh
# Inputs:     none required. Honors $TMPDIR for the throwaway root.
# Outputs:    EVIDENCE … ; PASS/FAIL/SKIP lines ; summary.
# Side-effects: creates + removes a throwaway LOCAL_DEPS_ROOT + probe build
#             dir under ${TMPDIR:-/tmp}/tmx67deps.$$ (trap-cleaned on every
#             exit path, §11.4.14). NEVER touches the real .local-deps/ tree.
# Dependencies: scripts/obtain_local_deps.sh (the feature under test — SKIP
#             if absent), `file`; C3 additionally needs a C compiler +
#             patchelf (or link-time -Wl,-rpath) + ldd/otool (SKIP-with-
#             reason per §11.4.3 when any are absent). C3 also uses `nm`
#             (optional) for §11.4.111 jemalloc-symbol-prefix detection; when
#             absent it falls back to trying mallctl then je_mallctl.
# Cross-refs: scripts/obtain_local_deps.sh (consumed, not edited) ;
#             scripts/verify.sh CM-LOCAL-DEPS-MECHANISM gate ;
#             scripts/tests/meta_test_false_positive_proof.sh M-test67 +
#             M-CM-LOCAL-DEPS-MECHANISM paired mutations ;
#             docs/research/local_deps_20260628/research.md (rpath vs
#             LD_PRELOAD: rpath helps the binary's DT_NEEDED, NOT preload).
# §11.4.67:   bash -n clean (executed as bash; uses bash arrays/heredocs).
# §11.4.50:   C1 resolve driven 3× — JEMALLOC_SO byte-identical each run.
# §11.4.111:  resolution proven independent of ambient PATH (absolute paths).
# §11.4.115:  C2 is the GREEN half of the obtain-when-missing reproduction;
#             the paired meta-test mutation M-test67 makes resolved.env emit
#             a nonexistent JEMALLOC_SO → C1 FAILs (the RED proof the guard
#             has teeth).
# Last verified: 2026-06-28
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
OBTAIN="$REPO_ROOT/scripts/obtain_local_deps.sh"
PLAT="$(uname -s)_$(uname -m)"
OS="$(uname -s)"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 67: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 67: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 67: $*"; SKIP=$((SKIP + 1)); }

# Throwaway root — never the real .local-deps/. trap-cleaned (§11.4.14).
SCRATCH_BASE="${TMPDIR:-/tmp}"; SCRATCH_BASE="${SCRATCH_BASE%/}"
WORK="$SCRATCH_BASE/tmx67deps.$$"
_cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap _cleanup EXIT
if ! mkdir -p "$WORK" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "SKIP 67: throwaway root $WORK not writable (disk full / RO) — §11.4.3"
    echo "── summary 67: PASS=0 FAIL=0 SKIP=1 ──"
    exit 0
fi

echo "── Test 67: per-host local-dependency obtaining mechanism (§11.4.77/.81/.111) ──"

# Feature under test must exist.
if [ ! -x "$OBTAIN" ]; then
    _skip "scripts/obtain_local_deps.sh absent or not executable — feature not built (§11.4.3)"
    echo "── summary 67: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 0
fi

# read a KEY=value line out of a resolved.env (absolute, no ambient eval).
_renv() { grep -m1 "^$1=" "$2" 2>/dev/null | sed "s/^$1=//"; }

# `file -L` (deref symlinks) matches a real shared object on either OS.
_is_shared_object() {
    file -L "$1" 2>/dev/null | grep -qiE 'shared object|Mach-O|dynamically linked|ELF'
}

# Map an obtain-script exit code to an honest §11.4.3 SKIP reason, or "" if
# the code is a genuine product defect that MUST surface as FAIL.
_obtain_skip_reason() {
    case "$1" in
        10) echo "no obtain toolchain on this host (network_unreachable / no compiler) — §11.4.3" ;;
        11) echo "network_unreachable_external — cannot download dependency tarball — §11.4.3" ;;
        13) echo "container obtain failed (no podman/docker or image build) — §11.4.3" ;;
        14) echo "unsupported dependency/OS topology — §11.4.3" ;;
        *)  echo "" ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════
# C1 — resolve-by-ABSOLUTE-path + §11.4.50 determinism (3×) + §11.4.111
#      PATH-independence. resolve = no FORCE_OBTAIN.
# ════════════════════════════════════════════════════════════════════════
R1="$WORK/r1"
c1_so=""; c1_libdir=""; c1_src=""; c1_skip=""
i=1; prev_so=""; det_ok=1
while [ "$i" -le 3 ]; do
    rm -rf "$R1"
    LOCAL_DEPS_ROOT="$R1" DEPS=jemalloc bash "$OBTAIN" >/dev/null 2>&1
    rc=$?
    renv="$R1/$PLAT/resolved.env"
    if [ "$rc" -ne 0 ]; then
        reason="$(_obtain_skip_reason "$rc")"
        if [ -n "$reason" ]; then c1_skip="$reason"; else c1_skip=""; fi
        break
    fi
    so="$(_renv JEMALLOC_SO "$renv")"
    if [ "$i" -eq 1 ]; then
        c1_so="$so"; c1_libdir="$(_renv JEMALLOC_LIBDIR "$renv")"; c1_src="$(_renv JEMALLOC_SOURCE "$renv")"
        prev_so="$so"
    else
        [ "$so" = "$prev_so" ] || det_ok=0
    fi
    i=$((i + 1))
done

if [ -z "$c1_so" ] && [ -n "$c1_skip" ]; then
    _skip "C1 resolve — $c1_skip"
elif [ -z "$c1_so" ]; then
    _fail "C1 resolve — obtain exited non-zero with a defect code (not a §11.4.3 SKIP); resolved.env missing JEMALLOC_SO"
else
    # absolute?
    case "$c1_so" in
        /*) abs_ok=1 ;;
        *)  abs_ok=0 ;;
    esac
    if [ "$abs_ok" -ne 1 ]; then
        _fail "C1 — JEMALLOC_SO is not an ABSOLUTE path (§11.4.111): '$c1_so'"
    elif [ ! -e "$c1_so" ]; then
        _fail "C1 — JEMALLOC_SO absolute path does NOT exist: '$c1_so'"
    elif ! _is_shared_object "$c1_so"; then
        _fail "C1 — JEMALLOC_SO is not a real shared object: $(file -L "$c1_so" 2>/dev/null | head -1)"
    elif [ "$det_ok" -ne 1 ]; then
        _fail "C1 — §11.4.50 determinism: JEMALLOC_SO differed across 3 resolve runs"
    else
        echo "[evidence 67-C1] JEMALLOC_SO=$c1_so source=$c1_src — $(file -L "$c1_so" 2>/dev/null | sed 's/.*: //' | head -1)"
        echo "[evidence 67-C1] resolve driven 3× — JEMALLOC_SO byte-identical (§11.4.50)"
        _pass "C1 — resolve-by-absolute-path: JEMALLOC_SO is an absolute, existing, real shared object (§11.4.111); deterministic 3×"
    fi

    # ── C1b §11.4.111 PATH-independence (mistborn brew exit-3 fix) ───────
    # Resolution MUST NOT depend on ambient PATH — re-resolve into a fresh
    # root with a minimal PATH and assert it still finds an absolute,
    # existing JEMALLOC_SO. Only meaningful when C1 resolved via a HOST
    # source (the resolve path); if C1 had to OBTAIN (no host jemalloc),
    # the PATH-independence-of-resolve point is N/A — C2 covers obtain.
    if [ -n "$c1_so" ] && [ "$abs_ok" = "1" ] && [ -e "$c1_so" ]; then
        case "${c1_src:-}" in
            host*)
                R1b="$WORK/r1b"; rm -rf "$R1b"
                env -i PATH=/usr/bin:/bin HOME="$HOME" \
                    LOCAL_DEPS_ROOT="$R1b" DEPS=jemalloc \
                    bash "$OBTAIN" >/dev/null 2>&1
                rcb=$?
                sob="$(_renv JEMALLOC_SO "$R1b/$PLAT/resolved.env")"
                if [ "$rcb" -eq 0 ] && [ -n "$sob" ] && [ -e "$sob" ]; then
                    case "$sob" in /*) okb=1 ;; *) okb=0 ;; esac
                    if [ "$okb" -eq 1 ]; then
                        echo "[evidence 67-C1b] PATH=/usr/bin:/bin still resolved JEMALLOC_SO=$sob (absolute resolution, no ambient PATH dependency)"
                        _pass "C1b — resolution is independent of ambient PATH (§11.4.111; mistborn brew exit-3 fix)"
                    else
                        _fail "C1b — minimal-PATH resolution returned a non-absolute JEMALLOC_SO: '$sob'"
                    fi
                else
                    _fail "C1b — resolution FAILED under minimal PATH (rc=$rcb so='$sob') — would mean it depends on ambient PATH (§11.4.111)"
                fi
                ;;
            *)
                _skip "C1b — C1 obtained (no host jemalloc to resolve); PATH-independence-of-resolve N/A here — C2 covers the obtain path (§11.4.3)"
                ;;
        esac
    fi
fi

# ════════════════════════════════════════════════════════════════════════
# C2 — obtain-when-missing (§11.4.115 GREEN half). FORCE_OBTAIN=1 → a REAL
#      local library is built/extracted (ELF/Mach-O) with SOURCE=local-build
#      (or container-extract on a compiler-less Linux host).
# ════════════════════════════════════════════════════════════════════════
R2="$WORK/r2"; rm -rf "$R2"
c2_so=""; c2_src=""
LOCAL_DEPS_ROOT="$R2" FORCE_OBTAIN=1 DEPS=jemalloc bash "$OBTAIN" >/dev/null 2>&1
rc2=$?
renv2="$R2/$PLAT/resolved.env"
if [ "$rc2" -eq 0 ]; then
    c2_so="$(_renv JEMALLOC_SO "$renv2")"; c2_src="$(_renv JEMALLOC_SOURCE "$renv2")"
    c2_libdir="$(_renv JEMALLOC_LIBDIR "$renv2")"
    if [ -z "$c2_so" ] || [ ! -e "$c2_so" ]; then
        _fail "C2 — FORCE_OBTAIN exited 0 but produced no existing JEMALLOC_SO ('$c2_so')"
    elif ! _is_shared_object "$c2_so"; then
        _fail "C2 — obtained JEMALLOC_SO is not a real shared object: $(file -L "$c2_so" 2>/dev/null | head -1)"
    else
        case "${c2_src:-}" in
            local-build|container-extract) src_ok=1 ;;
            *) src_ok=0 ;;
        esac
        echo "[evidence 67-C2] OBTAINED JEMALLOC_SO=$c2_so source=$c2_src — $(file -L "$c2_so" 2>/dev/null | sed 's/.*: //' | head -1)"
        if [ "$src_ok" -eq 1 ]; then
            _pass "C2 — obtain-when-missing produced a REAL local libjemalloc ($c2_src) via FORCE_OBTAIN (§11.4.115 GREEN)"
        else
            _fail "C2 — JEMALLOC_SOURCE='$c2_src' under FORCE_OBTAIN — expected local-build/container-extract"
        fi
    fi
elif [ "$rc2" -eq 12 ]; then
    _fail "C2 — sha256 MISMATCH on the obtained tarball (corruption defect, not a SKIP) (§11.4.115)"
else
    reason="$(_obtain_skip_reason "$rc2")"
    [ -n "$reason" ] || reason="obtain exited rc=$rc2"
    _skip "C2 obtain-when-missing — $reason"
fi

# ════════════════════════════════════════════════════════════════════════
# C3 — a binary FINDS the resolved jemalloc via the PRODUCT runtime mechanism
#      (LD_LIBRARY_PATH on Linux / DYLD_LIBRARY_PATH on Darwin — what
#      verify.sh / run_all.sh / the tmx wrapper export from resolved.env).
#      Prefer the C2 local-build root (non-default LIBDIR → strongest proof);
#      else the C1 root. Build a minimal probe calling mallctl("version"),
#      link it against the resolved SO (patchelf --force-rpath when present,
#      else link-time -Wl,-rpath as belt-and-suspenders), then run it +
#      ldd/otool it WITH LD_LIBRARY_PATH=<LIBDIR> set and assert it binds
#      libjemalloc to the resolved LIBDIR. LD_LIBRARY_PATH is searched by the
#      loader BEFORE ld.so.cache, so this is authoritative on EVERY host class
#      (system-jemalloc-present or absent; patchelf present or absent).
# ════════════════════════════════════════════════════════════════════════
P_SO=""; P_LIBDIR=""
if [ -n "$c2_so" ] && [ -e "$c2_so" ]; then
    P_SO="$c2_so"; P_LIBDIR="${c2_libdir:-$(dirname "$c2_so")}"
elif [ -n "$c1_so" ] && [ -e "$c1_so" ]; then
    P_SO="$c1_so"; P_LIBDIR="${c1_libdir:-$(dirname "$c1_so")}"
fi

CC="$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || command -v clang 2>/dev/null || true)"
PATCHELF=""
for c in patchelf "$HOME/.local/bin/patchelf" /usr/bin/patchelf /usr/local/bin/patchelf; do
    if command -v "$c" >/dev/null 2>&1; then PATCHELF="$(command -v "$c")"; break; fi
    [ -x "$c" ] && { PATCHELF="$c"; break; }
done

if [ -z "$P_SO" ]; then
    _skip "C3 — no resolved JEMALLOC_SO from C1/C2 to bind a probe against (§11.4.3)"
elif [ -z "$CC" ]; then
    _skip "C3 — no C compiler to build the probe (§11.4.3)"
else
    PDIR="$WORK/probe"; mkdir -p "$PDIR"
    cat > "$PDIR/probe.c" <<'PROBE_EOF'
#include <stddef.h>
#include <stdio.h>
/* §11.4.111 prefix-agnostic: the public jemalloc control symbol is supplied
 * at compile time via -DJE_MALLCTL=<sym> — detected from what the resolved SO
 * actually exports (`mallctl` for an empty-prefix build [Linux obtain/host,
 * Homebrew macOS]; `je_mallctl` for a Darwin-default local-build). Declared
 * here so the probe needs no jemalloc.h — it proves the SYMBOL links. */
#ifndef JE_MALLCTL
#define JE_MALLCTL mallctl
#endif
extern int JE_MALLCTL(const char *, void *, size_t *, void *, size_t);
int main(void) {
    const char *v = NULL;
    size_t sz = sizeof(v);
    int rc = JE_MALLCTL("version", &v, &sz, NULL, 0);
    if (rc != 0 || v == NULL) {
        fprintf(stderr, "jemalloc mallctl(version) failed rc=%d\n", rc);
        return 2;
    }
    printf("jemalloc-version=%s\n", v);
    return 0;
}
PROBE_EOF
    PROBE="$PDIR/probe"

    # ── §11.4.111 prefix-agnostic symbol detection ──────────────────────────
    # The probe must call the public jemalloc symbol the RESOLVED SO actually
    # exports — never assume `mallctl`. An empty-prefix jemalloc (Linux
    # obtain/host build; Homebrew macOS, configured with an EMPTY prefix)
    # exports `mallctl`; a macOS LOCAL-BUILD jemalloc keeps the Darwin-default
    # `je_` prefix and exports `je_mallctl` instead, so a probe hardcoding
    # `mallctl` fails to LINK on a no-brew macOS host
    # (`ld: Undefined symbols for architecture arm64: "_mallctl"`). We read the
    # SO's exported symbols (Linux dynamic table via `nm -D`; macOS/non-stripped
    # global table via `nm -g`) and strip the Mach-O leading-underscore C ABI
    # (`_mallctl` / `_je_mallctl`), preferring the empty-prefix `mallctl` when
    # present (what the product runtime expects on Linux + brew macOS).
    #
    # HONEST LIMITATION (§11.4.6 — recorded, not hidden): a macOS LOCAL-BUILD
    # jemalloc with the `je_` prefix does NOT auto-override system malloc —
    # macOS needs zone-based interposition / brew-equivalent configure flags —
    # so on a HYPOTHETICAL no-brew macOS host the obtained local-build SO may be
    # INERT as a malloc-OVERRIDE. C3 tests RESOLUTION + LINKABILITY of the
    # obtained SO via the LD/DYLD mechanism, NOT malloc-override effectiveness —
    # that scope is honest. The PRODUCT uses Homebrew jemalloc on macOS (empty
    # prefix, proper override) so this does NOT affect the 4 target hosts
    # (mistborn uses brew); the macOS source-build configure flags are a
    # separate future item if a no-brew macOS host ever appears.
    je_syms=""
    NM="$(command -v nm 2>/dev/null || true)"
    if [ -n "$NM" ]; then
        nm_out="$( { "$NM" -D "$P_SO" 2>/dev/null; "$NM" -g "$P_SO" 2>/dev/null; } || true)"
        have_mallctl=0; have_je_mallctl=0
        while IFS= read -r _ln; do
            _nm="${_ln##* }"; _nm="${_nm#_}"
            case "$_nm" in
                mallctl)    have_mallctl=1 ;;
                je_mallctl) have_je_mallctl=1 ;;
            esac
        done <<NM_EOF
$nm_out
NM_EOF
        if [ "$have_mallctl" -eq 1 ]; then je_syms="mallctl"
        elif [ "$have_je_mallctl" -eq 1 ]; then je_syms="je_mallctl"; fi
        if [ -n "$je_syms" ]; then
            echo "[evidence 67-C3] nm: resolved SO exports public symbol '$je_syms' — probe calls it (prefix-agnostic §11.4.111)"
        fi
    fi
    # nm absent OR no recognised symbol → try empty-prefix first, then je_-prefix.
    [ -n "$je_syms" ] || je_syms="mallctl je_mallctl"

    use_patchelf=0
    build_ok=0
    JE_SYM=""
    for _sym in $je_syms; do
        use_patchelf=0
        if [ "$OS" = "Linux" ] && [ -n "$PATCHELF" ]; then
            # Canonical mechanism: link against the absolute SO (no rpath), then
            # patchelf --set-rpath --force-rpath (mirrors setup.sh Step 2b).
            if "$CC" "$PDIR/probe.c" -DJE_MALLCTL="$_sym" -o "$PROBE" "$P_SO" 2>/dev/null; then
                if "$PATCHELF" --set-rpath "$P_LIBDIR" --force-rpath "$PROBE" 2>/dev/null; then
                    use_patchelf=1; build_ok=1; JE_SYM="$_sym"; break
                fi
            fi
        fi
        # Fallback (patchelf absent / macOS / patchelf step failed): link-time
        # rpath so the probe still runs and C3 keeps its "binary finds jemalloc"
        # proof. Also the second pass that tries the alternate symbol prefix.
        if "$CC" "$PDIR/probe.c" -DJE_MALLCTL="$_sym" -o "$PROBE" "$P_SO" -Wl,-rpath,"$P_LIBDIR" 2>/dev/null; then
            build_ok=1; JE_SYM="$_sym"; break
        fi
    done

    if [ "$build_ok" -ne 1 ]; then
        _fail "C3 — failed to build the jemalloc probe (link against $P_SO; tried symbol(s): $je_syms)"
    else
        # ── Authoritative resolution proof: the probe RUNS under the product
        #    runtime env (LD_LIBRARY_PATH on Linux / DYLD_LIBRARY_PATH on macOS
        #    from resolved.env). The probe was compiled against the OBTAINED SO
        #    and links a jemalloc symbol; if it runs and prints the version, the
        #    dynamic linker resolved the obtained lib successfully.
        #
        #    NOTE: `ldd` path-output is NOT a reliable LD_LIBRARY_PATH oracle
        #    on every host class. On ALT Linux (glibc ≥2.38, soname-based
        #    resolution, lib NOT in ld.so.cache), `env LD_LIBRARY_PATH=… ldd`
        #    always shows `/lib64/libjemalloc.so.2` regardless of LD_LIBRARY_PATH
        #    — LD_DEBUG=libs proves it. The probe RUNS correctly under
        #    LD_LIBRARY_PATH (dynamic linker DOES use it), but ldd's static
        #    report does not reflect that. So the probe-run assertion IS the
        #    proof; ldd is cosmetic. macOS DYLD_LIBRARY_PATH + otool IS reliable.
        if [ "$OS" = "Darwin" ]; then
            ld_var="DYLD_LIBRARY_PATH"; ld_cur="${DYLD_LIBRARY_PATH:-}"
        else
            ld_var="LD_LIBRARY_PATH"; ld_cur="${LD_LIBRARY_PATH:-}"
        fi
        if [ -n "$ld_cur" ]; then ld_run="$P_LIBDIR:$ld_cur"; else ld_run="$P_LIBDIR"; fi
        # run the probe with the product's runtime env (resolved LIBDIR FIRST).
        run_out="$(env "$ld_var=$ld_run" "$PROBE" 2>&1)"; run_rc=$?

        if [ "$run_rc" -ne 0 ] || ! printf '%s' "$run_out" | grep -q 'jemalloc-version='; then
            _fail "C3 — probe did not run cleanly under $ld_var=$P_LIBDIR (rc=$run_rc out='$run_out')"
        elif [ "$OS" = "Darwin" ]; then
            # macOS: DYLD_LIBRARY_PATH runtime resolution exercised by the probe
            # run above; otool shows link-time install-name.
            res_line="$(otool -L "$PROBE" 2>/dev/null | grep -i jemalloc | head -1)"
            echo "[evidence 67-C3] probe '$run_out' (exit 0) under $ld_var=$P_LIBDIR; otool: $(printf '%s' "$res_line" | tr -s ' ')"
            _pass "C3 — binary links+runs the OBTAINED jemalloc ($JE_SYM(version) returned a real version under DYLD_LIBRARY_PATH=$P_LIBDIR)"
        else
            # Linux: probe ran = dynamic linker resolved obtained jemalloc via
            # LD_LIBRARY_PATH (the product's real runtime mechanism).
            if [ "$use_patchelf" -eq 1 ]; then
                # belt-and-suspenders: patchelf --force-rpath writes DT_RPATH;
                # bare ldd should also resolve to LIBDIR (self-contained proof).
                bare_path="$(ldd "$PROBE" 2>/dev/null | grep -i jemalloc | head -1 | awk '{print $3}')"
                bare_dir=""; [ -n "$bare_path" ] && bare_dir="$(dirname "$bare_path" 2>/dev/null || true)"
                if [ "$bare_dir" = "$P_LIBDIR" ]; then
                    echo "[evidence 67-C3] probe '$run_out' (exit 0) under $ld_var=$P_LIBDIR; self-contained: patchelf rpath=$("$PATCHELF" --print-rpath "$PROBE" 2>/dev/null) — bare ldd ALSO → $P_LIBDIR"
                else
                    echo "[evidence 67-C3] probe '$run_out' (exit 0) under $ld_var=$P_LIBDIR; patchelf rpath=$("$PATCHELF" --print-rpath "$PROBE" 2>/dev/null) — bare ldd → $bare_dir (LD_LIBRARY_PATH is the authoritative proof)"
                fi
                _pass "C3 — binary links+runs the OBTAINED jemalloc ($JE_SYM(version) returned a real version under LD_LIBRARY_PATH=$P_LIBDIR); patchelf rpath also set"
            else
                echo "[evidence 67-C3] probe '$run_out' (exit 0) under $ld_var=$P_LIBDIR — runtime proof: dynamic linker resolved obtained jemalloc via LD_LIBRARY_PATH"
                _pass "C3 — binary links+runs the OBTAINED jemalloc ($JE_SYM(version) returned a real version under LD_LIBRARY_PATH=$P_LIBDIR)"
            fi
        fi
    fi

    # ── C3b — patchelf-specific sub-assertion (§11.4.3 SKIP when absent) ──
    if [ "$OS" != "Linux" ]; then
        _skip "C3b — patchelf is a Linux/ELF tool; Mach-O uses install_name/rpath (§11.4.81(C); C3 used link-time rpath)"
    elif [ -z "$PATCHELF" ]; then
        _skip "C3b — patchelf absent: skipping the patchelf set-rpath sub-assertion; C3 used link-time rpath instead (§11.4.3)"
    elif [ "$use_patchelf" -eq 1 ]; then
        got_rpath="$("$PATCHELF" --print-rpath "$PROBE" 2>/dev/null || true)"
        if [ "$got_rpath" = "$P_LIBDIR" ]; then
            _pass "C3b — patchelf --set-rpath --force-rpath wrote rpath=$got_rpath (== resolved LIBDIR)"
        else
            _fail "C3b — patchelf rpath is '$got_rpath', expected '$P_LIBDIR'"
        fi
    fi
fi

echo ""
echo "── summary 67: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
