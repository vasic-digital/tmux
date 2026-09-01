#!/usr/bin/env bash
# test_containerized.sh — run scripts/tests/run_all.sh inside the
# tmx-build:latest container so that the test environment is bounded
# (mem + cpu + network=none) and reproducible. Per the Containers
# submodule's mandate (§12 host-session safety): every process MUST
# run inside a container with explicit limits — including tests.
#
# Coverage profile inside this image:
#   01-08  : runnable (binary + libjemalloc + libevent + libncurses present)
#   09     : SKIPs honestly via topology probe (no user systemd in container)
#   10     : pure bash, runs
#   11     : SKIPs (wrapper requires user systemd)
#   12-14  : SKIP unless TMX_TEST_DESTRUCTIVE=1, then still SKIP (no user systemd)
#
# For full coverage including 09 / 11-14, the suite must run on a host
# with a real user systemd instance (regular Linux desktop / server,
# not a stripped container). The SKIP-with-reason behaviour is the
# §11.4.3 topology dispatch working as designed.
#
# Usage: bash scripts/test_containerized.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
else
    echo "ERROR: neither podman nor docker available"
    exit 2
fi

IMAGE="tmx-build:latest"
NAME="tmx-test"

if ! $CONTAINER_CMD image exists "$IMAGE" 2>/dev/null; then
    echo "[test_containerized] image $IMAGE missing — run scripts/build_containerized.sh first"
    exit 2
fi

$CONTAINER_CMD rm -f "$NAME" >/dev/null 2>&1 || true

echo "[test_containerized] launching $NAME (mem=2g, cpus=2, network=none)..."
# Generate the tmx wrapper inside the container so that libjemalloc.so.2
# resolves to the container's path (host macOS has no libjemalloc visible).
# Then run the suite. Both happen in the same container so paths are
# consistent.
$CONTAINER_CMD run --rm \
    --name "$NAME" \
    --network none \
    --userns=keep-id \
    --memory 2g \
    --memory-swap 3g \
    --cpus 2 \
    -v "$REPO_ROOT":/repo:rw \
    --workdir /repo \
    -e TMUX_BIN=/repo/tmux/build/bin/tmux \
    -e WRAPPER=/repo/scripts/tmx \
    -e EXPECTED_VERSION=next-3.8 \
    "$IMAGE" \
    bash -c '
        set -euo pipefail
        # Resolve jemalloc path inside the container
        JEMALLOC=$(/sbin/ldconfig -p 2>/dev/null | awk "/libjemalloc\\.so\\.[0-9]/ {print \$NF; exit}" || true)
        if [ -z "$JEMALLOC" ]; then
            JEMALLOC=$(find / -name "libjemalloc.so.2*" 2>/dev/null | head -1)
        fi
        echo "[in-container] jemalloc: $JEMALLOC"
        # Generate the wrapper
        sed -e "s|__TMUX_BIN__|/repo/tmux/build/bin/tmux|g" \
            -e "s|__JEMALLOC_PATH__|$JEMALLOC|g" \
            /repo/scripts/tmx.template > /repo/scripts/tmx
        chmod +x /repo/scripts/tmx
        echo "[in-container] generated /repo/scripts/tmx"
        # Run the suite
        exec bash /repo/scripts/tests/run_all.sh
    '
