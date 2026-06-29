# TMX-063 — PRODUCTION root-free zig build: captured evidence

**Revision:** 1
**Last modified:** 2026-06-29T16:30:00Z
**Authority:** vasic-digital tmux — QA evidence trail (§11.4.83)
**Scope:** the PROVEN PoC (verdict A) wired into the production scripts —
`scripts/obtain_local_deps.sh` + `scripts/build_native.sh` + `scripts/setup.sh`
build tmux 3.6a with NO root, NO sudo/su, NO interaction, even when the host
has NO working C toolchain (obtained zig 0.16.0 `cc` toolchain).

## Verdict

**WORKS via the unmodified project scripts.** On a real host (nezha,
Linux x86_64) the REAL `scripts/obtain_local_deps.sh` + `scripts/build_native.sh`,
run inside a neutered env (no cc/gcc/clang/ld/as/ar/autoconf/automake/bison/
pkg-config reachable), obtained the zig toolchain, source-built
libevent + ncurses + jemalloc with it, and built tmux 3.6a from the 3.6a
RELEASE tarball — `tmux -V` == `tmux 3.6a`, a live session ran, N=3 builds were
identical, and the §1.1 mutation was caught. NORMAL-host build path unchanged
(no regression). RED→GREEN polarity proven.

## Test results (scripts/tests/71_root_free_zig_build.sh)

- `RED_MODE=1` (reproduce the defect on the broken artifact): **PASS=5 FAIL=0 SKIP=0**
  — see `test71_RED_full.log`. C3 proves the neutered build WITHOUT the zig
  obtain FAILS at the can't-link step (defect present).
- `RED_MODE=0` (standing GREEN guard): **PASS=12 FAIL=0 SKIP=0**
  — see `test71_GREEN_full.log`.
- Sibling regression `scripts/tests/70_native_fallback_cc_link.sh`:
  **PASS=16 FAIL=0 SKIP=0** (my setup.sh edits introduce no regression).

## Captured proofs

| Proof | File |
|---|---|
| C1 NORMAL-host no-regression — cc resolved HOST (CC_KIND=host) | `C1_normal_host_resolved.env` |
| C2 neuter validity — host toolchain unreachable | `C2_neuter_proof.log` |
| C4/C4b GREEN — CC_KIND=zig (local-toolchain) drove the build; all deps local-build | `GREEN_resolved.env` |
| C5 tmux -V == tmux 3.6a (user-visible) + ELF | `GREEN_tmux_runtime_proof.log` |
| C6 live session — marker captured from a real pane | `GREEN_tmux_live_session.log` |
| C7 residual #2 — DT_NEEDED = LOCAL `libncursesw.so.6` (not host libtinfo+libncurses); RUNPATH=local | `GREEN_readelf_needed.log` |
| C8 §11.4.50 determinism — N=3 identical `tmux 3.6a` | `GREEN_determinism_n3.log` |
| C3 RED — neutered build with no toolchain fails to link | `RED_no_toolchain_build_fail.log` |

## Residuals fixed

1. **obtain_via_source bypassed the obtained zig** — fixed: `obtain_via_source`
   now consumes `RESOLVED_CC_KIND=zig` (CC = the flag-filter wrapper, wrapper dir
   prepended to PATH so ar/ranlib/objcopy/ld resolve to zig), and resolve_cc
   resolves the host compiler by LINK-CAPABILITY (a host cc that cannot link
   falls through to OBTAIN). `MAKE` is pinned to the absolute path so config.status
   + recursive `$(MAKE)` work on a bare/neutered PATH.
2. **ncurses host-preference** — fixed: `_ncurses_compat_symlinks` creates
   `libtinfo.so`/`libtinfo.so.6`/`libncurses.so`/`libncurses.so.6` →
   the local widec `libncursesw.so.6` (which bundles `setupterm`), so tmux's
   `AC_SEARCH_LIBS(setupterm,[tinfo terminfo ncurses ncursesw])` links the LOCAL
   copy first (`-L<local>` precedes /lib64). Proven by `GREEN_readelf_needed.log`
   showing DT_NEEDED `libncursesw.so.6`, not the host `libtinfo.so.6`+`libncurses.so.6`.

## Proven payload

- zig 0.16.0 x86_64-linux, sha256
  `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`
  (byte-verified pin == index.json shasum, cross-checked live). Other 3 tuples'
  shasums are fetched + parsed from `https://ziglang.org/download/index.json`
  at obtain time (never hardcoded unverified).
- tmux 3.6a release tarball sha256
  `b6d8d9c76585db8ef5fa00d4931902fa4b8cbe8166f528f44fc403961a3f3759`.

## Host safety (§12 / §11.4.133)

NO sudo/su, NO root, NO host-toolchain mutation, NO interaction. The test runs
the build into a scratch `LOCAL_DEPS_ROOT` + scratch `TMX_BUILD_DIR` (new env
overrides in build_native.sh) so it NEVER clobbers the operator's `tmux/build`
or `.local-deps`. CM-NO-SUDO-NO-INTERACTION + CM-LOCAL-DEPS-MECHANISM gates
re-verified clean against the current tree.

## Sources verified 2026-06-29

- zig downloads + index.json shasum schema: https://ziglang.org/download/index.json
- ncurses 6.5 tarball (sha-verified): https://invisible-island.net/archives/ncurses/ncurses-6.5.tar.gz
- tmux 3.6a release tarball: https://github.com/tmux/tmux/releases/download/3.6a/tmux-3.6a.tar.gz
- Full research artefact: `docs/research/root_free_c_toolchain_20260629/README.md`
