#!/usr/bin/env bash
# install_deps.sh — install the build dependencies for a from-source tmux
# build, per host OS / Linux distribution. INSTALL-ONLY, idempotent, honest.
#
# ── Purpose ──────────────────────────────────────────────────────────────────
# A host can have `gcc`/`cc` on PATH yet be UNABLE to link an executable
# because the C-runtime dev objects are absent (no crt1.o → autoconf dies with
# the cryptic "C compiler cannot create executables"). This script installs the
# full native-build toolchain so that failure cannot happen, and (best-effort)
# the rootless-container prerequisite so the preferred containerized build path
# also works. setup.sh's native-build fallback invokes it automatically
# (consent-gated) — see scripts/setup.sh `_native_build_preflight`.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   Linux (needs root — installs system packages; run AS ROOT, this script
#   NEVER escalates privilege itself — operator mandate 2026-06-29):
#       bash scripts/install_deps.sh                      # (as root) full set
#       bash scripts/install_deps.sh --toolchain-only     # (as root) native-build deps only
#   macOS (no root needed — Xcode CLT + Homebrew):
#       bash scripts/install_deps.sh
#   Preview without installing (no root needed):
#       INSTALL_DEPS_DRY_RUN=1 bash scripts/install_deps.sh
#
# ── Inputs (env) ─────────────────────────────────────────────────────────────
#   INSTALL_DEPS_DRY_RUN=1        resolve + print the package set, do NOT install
#                                 (no root required; also a nice "what would you
#                                 install?" preview). Used by the regression test.
#   INSTALL_DEPS_FORCE_DISTRO=ID  override /etc/os-release ID (test/debug — lets
#                                 the cross-distro mapping be exercised off-distro
#                                 under DRY_RUN; §11.4.81).
#   INSTALL_DEPS_ASSUME_MISSING=1 treat every package as not-installed (test:
#                                 forces the full resolved set into the DRY_RUN
#                                 plan regardless of host state).
#
# ── Flags ────────────────────────────────────────────────────────────────────
#   --toolchain-only   install ONLY the PRIMARY native-build toolchain group
#                      (what cc-can-link + build_native.sh need); skip the
#                      rootless-container prereq + the optional system jemalloc.
#
# ── Safety covenant ──────────────────────────────────────────────────────────
#   • INSTALL-ONLY — this script NEVER removes / purges / downgrades a package
#     (§11.4.122 no-silent-removal). grep this file for remove|purge|erase|-R:
#     there are none in any install path.
#   • Idempotent — already-present packages are skipped; a re-run with nothing
#     missing is a no-op (exit 0).
#   • Honest-on-failure — the package-manager exit code is captured; a failed
#     PRIMARY install is a clear non-zero error, never a silent continue
#     (§11.4 / §11.4.1). SECONDARY/OPTIONAL failures WARN (the native build,
#     which only needs PRIMARY, still proceeds).
#   • Bounded / no host-power ops (§12). Does NOT touch /etc/subuid ranges or run
#     `podman system migrate` — those are documented manual follow-ups (§11.4.92).
#
# ── Outputs ──────────────────────────────────────────────────────────────────
#   Human-readable progress + a final verification census. Exit codes:
#     0  success (installed, or nothing to do, or dry-run)
#     1  not root on Linux (prints the exact privileged command)
#     2  Homebrew absent on macOS
#     3  unsupported distro (no package mapping)
#     4  package-manager install FAILED (PRIMARY group)
#
# ── Dependencies ─────────────────────────────────────────────────────────────
#   /etc/os-release (Linux distro id); the host package manager
#   (apt-get/dnf/pacman/zypper/apk); rpm/dpkg/pacman/apk for the installed-query.
#
# ── Cross-refs ───────────────────────────────────────────────────────────────
#   scripts/setup.sh `_native_build_preflight` (auto-invokes this, consent-gated);
#   scripts/build_native.sh (the build this unblocks);
#   scripts/obtain_local_deps.sh (source-builds jemalloc/libevent/ncurses when a
#   system package is unavailable — the OPTIONAL jemalloc group is belt-and-
#   suspenders, not required);
#   scripts/tests/70_native_fallback_cc_link.sh (the §11.4.115 regression guard).
#
# §11.4.67: parses clean under `sh -n` AND `bash -n` (POSIX constructs only).
# Last verified: 2026-06-29 (ALT 11 / apt-rpm host, package names rpm-verified).

