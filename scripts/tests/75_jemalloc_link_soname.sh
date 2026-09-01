#!/usr/bin/env bash
# 75_jemalloc_link_soname.sh
# ─────────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.115 RED-baseline + standing regression guard for the
#             jemalloc LINK token emitted by scripts/build_native.sh on the
#             Linux native-build path (§11.4.111 resolve-by-stable-name).
#
# Forensic anchor (§11.4.138 operator-escape, 2026-06-30): on a base host whose
# rootless Podman lacked newuidmap, the containerized build failed and setup.sh's
# §11.4.101 native fallback ran build_native.sh → `./configure` died with the
# SAME cryptic symptom test 70 guards:
#     checking whether the C compiler works... no
#     configure: error: C compiler cannot create executables
# but a DIFFERENT, NEW root cause (FACT, config.log line-confirmed):
#     /usr/bin/ld.bfd: cannot find -ljemalloc: No such file or directory
# The host carried a RUNTIME-only jemalloc (/lib64/libjemalloc.so.2, NO -devel
# `libjemalloc.so` symlink), so build_native.sh's bare `-ljemalloc` in LDFLAGS
# was unresolvable and poisoned even configure's trivial executable probe
# (install.sh exit 77). Test 70's cc_can_link preflight passed (a PLAIN link
# works — crt1.o present), so this class slipped past it. The GREEN suite never
# caught it — NO test fault-injected a runtime-only jemalloc against the build's
# own link token. The fix links by the RESOLVED SONAME basename
# (`-l:libjemalloc.so.2`) which the GNU linker resolves WITHOUT a dev symlink.
#
# What this guard proves (captured evidence, §11.4.5 / §11.4.123):
#   C1  PRINCIPLE (Linux, mode-agnostic): against a synthesised runtime-only
#       libjemalloc.so.2 (no dev .so symlink), bare `-ljemalloc` FAILS to link
#       while `-l:libjemalloc.so.2` SUCCEEDS — the exact toolchain fact the fix
#       relies on. macOS/other ⇒ SKIP (`-l:` + `--no-as-needed` are GNU-ld only;
#       brew jemalloc ships a dev .dylib, §11.4.81 honest cross-platform gap).
#   C2  POLARITY (§11.4.115): RED_MODE=1 asserts the DEFECT is PRESENT on a
#       self-built neutered artifact (the host link line reverted to bare
#       `-ljemalloc`); RED_MODE=0 (the standing GREEN guard) asserts the
#       resolved-SONAME `${JEM_LINK}` form + its `-l:$(basename …)` derivation
#       are present on the HOST-toolchain link path. The zig path legitimately
#       keeps bare `-ljemalloc` (local-build dev symlink + the zig wrapper
#       rejects `-l:NAME`, regression caught 2026-06-30) — OUT of scope.
#   C3  §1.1 paired mutation (self-contained): a COPY of build_native.sh with
#       `${JEM_LINK}` reverted to bare `-ljemalloc` makes the GREEN assertion
#       FAIL → MUTATION CAUGHT (the guard has teeth).
#
# Usage:      bash scripts/tests/75_jemalloc_link_soname.sh
#             RED_MODE=1 bash scripts/tests/75_jemalloc_link_soname.sh   # reproduce
# Inputs:     RED_MODE (default 1 per §11.4.115). Honours $TMPDIR.
# Outputs:    EVIDENCE / PASS / FAIL / SKIP lines + summary (run_all-classified).
# Side-effects: builds a stub shared lib + conftests under ${TMPDIR:-/tmp}/tmx75.$$
#             (trap-cleaned, §11.4.14). HOST-SAFE: never touches the real toolchain
#             or .local-deps tree (§12).
# Dependencies: scripts/build_native.sh (under test); a real C compiler for C1
#             (SKIP-with-reason per §11.4.3 if absent).
# §11.4.67:   bash -n + sh -n clean (POSIX constructs only — no arrays/[[ ]]/<<<).
# §11.4.81:   C1 is Linux-only by toolchain (honest SKIP elsewhere); C2/C3 are
#             source assertions that run on every platform.
# Last verified: 2026-06-30
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

RED_MODE="${RED_MODE:-1}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
BN="$REPO_ROOT/scripts/build_native.sh"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 75: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 75: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 75: $*"; SKIP=$((SKIP + 1)); }
_ev()   { echo "EVIDENCE 75: $*"; }

SCRATCH_BASE="${TMPDIR:-/tmp}"; SCRATCH_BASE="${SCRATCH_BASE%/}"
WORK="$SCRATCH_BASE/tmx75.$$"
EVID_DIR="$REPO_ROOT/qa-results/loop-20260630/jemalloc-link-soname"
_cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap _cleanup EXIT
if ! mkdir -p "$WORK" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "SKIP 75: scratch root $WORK not writable (disk full / RO) — §11.4.3"
    echo "── summary 75: PASS=0 FAIL=0 SKIP=1 ──"; exit 0
