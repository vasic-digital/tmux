#!/usr/bin/env bash
# build_native.sh — build the locally-pinned tmux 3.6a natively for the
# host OS (macOS Darwin or Linux). Produces a binary that runs as a
# host-native process: full host PATH, full filesystem access, plus the
# OS's strongest isolation primitive (cgroup on Linux, rlimit on macOS)
# applied per session by the wrapper.
#
# This is the macOS daily-use build. Linux still uses
# scripts/build_containerized.sh for the verified ELF artifact (kept for
# CI integrity); on Linux you can also use build_native.sh to produce
# the same binary directly on the host if you prefer.
#
# §1 covenant: hardening flags identical to the containerized build
# (`-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2`); jemalloc
# linked at the binary level (DT_NEEDED on Linux, LC_LOAD_DYLIB on
# Mach-O); verification gate refuses install unless functional tests pass.
#
# Usage: bash scripts/build_native.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

# Local-deps root + build dir are env-overridable so an isolated harness
# (scripts/tests/71_root_free_zig_build.sh) can run the REAL build into a
# scratch tree WITHOUT clobbering the operator's installed tmux/build (§12
# host-safety + §11.4.14). Default = the canonical in-repo locations (no
# behaviour change for `bash scripts/setup.sh`). LOCAL_DEPS_ROOT matches
# scripts/obtain_local_deps.sh so resolved.env + obtained deps line up.
LOCAL_DEPS_ROOT="${LOCAL_DEPS_ROOT:-$REPO_ROOT/.local-deps}"

