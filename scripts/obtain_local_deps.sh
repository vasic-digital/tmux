#!/usr/bin/env bash
# obtain_local_deps.sh — per-host LOCAL-DEPENDENCY obtaining mechanism.
# ─────────────────────────────────────────────────────────────────────────
# Purpose:
#   For every host we distribute to, install LOCALLY (git-ignored) every
#   runtime dependency the host may be missing, with a cross-platform
#   obtaining mechanism that kicks in out-of-the-box during setup. The
#   first + primary consumer is jemalloc (the project's core hardening
#   allocator), which:
#     - amber  : has NO host jemalloc AND no sudo to install one → a
#                container-built binary with DT_NEEDED libjemalloc.so.2
#                CANNOT START (loader: "libjemalloc.so.2: cannot open
#                shared object file").
#     - mistborn: HAS jemalloc via Homebrew, but `command -v brew` FAILS
#                under a non-interactive SSH PATH (the exit-3 root cause),
#                so setup never resolves it.
#   Beyond the runtime allocator, this script also obtains the tmux BUILD
#   dependencies a forced NATIVE build needs on a minimal host — libevent and
#   ncurses (widec) — so setup.sh's native-build fallback links even where the
#   host lacks libevent-dev / libncurses-dev (e.g. nezha has NO libevent:
#   /usr/include/event2/event.h absent). Build deps are source-built into the
#   local prefix WITH their pkg-config .pc files; build_native.sh adds
#   -I/-L + PKG_CONFIG_PATH so tmux's ./configure finds the local copies.
#
#   This script (a) RESOLVES an already-present dependency by ABSOLUTE path
#   (§11.4.111 — never ambient `command -v`/PATH for the dependency), and
#   (b) OBTAINS it git-ignored into .local-deps/ when genuinely missing,
#   producing a host-runnable shared library. jemalloc STAYS DYNAMIC
#   (DT_NEEDED libjemalloc.so.2 / LC_LOAD_DYLIB preserved) — this script
#   only makes the library AVAILABLE; the binary/wrapper then find it via
#   patchelf rpath (set by setup.sh) + LD_PRELOAD/LD_LIBRARY_PATH (Linux)
#   or DYLD_INSERT_LIBRARIES/DYLD_LIBRARY_PATH (macOS).
#
# Usage:
#   bash scripts/obtain_local_deps.sh            # resolve-or-obtain all deps
#   FORCE_OBTAIN=1 bash scripts/obtain_local_deps.sh   # skip host detection,
#                                                       # always obtain locally
#   LOCAL_DEPS_ROOT=/path bash scripts/obtain_local_deps.sh  # override root
#   DEPS="jemalloc libevent ncurses go" bash scripts/obtain_local_deps.sh  # all
#
# Inputs (env, all optional):
#   FORCE_OBTAIN     1 → skip host detection, obtain into the local prefix.
#   LOCAL_DEPS_ROOT  override the git-ignored root (default <repo>/.local-deps).
#   DEPS             space-separated dep names. Default "jemalloc" (backward
#                    compatible); setup.sh passes "jemalloc libevent ncurses"
#                    so the native-build fallback has its build deps ready.
#   OBTAIN_METHOD    auto|source|container (Linux obtain method; default auto).
#
# Outputs:
#   .local-deps/<uname-s>_<uname-m>/lib/<libname>     the obtained library
#   .local-deps/<uname-s>_<uname-m>/resolved.env      KEY=VALUE sourceable
#       runtime dep (jemalloc): JEMALLOC_SO=…, JEMALLOC_LIBDIR=…, JEMALLOC_SOURCE=…
#       build deps (libevent/ncurses): LIBEVENT_LIBDIR/_INCDIR/_SOURCE,
#       NCURSES_LIBDIR/_INCDIR/_SOURCE
#   "RESOLVED <dep> …" / "OBTAINED <dep> …" lines on stdout.
#
# Side-effects:
#   Creates/populates the git-ignored .local-deps/ tree. NO sudo. NO host
#   package-manager mutation except an explicit `brew install` fallback on
#   macOS when a compiler is unavailable. Idempotent: a present+valid local
#   library is reused, not rebuilt.
#
# Dependencies:
#   Resolve: ldconfig (Linux) / absolute brew (macOS) / pkg-config / file globs.
#   Obtain (source): a C compiler (cc/gcc/clang) + make + curl|wget + tar +
#     a sha256 tool (sha256sum / shasum). Obtain (container, Linux fallback):
#     podman|docker + the docker/Dockerfile build image.
#
# Cross-references:
#   scripts/setup.sh (Step 1b invokes this; Step 2b applies patchelf rpath) ;
#   scripts/tmx.template (LD_PRELOAD/LD_LIBRARY_PATH + DYLD_* from resolved.env) ;
#   .gitignore-meta/local_deps.yaml (§11.4.77 regen manifest) ;
#   scripts/tests/67_local_deps.sh (anti-bluff coverage) ;
#   docs/scripts/obtain_local_deps.md (§11.4.18 companion guide).
#
# §11.4.67: bash -n clean (executed as bash; uses bash arrays/case only).
# §11.4.77: the git-ignored .local-deps/ tree's documented obtain mechanism.
# §11.4.81: cross-platform (Linux source/container + macOS source/brew).
# §11.4.111: dependencies resolved by ABSOLUTE path, never by ambient PATH.
# Last verified: 2026-06-28
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
PLAT="${HOST_OS}_${HOST_ARCH}"

LOCAL_DEPS_ROOT="${LOCAL_DEPS_ROOT:-$REPO_ROOT/.local-deps}"
LOCAL_PREFIX="$LOCAL_DEPS_ROOT/$PLAT"
LIBDIR="$LOCAL_PREFIX/lib"
INCDIR="$LOCAL_PREFIX/include"
RESOLVED_ENV="$LOCAL_PREFIX/resolved.env"
TARBALL_CACHE="$LOCAL_DEPS_ROOT/.tarballs"

FORCE_OBTAIN="${FORCE_OBTAIN:-0}"
OBTAIN_METHOD="${OBTAIN_METHOD:-auto}"
DEPS="${DEPS:-jemalloc}"