set -euo pipefail

HOST_OS="$(uname -s)"

# ── flag parsing ─────────────────────────────────────────────────────────────
TOOLCHAIN_ONLY=0
for _a in "$@"; do
    case "$_a" in
        --toolchain-only) TOOLCHAIN_ONLY=1 ;;
        --help|-h) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[install_deps] unknown arg: $_a" >&2; exit 2 ;;
    esac
done

DRY_RUN="${INSTALL_DEPS_DRY_RUN:-0}"
ASSUME_MISSING="${INSTALL_DEPS_ASSUME_MISSING:-0}"

# ── macOS branch: Xcode Command Line Tools (the C toolchain) + Homebrew libs ──
if [ "$HOST_OS" = "Darwin" ]; then
    # The macOS C compiler/linker/libSystem comes from the Xcode Command Line
    # Tools, NOT Homebrew. A host can have brew yet fail to link if the CLT is
    # absent → the macOS analogue of the missing-crt1.o failure (§11.4.81).
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "[install_deps] Xcode Command Line Tools not installed — the C"
        echo "  compiler + macOS SDK (libSystem/linker) come from the CLT."
        if [ "$DRY_RUN" = "1" ]; then
            echo "DRY-RUN: would run: xcode-select --install"
        else
            echo "  Installing (a GUI prompt may appear): xcode-select --install"
            xcode-select --install 2>/dev/null || true
            echo "  ⓘ Complete the CLT install dialog, then re-run this script."
        fi
    fi
    if ! command -v brew >/dev/null 2>&1; then
        echo "ERROR: Homebrew not installed on macOS."
        echo "  Install via:"
        echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 2
    fi
    BREWS="libevent jemalloc automake autoconf pkg-config bison utf8proc"
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY-RUN: would run: brew install $BREWS"
        exit 0
    fi
    echo "[install_deps] Darwin: brew install $BREWS"
    # shellcheck disable=SC2086
    brew install $BREWS
    echo "[install_deps] ✓ Darwin build deps ready (no root needed)."
    echo "[install_deps] next: bash scripts/setup.sh"
    exit 0
fi

# ── Linux branch ─────────────────────────────────────────────────────────────
# Distro id (overridable for cross-distro dry-run testing per §11.4.81).
DISTRO_ID="${INSTALL_DEPS_FORCE_DISTRO:-}"
if [ -z "$DISTRO_ID" ]; then
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null || true
        DISTRO_ID="${ID:-}"
    fi
fi
[ -n "$DISTRO_ID" ] || { echo "ERROR: cannot determine Linux distro (/etc/os-release missing)"; exit 2; }

