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
        _RENV="$LOCAL_DEPS_ROOT/${HOST_OS}_${HOST_ARCH}/resolved.env"
        if [ -f "$_RENV" ]; then
            # shellcheck disable=SC1090
            . "$_RENV"
            case "${JEMALLOC_SOURCE:-}" in
                host-system|host-probe-fallback|"") : ;;  # default path — no -L/-I needed
                *)
                    [ -n "${LOCAL_DEPS_PREFIX:-}" ] && [ -d "${LOCAL_DEPS_PREFIX}/include" ] \
                        && JEM_CPPFLAGS="-I${LOCAL_DEPS_PREFIX}/include"
                    [ -n "${JEMALLOC_LIBDIR:-}" ] && JEM_LDFLAGS="-L${JEMALLOC_LIBDIR}"
                    ;;
            esac
            case "${LIBEVENT_SOURCE:-}" in
                host-system|host-brew|host-probe-fallback|"") : ;;
                *)
                    [ -n "${LIBEVENT_INCDIR:-}" ] && LE_CPPFLAGS="-I${LIBEVENT_INCDIR}"
                    [ -n "${LIBEVENT_LIBDIR:-}" ] && LE_LDFLAGS="-L${LIBEVENT_LIBDIR}"
                    _NEED_LOCAL_PC=1
                    ;;
            esac
            case "${NCURSES_SOURCE:-}" in
                host-system|host-brew|host-probe-fallback|"") : ;;
                *)
                    [ -n "${NCURSES_INCDIR:-}" ] && NC_CPPFLAGS="-I${NCURSES_INCDIR}"
                    [ -n "${NCURSES_LIBDIR:-}" ] && NC_LDFLAGS="-L${NCURSES_LIBDIR}"
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

        CFLAGS="-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
                -Wno-unused-parameter -Wno-deprecated-declarations \
                ${JEM_CPPFLAGS} ${LE_CPPFLAGS} ${NC_CPPFLAGS} ${CPPFLAGS:-} ${CFLAGS:-}"
        # -L MUST precede -ljemalloc / the libevent+ncurses link for the linker
        # to find the local prefix before any system copy.
        LDFLAGS="-Wl,-z,relro,-z,now ${JEM_LDFLAGS} ${LE_LDFLAGS} ${NC_LDFLAGS} \
                 -Wl,--no-as-needed -ljemalloc -Wl,--as-needed ${LDFLAGS:-}"

        if [ "${CC_KIND:-}" = "zig" ] && [ -n "${CC_WRAPPER_DIR:-}" ] && [ -x "${CC_WRAPPER_DIR}/cc" ]; then
            # ── ROOT-FREE zig toolchain path (TMX-063) ───────────────────────
            # The host has no working C toolchain → obtain_local_deps.sh obtained
            # zig (CC_KIND=zig) + emitted the binutils/flag-filter wrappers, and
            # source-built libevent/ncurses/jemalloc with it. Build tmux from the
            # sha256-pinned 3.6a RELEASE tarball (ships pre-generated configure +
            # cmd-parse.c → NO autotools generators, NO bison: YACC=true) so the
            # WHOLE pipeline needs only zig + make. Proven end-to-end on this host
            # 2026-06-29 (qa-results/loop-20260629/zig-impl/).
            TMUX_REL_VER="3.6a"
            TMUX_REL_URL="https://github.com/tmux/tmux/releases/download/3.6a/tmux-3.6a.tar.gz"
            TMUX_REL_SHA="b6d8d9c76585db8ef5fa00d4931902fa4b8cbe8166f528f44fc403961a3f3759"
            PFX="${LOCAL_DEPS_PREFIX:-$LOCAL_DEPS_ROOT/${HOST_OS}_${HOST_ARCH}}"
            CACHE="$LOCAL_DEPS_ROOT/.tarballs"; mkdir -p "$CACHE"
            SRCROOT="$PFX/tmux-src"
            TARBALL="$CACHE/tmux-${TMUX_REL_VER}.tar.gz"
            ZCC="${CC_WRAPPER_DIR}/cc"
            MKBIN="$(command -v make 2>/dev/null || echo /usr/bin/make)"

            echo "[build_native] ROOT-FREE zig build: CC=$ZCC"
            # download + sha256-verify the release tarball (network-frugal cache).
            _shatool() { command -v sha256sum >/dev/null 2>&1 && { sha256sum "$1" | awk '{print $1}'; return; }; command -v shasum >/dev/null 2>&1 && shasum -a 256 "$1" | awk '{print $1}'; }
            if [ -f "$TARBALL" ]; then [ "$(_shatool "$TARBALL")" = "$TMUX_REL_SHA" ] || rm -f "$TARBALL"; fi
            if [ ! -f "$TARBALL" ]; then
                echo "[build_native] downloading $TMUX_REL_URL"
                if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$TARBALL" "$TMUX_REL_URL"
                elif command -v wget >/dev/null 2>&1; then wget -q -O "$TARBALL" "$TMUX_REL_URL"
                else echo "[build_native] ✗ no curl/wget to fetch tmux release tarball"; exit 1; fi
            fi
            GOT_SHA="$(_shatool "$TARBALL")"
            if [ "$GOT_SHA" != "$TMUX_REL_SHA" ]; then
                echo "[build_native] ✗ tmux tarball sha256 MISMATCH — want $TMUX_REL_SHA got $GOT_SHA"
                rm -f "$TARBALL"; exit 1
            fi
            echo "[build_native] tmux tarball sha256 verified ($TMUX_REL_SHA)"

            rm -rf "$SRCROOT"; mkdir -p "$SRCROOT"
            tar xzf "$TARBALL" -C "$SRCROOT"
            TMUX_SRC="$SRCROOT/tmux-${TMUX_REL_VER}"
            [ -d "$TMUX_SRC" ] || { echo "[build_native] ✗ tmux source dir missing after extract"; exit 1; }
            # cmd-parse.c ships pre-generated; touch it newer than cmd-parse.y so
            # make never invokes the yacc rule (YACC=true is a never-called no-op).
            touch "$TMUX_SRC/cmd-parse.c"

            # zig-specific flags: ncursesw widec headers live at include/ncursesw/;
            # --allow-shlib-undefined relaxes the configure link probe (host
            # libtinfo references a private glibc symbol → otherwise a misleading
            # forkpty failure). Hardened flags identical to the host build.
            ZCFLAGS="-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
                     -Wno-unused-parameter -Wno-deprecated-declarations \
                     -I$PFX/include -I$PFX/include/ncursesw"
            ZLDFLAGS="-Wl,-z,relro,-z,now -L$PFX/lib -Wl,--allow-shlib-undefined"
            [ -n "${JEMALLOC_LIBDIR:-}" ] && ZLDFLAGS="$ZLDFLAGS -L${JEMALLOC_LIBDIR}"
            ZLDFLAGS="$ZLDFLAGS -Wl,--no-as-needed -ljemalloc -Wl,--as-needed"

            echo "[build_native] configuring tmux $TMUX_REL_VER (zig, YACC=true, release tarball)..."
            (
                cd "$TMUX_SRC"
                PATH="${CC_WRAPPER_DIR}:$PATH"; export PATH
                export CC="$ZCC" YACC=true MAKE="$MKBIN"
                CC="$ZCC" YACC=true MAKE="$MKBIN" \
                CFLAGS="$ZCFLAGS" LDFLAGS="$ZLDFLAGS" \
                PKG_CONFIG_PATH="${LOCAL_PKGCONFIG:+${LOCAL_PKGCONFIG}:}${PKG_CONFIG_PATH:-}" \
                    ./configure --prefix="$BUILD_DIR" --disable-debug 2>&1 | tail -10
                "$MKBIN" -j"$(nproc)" 2>&1 | tail -5
                "$MKBIN" install 2>&1 | tail -3
            ) || { echo "[build_native] ✗ zig tmux build FAILED"; exit 1; }
        else
            # ── existing host-toolchain submodule path (unchanged) ───────────
            cd "$REPO_ROOT/tmux"
            if [ ! -f configure ]; then
                sh autogen.sh 2>&1 | tail -3
            fi
            if [ -f Makefile ]; then
                make clean 2>&1 | tail -2 || true
            fi

            echo "[build_native] configuring..."
            CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
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
