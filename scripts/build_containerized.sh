#!/usr/bin/env bash
# build_containerized.sh — build tmux from source inside an isolated
# podman container, per §12.9 architecture. Resource limits: 2 CPUs, 2 GB RAM
# (tmux peaks at ~500 MB during build).
#
# Usage: bash scripts/build_containerized.sh
#
# Output: <project>/tmux/build/bin/tmux (host-visible via volume mount)
#
# §12.9 invariants:
#   - Container has its own cgroup with mem_limit=2g
#   - Container is OUTSIDE user.slice (cannot escalate)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

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
    echo "[build_containerized] building image $IMAGE..."
    $CONTAINER_CMD build \
        --build-arg BUILD_UID="$(id -u)" \
        --build-arg BUILD_GID="$(id -g)" \
        -f docker/Dockerfile \
        -t "$IMAGE" .
fi

# Remove any stale container
$CONTAINER_CMD rm -f "$NAME" >/dev/null 2>&1 || true

# --userns=keep-id is a PODMAN-only run mode (rootless UID-mapping so the
# bind-mounted output is host-owned). Docker REJECTS it ("--userns: invalid
# USER mode", exit 125) and does not need it: the Dockerfile's `USER builder`
# + BUILD_UID/BUILD_GID build-args (passed above) already make a rootful
# `docker run` execute as the host UID, so the mounted output is host-owned
# without any --userns flag (forensic anchor: amber docker 29.4.1 rejected the
# flag, 2026-06-28; §11.4.81 cross-platform-parity / §11.4.161). Gate the flag
# on the engine. An `if` keeps the gate unambiguous under set -e (a bare
# `[ cond ] && USERNS_ARGS+=(...)` is exempt from set -e only by the AND-list
# rule — subtle + shell-dependent; the `if` is plainly correct regardless); the
# ${arr[@]+"${arr[@]}"} idiom expands an empty array safely under set -u.
USERNS_ARGS=()
if [ "$CONTAINER_CMD" = "podman" ]; then
    USERNS_ARGS+=(--userns=keep-id)
fi

# Launch
echo "[build_containerized] launching container $NAME (mem_limit=2g, cpus=2)..."
$CONTAINER_CMD run --rm \
    --name "$NAME" \
    --network none \
    ${USERNS_ARGS[@]+"${USERNS_ARGS[@]}"} \
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
    echo "[build_containerized] ✓ binary produced: $REPO_ROOT/tmux/build/bin/tmux"
    "$REPO_ROOT/tmux/build/bin/tmux" -V
    echo ""
    echo "[build_containerized] next: bash scripts/tests/run_all.sh   — validates the binary"
else
    echo "[build_containerized] ✗ binary missing after container exit — inspect output above"
    exit 3
fi