# Per-distro mapping. PM = installer; PMQUERY = installed-check method.
# PRIMARY  = native-build toolchain (HARD requirement — the guaranteed-works path).
# SECONDARY= rootless-container prerequisite (newuidmap/newgidmap provider; best-effort).
# OPTIONAL = system jemalloc dev (best-effort — obtain_local_deps.sh source-builds
#            it when the package is unavailable, so a miss here is not fatal).
case "$DISTRO_ID" in
    altlinux|alt)
        PM="apt-get"; PMQUERY="rpm"
        PRIMARY="gcc glibc-devel make libevent-devel libncursesw-devel autoconf automake pkg-config bison flex"
        SECONDARY="shadow-submap"
        OPTIONAL="libjemalloc-devel"
        ;;
    debian|ubuntu|linuxmint|raspbian|pop|neon)
        PM="apt-get"; PMQUERY="dpkg"
        PRIMARY="build-essential libevent-dev libncurses-dev autoconf automake pkg-config bison flex"
        SECONDARY="uidmap"
        OPTIONAL="libjemalloc-dev"
        ;;
    fedora|rhel|centos|rocky|almalinux|amzn)
        PM="dnf"; PMQUERY="rpm"
        PRIMARY="gcc glibc-devel make libevent-devel ncurses-devel autoconf automake pkgconf-pkg-config bison flex"
        SECONDARY="shadow-utils"
        OPTIONAL="jemalloc-devel"
        ;;
    arch|manjaro|endeavouros|cachyos)
        PM="pacman"; PMQUERY="pacman"
        PRIMARY="base-devel libevent ncurses"
        SECONDARY="shadow"
        OPTIONAL="jemalloc"
        ;;
    opensuse*|sles|sled)
        PM="zypper"; PMQUERY="rpm"
        PRIMARY="gcc glibc-devel make libevent-devel ncurses-devel autoconf automake pkg-config bison flex"
        SECONDARY="shadow"
        OPTIONAL="jemalloc-devel"
        ;;
    alpine)
        PM="apk"; PMQUERY="apk"
        PRIMARY="build-base libevent-dev ncurses-dev autoconf automake pkgconf bison flex"
        SECONDARY="shadow-uidmap"
        OPTIONAL="jemalloc-dev"
        ;;
    *)
        echo "ERROR: unsupported distro '$DISTRO_ID'. No package mapping."
        echo "  Add a case for it, or install your toolchain manually:"
        echo "    a C compiler + the C-runtime dev objects (crt*.o / libc dev),"
        echo "    make, libevent + (wide) ncurses headers, autoconf, automake,"
        echo "    pkg-config, bison, flex."
        exit 3
        ;;
esac

# ── is-installed query (idempotency) ─────────────────────────────────────────
# Returns 0 when $1 is installed. ASSUME_MISSING forces "not installed" so the
# DRY_RUN plan shows the full resolved set regardless of host state (test hook).
_pkg_installed() {
    [ "$ASSUME_MISSING" = "1" ] && return 1
    case "$PMQUERY" in
        rpm)    rpm -q "$1" >/dev/null 2>&1 ;;
        dpkg)   dpkg -s "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$1" >/dev/null 2>&1 || pacman -Qg "$1" >/dev/null 2>&1 ;;
        apk)    apk info -e "$1" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# Compute the not-yet-installed subset of a space-separated group.
# pacman groups/metapackages (base-devel) defer to `pacman -S --needed`, so we
# pass the group through verbatim rather than mis-querying it.
_missing_of() {
    if [ "$PMQUERY" = "pacman" ]; then printf '%s' "$*"; return 0; fi
    _out=""
    for _p in $*; do
        _pkg_installed "$_p" || _out="$_out $_p"
    done
    printf '%s' "${_out# }"
}

# ── run the package-manager install for one resolved set ─────────────────────
# Echoes the command; honours DRY_RUN. Returns the installer's exit code.
_pm_install() {
    _pkgs="$1"
    [ -n "$_pkgs" ] || return 0
    case "$PM" in
        apt-get) set -- apt-get install -y $_pkgs ;;
        dnf)     set -- dnf install -y $_pkgs ;;
        pacman)  set -- pacman -S --needed --noconfirm $_pkgs ;;
        zypper)  set -- zypper --non-interactive install $_pkgs ;;
        apk)     set -- apk add $_pkgs ;;
        *)       echo "  ✗ no installer for PM=$PM" >&2; return 4 ;;
    esac
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY-RUN: would run: $*"
        return 0
    fi
    echo "  + $*"
    "$@"
}

echo "[install_deps] distro=$DISTRO_ID  pm=$PM  query=$PMQUERY  toolchain-only=$TOOLCHAIN_ONLY  dry-run=$DRY_RUN"

# Resolve the missing subset per group (idempotency).
PRIMARY_MISSING="$(_missing_of $PRIMARY)"
SECONDARY_MISSING="$(_missing_of $SECONDARY)"
OPTIONAL_MISSING="$(_missing_of $OPTIONAL)"

