#!/usr/bin/env bash
# build_tmux_containerized.sh — build tmux from source inside an isolated
# podman container, per §12.9 architecture. Mirrors scripts/build_containerized.sh
# but with much smaller resource limits (tmux peaks at ~500 MB during build).
#
# Usage: bash scripts/build_tmux_containerized.sh
#
# Output: <project>/tmux/build/bin/tmux (host-visible via volume mount)
#
# §12.9 invariants:
#   - Container has its own cgroup with mem_limit=2g
#   - Container is OUTSIDE user.slice (cannot escalate)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# §12 host safety preflight
    # shellcheck source=/dev/null
        echo "[build_tmux_containerized] §12 host safety preflight..."
    fi
fi

# Detect podman or docker
if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
else
    echo "ERROR: neither podman nor docker available"
    exit 2
fi

IMAGE="tmx-build:latest"
NAME="tmx-build"

# Build the image if missing
if ! $CONTAINER_CMD image exists "$IMAGE" 2>/dev/null; then
    echo "[build_tmux_containerized] building image $IMAGE..."
    $CONTAINER_CMD build \
        --build-arg BUILD_UID="$(id -u)" \
        --build-arg BUILD_GID="$(id -g)" \
        -f docker/Dockerfile.tmux-build \
        -t "$IMAGE" .
fi

# Remove any stale container
$CONTAINER_CMD rm -f "$NAME" >/dev/null 2>&1 || true

# Launch
echo "[build_tmux_containerized] launching container $NAME (mem_limit=2g, cpus=2)..."
$CONTAINER_CMD run --rm \
    --name "$NAME" \
    --network none \
    --userns=keep-id \
    --memory 2g \
    --memory-swap 3g \
    --cpus 2 \
    -v "$REPO_ROOT/tmux":/tmux-src:rw \
    -v "$REPO_ROOT/docker/build_inside_container.sh":/build.sh:ro \
    --workdir /tmux-src \
    "$IMAGE" \
    bash /build.sh

# Verify host-side that the binary appeared
if [ -x "$REPO_ROOT/tmux/build/bin/tmux" ]; then
    echo ""
    echo "[build_tmux_containerized] ✓ binary produced: $REPO_ROOT/tmux/build/bin/tmux"
    "$REPO_ROOT/tmux/build/bin/tmux" -V
    echo ""
    echo "[build_tmux_containerized] next: bash scripts/tests/run_all.sh   — validates the binary"
else
    echo "[build_tmux_containerized] ✗ binary missing after container exit — inspect output above"
    exit 3
fi
