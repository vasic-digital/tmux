#!/usr/bin/env bash
# install_tmux_deps.sh — install build dependencies for tmux from-source build.
#
# Usage: sudo bash scripts/install_tmux_deps.sh
#
# Detects package manager (apt/dnf/yum/pacman/zypper) and installs:
#   - libevent (>= 2.1) headers
#   - ncurses headers
#   - jemalloc headers (for runtime LD_PRELOAD optimisation)
#   - autoconf, automake, pkg-config, gcc, make (build chain)
#
# OS coverage: ALT Linux (apt-rpm), Debian/Ubuntu (apt-get), Fedora/RHEL (dnf),
# Arch (pacman), openSUSE (zypper), Alpine (apk).
#
# Idempotent — safe to re-run.

set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: this script needs root (it installs system packages)."
    echo "       run with: sudo bash $0"
    exit 1
fi

. /etc/os-release 2>/dev/null || { echo "ERROR: /etc/os-release missing — unsupported OS"; exit 2; }

echo "[install_tmux_deps] OS=$ID  VERSION=$VERSION_ID  ($PRETTY_NAME)"

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

echo "[install_tmux_deps] using $PM to install: $PKGS"
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
echo "[install_tmux_deps] verification:"
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
echo "[install_tmux_deps] done. Now run (without sudo):"
echo "  bash scripts/build_containerized.sh"
