#!/usr/bin/env bash
# test_vm.sh — run the full verification suite inside the podman machine VM
# (Fedora CoreOS with systemd, where user-scope tests + destructive tests
# can run with real evidence). Each invocation regenerates scripts/tmx with
# VM-native paths so the wrapper actually works in the VM.
#
# Why this matters (§11.4.6 — no-guessing): scripts/tmx is GENERATED from
# tmx.template with absolute paths baked in for either (a) the host
# filesystem or (b) the container's /repo mount. Running the same wrapper
# in a different environment than the one it was generated for silently
# fails (tmux binary not found → server never starts → tests downstream
# fail with confusing errors like "tmux server PID not found"). This
# script makes the environment-binding explicit.
#
# Usage:
#   bash scripts/test_vm.sh                 # full verify.sh (PASS=10 typical)
#   TMX_TEST_DESTRUCTIVE=1 bash scripts/test_vm.sh  # also run tests 12/13/14
#   META=1 bash scripts/test_vm.sh          # only run the meta-test instead
#
# Prerequisites:
#   - podman machine running (`podman machine list` shows "Currently up")
#   - VM has libjemalloc + stress-ng + gcc + make installed (one-time setup
#     via `sudo rpm-ostree install --apply-live jemalloc gcc make stress-ng`)
#   - OOM helper installed in VM (one-time:
#     `podman machine ssh "sudo bash /Users/$USER/Projects/tmux/scripts/build_oom_set.sh --install"`)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! podman machine list --format '{{.LastUp}}' 2>/dev/null | grep -qi "currently running"; then
    echo "ERROR: podman machine is not running. Start it with: podman machine start"
    exit 2
fi

# VM mount point for the repo — virtiofs auto-mounts /Users on macOS.
VM_REPO="/Users/$(id -un)/Projects/tmux"

echo "[test_vm] verifying VM repo mount + tmux binary..."
if ! podman machine ssh "test -x $VM_REPO/tmux/build/bin/tmux" 2>/dev/null; then
    echo "ERROR: $VM_REPO/tmux/build/bin/tmux not found inside VM."
    echo "       Build first: bash scripts/build_containerized.sh"
    exit 3
fi

echo "[test_vm] regenerating $VM_REPO/scripts/tmx with VM-native paths..."
# Resolve libjemalloc inside the VM (not the host, since the binary loads
# against VM glibc / libjemalloc).
VM_JEMALLOC=$(podman machine ssh "ldconfig -p 2>/dev/null | awk '/libjemalloc\\.so\\.[0-9]/ {print \$NF; exit}'" 2>/dev/null | tr -d '\r' || true)
if [ -z "$VM_JEMALLOC" ]; then
    echo "ERROR: libjemalloc.so.* not found in VM. One-time fix:"
    echo "  podman machine ssh \"sudo rpm-ostree install --apply-live jemalloc\""
    exit 3
fi
echo "[test_vm] VM libjemalloc: $VM_JEMALLOC"

podman machine ssh "sed -e 's|__TMUX_BIN__|$VM_REPO/tmux/build/bin/tmux|g' \
                          -e 's|__JEMALLOC_PATH__|$VM_JEMALLOC|g' \
                          $VM_REPO/scripts/tmx.template > $VM_REPO/scripts/tmx \
                          && chmod +x $VM_REPO/scripts/tmx"

echo "[test_vm] running suite in VM..."
echo ""
if [ "${META:-0}" = "1" ]; then
    podman machine ssh "bash $VM_REPO/scripts/tests/meta_test_false_positive_proof.sh"
else
    if [ "${TMX_TEST_DESTRUCTIVE:-0}" = "1" ]; then
        podman machine ssh "TMX_TEST_DESTRUCTIVE=1 bash $VM_REPO/scripts/verify.sh"
    else
        podman machine ssh "bash $VM_REPO/scripts/verify.sh"
    fi
fi
