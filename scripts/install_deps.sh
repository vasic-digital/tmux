#!/usr/bin/env bash
# install_deps.sh — install build dependencies for tmux from-source build.
#
# Usage:
#   Linux:  sudo bash scripts/install_deps.sh
#   macOS:  bash scripts/install_deps.sh   (no sudo — uses Homebrew)
#
# Detects OS first, then on Linux detects package manager
# (apt/dnf/yum/pacman/zypper).
#
# Packages installed:
#   - libevent (>= 2.1) headers
#   - ncurses headers
#   - jemalloc headers (for runtime LD_PRELOAD / DYLD_INSERT_LIBRARIES optimisation)
#   - autoconf, automake, pkg-config, gcc, make, bison, utf8proc
#
# OS coverage:
#   macOS Darwin  → Homebrew
#   ALT Linux (apt-rpm), Debian/Ubuntu (apt-get), Fedora/RHEL (dnf),
#   Arch (pacman), openSUSE (zypper), Alpine (apk).
#
# Idempotent — safe to re-run.

set -euo pipefail

HOST_OS="$(uname -s)"

# ── Darwin branch: brew installs the deps build_native.sh needs ──────
if [ "$HOST_OS" = "Darwin" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "ERROR: Homebrew not installed on macOS."
        echo "  Install via:"
        echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 2
    fi
    BREWS="libevent jemalloc automake autoconf pkg-config bison utf8proc"
    echo "[install_deps] Darwin: brew install $BREWS"
    # shellcheck disable=SC2086
    brew install $BREWS
    echo "[install_deps] ✓ Darwin build deps ready (no sudo needed)."
    echo "[install_deps] next: bash scripts/setup.sh"
    exit 0
fi

# ── Linux branch (requires root for system package install) ──────────
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: this script needs root on Linux (it installs system packages)."
    echo "       run with: sudo bash $0"
    exit 1
fi

. /etc/os-release 2>/dev/null || { echo "ERROR: /etc/os-release missing — unsupported OS"; exit 2; }

echo "[install_deps] OS=$ID  VERSION=$VERSION_ID  ($PRETTY_NAME)"

# Package name mapping per OS family.
case "$ID" in
    altlinux|alt)
        PM="apt-get"
        PKGS="libevent-devel libncurses-devel jemalloc-devel pkg-config gcc make autoconf automake bison byacc"
        ;;
    debian|ubuntu|linuxmint|raspbian)
        PM="apt-get"
        PKGS="libevent-dev libncurses-dev libjemalloc-dev pkg-config gcc make autoconf automake bison"
        ;;
    fedora|rhel|centos|rocky|almalinux|amzn)
        PM="dnf"
        PKGS="libevent-devel ncurses-devel jemalloc-devel pkgconf-pkg-config gcc make autoconf automake bison"
        ;;
    arch|manjaro|endeavouros)
        PM="pacman"
        PKGS="libevent ncurses jemalloc pkgconf gcc make autoconf automake bison"
        ;;
    opensuse*|sles)
        PM="zypper"
        PKGS="libevent-devel ncurses-devel jemalloc-devel pkg-config gcc make autoconf automake bison"
        ;;
    alpine)
        PM="apk"
        PKGS="libevent-dev ncurses-dev jemalloc-dev pkgconf gcc make autoconf automake bison-dev"
        ;;
    *)
        echo "ERROR: unsupported OS '$ID'. Add a case for it in this script."
        exit 3
        ;;
esac

echo "[install_deps] using $PM to install: $PKGS"
echo ""

case "$PM" in
    apt-get)
        apt-get update -qq
        # shellcheck disable=SC2086
        apt-get install -y $PKGS
        ;;
    dnf|yum)
        # shellcheck disable=SC2086
        $PM install -y $PKGS
        ;;
    pacman)
        # shellcheck disable=SC2086
        pacman -Syu --noconfirm $PKGS
        ;;
    zypper)
        # shellcheck disable=SC2086
        zypper install -y $PKGS
        ;;
    apk)
        # shellcheck disable=SC2086
        apk add --no-cache $PKGS
        ;;
esac

echo ""
echo "[install_deps] verification:"
for tool in gcc make autoconf automake pkg-config; do
    if command -v $tool >/dev/null 2>&1; then
        echo "  ✓ $tool: $(command -v $tool)"
    else
        echo "  ✗ $tool MISSING after install — investigate"
    fi
done

# Verify libraries via pkg-config or ldconfig
echo ""
for lib in libevent ncurses jemalloc; do
    if pkg-config --exists $lib 2>/dev/null; then
        echo "  ✓ $lib pkg-config: $(pkg-config --modversion $lib 2>/dev/null)"
    elif ldconfig -p 2>/dev/null | grep -qi $lib; then
        echo "  ✓ $lib (via ldconfig): $(ldconfig -p | grep -i $lib | head -1 | awk '{print $NF}')"
    else
        echo "  ⚠ $lib NOT visible via pkg-config or ldconfig — build may fail"
    fi
done

echo ""
echo "[install_deps] done. Now run (without sudo):"
echo "  bash scripts/build_containerized.sh"