# Records the ACTUAL obtain method an obtain_via_* function used, so the main
# loop labels JEMALLOC_SOURCE honestly (§11.4.6) — in `auto` mode OBTAIN_METHOD
# stays "auto" even when the container path runs, so it cannot be the label
# source. Set by obtain_via_source ("source") / obtain_via_container ("container").
_LAST_OBTAIN_METHOD=""

# Exit codes (typed errors — never fake success):
#   0  ok            10 no obtain toolchain      11 network unreachable
#   12 sha256 mismatch  13 container obtain failed  14 unsupported dep/os
EC_NO_TOOLCHAIN=10
EC_NETWORK=11
EC_SHA=12
EC_CONTAINER=13
EC_UNSUPPORTED=14

_info() { printf '[obtain-deps] %s\n' "$*"; }
_warn() { printf '[obtain-deps] WARN: %s\n' "$*" >&2; }
_err()  { printf '[obtain-deps] ERROR: %s\n' "$*" >&2; }

# ── absolute-path tool resolver (§11.4.111) ───────────────────────────────
# Print the first executable among the given candidate ABSOLUTE paths.
# Returns 1 if none. A trailing bare name (e.g. "gcc") falls back to a
# PATH lookup for TOOLCHAIN binaries only (compilers/make/curl) — never for
# the dependency itself, whose resolution is strictly absolute below.
_first_exe() {
    local c
    for c in "$@"; do
        case "$c" in
            /*) [ -x "$c" ] && { printf '%s' "$c"; return 0; } ;;
            *)  command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; } ;;
        esac
    done
    return 1
}

_sha256_of() {
    local f="$1" tool
    if tool="$(_first_exe /usr/bin/sha256sum /bin/sha256sum sha256sum)"; then
        "$tool" "$f" | awk '{print $1}'
        return 0
    fi
    if tool="$(_first_exe /usr/bin/shasum /bin/shasum shasum)"; then
        "$tool" -a 256 "$f" | awk '{print $1}'
        return 0
    fi
    return 1
}

# ── declarative dependency registry (bash-3.2 safe: case, no assoc arrays) ──
# Add a new dependency by adding case branches here + a resolve/obtain note.
#
# Per-dep `kind` (§11.4.6):
#   runtime — a shared library the wrapper PRELOADS (jemalloc): resolved.env
#             emits <PREFIX>_SO (ABSOLUTE), <PREFIX>_LIBDIR, <PREFIX>_SOURCE.
#   build   — a BUILD dependency tmux's `./configure` links against (libevent,
#             ncurses): resolved.env emits <PREFIX>_LIBDIR, <PREFIX>_INCDIR,
#             <PREFIX>_SOURCE; build_native.sh adds -I/-L + PKG_CONFIG_PATH.
# `configure_args` may contain the literal token @PREFIX@ — obtain_via_source
# substitutes it with the resolved $LOCAL_PREFIX (used by ncurses for its
# pkg-config .pc install dir). `build_targets` empty ⇒ the default `all`.
# `container_extract` = yes only for deps the docker/Dockerfile image carries
# (jemalloc); build deps are source-only (no container recipe — honest fail).
dep_field() {
    case "$1:$2" in
        jemalloc:version)        printf '%s' "5.3.0" ;;
        jemalloc:url)            printf '%s' "https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2" ;;
        jemalloc:sha256)         printf '%s' "2db82d1e7119df3e71b7640219b6dfe84789bc0537983c3b7ac4f7189aecfeaa" ;;
        jemalloc:linux_lib)      printf '%s' "libjemalloc.so.2" ;;
        jemalloc:macos_libs)     printf '%s' "libjemalloc.2.dylib libjemalloc.dylib" ;;
        jemalloc:pkgconfig)      printf '%s' "jemalloc" ;;
        jemalloc:brew)           printf '%s' "jemalloc" ;;
        jemalloc:envprefix)      printf '%s' "JEMALLOC" ;;
        jemalloc:kind)           printf '%s' "runtime" ;;
        jemalloc:container_extract) printf '%s' "yes" ;;
        jemalloc:configure_args) printf '%s' "--disable-debug" ;;
        jemalloc:build_targets)  printf '%s' "build_lib_shared" ;;
        jemalloc:install_targets) printf '%s' "install_lib_shared install_include" ;;

        # libevent — tmux's event loop. Source-built shared (no OpenSSL, no
        # static, no samples/regress) into the local prefix; installs
        # libevent.pc into <prefix>/lib/pkgconfig (autotools default) so tmux's
        # configure pkg-config check finds it. soname libevent-2.1.so.7
        # (Makefile.am VERSION_INFO=7:1:0 → current-age = 7-0 = 7).
        libevent:version)        printf '%s' "2.1.12-stable" ;;
        libevent:url)            printf '%s' "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz" ;;
        libevent:sha256)         printf '%s' "92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb" ;;
        libevent:linux_lib)      printf '%s' "libevent-2.1.so.7 libevent.so" ;;
        libevent:macos_libs)     printf '%s' "libevent-2.1.7.dylib libevent.dylib" ;;
        libevent:pkgconfig)      printf '%s' "libevent" ;;
        libevent:brew)           printf '%s' "libevent" ;;
        libevent:envprefix)      printf '%s' "LIBEVENT" ;;
        libevent:kind)           printf '%s' "build" ;;
        libevent:header)         printf '%s' "event2/event.h" ;;
        libevent:container_extract) printf '%s' "no" ;;
        libevent:configure_args) printf '%s' "--disable-openssl --disable-debug-mode --disable-static --enable-shared --disable-samples --disable-libevent-regress" ;;
        libevent:build_targets)  printf '%s' "" ;;
        libevent:install_targets) printf '%s' "install" ;;

        # ncurses (widec) — tmux's terminal library. Source-built shared widec
        # into the local prefix WITH .pc files (--enable-pc-files +
        # --with-pkg-config-libdir=@PREFIX@/lib/pkgconfig → ncursesw.pc, which
        # tmux's configure resolves via `pkg-config ncursesw`). soname
        # libncursesw.so.6.
        ncurses:version)         printf '%s' "6.5" ;;
        ncurses:url)             printf '%s' "https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz" ;;
        ncurses:sha256)          printf '%s' "136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6" ;;
        ncurses:linux_lib)       printf '%s' "libncursesw.so.6 libncursesw.so" ;;
        ncurses:macos_libs)      printf '%s' "libncursesw.6.dylib libncursesw.dylib" ;;
        ncurses:pkgconfig)       printf '%s' "ncursesw" ;;
        ncurses:brew)            printf '%s' "ncurses" ;;
        ncurses:envprefix)       printf '%s' "NCURSES" ;;
        ncurses:kind)            printf '%s' "build" ;;
        ncurses:header)          printf '%s' "ncurses.h ncursesw/curses.h" ;;
        ncurses:container_extract) printf '%s' "no" ;;
        ncurses:configure_args)  printf '%s' "--with-shared --without-debug --without-ada --without-cxx-binding --without-tests --without-manpages --enable-widec --enable-pc-files --with-pkg-config-libdir=@PREFIX@/lib/pkgconfig --disable-stripping" ;;
        ncurses:build_targets)   printf '%s' "" ;;
        ncurses:install_targets) printf '%s' "install" ;;

        # go — the tmx-state build toolchain (kind=toolchain, §11.4.77). FACT:
        # tmx-state is PURE Go (scripts/tmx-state/go.mod declares `go 1.21` with
        # ZERO `require`; no `import "C"`/cgo/sqlite) → building with
        # CGO_ENABLED=0 needs NO C compiler — the Go toolchain ALONE suffices.
        # RESOLVED-first by ABSOLUTE path (resolve_go, §11.4.111); OBTAINED as a
        # PREBUILT official tarball (obtain_via_prebuilt) — NOT ./configure+make,
        # so kind=toolchain dispatches differently from runtime/build deps.
        # Per-platform url+sha256 keyed by the Go platform tuple (4 official
        # variants linux/darwin × amd64/arm64, §11.4.81); any other arch →
        # EC_UNSUPPORTED (honest, never a fake build). Checksums copied verbatim
        # from the authoritative https://go.dev/dl/?mode=json on 2026-06-29
        # (§11.4.99 latest-source — DO NOT invent). go.mod minimum = go 1.21.
        go:version)              printf '%s' "1.25.11" ;;
        go:kind)                 printf '%s' "toolchain" ;;
        go:envprefix)            printf '%s' "GO" ;;
        go:min_major)            printf '%s' "1" ;;
        go:min_minor)            printf '%s' "21" ;;
        go:url_linux_amd64)      printf '%s' "https://go.dev/dl/go1.25.11.linux-amd64.tar.gz" ;;
        go:url_linux_arm64)      printf '%s' "https://go.dev/dl/go1.25.11.linux-arm64.tar.gz" ;;
        go:url_darwin_amd64)     printf '%s' "https://go.dev/dl/go1.25.11.darwin-amd64.tar.gz" ;;
        go:url_darwin_arm64)     printf '%s' "https://go.dev/dl/go1.25.11.darwin-arm64.tar.gz" ;;
        go:sha256_linux_amd64)   printf '%s' "34f14304e856893f4ba30c2cacfe93906e9de7915c5f6aaaf3a81cdccd7ba30b" ;;
        go:sha256_linux_arm64)   printf '%s' "c30bf9e156a54ea4e31fbbbf31a712b32734b58cc9a22426fa5ee632d0885124" ;;
        go:sha256_darwin_amd64)  printf '%s' "26d0ee4071de42b5c332337db9fdd234072877697c547e46e85efb0f59507c66" ;;
        go:sha256_darwin_arm64)  printf '%s' "cd8d4920e7930d55da1a5a57ba43a64b1305f71cdf2ca3c76cd8c549272b1680" ;;
        go:container_extract)    printf '%s' "no" ;;
        *) return 1 ;;
    esac
}

# Library file name(s) we look for on this OS.
_dep_libnames() {
    local dep="$1"
    if [ "$HOST_OS" = "Darwin" ]; then
        dep_field "$dep" macos_libs
    else
        dep_field "$dep" linux_lib
    fi
}

# ── RESOLVE: find an already-present copy of <dep> by ABSOLUTE path ─────────
# Detection order (first hit wins): pkg-config → ldconfig (Linux) →
# absolute brew (macOS) → common lib dirs → .local-deps/. Prints the
# absolute path to the resolved shared library; returns 1 if none.
resolve_existing() {
    local dep="$1" libnames lib pc pcbin libdir cand b brewpfx ldc d
    libnames="$(_dep_libnames "$dep")"

    # (1) pkg-config — absolute candidates only.
    pc="$(dep_field "$dep" pkgconfig || true)"
    if [ -n "$pc" ]; then
        pcbin="$(_first_exe /usr/bin/pkg-config /usr/local/bin/pkg-config /opt/homebrew/bin/pkg-config /bin/pkg-config || true)"
        if [ -n "$pcbin" ] && "$pcbin" --exists "$pc" >/dev/null 2>&1; then
            libdir="$("$pcbin" --variable=libdir "$pc" 2>/dev/null || true)"
            if [ -n "$libdir" ]; then
                for lib in $libnames; do
                    [ -e "$libdir/$lib" ] && { printf '%s\n' "$libdir/$lib"; return 0; }
                done
            fi
        fi
    fi

    # (2) ldconfig -p (Linux) — last field of the matching line is absolute.
    if [ "$HOST_OS" != "Darwin" ]; then
        ldc="$(_first_exe /sbin/ldconfig /usr/sbin/ldconfig /usr/bin/ldconfig ldconfig || true)"
        if [ -n "$ldc" ]; then
            for lib in $libnames; do
                cand="$("$ldc" -p 2>/dev/null | awk -v n="$lib" '$0 ~ n {print $NF; exit}' || true)"
                [ -n "$cand" ] && [ -e "$cand" ] && { printf '%s\n' "$cand"; return 0; }
            done
        fi
    fi

    # (3) macOS Homebrew — ABSOLUTE brew binary (fixes the non-interactive
    #     SSH PATH case where `command -v brew` fails on mistborn).
    if [ "$HOST_OS" = "Darwin" ]; then
        local brewname; brewname="$(dep_field "$dep" brew || true)"
        if [ -n "$brewname" ]; then
            for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                [ -x "$b" ] || continue
                brewpfx="$("$b" --prefix "$brewname" 2>/dev/null || true)"
                [ -n "$brewpfx" ] || continue
                for lib in $libnames; do
                    [ -e "$brewpfx/lib/$lib" ] && { printf '%s\n' "$brewpfx/lib/$lib"; return 0; }
                done
            done
        fi
    fi

    # (4) common lib directories (absolute globs).
    local dirs
    if [ "$HOST_OS" = "Darwin" ]; then
        dirs="/opt/homebrew/lib /usr/local/lib /opt/homebrew/opt/$dep/lib /usr/local/opt/$dep/lib"
    else
        dirs="/lib64 /usr/lib64 /usr/lib /usr/lib/$HOST_ARCH-linux-gnu /usr/local/lib /lib /opt/homebrew/lib"
    fi
    for d in $dirs; do
        for lib in $libnames; do
            [ -e "$d/$lib" ] && { printf '%s\n' "$d/$lib"; return 0; }
        done
    done

    # (5) previously-obtained .local-deps/.
    for lib in $libnames; do
        [ -e "$LIBDIR/$lib" ] && { printf '%s\n' "$LIBDIR/$lib"; return 0; }
    done

    return 1
}

# ── RESOLVE the include dir for a BUILD dependency (libevent/ncurses) ───────
# tmux's configure needs the dev HEADER, not just the shared library — a host
# with the runtime .so but no header cannot link. Print the absolute include
# directory that contains the dep's signature header (dep_field <dep> header),
# or return 1. Used only for kind=build deps.
#
# `mode` (§11.4.6 — consistent provenance, never mixed): the header MUST come
# from the SAME tier as the resolved library, else build_native.sh mis-labels
# the dep. mode=host → pkg-config includedir + common host dirs ONLY (never
# .local-deps — a host runtime .so must NOT be paired with a previously-OBTAINED
# local header, which would falsely label the dep host-system while the host
# lacks a usable build copy). mode=local → ONLY the .local-deps include dir.
# `header` may be a space-separated candidate list (ncurses widec installs its
# signature header at include/ncursesw/curses.h locally vs include/ncurses.h on
# a system install — try each).
_resolve_incdir() {
    local dep="$1" mode="${2:-host}" hdrs hdr pc pcbin incdir dirs d
    hdrs="$(dep_field "$dep" header 2>/dev/null || true)"
    [ -n "$hdrs" ] || return 1

    if [ "$mode" = "local" ]; then
        # Header must live in the local prefix beside the local-built lib.
        for hdr in $hdrs; do
            [ -e "$INCDIR/$hdr" ] && { printf '%s\n' "$INCDIR"; return 0; }
        done
        return 1
    fi

    # mode=host: HOST include locations only (NEVER .local-deps).
    # (1) pkg-config --variable=includedir (absolute candidate only).
    pc="$(dep_field "$dep" pkgconfig 2>/dev/null || true)"
    if [ -n "$pc" ]; then
        pcbin="$(_first_exe /usr/bin/pkg-config /usr/local/bin/pkg-config /opt/homebrew/bin/pkg-config /bin/pkg-config || true)"
        if [ -n "$pcbin" ] && "$pcbin" --exists "$pc" >/dev/null 2>&1; then
            incdir="$("$pcbin" --variable=includedir "$pc" 2>/dev/null || true)"
            if [ -n "$incdir" ]; then
                for hdr in $hdrs; do
                    [ -e "$incdir/$hdr" ] && { printf '%s\n' "$incdir"; return 0; }
                done
            fi
        fi
    fi

    # (2) common HOST include directories.
    if [ "$HOST_OS" = "Darwin" ]; then
        dirs="/opt/homebrew/include /usr/local/include /opt/homebrew/opt/$dep/include /usr/local/opt/$dep/include"
    else
        dirs="/usr/include /usr/local/include /usr/include/$HOST_ARCH-linux-gnu"
    fi
    for d in $dirs; do
        for hdr in $hdrs; do
            [ -e "$d/$hdr" ] && { printf '%s\n' "$d"; return 0; }
        done
    done

    return 1
}

# ── OBTAIN: build/extract <dep> into $LIBDIR (git-ignored) ─────────────────
# Idempotent: if a valid local library already exists, returns 0 (reuse).
_local_lib_present() {
    local dep="$1" lib
    for lib in $(_dep_libnames "$dep"); do
        [ -e "$LIBDIR/$lib" ] && { printf '%s\n' "$LIBDIR/$lib"; return 0; }
    done
    return 1
}

_download() {
    local url="$1" out="$2" tool
    if tool="$(_first_exe /usr/bin/curl /bin/curl curl || true)"; then
        "$tool" -fsSL -o "$out" "$url" && return 0
    fi
    if tool="$(_first_exe /usr/bin/wget /bin/wget wget || true)"; then
        "$tool" -q -O "$out" "$url" && return 0
    fi
    return 1
}

# Build <dep> from its pinned source tarball into $LOCAL_PREFIX. Needs a C
# compiler + make + a downloader + sha256 tool. Returns EC_* on failure.
obtain_via_source() {
    local dep="$1"
    _LAST_OBTAIN_METHOD="source"
    local ver url want_sha tar dl_sha srcdir cc mk
    ver="$(dep_field "$dep" version)"
    url="$(dep_field "$dep" url)"
    want_sha="$(dep_field "$dep" sha256)"

    cc="$(_first_exe /usr/bin/cc /usr/bin/gcc /usr/bin/clang cc gcc clang || true)"
    mk="$(_first_exe /usr/bin/make /bin/make make || true)"
    if [ -z "$cc" ] || [ -z "$mk" ]; then
        _err "$dep: no C compiler/make for source build"
        return $EC_NO_TOOLCHAIN
    fi

    mkdir -p "$TARBALL_CACHE"
    tar="$TARBALL_CACHE/$(basename "$url")"
    # Reuse a cached tarball iff its sha256 already matches (network-frugal).
    if [ -f "$tar" ]; then
        dl_sha="$(_sha256_of "$tar" || true)"
        [ "$dl_sha" = "$want_sha" ] || rm -f "$tar"
    fi
    if [ ! -f "$tar" ]; then
        _info "$dep: downloading $url"
        if ! _download "$url" "$tar"; then
            rm -f "$tar" 2>/dev/null || true
            _err "$dep: download failed (network unreachable?)"
            return $EC_NETWORK
        fi
    fi
    dl_sha="$(_sha256_of "$tar" || true)"
    if [ -z "$dl_sha" ]; then
        _err "$dep: no sha256 tool to verify $tar"
        return $EC_NO_TOOLCHAIN
    fi
    if [ "$dl_sha" != "$want_sha" ]; then
        _err "$dep: sha256 MISMATCH — want $want_sha got $dl_sha"
        rm -f "$tar" 2>/dev/null || true
        return $EC_SHA
    fi
    _info "$dep: sha256 verified ($want_sha)"

    local work; work="$LOCAL_PREFIX/.build"
    rm -rf "$work"; mkdir -p "$work" "$LIBDIR" "$INCDIR"
    if ! tar xf "$tar" -C "$work" 2>/dev/null; then
        _err "$dep: extract failed"
        return $EC_NETWORK
    fi
    srcdir="$(find "$work" -maxdepth 1 -type d -name "$dep-*" 2>/dev/null | head -1)"
    [ -n "$srcdir" ] || srcdir="$work/$dep-$ver"
    if [ ! -d "$srcdir" ]; then
        _err "$dep: source dir not found after extract"
        return $EC_NETWORK
    fi

    # Per-dep configure args + make targets come from the registry
    # (jemalloc keeps its fast build_lib_shared/install_lib_shared path;
    # libevent/ncurses use the standard `all` + `install`). @PREFIX@ in
    # configure_args is replaced with the resolved local prefix (ncurses
    # pkg-config .pc install dir). Build output is tee'd to a persistent
    # per-dep log so a failure is debuggable (§11.4.6/§11.4.69 — never
    # silently swallowed), mirroring the container_extract.log pattern.
    local cfg_args build_tgt inst_tgt blog
    cfg_args="$(dep_field "$dep" configure_args 2>/dev/null || true)"
    build_tgt="$(dep_field "$dep" build_targets 2>/dev/null || true)"
    inst_tgt="$(dep_field "$dep" install_targets 2>/dev/null || true)"
    [ -n "$inst_tgt" ] || inst_tgt="install"
    cfg_args="${cfg_args//@PREFIX@/$LOCAL_PREFIX}"
    blog="$LOCAL_PREFIX/build_${dep}.log"
    : > "$blog" 2>/dev/null || true
    _info "$dep: configuring + building into $LOCAL_PREFIX (log: $blog)"
    (
        cd "$srcdir"
        # cfg_args/build_tgt/inst_tgt are intentional word lists — unquoted.
        ./configure --prefix="$LOCAL_PREFIX" $cfg_args >>"$blog" 2>&1
        "$mk" -j"$( (command -v nproc >/dev/null 2>&1 && nproc) || echo 2)" $build_tgt >>"$blog" 2>&1
        "$mk" $inst_tgt >>"$blog" 2>&1
    ) || { _err "$dep: source build failed — see $blog"; return $EC_NO_TOOLCHAIN; }

    rm -rf "$work"
    if _local_lib_present "$dep" >/dev/null; then
        return 0
    fi
    _err "$dep: source build produced no library in $LIBDIR"
    return $EC_NO_TOOLCHAIN
}

# Extract <dep>'s shared library from the project build container (the
# Linux fallback for hosts with no C compiler — e.g. amber). The image
# (docker/Dockerfile) already installs libjemalloc-dev; we copy the real
# (dereferenced) .so out into the bind-mounted $LIBDIR. NO network needed
# once the image exists; building the image needs network (apt).
obtain_via_container() {
    local dep="$1" engine lib
    _LAST_OBTAIN_METHOD="container"
    [ "$HOST_OS" = "Darwin" ] && { _err "$dep: container extract is Linux-only"; return $EC_UNSUPPORTED; }
    lib="$(dep_field "$dep" linux_lib)"
    engine="$(_first_exe /usr/bin/podman /usr/local/bin/podman podman /usr/bin/docker /usr/local/bin/docker docker || true)"
    if [ -z "$engine" ]; then
        _err "$dep: no podman/docker for container extract"
        return $EC_NO_TOOLCHAIN
    fi
    # §11.4.6/§11.4.69: tee container build+extract diagnostics to a persistent
    # log under the local prefix (was: swallowed with >/dev/null) so an
    # amber container-extract failure is debuggable. Typed exit codes preserved.
    mkdir -p "$LOCAL_PREFIX"
    local log="$LOCAL_PREFIX/container_extract.log"
    : > "$log"
    local image="tmx-build:latest"
    if ! "$engine" image exists "$image" >>"$log" 2>&1 \
         && ! "$engine" image inspect "$image" >>"$log" 2>&1; then
        _info "$dep: building $image (docker/Dockerfile) for extract"
        if ! "$engine" build \
                --build-arg BUILD_UID="$(id -u)" \
                --build-arg BUILD_GID="$(id -g)" \
                -f "$REPO_ROOT/docker/Dockerfile" \
                -t "$image" "$REPO_ROOT" >>"$log" 2>&1; then
            _err "$dep: build image failed (network for apt?) — see $log"
            return $EC_CONTAINER
        fi
    fi
    mkdir -p "$LIBDIR"
    local userns=()
    [ "${engine##*/}" = "podman" ] && userns=(--userns=keep-id)
    # Inside the image: locate the dereferenced lib (ldconfig or known dir)
    # and copy it to the bind-mounted /out (host-owned via USER builder).
    if ! "$engine" run --rm \
            ${userns[@]+"${userns[@]}"} \
            -v "$LIBDIR":/out:rw \
            "$image" \
            bash -c '
                set -e
                src="$(ldconfig -p 2>/dev/null | awk -v n="'"$lib"'" "\$0 ~ n {print \$NF; exit}")"
                [ -n "$src" ] || src="/usr/lib/'"$HOST_ARCH"'-linux-gnu/'"$lib"'"
                [ -e "$src" ] || { echo "lib not found in image" >&2; exit 1; }
                cp -L "$src" "/out/'"$lib"'"
            ' >>"$log" 2>&1; then
        _err "$dep: container extract command failed — see $log"
        return $EC_CONTAINER
    fi
    if [ ! -e "$LIBDIR/$lib" ]; then
        _err "$dep: container extract produced no $LIBDIR/$lib"
        return $EC_CONTAINER
    fi
    return 0
}

