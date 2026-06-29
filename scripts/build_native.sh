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
        BUILD_DIR="$REPO_ROOT/tmux/build-darwin"
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
        BUILD_DIR="$REPO_ROOT/tmux/build"
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
        _RENV="$REPO_ROOT/.local-deps/${HOST_OS}_${HOST_ARCH}/resolved.env"
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