echo "  PRIMARY  (native-build toolchain): $PRIMARY"
echo "    → missing: ${PRIMARY_MISSING:-<none — all present>}"
if [ "$TOOLCHAIN_ONLY" = "0" ]; then
    echo "  SECONDARY(rootless-container prereq newuidmap): $SECONDARY"
    echo "    → missing: ${SECONDARY_MISSING:-<none — all present>}"
    echo "  OPTIONAL (system jemalloc; obtain handles fallback): $OPTIONAL"
    echo "    → missing: ${OPTIONAL_MISSING:-<none — all present>}"
fi
echo ""

# ── privilege gate (real install only; DRY_RUN needs no root) ────────────────
# Honest message ONLY — this script NEVER escalates privilege itself (operator
# mandate 2026-06-29: no privilege escalation in automation). Run it AS ROOT.
if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" != "0" ]; then
    echo "ERROR: installing system packages needs root on Linux."
    echo "  re-run AS ROOT:  bash $0 $*"
    echo "  (preview without root: INSTALL_DEPS_DRY_RUN=1 bash $0)"
    exit 1
fi

# apt index refresh (best-effort; a stale index would make install fail honestly).
if [ "$DRY_RUN" != "1" ] && [ "$PM" = "apt-get" ]; then
    apt-get update -qq || echo "  ⚠ apt-get update failed (continuing — install will surface any real error)"
fi

# ── PRIMARY group — HARD requirement (honest non-zero on failure) ────────────
rc_primary=0
if [ -n "$PRIMARY_MISSING" ]; then
    echo "[install_deps] PRIMARY toolchain:"
    _pm_install "$PRIMARY_MISSING" || rc_primary=$?
else
    echo "[install_deps] PRIMARY toolchain already present — nothing to do."
fi
if [ "$rc_primary" != "0" ]; then
    echo "FAIL: PRIMARY toolchain install exited $rc_primary — native build will NOT work."
    echo "  This is the real error (no silent continue, §11.4 / §11.4.1)."
    exit 4
fi

# ── SECONDARY + OPTIONAL — best-effort (WARN, never abort the native path) ────
if [ "$TOOLCHAIN_ONLY" = "0" ]; then
    if [ -n "$SECONDARY_MISSING" ]; then
        echo "[install_deps] SECONDARY rootless-container prereq (newuidmap):"
        if ! _pm_install "$SECONDARY_MISSING"; then
            echo "  ⚠ rootless-container prereq install failed — the CONTAINERIZED"
            echo "    build path may still error with 'newuidmap: executable file"
            echo "    not found'. The NATIVE build (PRIMARY above) is unaffected."
        fi
    fi
    if [ -n "$OPTIONAL_MISSING" ]; then
        echo "[install_deps] OPTIONAL system jemalloc (best-effort):"
        if ! _pm_install "$OPTIONAL_MISSING"; then
            echo "  ⓘ system jemalloc package unavailable — obtain_local_deps.sh"
            echo "    will source-build it locally (§11.4.77). Not a failure."
        fi
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "[install_deps] DRY-RUN complete — nothing was installed."
    exit 0
fi

# ── verification census (§11.4 captured evidence) ────────────────────────────
echo ""
echo "[install_deps] verification:"
for tool in gcc cc make autoconf automake pkg-config bison flex; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "  ✓ $tool: $(command -v "$tool")"
    else
        echo "  ⚠ $tool not on PATH"
    fi
done
# The decisive check: can the compiler actually LINK an executable now?
_probe="$(mktemp -d "${TMPDIR:-/tmp}/idprobe.XXXXXX")" || _probe=""
if [ -n "$_probe" ]; then
    printf 'int main(void){return 0;}\n' > "$_probe/t.c"
    if "${CC:-cc}" "$_probe/t.c" -o "$_probe/t" >/dev/null 2>&1 && [ -x "$_probe/t" ]; then
        echo "  ✓ C compiler can LINK an executable (crt objects present)"
    else
        echo "  ✗ C compiler STILL cannot link — investigate (glibc-devel / libc dev?)"
    fi
    rm -rf "$_probe"
fi

echo ""
echo "[install_deps] done. Now run: bash scripts/setup.sh"