case "$HOST_OS" in
    Darwin)
        # ── macOS native build via Homebrew deps ────────────────────────
        # Apple-silicon Homebrew lives at /opt/homebrew; Intel at /usr/local.
        # `brew --prefix` resolves either correctly without hardcoding.
        if ! command -v brew >/dev/null 2>&1; then
            echo "[build_native] ERROR: Homebrew not installed."
            echo "  Install via: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            exit 2
        fi
        BREW_PREFIX=$(brew --prefix)
        echo "[build_native] Darwin $HOST_ARCH host, brew @ $BREW_PREFIX"

        # Verify required brews (or auto-install on first run).
        # NB: `brew --prefix pkg` returns a path whether or not the package
        # is installed (it's the "would be" path). Use `brew --cellar pkg`
        # which only succeeds when the kg directory actually exists.
        REQUIRED_BREWS=(libevent jemalloc automake autoconf pkg-config bison utf8proc)
        MISSING=()
        for pkg in "${REQUIRED_BREWS[@]}"; do
            if ! brew --cellar "$pkg" >/dev/null 2>&1 || ! [ -d "$(brew --cellar "$pkg" 2>/dev/null)" ]; then
                MISSING+=("$pkg")
            fi
        done
        if [ ${#MISSING[@]} -gt 0 ]; then
            echo "[build_native] installing missing brews: ${MISSING[*]}"
            brew install "${MISSING[@]}"
        fi

        # Build dir per OS — Linux ELF stays at tmux/build, Mach-O at tmux/build-darwin.
        BUILD_DIR="${TMX_BUILD_DIR:-$REPO_ROOT/tmux/build-darwin}"
        BIN_PATH="$BUILD_DIR/bin/tmux"

        # Use Homebrew's bison (Apple's bison is stuck at 2.x; tmux needs ≥3).
        export PATH="$(brew --prefix bison)/bin:$PATH"

        # Mach-O hardening flags:
        #   -fstack-protector-strong   stack-canary on functions with locals
        #   -D_FORTIFY_SOURCE=2        compile-time + runtime checked string ops
        #   -O2 -DNDEBUG               optimised non-debug build
        # Mach-O linker flags:
        #   -Wl,-bind_at_load          bind symbols at dyld load (RELRO analogue)
        #   -Wl,-search_paths_first    resolve absolute deps before rpath search
        #   -ljemalloc                 link jemalloc at DT_NEEDED-equivalent
        # macOS does NOT support -z,relro / --no-as-needed — those are GNU ld
        # only. Mach-O always binds at load when -bind_at_load is requested.

        # Use ncurses include path only if installed; system /usr/include
        # works for the SDK's ncurses headers otherwise.
        NCURSES_INC=""
        if brew --cellar ncurses >/dev/null 2>&1 && [ -d "$(brew --cellar ncurses)" ]; then
            NCURSES_INC="-I$(brew --prefix ncurses)/include"
        fi
        # `-Wl,-bind_at_load` is deprecated on macOS 15+ (Sequoia) — Mach-O
        # now binds immediately by default. We drop it.
        # `-Wl,-search_paths_first` is the safe default for finding our
        # Homebrew dylibs before system ones.

        CFLAGS="-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
                -I$BREW_PREFIX/include \
                -I$(brew --prefix libevent)/include \
                -I$(brew --prefix jemalloc)/include \
                $NCURSES_INC \
                -Wno-unused-parameter -Wno-deprecated-declarations"
        LDFLAGS="-Wl,-search_paths_first \
                 -L$BREW_PREFIX/lib \
                 -L$(brew --prefix libevent)/lib \
                 -L$(brew --prefix jemalloc)/lib \
                 -ljemalloc"

        cd "$REPO_ROOT/tmux"
        if [ ! -f configure ]; then
            echo "[build_native] running autogen.sh..."
            sh autogen.sh 2>&1 | tail -3
        fi

        # make clean — force re-link in case LDFLAGS changed since last build.
        # Without this, an LDFLAGS change is silently dropped when mtimes align
        # (Fixed.md A4 forensic anchor).
        if [ -f Makefile ]; then
            echo "[build_native] make clean (force re-link)..."
            make clean 2>&1 | tail -2 || true
        fi

        echo "[build_native] configuring with hardened flags + jemalloc link..."
        # `--enable-utf8proc` — required by tmux 3.6a configure on Darwin
        # (libutf8proc provides proper emoji/CJK width on macOS where the
        # native libc Unicode tables are incomplete).
        CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
        PKG_CONFIG_PATH="$(brew --prefix utf8proc)/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
            ./configure \
                --prefix="$BUILD_DIR" \
                --enable-utf8proc \
                --disable-debug 2>&1 | tail -10

        echo ""
        echo "[build_native] compiling -j$(sysctl -n hw.ncpu)..."
        make -j"$(sysctl -n hw.ncpu)" 2>&1 | tail -5

        echo ""
        echo "[build_native] installing to $BUILD_DIR..."
        make install 2>&1 | tail -3

        echo ""
        echo "[build_native] verifying binary..."
        if [ ! -x "$BIN_PATH" ]; then
            echo "[build_native] ✗ BUILD FAILED — no $BIN_PATH"
            exit 1
        fi
        echo "  version: $("$BIN_PATH" -V 2>&1 | head -1)"
        echo "  format:  $(file "$BIN_PATH" | sed 's|^[^:]*: *||')"
        echo "  dyld deps:"
        otool -L "$BIN_PATH" | sed 's/^/    /'

        echo ""
        echo "[build_native] jemalloc verification:"
        if otool -L "$BIN_PATH" | grep -q jemalloc; then
            echo "  ✓ jemalloc linked (Mach-O LC_LOAD_DYLIB)"
        else
            echo "  ⚠ jemalloc NOT linked — Mach-O dyld will not load it"
        fi
        ;;

    Linux)
        # ── Linux native build (no container) ───────────────────────────
        # Same flags as build_containerized.sh, but runs on the host
        # directly. Use this when the host already has libevent-dev +
        # libjemalloc-dev + build-essential installed. Otherwise prefer
        # build_containerized.sh for hermetic builds.
        BUILD_DIR="${TMX_BUILD_DIR:-$REPO_ROOT/tmux/build}"
        BIN_PATH="$BUILD_DIR/bin/tmux"

        # ── local-dependency jemalloc wiring (§11.4.77 + I1 remediation) ────
        # A host with a compiler but NO container engine + NO system jemalloc
        # routes here (setup.sh Step 2 Linux: no ENGINE ⇒ build_native). The
        # bare `-ljemalloc` below would then have NO `-L` to find the
        # local-prefix libjemalloc that obtain_local_deps.sh source-built into
        # .local-deps/<plat>/lib → the link would fail. Source resolved.env
        # directly (so this works standalone AND via setup.sh — a subprocess
        # does NOT inherit setup's shell vars) and add the local prefix's
        # include/lib dirs. Also APPEND any inherited CPPFLAGS/CFLAGS/LDFLAGS
        # (was: plain-assign DISCARDED them — the dead-flag defect). PoC that
        # `-L$JEMALLOC_LIBDIR -ljemalloc` links a local-prefix jemalloc:
        # scripts/tests/67_local_deps.sh C3 (builds+runs a mallctl probe
        # against the resolved local libjemalloc). For a host-system jemalloc
        # (default path) JEM_* stay empty ⇒ behaviour unchanged (no regression).
        JEM_CPPFLAGS=""; JEM_LDFLAGS=""
        # ── jemalloc LINK token (§11.4.111 resolve-by-stable-name) ──────────
        # Default bare `-ljemalloc` REQUIRES a `libjemalloc.so` dev symlink
        # (the -devel package). A host with a RUNTIME-only jemalloc (just
        # libjemalloc.so.2, no dev symlink — the common base-distro case) makes
        # bare `-ljemalloc` UNRESOLVABLE → `cannot find -ljemalloc` poisons even
        # configure's "C compiler cannot create executables" probe (install.sh
        # exit 77; forensic 2026-06-30, qa-results/loop-20260630/). Below, when
        # resolved.env records a concrete JEMALLOC_SO, we link it by its
        # resolved SONAME basename via `-l:NAME`, which the GNU linker resolves
        # WITHOUT a dev symlink (works for a host-system runtime-only .so.2 AND
        # a local-build .so/.a alike). Empty JEMALLOC_SO ⇒ keep the bare default.
        JEM_LINK="-ljemalloc"
        # ── local-prefix BUILD deps (libevent + ncurses) (§11.4.77) ─────────
        # A minimal host with a compiler but NO libevent-dev / libncurses-dev
        # (e.g. nezha: /usr/include/event2/event.h absent) source-builds them
        # locally via obtain_local_deps.sh. When LIBEVENT_SOURCE/NCURSES_SOURCE
        # report a NON-host provenance (local-build / local-deps), wire the
        # local prefix's include + lib dirs into the build AND export
        # PKG_CONFIG_PATH=<prefix>/lib/pkgconfig so tmux's `./configure`
        # pkg-config check finds the local libevent/ncursesw .pc files (the
        # source build installs them there). Host-system / host-brew / absent
        # ⇒ these stay EMPTY ⇒ default behaviour unchanged (no regression).
        LE_CPPFLAGS=""; LE_LDFLAGS=""; NC_CPPFLAGS=""; NC_LDFLAGS=""
        LOCAL_PKGCONFIG=""; _NEED_LOCAL_PC=0
        CC_KIND=""; CC_WRAPPER_DIR=""
        # Colon-joined list of LOCAL-prefix lib dirs holding a source-built /
        # obtained dependency the built binary loads at RUNTIME (TMX-FIX-a).
        # Exported as LD_LIBRARY_PATH below so autoconf's "checking whether we
        # are cross compiling" RUN-test (./conftest) AND the final `tmux -V`
        # probe can dynamically load them. STAYS EMPTY when every dep is
        # host-system-resolved (default ld.so path) ⇒ no LD_LIBRARY_PATH change
        # ⇒ host-toolchain path byte-identical (no regression).
        LOCAL_RUN_LIBDIRS=""
        _add_run_libdir() {
            [ -n "${1:-}" ] || return 0
            case ":${LOCAL_RUN_LIBDIRS}:" in *":$1:"*) return 0 ;; esac
            LOCAL_RUN_LIBDIRS="${LOCAL_RUN_LIBDIRS:+${LOCAL_RUN_LIBDIRS}:}$1"
        }
        _RENV="$LOCAL_DEPS_ROOT/${HOST_OS}_${HOST_ARCH}/resolved.env"
        if [ -f "$_RENV" ]; then
            # shellcheck disable=SC1090
            . "$_RENV"
            # §11.4.111: link jemalloc by its resolved SONAME basename so a
            # runtime-only host jemalloc (no -devel `libjemalloc.so` symlink)
            # links via `-l:libjemalloc.so.2` instead of the unresolvable bare
            # `-ljemalloc`. Empty JEMALLOC_SO ⇒ keep the bare default.
            [ -n "${JEMALLOC_SO:-}" ] && JEM_LINK="-l:$(basename "$JEMALLOC_SO")"
            case "${JEMALLOC_SOURCE:-}" in
                host-system|host-probe-fallback|"") : ;;  # default path — no -L/-I needed
                *)
                    [ -n "${LOCAL_DEPS_PREFIX:-}" ] && [ -d "${LOCAL_DEPS_PREFIX}/include" ] \
                        && JEM_CPPFLAGS="-I${LOCAL_DEPS_PREFIX}/include"
                    [ -n "${JEMALLOC_LIBDIR:-}" ] && JEM_LDFLAGS="-L${JEMALLOC_LIBDIR}"
                    _add_run_libdir "${JEMALLOC_LIBDIR:-}"
                    ;;
            esac
            case "${LIBEVENT_SOURCE:-}" in
                host-system|host-brew|host-probe-fallback|"") : ;;
                *)
                    [ -n "${LIBEVENT_INCDIR:-}" ] && LE_CPPFLAGS="-I${LIBEVENT_INCDIR}"
                    [ -n "${LIBEVENT_LIBDIR:-}" ] && LE_LDFLAGS="-L${LIBEVENT_LIBDIR}"
                    _add_run_libdir "${LIBEVENT_LIBDIR:-}"
                    _NEED_LOCAL_PC=1
                    ;;
            esac
            case "${NCURSES_SOURCE:-}" in
                host-system|host-brew|host-probe-fallback|"") : ;;
                *)
                    [ -n "${NCURSES_INCDIR:-}" ] && NC_CPPFLAGS="-I${NCURSES_INCDIR}"
                    [ -n "${NCURSES_LIBDIR:-}" ] && NC_LDFLAGS="-L${NCURSES_LIBDIR}"
                    _add_run_libdir "${NCURSES_LIBDIR:-}"
                    _NEED_LOCAL_PC=1
                    ;;
            esac
            # Only prepend the local pkgconfig dir when a local-built build dep
            # is actually in play — avoids a stale local .pc shadowing a
            # host-system resolution on a host that needed neither.
            if [ "$_NEED_LOCAL_PC" = "1" ] && [ -n "${LOCAL_DEPS_PREFIX:-}" ] \
               && [ -d "${LOCAL_DEPS_PREFIX}/lib/pkgconfig" ]; then
                LOCAL_PKGCONFIG="${LOCAL_DEPS_PREFIX}/lib/pkgconfig"
            fi
        fi

        # ── LD_LIBRARY_PATH for autoconf RUN-tests + the final `tmux -V` probe
        # (TMX-FIX-a; amber 2026-06-29) ─────────────────────────────────────
        # autoconf's "checking whether we are cross compiling" RUNS ./conftest,
        # and below this script RUNS the built binary (`"$BIN_PATH" -V`). When a
        # dependency was source-built/obtained into a LOCAL prefix (libjemalloc.so.2
        # / libevent / ncursesw) that is NOT on the default ld.so path, a RUN with
        # no LD_LIBRARY_PATH dies with
        #   ./conftest: error while loading shared libraries: libjemalloc.so.2
        # → autoconf aborts `configure: error: cannot run C compiled programs`
        # (setup --rebuild EXIT 77; forensic:
        # qa-results/loop-20260629/host-install-amber/07_config_log.txt:124). Export
        # the SAME local lib dirs the -L flags already point at so the run-tests +
        # the -V probe can load them. Inherited by the zig subshell below too.
        # EMPTY ⇒ no LD_LIBRARY_PATH change ⇒ fully-host-resolved path unchanged.
        if [ -n "$LOCAL_RUN_LIBDIRS" ]; then
            export LD_LIBRARY_PATH="${LOCAL_RUN_LIBDIRS}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
        fi

        CFLAGS="-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
                -Wno-unused-parameter -Wno-deprecated-declarations \
                ${JEM_CPPFLAGS} ${LE_CPPFLAGS} ${NC_CPPFLAGS} ${CPPFLAGS:-} ${CFLAGS:-}"
        # -L MUST precede -ljemalloc / the libevent+ncurses link for the linker
        # to find the local prefix before any system copy.
        LDFLAGS="-Wl,-z,relro,-z,now ${JEM_LDFLAGS} ${LE_LDFLAGS} ${NC_LDFLAGS} \
                 -Wl,--no-as-needed ${JEM_LINK} -Wl,--as-needed ${LDFLAGS:-}"

        if [ "${CC_KIND:-}" = "zig" ] && [ -n "${CC_WRAPPER_DIR:-}" ] && [ -x "${CC_WRAPPER_DIR}/cc" ]; then
            # ── ROOT-FREE zig toolchain path (TMX-063) ───────────────────────
            # The host has no working C toolchain → obtain_local_deps.sh obtained
            # zig (CC_KIND=zig) + emitted the binutils/flag-filter wrappers, and
            # source-built libevent/ncurses/jemalloc with it. tmux itself is built
            # from THE PINNED SUBMODULE — the same source of record the
            # host-toolchain path below uses — so the binary this path installs
            # into $BUILD_DIR corresponds to the submodule pin.
            #
            # WHY NOT AN UPSTREAM RELEASE TARBALL (changed 2026-09-01, when the
            # operator adopted the next-3.8 pin). This path previously downloaded
            # the sha256-pinned tmux 3.6a RELEASE tarball, because release
            # tarballs ship a pre-generated `configure` + `cmd-parse.c` and the
            # pipeline then needed only zig + make. That is no longer viable and
            # is no longer honest:
            #   * the submodule is pinned at 40381bdc (`3.7b-808-g40381bdc`;
            #     tmux/configure.ac: AC_INIT([tmux], next-3.8));
            #   * upstream publishes NO release tarball for that version —
            #     measured 2026-09-01 by HTTP HEAD, instrument proven seeing
            #     (§11.4.201(7)(b)): .../next-3.8/tmux-next-3.8.tar.gz → 404,
            #     .../3.8/... → 404, while .../3.6a/... and .../3.7b/... → 200;
            #   * the nearest reachable release, 3.7b, IS available (200) but the
            #     pin is 808 commits AHEAD of it (`git -C tmux rev-list --count
            #     3.7b..HEAD` = 808), so re-pointing at 3.7b would trade a
            #     two-release mismatch for an 808-commit one, not fix it.
            # Any tarball here would install a binary whose reported version does
            # not describe the pinned source — a §11.4.108 SOURCE→ARTIFACT
            # integrity gap. The version gates assert on the BUILT BINARY
            # (EXPECTED_VERSION defaults to next-3.8 in scripts/tests/run_all.sh,
            # 01_smoke.sh and 71_root_free_zig_build.sh C5), so a tarball build
            # would either FAIL them honestly or, worse, be green against source
            # nobody reviewed.
            #
            # COST, stated honestly (§11.4.6). The submodule ships NO generated
            # build system — `configure`, `Makefile.in`, `cmd-parse.c` and
            # `aclocal.m4` are all listed in tmux/.gitignore — so on a host where
            # they are absent this path additionally needs the autotools
            # generators (aclocal/automake/autoreconf) and, for `cmd-parse.c`,
            # yacc/bison. None of those needs a working C compiler in order to
            # RUN (autotools are perl+m4; bison ships precompiled), so a zig host
            # may well have them. When it does not, we REFUSE with an actionable
            # message naming exactly what is missing — never silently substitute
            # a mismatched tarball.
            PFX="${LOCAL_DEPS_PREFIX:-$LOCAL_DEPS_ROOT/${HOST_OS}_${HOST_ARCH}}"
            SRCROOT="$PFX/tmux-src"
            TMUX_SRC="$SRCROOT/tmux"
            ZCC="${CC_WRAPPER_DIR}/cc"
            MKBIN="$(command -v make 2>/dev/null || echo /usr/bin/make)"

            [ -f "$REPO_ROOT/tmux/configure.ac" ] || {
                echo "[build_native] ✗ tmux submodule not checked out (no tmux/configure.ac)"
                echo "  fix: git submodule update --init --recursive tmux"
                exit 1
            }
            PIN_VER="$(sed -n 's/^AC_INIT(\[tmux\], *\([^)]*\)).*/\1/p' \
                        "$REPO_ROOT/tmux/configure.ac" | head -1)"

            # ── tarball FAST-PATH, derived from the pin and sha-verified ──────
            # Restored 2026-09-01 after the operator re-pinned to TAG 3.7b.
            # The root-free property this path exists for is "zig + make only":
            # an upstream RELEASE tarball ships a pre-generated ./configure AND
            # cmd-parse.c, so no autotools and no bison are needed. Building from
            # the submodule instead requires both, which measurably broke test 71
            # C4 on a deliberately-neutered bare host.
            #
            # WHY THIS IS NOW SAFE (it was not, under the untagged next-3.8 pin):
            # TMUX_REL_VER is DERIVED from the submodule's own configure.ac, never
            # hardcoded, and the download is refused unless a sha256 is pinned for
            # exactly that version. So the tarball can only ever be the SAME
            # version as the pin. If someone re-pins to a version with no pinned
            # sha (e.g. back to an untagged master commit), this path REFUSES and
            # falls through to the submodule build rather than silently shipping a
            # binary whose -V disagrees with the pin (§11.4.108 SOURCE->ARTIFACT).
            TMUX_REL_VER="$PIN_VER"
            TMUX_REL_SHA=""
            case "$TMUX_REL_VER" in
                3.7b) TMUX_REL_SHA="87f2e99e3b685973f2ca002ffd6ed7e51a5744f7009daae5a15670b6d532db96" ;;
                3.6a) TMUX_REL_SHA="b6d8d9c76585db8ef5fa00d4931902fa4b8cbe8166f528f44fc403961a3f3759" ;;
            esac
            _tarball_ok=0
            if [ -n "$TMUX_REL_SHA" ] && command -v curl >/dev/null 2>&1; then
                TMUX_REL_URL="https://github.com/tmux/tmux/releases/download/${TMUX_REL_VER}/tmux-${TMUX_REL_VER}.tar.gz"
                CACHE="$LOCAL_DEPS_ROOT/.tarballs"; mkdir -p "$CACHE"
                TARBALL="$CACHE/tmux-${TMUX_REL_VER}.tar.gz"
                if [ ! -f "$TARBALL" ]; then
                    echo "[build_native] fetching pinned tmux ${TMUX_REL_VER} release tarball..."
                    curl -fsSL --connect-timeout 30 --max-time 600 -o "$TARBALL" "$TMUX_REL_URL" || rm -f "$TARBALL"
                fi
                if [ -f "$TARBALL" ]; then
                    _got="$(sha256sum "$TARBALL" 2>/dev/null | cut -d' ' -f1)"
                    if [ "$_got" = "$TMUX_REL_SHA" ]; then
                        rm -rf "$SRCROOT"; mkdir -p "$SRCROOT"
                        if tar xzf "$TARBALL" -C "$SRCROOT" 2>/dev/null; then
                            TMUX_SRC="$SRCROOT/tmux-${TMUX_REL_VER}"
                            # keep the no-bison property: make must not re-run yacc
                            [ -f "$TMUX_SRC/cmd-parse.c" ] && touch "$TMUX_SRC/cmd-parse.c"
                            _tarball_ok=1
                            echo "[build_native] ROOT-FREE zig build from the sha256-pinned ${TMUX_REL_VER} RELEASE TARBALL (matches the submodule pin): CC=$ZCC"
                        fi
                    else
                        echo "[build_native] ! tarball sha256 mismatch for ${TMUX_REL_VER} (got ${_got:-none}) — ignoring it, falling back to the submodule"
                        rm -f "$TARBALL"
                    fi
                fi
            fi

            if [ "$_tarball_ok" != "1" ]; then
            echo "[build_native] ROOT-FREE zig build from the PINNED SUBMODULE (${PIN_VER:-unknown}): CC=$ZCC"

            # Build from an ISOLATED COPY of the submodule, never in-tree. This
            # preserves the non-destructive property the tarball path had:
            # scripts/tests/71_root_free_zig_build.sh runs the REAL build without
            # clobbering the operator's tmux/ worktree (§12 host-safety +
            # §11.4.14). It also makes the build immune to the worktree's
            # generated files changing underneath it mid-build.
            rm -rf "$SRCROOT"; mkdir -p "$TMUX_SRC"
            tar -cf - -C "$REPO_ROOT/tmux" \
                --exclude=.git --exclude=build --exclude=build-darwin \
                --exclude=.deps --exclude='*.o' . \
                | tar -xf - -C "$TMUX_SRC" \
                || { echo "[build_native] ✗ could not copy the tmux submodule into $TMUX_SRC"; exit 1; }
            # Drop configure/compile state carried over from a HOST-toolchain
            # build of the worktree: it is stale for the zig toolchain and would
            # make `make` reuse host-compiled state. `configure` below regenerates
            # all of it. `configure` / `Makefile.in` themselves are KEPT.
            rm -f "$TMUX_SRC/config.status" "$TMUX_SRC/config.log" \
                  "$TMUX_SRC/config.h" "$TMUX_SRC/Makefile"

            # ── generated build system: probe, never assume (§11.4.6) ─────────
            if [ ! -f "$TMUX_SRC/configure" ]; then
                _missing_gen=""
                for _g in aclocal automake autoreconf; do
                    command -v "$_g" >/dev/null 2>&1 \
                        || _missing_gen="${_missing_gen:+$_missing_gen }$_g"
                done
                if [ -n "$_missing_gen" ]; then
                    echo "[build_native] ✗ cannot build the pinned tmux source root-free."
                    echo "    The submodule ships no pre-generated ./configure (it is"
                    echo "    .gitignore'd) and these autotools generators are MISSING:"
                    echo "      $_missing_gen"
                    echo "    This path deliberately REFUSES to substitute an upstream"
                    echo "    release tarball: upstream publishes none for the pinned"
                    echo "    version (${PIN_VER:-unknown}), so any tarball would install a"
                    echo "    binary that does not correspond to the pin (§11.4.108)."
                    echo "  fix: install the generators — they need no C compiler to run:"
                    echo "    Debian/Ubuntu: apt-get install autoconf automake bison"
                    echo "    Fedora/RHEL:   dnf install autoconf automake bison"
                    echo "    Alpine:        apk add autoconf automake bison"
                    exit 1
                fi
                echo "[build_native] generating ./configure from the submodule (autogen.sh)..."
                # `|| true`: under `set -euo pipefail` a failing autogen.sh would
                # abort here and the actionable refusal below would never print
                # (measured). Let it fall through to the explicit check.
                ( cd "$TMUX_SRC" && sh autogen.sh ) 2>&1 | tail -5 || true
                [ -f "$TMUX_SRC/configure" ] || {
                    echo "[build_native] ✗ autogen.sh did not produce ./configure"; exit 1; }
            fi

            # cmd-parse.c is generated from cmd-parse.y by yacc. When the copy
            # already carries a generated one, touch it newer than the .y so make
            # never invokes the yacc rule (YACC=true is then a never-called no-op
            # — this preserves the old tarball path's "no bison needed" property
            # whenever the worktree happens to be already generated). When it is
            fi   # end submodule-build fallback (tarball fast-path skipped it)

            # ABSENT a real yacc/bison is REQUIRED: forcing YACC=true there would
            # silently build a tmux with no command parser.
            ZYACC="true"
            if [ -f "$TMUX_SRC/cmd-parse.c" ]; then
                touch "$TMUX_SRC/cmd-parse.c"
            else
                # BARE word, never an absolute path, and `-y` is mandatory:
                #   * tmux/configure's AC_CHECK_PROG concatenates a $PATH entry
                #     with $ac_word, so a slash-bearing value can never resolve
                #     ("/usr/bin//usr/bin/bison") and configure aborts with
                #     "yacc not found" -- on a host that HAS bison. Measured.
                #   * tmux/Makefile.in's .y.c rule drives etc/ylwrap, which
                #     requires the program to emit y.tab.c. Plain `bison` emits
                #     cmd-parse.tab.c and ylwrap still EXITS 0 -- a silent failure
                #     leaving make with no cmd-parse.c. `bison -y` emits the
                #     expected name. Measured both ways with a control needle.
                if command -v bison >/dev/null 2>&1; then ZYACC="bison -y"
                elif command -v yacc >/dev/null 2>&1; then ZYACC="yacc"
                else ZYACC=""; fi
                [ -n "$ZYACC" ] || {
                    echo "[build_native] ✗ cmd-parse.c is not pre-generated and no yacc/bison found."
                    echo "    Forcing YACC=true here would build a tmux with no command parser."
                    echo "  fix: install bison (Debian/Ubuntu: apt-get install bison)"
                    exit 1
                }
            fi

            # zig-specific flags: ncursesw widec headers live at include/ncursesw/;
            # --allow-shlib-undefined relaxes the configure link probe (host
            # libtinfo references a private glibc symbol → otherwise a misleading
            # forkpty failure). Hardened flags identical to the host build.
            ZCFLAGS="-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
                     -Wno-unused-parameter -Wno-deprecated-declarations \
                     -I$PFX/include -I$PFX/include/ncursesw"
            ZLDFLAGS="-Wl,-z,relro,-z,now -L$PFX/lib -Wl,--allow-shlib-undefined"
            [ -n "${JEMALLOC_LIBDIR:-}" ] && ZLDFLAGS="$ZLDFLAGS -L${JEMALLOC_LIBDIR}"
            # zig path links the LOCAL-BUILD jemalloc in $PFX/lib, which jemalloc's
            # `make install` ships WITH a `libjemalloc.so` dev symlink, so bare
            # `-ljemalloc` (resolved via -L$PFX/lib above) links correctly here.
            # It MUST stay bare: the obtained zig cc/LLD wrapper does NOT accept
            # the GNU `-l:NAME` extension — passing ${JEM_LINK}=-l:libjemalloc.so.2
            # dies `configure: error: C compiler cannot create executables`
            # (regression caught 2026-06-30, qa-results/loop-20260630/). The
            # resolved-SONAME ${JEM_LINK} form is needed ONLY on the HOST path
            # (a runtime-only host jemalloc with no dev symlink). §11.4.111 honest
            # boundary: same resource, but the zig toolchain + local-build symlink
            # make bare the correct stable resolution here.
            ZLDFLAGS="$ZLDFLAGS -Wl,--no-as-needed -ljemalloc -Wl,--as-needed"

            echo "[build_native] configuring tmux ${PIN_VER:-unknown} (zig, pinned submodule source)..."
            (
                cd "$TMUX_SRC"
                PATH="${CC_WRAPPER_DIR}:$PATH"; export PATH
                export CC="$ZCC" YACC="$ZYACC" MAKE="$MKBIN"
                CC="$ZCC" YACC="$ZYACC" MAKE="$MKBIN" \
                CFLAGS="$ZCFLAGS" LDFLAGS="$ZLDFLAGS" \
                PKG_CONFIG_PATH="${LOCAL_PKGCONFIG:+${LOCAL_PKGCONFIG}:}${PKG_CONFIG_PATH:-}" \
                    ./configure --prefix="$BUILD_DIR" --disable-debug 2>&1 | tail -10
                "$MKBIN" -j"$(nproc)" 2>&1 | tail -5
                "$MKBIN" install 2>&1 | tail -3
            ) || { echo "[build_native] ✗ zig tmux build FAILED"; exit 1; }
        else
            # ── existing host-toolchain submodule path ───────────────────────
            # ── TMX-FIX-c: static libtinfo seam (CC_KIND=host native build) ──
            # resolved.env (sourced above) carries TINFO_STATIC when
            # obtain_local_deps RESOLVED a host static libtinfo.a (amber:
            # /usr/lib/x86_64-linux-gnu/libtinfo.a) OR BUILT a local one. tmux's
            # configure uses PKG_CHECK_MODULES(LIBTINFO,tinfo) — setting BOTH
            # LIBTINFO_CFLAGS (non-empty) AND LIBTINFO_LIBS makes it take the
            # ENV-override branch WITHOUT a tinfo.pc (amber has none), so tmux
            # links the STATIC archive (-l:libtinfo.a) → NO libtinfo.so DT_NEEDED
            # → CM-NO-DYNAMIC-LIBTINFO / test 61 T2 pass (the cross-distro guard
            # the containerized build already gets). EMPTY TINFO_STATIC ⇒ both
            # vars stay empty ⇒ `test -n ""` false in PKG_CHECK_MODULES ⇒
            # configure unchanged (dynamic -ltinfo; gate FAILs honestly). The zig
            # path above keeps its DYNAMIC local libncursesw (test 71 C7).
            TINFO_CFG_CFLAGS=""; TINFO_CFG_LIBS=""
            if [ -n "${TINFO_STATIC:-}" ] && [ -f "${TINFO_STATIC}" ]; then
                TINFO_CFG_CFLAGS="-I${TINFO_INCDIR:-/usr/include}"
                TINFO_CFG_LIBS="-l:libtinfo.a"
                [ -n "${TINFO_LIBDIR:-}" ] && LDFLAGS="-L${TINFO_LIBDIR} $LDFLAGS"
                echo "[build_native] static tinfo: LIBTINFO_LIBS='$TINFO_CFG_LIBS' from ${TINFO_STATIC} (${TINFO_SOURCE:-?})"
            else
                echo "[build_native] ⚠ no static libtinfo.a (TINFO_STATIC unset) — linking dynamic -ltinfo (CM-NO-DYNAMIC-LIBTINFO will FAIL honestly)"
            fi
            cd "$REPO_ROOT/tmux"
            if [ ! -f configure ]; then
                sh autogen.sh 2>&1 | tail -3
            fi
            if [ -f Makefile ]; then
                make clean 2>&1 | tail -2 || true
            fi

            echo "[build_native] configuring..."
            CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
            LIBTINFO_CFLAGS="$TINFO_CFG_CFLAGS" LIBTINFO_LIBS="$TINFO_CFG_LIBS" \
            PKG_CONFIG_PATH="${LOCAL_PKGCONFIG:+${LOCAL_PKGCONFIG}:}${PKG_CONFIG_PATH:-}" \
                ./configure --prefix="$BUILD_DIR" --disable-debug 2>&1 | tail -10

            make -j"$(nproc)" 2>&1 | tail -5
            make install 2>&1 | tail -3
        fi

        if [ ! -x "$BIN_PATH" ]; then
            echo "[build_native] ✗ BUILD FAILED — no $BIN_PATH"
            exit 1
        fi
        echo "  version: $("$BIN_PATH" -V 2>&1 | head -1)"
        echo "  format:  $(file "$BIN_PATH" | sed 's|^[^:]*: *||')"
        ;;

    *)
        echo "[build_native] ERROR: unsupported OS '$HOST_OS'."
        echo "  Supported: Darwin (macOS), Linux."
        exit 2
        ;;
esac

echo ""
echo "[build_native] ✓ binary produced: $BIN_PATH"
echo "[build_native] next: bash scripts/setup.sh   # generates tmx wrapper + installs shell snippet"
