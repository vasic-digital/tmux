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
#   DEPS="jemalloc" bash scripts/obtain_local_deps.sh  # subset of deps
#
# Inputs (env, all optional):
#   FORCE_OBTAIN     1 → skip host detection, obtain into the local prefix.
#   LOCAL_DEPS_ROOT  override the git-ignored root (default <repo>/.local-deps).
#   DEPS             space-separated dep names (default: jemalloc).
#   OBTAIN_METHOD    auto|source|container (Linux obtain method; default auto).
#
# Outputs:
#   .local-deps/<uname-s>_<uname-m>/lib/<libname>     the obtained library
#   .local-deps/<uname-s>_<uname-m>/resolved.env      KEY=VALUE sourceable
#       (e.g. JEMALLOC_SO=…, JEMALLOC_LIBDIR=…, JEMALLOC_SOURCE=…)
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

    _info "$dep: configuring + building shared library into $LOCAL_PREFIX"
    (
        cd "$srcdir"
        ./configure --prefix="$LOCAL_PREFIX" --disable-debug >/dev/null 2>&1
        # build_lib_shared keeps the build to the shared library only (fast).
        "$mk" -j"$( (command -v nproc >/dev/null 2>&1 && nproc) || echo 2)" build_lib_shared >/dev/null 2>&1
        "$mk" install_lib_shared install_include >/dev/null 2>&1
    ) || { _err "$dep: source build failed"; return $EC_NO_TOOLCHAIN; }

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
            case "$OBTAIN_METHOD" in
                source)    obtain_via_source "$dep"; return $? ;;
                container) obtain_via_container "$dep"; return $? ;;
                *)
                    # auto: source if a compiler exists, else container.
                    if _first_exe /usr/bin/cc /usr/bin/gcc /usr/bin/clang cc gcc clang >/dev/null 2>&1; then
                        obtain_via_source "$dep" && return 0
                        _warn "$dep: source build failed — trying container extract"
                    fi
                    obtain_via_container "$dep"; return $?
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
    so=""
    src=""

    if [ "$FORCE_OBTAIN" != "1" ]; then
        if so="$(resolve_existing "$dep" 2>/dev/null)"; then
            # Where did it come from? (Best-effort label by location.)
            case "$so" in
                "$LIBDIR"/*)          src="local-deps" ;;
                /opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*) src="host-brew" ;;
                /lib64/*|/usr/lib*/*|/lib/*) src="host-system" ;;
                *)                    src="host" ;;
            esac
            _info "RESOLVED $dep → $so ($src)"
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
            _info "OBTAINED $dep → $so ($src)"
        else
            rc=$?
            _err "OBTAIN FAILED for $dep (rc=$rc) — NOT faking success"
            overall_rc=$rc
            continue
        fi
    fi

    libdir="$(dirname "$so")"
    {
        printf '%s_SO=%s\n'     "$ep" "$so"
        printf '%s_LIBDIR=%s\n' "$ep" "$libdir"
        printf '%s_SOURCE=%s\n' "$ep" "$src"
    } >> "$RESOLVED_ENV.tmp"
done

mv "$RESOLVED_ENV.tmp" "$RESOLVED_ENV"
_info "wrote $RESOLVED_ENV"
exit "$overall_rc"
