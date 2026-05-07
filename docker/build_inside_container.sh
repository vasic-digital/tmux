#!/usr/bin/env bash
# build_inside_container.sh — runs INSIDE the tmux-build podman container.
# Configures, compiles, and installs tmux to the volume-mounted source tree.
#
# Build flags applied:
#   --prefix=/tmux-src/build  (volume-mounted, host sees output)
#   CFLAGS hardening + optimization
#   LDFLAGS RELRO + immediate binding
# jemalloc: linked via LDFLAGS=-ljemalloc for runtime preference
#           (also available via LD_PRELOAD at runtime — see wrapper script)

set -euo pipefail

cd /tmux-src

# Generate ./configure (autoreconf + automake)
if [ ! -f configure ]; then
    echo "[inner] running autogen.sh..."
    bash autogen.sh 2>&1 | tail -3
fi

echo "[inner] configuring with hardened flags + jemalloc link..."
CFLAGS="-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wno-unused-parameter -Wno-deprecated-declarations" \
LDFLAGS="-Wl,-z,relro,-z,now -ljemalloc" \
    ./configure \
        --prefix=/tmux-src/build \
        --disable-debug 2>&1 | tail -10

echo ""
echo "[inner] compiling with -j2 (container CPU cap)..."
make -j2 2>&1 | tail -5

echo ""
echo "[inner] installing to /tmux-src/build..."
make install 2>&1 | tail -3

echo ""
echo "[inner] verifying binary..."
if [ -x /tmux-src/build/bin/tmux ]; then
    /tmux-src/build/bin/tmux -V
    echo "[inner] dynamic linkage:"
    ldd /tmux-src/build/bin/tmux | sed 's/^/  /'
    echo ""
    echo "[inner] jemalloc verification:"
    if ldd /tmux-src/build/bin/tmux | grep -q jemalloc; then
        echo "  ✓ jemalloc linked"
    else
        echo "  ⚠ jemalloc NOT linked at build time — will rely on LD_PRELOAD only"
    fi
else
    echo "[inner] ✗ BUILD FAILED — no /tmux-src/build/bin/tmux"
    exit 1
fi

echo ""
echo "[inner] done. Host can now run scripts/tests/run_all.sh."