# ── Go toolchain (kind=toolchain) helpers ──────────────────────────────────
# Derive the Go platform tuple (goos_goarch) from uname; print it or return 1
# for an unsupported OS/arch (§11.4.6 honest boundary — the registry pins only
# the 4 official linux/darwin × amd64/arm64 variants; anything else is
# EC_UNSUPPORTED, never a fake build).
_go_plat() {
    local goos goarch
    case "$HOST_OS" in
        Linux)  goos="linux" ;;
        Darwin) goos="darwin" ;;
        *) return 1 ;;
    esac
    case "$HOST_ARCH" in
        x86_64|amd64)  goarch="amd64" ;;
        aarch64|arm64) goarch="arm64" ;;
        *) return 1 ;;
    esac
    printf '%s_%s' "$goos" "$goarch"
}

# Run `<gobin> version`, parse `go version goX.Y[.Z]… …`, and verify it is a
# real Go binary >= the registry minimum (go:min_major / go:min_minor). On
# success print the parsed version (X.Y[.Z]) and return 0; else return 1.
# `go version` is self-contained (figures GOROOT from the binary path), so no
# GOROOT env is needed here.
_go_version_ok() {
    local gobin="$1" raw ver major minor min_major min_minor
    [ -n "$gobin" ] && [ -x "$gobin" ] || return 1
    raw="$("$gobin" version 2>/dev/null)" || return 1
    ver="$(printf '%s\n' "$raw" | awk '{print $3}' | sed 's/^go//')"
    major="$(printf '%s\n' "$ver" | awk -F. '{print $1}')"
    minor="$(printf '%s\n' "$ver" | awk -F. '{print $2}')"
    [ -n "$major" ] && [ -n "$minor" ] || return 1
    case "$major" in *[!0-9]*|'') return 1 ;; esac
    case "$minor" in *[!0-9]*|'') return 1 ;; esac
    min_major="$(dep_field go min_major 2>/dev/null || echo 1)"
    min_minor="$(dep_field go min_minor 2>/dev/null || echo 21)"
    if [ "$major" -lt "$min_major" ] || { [ "$major" -eq "$min_major" ] && [ "$minor" -lt "$min_minor" ]; }; then
        return 1
    fi
    printf '%s' "$ver"
    return 0
}