fi
mkdir -p "$EVID_DIR" 2>/dev/null || true

[ -f "$BN" ] || { echo "FAIL 75: scripts/build_native.sh absent"; exit 1; }

echo "════════════════════════════════════════════════════════════════"
echo "  test 75 — jemalloc link-by-SONAME (§11.4.111) (RED_MODE=$RED_MODE)"
echo "════════════════════════════════════════════════════════════════"

# ── source helpers: the GNU (Linux) jemalloc-link lines carry the GNU-only
# --no-as-needed guard. The macOS line (brew dev .dylib, -search_paths_first)
# legitimately keeps bare -ljemalloc and is OUT of scope. ────────────────────
_gnu_jem_lines() { grep -nE -- '-Wl,--no-as-needed' "$1" | grep -E -- 'jemalloc|JEM_LINK'; }
_bare_defect()   { _gnu_jem_lines "$1" | grep -E -- '[ "]-ljemalloc'; }   # bare form
_fixed_form()    { _gnu_jem_lines "$1" | grep -F -- '${JEM_LINK}'; }      # resolved form

# ── C1: PRINCIPLE — runtime-only jemalloc: bare fails, -l:soname links ────────
OS="$(uname -s)"
REAL_CC=""
for _c in cc gcc clang; do command -v "$_c" >/dev/null 2>&1 && { REAL_CC="$(command -v "$_c")"; break; }; done
if [ "$OS" != "Linux" ]; then
    _skip "C1 principle is GNU-ld-only (-l:/--no-as-needed); macOS uses brew dev .dylib (§11.4.81 honest gap)"
elif [ -z "$REAL_CC" ]; then
    _skip "C1 no C compiler on host — cannot exercise the link principle (§11.4.3)"
else
    JLIB="$WORK/jlib"; mkdir -p "$JLIB"
    printf 'int __tmx75_stub;\n' > "$WORK/stub.c"
    # ISOLATION (TMX-091, root-caused 2026-09-01): the stub was previously named
    # libjemalloc.so.2, so bare `-ljemalloc` searched for `libjemalloc.so`, missed
    # this scratch -L dir, and FELL BACK TO THE SYSTEM SEARCH PATH, where the
    # installed libjemalloc-dev provides /usr/lib/<triple>/libjemalloc.so. bare_rc
    # was therefore 0 and the test SKIPped with a misattributed reason ("binutils
    # variant"), never exercising its own principle on any host with the dev
    # package. A stub name that CANNOT exist system-wide isolates the link so the
    # principle is genuinely tested. The principle is name-independent: bare -lNAME
    # needs libNAME.so (dev symlink), while -l:libNAME.so.2 links a runtime-only lib.
    if "$REAL_CC" -shared -fPIC -o "$JLIB/libtmx75jem.so.2" "$WORK/stub.c" >/dev/null 2>&1; then
        # NO libjemalloc.so dev symlink is created — runtime-only, the host condition.
        printf 'int main(void){return 0;}\n' > "$WORK/conftest.c"
        bare_rc=0
        "$REAL_CC" "$WORK/conftest.c" -L"$JLIB" -Wl,--no-as-needed -ltmx75jem -Wl,--as-needed \
            -o "$WORK/t_bare" > "$WORK/bare.log" 2>&1 || bare_rc=$?
        soname_rc=0
        "$REAL_CC" "$WORK/conftest.c" -L"$JLIB" -Wl,--no-as-needed -l:libtmx75jem.so.2 -Wl,--as-needed \
            -o "$WORK/t_soname" > "$WORK/soname.log" 2>&1 || soname_rc=$?
        cp "$WORK/bare.log" "$EVID_DIR/C1_bare_ljemalloc.log" 2>/dev/null || true
        cp "$WORK/soname.log" "$EVID_DIR/C1_soname_link.log" 2>/dev/null || true
        if [ "$bare_rc" != "0" ] && [ "$soname_rc" = "0" ]; then
            _pass "C1 runtime-only lib (isolated stub): bare -l NAME FAILS (rc=$bare_rc), -l:libNAME.so.2 LINKS (rc=0) — jemalloc link-by-SONAME principle proven"
            _ev "captured: qa-results/loop-20260630/jemalloc-link-soname/C1_bare_ljemalloc.log + C1_soname_link.log"
        elif [ "$bare_rc" = "0" ]; then
            _fail "C1 bare -l resolved against a runtime-only stub (rc=0) — the isolated stub should NOT be satisfiable without a .so dev symlink; link isolation is broken"
        else
            _fail "C1 -l:libtmx75jem.so.2 did NOT link a runtime-only lib (rc=$soname_rc) — fix principle broken: $(tail -1 "$WORK/soname.log")"
        fi
    else
        _skip "C1 could not build a stub shared object on this host (§11.4.3)"
    fi
