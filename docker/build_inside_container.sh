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
# `-Wl,--no-as-needed -ljemalloc -Wl,--as-needed` forces jemalloc into the
# DT_NEEDED list even though tmux doesn't reference jemalloc symbols directly
# (the linker's default --as-needed would drop it). This is what makes the
# README's "Build-time `-ljemalloc`" claim true rather than a bluff — without
# --no-as-needed, ldd shows no libjemalloc.so and we'd be falsely advertising
# the build-time linkage.
CFLAGS="-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wno-unused-parameter -Wno-deprecated-declarations" \
LDFLAGS="-Wl,-z,relro,-z,now -Wl,--no-as-needed -ljemalloc -Wl,--as-needed" \
    ./configure \
        --prefix=/tmux-src/build \
        --disable-debug 2>&1 | tail -10

echo ""
# `make clean` forces re-link even when source unchanged. Without this,
# an LDFLAGS change (e.g. adding --no-as-needed) is silently dropped when
# the existing binary's mtime defeats make's dependency check.
if [ -f Makefile ]; then
    echo "[inner] make clean (force re-link to honour current LDFLAGS)..."
    make clean 2>&1 | tail -2 || true
fi
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