# RESOLVE an already-present suitable Go (>= min) by ABSOLUTE path first
# (§11.4.111), bare-name PATH lookup last. On success print
# "GO_BIN|GOROOT|version|source" and return 0; else return 1. GOROOT comes from
# the toolchain itself (`go env GOROOT`) — authoritative, never guessed.
resolve_go() {
    local cand gobin ver goroot src
    for cand in \
        /usr/local/go/bin/go /usr/lib/go/bin/go /usr/lib/golang/bin/go \
        /opt/go/bin/go /opt/homebrew/bin/go /opt/homebrew/opt/go/bin/go \
        /usr/local/bin/go /usr/bin/go \
        go; do
        gobin=""
        case "$cand" in
            /*) [ -x "$cand" ] && gobin="$cand" ;;
            *)  command -v "$cand" >/dev/null 2>&1 && gobin="$(command -v "$cand")" ;;
        esac
        [ -n "$gobin" ] || continue
        ver="$(_go_version_ok "$gobin")" || continue
        goroot="$("$gobin" env GOROOT 2>/dev/null || true)"
        [ -n "$goroot" ] || goroot="$(cd "$(dirname "$gobin")/.." 2>/dev/null && pwd)"
        case "$gobin" in
            /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*) src="host-brew" ;;
            *) src="host-system" ;;
        esac
        printf '%s|%s|%s|%s' "$gobin" "$goroot" "$ver" "$src"
        return 0
    done
    return 1
}

# OBTAIN the Go toolchain as a PREBUILT official tarball into $LOCAL_PREFIX/go
# (NO ./configure+make — Go ships prebuilt). Needs a downloader + sha256 tool +
# tar + network. Idempotent: reuse an already-extracted toolchain that runs
# >= min. Returns EC_* on failure (never a fake success). On success the
# toolchain is at $LOCAL_PREFIX/go/bin/go (the tarball top-level dir is `go/`).
obtain_via_prebuilt() {
    local dep="$1"
    _LAST_OBTAIN_METHOD="prebuilt"
    local goplat url want_sha tar dl_sha goroot gobin
    goplat="$(_go_plat)" || {
        _err "$dep: unsupported platform ${HOST_OS}/${HOST_ARCH} for prebuilt toolchain (4 official variants only)"
        return $EC_UNSUPPORTED
    }
    url="$(dep_field "$dep" "url_$goplat" 2>/dev/null || true)"
    want_sha="$(dep_field "$dep" "sha256_$goplat" 2>/dev/null || true)"
    if [ -z "$url" ] || [ -z "$want_sha" ]; then
        _err "$dep: no url/sha256 registered for platform '$goplat'"
        return $EC_UNSUPPORTED
    fi

    goroot="$LOCAL_PREFIX/go"
    gobin="$goroot/bin/go"
    # Idempotent reuse of an already-extracted, runnable toolchain.
    if [ -x "$gobin" ] && _go_version_ok "$gobin" >/dev/null 2>&1; then
        _info "$dep: local toolchain already present at $gobin — reuse"
        return 0
    fi

    mkdir -p "$TARBALL_CACHE"
    tar="$TARBALL_CACHE/$(basename "$url")"
    # Reuse a cached tarball iff its sha256 already matches (network-frugal).
    if [ -f "$tar" ]; then
        dl_sha="$(_sha256_of "$tar" || true)"
        [ "$dl_sha" = "$want_sha" ] || rm -f "$tar"
    fi
    if [ ! -f "$tar" ]; then
        _info "$dep: downloading $url"
        if ! _download "$url" "$tar"; then
            rm -f "$tar" 2>/dev/null || true
            _err "$dep: download failed (network unreachable?)"
            return $EC_NETWORK
        fi
    fi
    dl_sha="$(_sha256_of "$tar" || true)"
    if [ -z "$dl_sha" ]; then
        _err "$dep: no sha256 tool to verify $tar"
        return $EC_NO_TOOLCHAIN
    fi
    if [ "$dl_sha" != "$want_sha" ]; then
        _err "$dep: sha256 MISMATCH — want $want_sha got $dl_sha"
        rm -f "$tar" 2>/dev/null || true
        return $EC_SHA
    fi
    _info "$dep: sha256 verified ($want_sha)"

    rm -rf "$goroot"
    mkdir -p "$LOCAL_PREFIX"
    # The official tarball's top-level dir is `go/` → extracts to $LOCAL_PREFIX/go.
    if ! tar xf "$tar" -C "$LOCAL_PREFIX" 2>/dev/null; then
        _err "$dep: extract failed"
        return $EC_NETWORK
    fi
    if [ ! -x "$gobin" ]; then
        _err "$dep: extract produced no executable $gobin"
        return $EC_NO_TOOLCHAIN
    fi
    # Anti-bluff (§11.4.5): run the obtained toolchain once as proof it executes
    # AND is >= min — never claim an obtained toolchain that does not run.
    if ! _go_version_ok "$gobin" >/dev/null 2>&1; then
        _err "$dep: obtained toolchain at $gobin does not run or is too old"
        return $EC_NO_TOOLCHAIN
    fi
    return 0
}

obtain_dep() {
    local dep="$1"
    # Idempotent reuse.
    if _local_lib_present "$dep" >/dev/null; then
        _info "$dep: local copy already present — reuse"
        return 0
    fi
    mkdir -p "$LIBDIR" "$INCDIR"
    case "$HOST_OS" in
        Darwin)
            # Prefer a source build (Xcode CLT clang); else brew install.
            if obtain_via_source "$dep"; then return 0; fi
            local b brewname; brewname="$(dep_field "$dep" brew || true)"
            for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                [ -x "$b" ] || continue
                _info "$dep: brew install $brewname (no compiler available)"
                "$b" install "$brewname" >/dev/null 2>&1 || true
            done
            resolve_existing "$dep" >/dev/null && return 0
            _err "$dep: could not obtain on Darwin (no compiler, brew install failed)"
            return $EC_NO_TOOLCHAIN
            ;;
        Linux)
            # Container extract only applies to deps the build image carries
            # (jemalloc). Build deps (libevent/ncurses) are source-only — when
            # a compiler-less Linux host cannot source-build them there is NO
            # container recipe, so we fail honestly (EC_NO_TOOLCHAIN), never a
            # misleading image build that cannot produce the lib.
            local ce; ce="$(dep_field "$dep" container_extract 2>/dev/null || echo no)"
            case "$OBTAIN_METHOD" in
                source)    obtain_via_source "$dep"; return $? ;;
                container)
                    if [ "$ce" = "yes" ]; then obtain_via_container "$dep"; return $?; fi
                    _err "$dep: OBTAIN_METHOD=container but no container-extract recipe (source-only build dep)"
                    return $EC_UNSUPPORTED
                    ;;
                *)
                    # auto: source if a compiler exists, else container (when
                    # the dep has a container recipe).
                    local src_rc=0
                    if _first_exe /usr/bin/cc /usr/bin/gcc /usr/bin/clang cc gcc clang >/dev/null 2>&1; then
                        obtain_via_source "$dep" && return 0
                        src_rc=$?
                        _warn "$dep: source build failed (rc=$src_rc)"
                    fi
                    if [ "$ce" = "yes" ]; then
                        _warn "$dep: trying container extract"
                        obtain_via_container "$dep"; return $?
                    fi
                    # No container recipe: surface the source failure honestly
                    # (or no-toolchain when no compiler was present at all).
                    if [ "$src_rc" -ne 0 ]; then return $src_rc; fi
                    return $EC_NO_TOOLCHAIN
                    ;;
            esac
            ;;
        *)
            _err "unsupported OS '$HOST_OS'"
            return $EC_UNSUPPORTED
            ;;
    esac
}

# ── main ──────────────────────────────────────────────────────────────────
mkdir -p "$LOCAL_PREFIX" "$LIBDIR" "$INCDIR"
: > "$RESOLVED_ENV.tmp"
printf '# generated by scripts/obtain_local_deps.sh on %s — source me\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RESOLVED_ENV.tmp"
printf 'LOCAL_DEPS_PREFIX=%s\n' "$LOCAL_PREFIX" >> "$RESOLVED_ENV.tmp"

overall_rc=0
for dep in $DEPS; do
    if ! dep_field "$dep" version >/dev/null 2>&1; then
        _err "$dep: not in registry (§11.4.6 no-guessing) — add a dep_field branch"
        overall_rc=$EC_UNSUPPORTED
        continue
    fi
    ep="$(dep_field "$dep" envprefix)"
    kind="$(dep_field "$dep" kind 2>/dev/null || echo runtime)"
    so=""
    src=""
    incdir=""

    # ── kind=toolchain (Go): a self-contained resolve+obtain+emit path. A
    #    toolchain has NO shared library, so the resolve_existing / _local_lib_present
    #    / obtain_dep machinery (which hunts for a .so) does not apply. RESOLVE an
    #    already-present Go by absolute path (§11.4.111); else OBTAIN the prebuilt
    #    official tarball (§11.4.77). Emit GO_BIN / GOROOT / GO_SOURCE, then
    #    `continue` so the runtime/build emission below is bypassed cleanly.
    if [ "$kind" = "toolchain" ]; then
        tc_bin=""; tc_root=""; tc_ver=""; tc_src=""; tc_out=""; tc_rest=""
        if [ "$FORCE_OBTAIN" != "1" ]; then
            if tc_out="$(resolve_go 2>/dev/null)"; then
                tc_bin="${tc_out%%|*}"; tc_rest="${tc_out#*|}"
                tc_root="${tc_rest%%|*}"; tc_rest="${tc_rest#*|}"
                tc_ver="${tc_rest%%|*}"; tc_src="${tc_rest##*|}"
                _info "RESOLVED $dep → $tc_bin (go $tc_ver, GOROOT=$tc_root, $tc_src)"
            fi
        else
            _info "$dep: FORCE_OBTAIN=1 — skipping host detection"
        fi
        if [ -z "$tc_bin" ]; then
            if obtain_via_prebuilt "$dep"; then
                tc_root="$LOCAL_PREFIX/go"
                tc_bin="$tc_root/bin/go"
                tc_src="local-toolchain"
                tc_ver="$(_go_version_ok "$tc_bin" 2>/dev/null || echo unknown)"
                _info "OBTAINED $dep → $tc_bin (go $tc_ver, GOROOT=$tc_root, $tc_src)"
            else
                rc=$?
                _err "OBTAIN FAILED for $dep (rc=$rc) — NOT faking success"
                overall_rc=$rc
                continue
            fi
        fi
        {
            printf '%s_BIN=%s\n'    "$ep" "$tc_bin"
            printf 'GOROOT=%s\n'    "$tc_root"
            printf '%s_SOURCE=%s\n' "$ep" "$tc_src"
        } >> "$RESOLVED_ENV.tmp"
        continue
    fi

    if [ "$FORCE_OBTAIN" != "1" ]; then
        if so="$(resolve_existing "$dep" 2>/dev/null)"; then
            # Build dependencies (libevent/ncurses) are usable by tmux's
            # configure ONLY when BOTH the shared library AND its dev header
            # are present — a runtime-only host (the .so but no header) cannot
            # link. Require the header too; if absent, fall through to OBTAIN
            # locally (§11.4.6 — never claim host-resolved when the header
            # tmux needs is missing).
            if [ "$kind" = "build" ]; then
                # The header MUST come from the SAME tier as the resolved lib
                # (§11.4.6 — no mixed host-lib + local-header provenance, which
                # would falsely label the dep host-system while the host lacks
                # a buildable copy). Pick the mode by where the lib resolved.
                case "$so" in
                    "$LIBDIR"/*) _incmode="local" ;;
                    *)           _incmode="host" ;;
                esac
                if incdir="$(_resolve_incdir "$dep" "$_incmode" 2>/dev/null)"; then
                    : # lib + matching-tier header present — genuine resolution
                else
                    _info "$dep: $_incmode lib present but matching dev header ($(dep_field "$dep" header 2>/dev/null)) absent — OBTAINING locally"
                    so=""
                fi
            fi
            if [ -n "$so" ]; then
                # Where did it come from? (Best-effort label by location.)
                case "$so" in
                    "$LIBDIR"/*)          src="local-deps" ;;
                    /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*) src="host-brew" ;;
                    /lib64/*|/usr/lib*/*|/lib/*) src="host-system" ;;
                    *)                    src="host" ;;
                esac
                _info "RESOLVED $dep → $so ($src${incdir:+, headers: $incdir})"
            fi
        fi
    else
        _info "$dep: FORCE_OBTAIN=1 — skipping host detection"
    fi

    if [ -z "$so" ]; then
        if obtain_dep "$dep"; then
            so="$(_local_lib_present "$dep")"
            # §11.4.6 honest provenance: label by the method actually used
            # (_LAST_OBTAIN_METHOD), NOT OBTAIN_METHOD (which stays "auto" even
            # when the container path ran in auto mode). container ⇒
            # container-extract (matches docs/scripts/obtain_local_deps.md);
            # everything else (source build, macOS) ⇒ local-build.
            if [ "$_LAST_OBTAIN_METHOD" = "container" ]; then
                src="container-extract"
            else
                src="local-build"
            fi
            # Source-built build deps install their headers into the local
            # prefix's include dir (configure --prefix=$LOCAL_PREFIX).
            [ "$kind" = "build" ] && incdir="$INCDIR"
            _info "OBTAINED $dep → $so ($src${incdir:+, headers: $incdir})"
        else
            rc=$?
            _err "OBTAIN FAILED for $dep (rc=$rc) — NOT faking success"
            overall_rc=$rc
            continue
        fi
    fi

    libdir="$(dirname "$so")"
    {
        if [ "$kind" = "build" ]; then
            # Build dependency (libevent/ncurses): tmux's configure consumes
            # the lib dir + include dir (+ the .pc under $libdir/pkgconfig).
            printf '%s_LIBDIR=%s\n' "$ep" "$libdir"
            printf '%s_INCDIR=%s\n' "$ep" "$incdir"
            printf '%s_SOURCE=%s\n' "$ep" "$src"
        else
            # Runtime dependency (jemalloc): preloaded by the wrapper — the
            # ABSOLUTE .so path is load-bearing (LD_PRELOAD ignores rpath).
            printf '%s_SO=%s\n'     "$ep" "$so"
            printf '%s_LIBDIR=%s\n' "$ep" "$libdir"
            printf '%s_SOURCE=%s\n' "$ep" "$src"
        fi
    } >> "$RESOLVED_ENV.tmp"
done

mv "$RESOLVED_ENV.tmp" "$RESOLVED_ENV"
_info "wrote $RESOLVED_ENV"
exit "$overall_rc"