fi

# ── C2/C3 setup: current artifact + a self-built NEUTERED (broken) copy ───────
# Scope = the HOST-toolchain native LDFLAGS line, the GNU (--no-as-needed) line
# that uses the resolved ${JEM_LINK} form. The zig path legitimately keeps bare
# -ljemalloc (local-build dev symlink + the zig wrapper rejects -l:NAME; that
# regression was caught 2026-06-30) and the macOS line keeps bare too — both OUT
# of scope. GREEN condition = the resolved ${JEM_LINK} form present on >=1 GNU
# line AND the -l:$(basename …) derivation present. The "broken artifact" is a
# neutered COPY (every ${JEM_LINK} reverted to bare) — self-contained like test
# 70, so the RED-mode assertion PASSes on a fixed tree under run_all's default
# RED_MODE=1; the meta-test mutation flips the mode-agnostic C2b by reverting the
# REAL build_native.sh.
cur_fixed="$(_fixed_form "$BN" | wc -l | tr -d ' ')"
cur_deriv=1; grep -qE -- '-l:\$\(basename "\$JEMALLOC_SO"\)' "$BN" && cur_deriv=0
cur_green=1; { [ "$cur_fixed" -ge 1 ] && [ "$cur_deriv" = "0" ]; } && cur_green=0

MUT="$WORK/build_native_neutered.sh"
sed 's/\${JEM_LINK}/-ljemalloc/g' "$BN" > "$MUT"
mut_fixed="$(_fixed_form "$MUT" | wc -l | tr -d ' ')"
mut_green=1; [ "$mut_fixed" -ge 1 ] && [ "$cur_deriv" = "0" ] && mut_green=0

{ echo "current build_native.sh GNU jemalloc-link lines:"; _gnu_jem_lines "$BN"; \
  echo "current: host \${JEM_LINK} lines=$cur_fixed deriv_ok=$cur_deriv green=$cur_green"; \
  echo "neutered copy: \${JEM_LINK} lines=$mut_fixed green=$mut_green"; } \
  > "$EVID_DIR/C2_source_link_lines.log" 2>/dev/null || true

# ── C2: POLARITY (§11.4.115) — defect on broken copy (RED) / fix on current (GREEN)
if [ "$RED_MODE" = "1" ]; then
    if [ "$mut_fixed" = "0" ] && [ "$mut_green" != "0" ]; then
        _pass "C2 RED reproduced on the neutered artifact: reverting \${JEM_LINK}→-ljemalloc leaves the host link line bare (the linker cannot resolve it on a runtime-only host)"
    else
        _fail "C2 RED did not reproduce on the neutered copy (mut_fixed=$mut_fixed) — §11.4.115 blind-test check"
    fi
else
    if [ "$cur_green" = "0" ]; then
        _pass "C2 GREEN guard: current build_native.sh host line links jemalloc by resolved SONAME (\${JEM_LINK} on $cur_fixed GNU line(s), -l:\$(basename …) derivation present)"
        _ev "captured: qa-results/loop-20260630/jemalloc-link-soname/C2_source_link_lines.log"
    else
        _fail "C2 GREEN guard FAILED — host \${JEM_LINK} lines=$cur_fixed (want >=1), deriv_ok=$cur_deriv (want 0)"
    fi
fi

# ── C2b: MODE-AGNOSTIC standing invariant — current artifact carries the fix ──
# This is the assertion the meta-test mutation (revert the REAL build_native.sh)
# flips to FAIL → MUTATION CAUGHT. Always checked regardless of RED_MODE so
# run_all (default RED_MODE=1) still guards the real tree against regression.
if [ "$cur_green" = "0" ]; then
    _pass "C2b current build_native.sh carries the fix (host line uses resolved -l:SONAME via \${JEM_LINK}; derivation present)"
else
    _fail "C2b current build_native.sh LACKS the fix (host \${JEM_LINK} lines=$cur_fixed deriv_ok=$cur_deriv) — regression / §1.1 mutation caught"
fi

# ── C3: §1.1 paired mutation (self-contained) — neutered copy fails the GREEN ──
if [ "$mut_green" != "0" ]; then
    _pass "C3 §1.1 MUTATION CAUGHT — neutering \${JEM_LINK}→-ljemalloc strips the host resolved-SONAME link (host \${JEM_LINK} lines=$mut_fixed) the GREEN guard requires (teeth)"
else
    _fail "C3 §1.1 MUTATION ESCAPED — neutered copy still satisfies the GREEN guard (no teeth)"
fi

echo "════════════════════════════════════════════════════════════════"
echo "  test 75 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
echo "════════════════════════════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
