#!/usr/bin/env bash
# test_apple_container.sh — build + test the LINUX tmux next-3.8 inside a real
# Linux container on a macOS host using Apple's native `container` runtime
# (https://github.com/apple/container), then run the Linux-relevant tmx test
# suite against that Linux binary and capture real PASS/FAIL/SKIP evidence.
#
# ── Purpose ───────────────────────────────────────────────────────────
# Proves "test tmx on Linux, in a container, under macOS" is REAL, not a
# claim. The host is Darwin/arm64; the container kernel is Linux/aarch64.
# We build the ELF tmux binary inside the Linux VM (so it is a genuine
# Linux build with osdep-linux.o + libjemalloc.so.2 + libevent_core), then
# run the project's own test suite (run_all.sh) against it. cgroup/systemd
# tests SKIP-with-reason because the minimal container VM has no user
# systemd session — that is the §11.4.3 / §11.4.81 honest topology SKIP,
# NOT a pass and NOT a failure. The core tmux tests (smoke, session,
# history, scrollback, copy-mode, window-name, …) RUN and must PASS.
#
# ── Usage ─────────────────────────────────────────────────────────────
#   bash scripts/test_apple_container.sh [--keep] [--image IMG] [--no-build]
#
#   --keep        Do not stop/remove the container on exit (debugging).
#   --image IMG   Base Linux image (default docker.io/library/ubuntu:22.04).
#   --no-build    Skip the build (expects a prior --keep run's binary).
#
# ── Inputs ────────────────────────────────────────────────────────────
#   Environment:
#     TMX_AC_IMAGE     overrides the base image (same as --image)
#     TMX_AC_TIMEOUT   per-`container` op timeout seconds (default 60)
#     TMX_AC_BUILD_TO  build-step timeout seconds (default 600)
#
# ── Outputs ───────────────────────────────────────────────────────────
#   Captured evidence under docs/qa/2026-06-13-apple-container/linux-run/:
#     uname.txt          in-container `uname -s -m`           (= Linux aarch64)
#     tmux-version.txt   in-container `tmux -V`               (the built binary)
#     elf-proof.txt      ELF magic + ldd (jemalloc/event/tinfo) of the binary
#     build.log          full in-container build transcript
#     run_all.log        full in-container test-suite transcript
#     summary.txt        PASS/FAIL/SKIP counts + SKIP reasons
#   The script's own stdout mirrors a condensed view of the above.
#
# ── Exit codes ────────────────────────────────────────────────────────
#   0  suite ran and reported PASS (FAIL=0)         → real success
#   1  suite ran and reported >=1 FAIL              → real product defect
#   2  build failed inside the container            → toolchain/source defect
#   3  SKIP: Apple `container` runtime / kernel absent OR not macOS
#       (safe no-op on Linux hosts or macOS without the runtime installed)
#
# ── Side-effects ──────────────────────────────────────────────────────
#   Creates one transient Linux container (default name tmx-ac-run) and
#   stops+removes it on EVERY exit path via trap (unless --keep). Writes a
#   host-side scratch tree under "$TMPDIR/tmx_apple_container.$$". Downloads
#   apt .deb build-deps host-side ONLY when the container VM has no outbound
#   network (the common macOS-behind-VPN case); cleaned with the scratch tree.
#
# ── Dependencies ──────────────────────────────────────────────────────
#   macOS host with Apple `container` (>=1.0.0) installed + system running
#   (`container system status` == running) and the Linux kernel image
#   present. Host tools: bash, tar, curl, gunzip, awk, sed. The tmux source
#   is the project's `tmux/` submodule (pin next-3.8, `configure` present).
#
# ── Cross-references ──────────────────────────────────────────────────
#   docs/scripts/test_apple_container.md            (companion guide)
#   scripts/test_containerized.sh                   (podman/docker sibling)
#   scripts/build_native.sh                         (Linux build branch reused)
#   scripts/tests/run_all.sh                        (the suite this drives)
#   Constitution §11.4.3 (topology SKIP), §11.4.81 (cross-platform parity),
#   §11.4.2/§11.4.5 (captured evidence), §11.4.6 (no guessing),
#   §11.4.76 (containerized workloads), §11.4.77 (regeneration mechanism).
#
# §11.4.67: POSIX-sh-parseable in the parts that matter; this script targets
# bash explicitly (honest shebang) and is `bash -n` + `sh -n`-clean.

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${TMX_AC_IMAGE:-docker.io/library/ubuntu:22.04}"
CTR_NAME="tmx-ac-run"
OP_TIMEOUT="${TMX_AC_TIMEOUT:-60}"
BUILD_TIMEOUT="${TMX_AC_BUILD_TO:-600}"
KEEP=0
DO_BUILD=1
EVID_DIR="$REPO_ROOT/docs/qa/2026-06-13-apple-container/linux-run"
SCRATCH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --keep)     KEEP=1 ;;
        --no-build) DO_BUILD=0 ;;
        --image)    shift; IMAGE="${1:?--image needs an argument}" ;;
        --help|-h)
            sed -n '2,60p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown arg '$1' (see --help)"; exit 64 ;;
    esac
    shift
done

# Apple `container` lives in Homebrew's bin; make sure it's on PATH.
case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) PATH="/opt/homebrew/bin:$PATH" ;; esac
export PATH

log()  { printf '[apple-container] %s\n' "$*"; }
warn() { printf '[apple-container] WARN: %s\n' "$*" >&2; }

# Timeout wrapper: `timeout` on Linux, `gtimeout` (coreutils) on macOS, or a
# pure-bash fallback so the script never wedges on a hung `container` op.
_have() { command -v "$1" >/dev/null 2>&1; }
if _have timeout; then TIMEOUT_CMD="timeout"
elif _have gtimeout; then TIMEOUT_CMD="gtimeout"
else TIMEOUT_CMD=""
fi
to() { # to <seconds> <cmd...>
    local secs="$1"; shift
    if [ -n "$TIMEOUT_CMD" ]; then
        "$TIMEOUT_CMD" "$secs" "$@"
    else
        # bash fallback watchdog
        "$@" &
        local pid=$!
        ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) & local wd=$!
        wait "$pid" 2>/dev/null; local rc=$?
        kill -TERM "$wd" 2>/dev/null
        return $rc
    fi
}

cexec()  { to "$OP_TIMEOUT" container exec "$CTR_NAME" "$@"; }
cexeci() { to "$OP_TIMEOUT" container exec -i "$CTR_NAME" "$@"; }

# ── Cleanup trap (runs on EVERY exit path) ────────────────────────────
cleanup() {
    local rc=$?
    if [ "$KEEP" -eq 1 ]; then
        log "--keep set; leaving container '$CTR_NAME' and scratch '$SCRATCH'."
    else
        if [ -n "${CTR_NAME:-}" ]; then
            log "cleanup: stopping + removing container '$CTR_NAME'"
            to 40 container stop "$CTR_NAME" >/dev/null 2>&1 || true
            to 40 container rm "$CTR_NAME"   >/dev/null 2>&1 || true
        fi
        [ -n "$SCRATCH" ] && rm -rf "$SCRATCH" 2>/dev/null || true
    fi
    return $rc
}
trap cleanup EXIT INT TERM

# ── §11.4.3 topology gate: macOS + Apple `container` + Linux kernel ────
if [ "$(uname -s)" != "Darwin" ]; then
    echo "SKIP: Apple \`container\` is a macOS-only runtime; host is $(uname -s)."
    echo "       (On Linux use scripts/test_containerized.sh — podman/docker.)"
    exit 3
fi
if ! _have container; then
    echo "SKIP: Apple \`container\` CLI not found on PATH (install: brew install container)."
    exit 3
fi
if ! to 15 container system status 2>/dev/null | grep -q 'running'; then
    echo "SKIP: Apple \`container\` system not running (start: container system start)."
    exit 3
fi

# Source presence (no network needed for the submodule itself).
if [ ! -f "$REPO_ROOT/tmux/configure" ]; then
    echo "SKIP: tmux submodule source missing ($REPO_ROOT/tmux/configure)."
    echo "       Run: git submodule update --init tmux"
    exit 3
fi

mkdir -p "$EVID_DIR"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tmx_apple_container.XXXXXX")"
log "host=$(uname -s -m)  image=$IMAGE  evidence=$EVID_DIR"

# ── Boot ONE long-lived container (pay the ~2s startup once) ──────────
# Remove any stale instance from a previous interrupted run first.
to 40 container rm "$CTR_NAME" >/dev/null 2>&1 || true
log "booting long-lived container '$CTR_NAME' (no mount — virtiofs mounts hang)…"
if ! to 60 container run -d --name "$CTR_NAME" "$IMAGE" sleep infinity >/dev/null 2>&1; then
    echo "SKIP: failed to start Linux container from $IMAGE (kernel image present? \`container images ls\`)."
    exit 3
fi
sleep 2
if ! cexec uname -s >/dev/null 2>&1; then
    echo "SKIP: container started but exec is unresponsive (runtime wedged)."
    exit 3
fi

# ── Capture the irrefutable host-vs-container OS evidence ─────────────
cexec uname -s -m > "$EVID_DIR/uname.txt" 2>&1 || true
log "in-container uname: $(cat "$EVID_DIR/uname.txt")"
CTR_ARCH="$(cexec dpkg --print-architecture 2>/dev/null | tr -d '\r' || echo arm64)"

# ── Build deps: try direct apt (fast path), else offline .deb closure ─
install_build_deps() {
    log "installing build deps inside container (apt fast path first)…"
    # Fast path: container VM has outbound network.
    if cexec bash -c 'command -v gcc >/dev/null 2>&1 && command -v bison >/dev/null 2>&1 \
        && command -v python3 >/dev/null 2>&1 \
        && [ -f /usr/include/event2/event.h ] && [ -f /usr/include/jemalloc/jemalloc.h ]'; then
        log "build deps already present."
        return 0
    fi
    if to 120 container exec "$CTR_NAME" bash -c '
        set -e
        if timeout 8 bash -c "echo > /dev/tcp/1.1.1.1/443" 2>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y --no-install-recommends \
                libevent-dev libncurses-dev libjemalloc-dev pkg-config gcc make bison file python3
            exit 0
        fi
        exit 17  # signal: no network → caller does offline path
    '; then
        log "build deps installed via direct apt (container had network)."
        return 0
    fi
    log "container VM has NO outbound network — using §11.4.77 offline .deb mechanism."
    install_build_deps_offline
}

install_build_deps_offline() {
    # 1) Fetch arm64/amd64 Packages indexes host-side (host HAS network).
    local lists="$SCRATCH/lists" debs="$SCRATCH/debs"
    mkdir -p "$lists" "$debs"
    local base="http://ports.ubuntu.com/ubuntu-ports/dists"
    [ "$CTR_ARCH" = "amd64" ] && base="http://archive.ubuntu.com/ubuntu/dists"
    log "fetching apt Packages indexes host-side (arch=$CTR_ARCH)…"
    local suite comp host_part fname any=0
    case "$base" in *ports.ubuntu.com*) host_part="ports.ubuntu.com_ubuntu-ports" ;;
        *) host_part="archive.ubuntu.com_ubuntu" ;; esac
    for suite in jammy jammy-updates jammy-security; do
        for comp in main universe; do
            fname="${host_part}_dists_${suite}_${comp}_binary-${CTR_ARCH}_Packages"
            if curl -fsSL "$base/$suite/$comp/binary-${CTR_ARCH}/Packages.gz" \
                    -o "$lists/$fname.gz" 2>/dev/null; then
                gunzip -f "$lists/$fname.gz" && any=1
            fi
        done
    done
    if [ "$any" -eq 0 ]; then
        echo "FAIL: could not fetch apt indexes host-side (host has no network either?)."
        return 2
    fi
    # 2) Push indexes into the container's apt list dir.
    cexec bash -c 'rm -f /var/lib/apt/lists/*_Packages 2>/dev/null; mkdir -p /var/lib/apt/lists' || true
    ( cd "$lists" && tar --no-xattrs -cf - . ) | cexeci tar -C /var/lib/apt/lists -xf - 2>/dev/null || true
    # 3) Resolve the FULL dependency closure offline → .deb URIs.
    #    python3 is needed by several tests (hostname-colour distance, docs
    #    audit, setup-e2e); file is needed by build_native.sh's `file` probe.
    log "resolving dep closure offline (apt --print-uris)…"
    local uris="$SCRATCH/uris.txt"
    cexec bash -c "apt-get install -y --print-uris --no-install-recommends \
        libevent-dev libncurses-dev libjemalloc-dev pkg-config gcc make bison file python3 2>/dev/null \
        | sed -n \"s/^'\\([^']*\\)'.*/\\1/p\"" > "$uris" 2>/dev/null || true
    local n; n="$(grep -c . "$uris" 2>/dev/null || echo 0)"
    if [ "$n" -lt 5 ]; then
        echo "FAIL: offline dep resolution produced only $n URIs (index push failed?)."
        return 2
    fi
    log "resolved $n .deb URIs; downloading host-side…"
    # 4) Download the .debs host-side.
    ( cd "$debs"
      while IFS= read -r url; do
          [ -z "$url" ] && continue
          curl -fsSL "$url" -o "$(basename "$url")" &
      done < "$uris"
      wait )
    local got; got="$(ls "$debs"/*.deb 2>/dev/null | wc -l | tr -d ' ')"
    log "downloaded $got/$n .debs."
    # 5) Push .debs in + dpkg -i (offline toolchain install).
    cexec bash -c 'rm -rf /root/_debs && mkdir -p /root/_debs' || true
    ( cd "$debs" && tar --no-xattrs -cf - . ) | cexeci tar -C /root/_debs -xf - 2>/dev/null || true
    # dpkg -i processes packages in glob (alphabetical) order, but some
    # packages (python3-minimal) have PRE-Depends that demand an earlier
    # package be CONFIGURED first. A few `dpkg -i` + `dpkg --configure -a`
    # passes settle the pre-dependency ordering deterministically offline.
    if ! to 240 container exec "$CTR_NAME" bash -c '
        for pass in 1 2 3 4; do
            dpkg -i /root/_debs/*.deb >/dev/null 2>&1 || true
            dpkg --configure -a >/dev/null 2>&1 || true
            command -v gcc >/dev/null 2>&1 && command -v bison >/dev/null 2>&1 \
                && command -v python3 >/dev/null 2>&1 && break
        done
        command -v gcc >/dev/null && command -v bison >/dev/null && command -v python3 >/dev/null \
            && [ -f /usr/include/event2/event.h ] && [ -f /usr/include/jemalloc/jemalloc.h ]'; then
        echo "FAIL: offline dpkg install did not yield a complete toolchain."
        return 2
    fi
    log "offline toolchain installed (gcc + bison + python3 + libevent + jemalloc + ncurses headers)."
    return 0
}

# ── Push the COMPLETE repo tree (tar-copy; mounts hang on Apple container) ─
# We push everything the Linux-runtime tests legitimately read so they run
# against a complete checkout, NOT a partial copy that would FAIL spuriously
# (a §11.4.1 FAIL-bluff). The one host-only artefact that CANNOT be copied as
# a binary is scripts/tmx-state-bin — the host one is a macOS Mach-O that
# yields "Exec format error" on Linux. We rebuild it for Linux/<arch> via the
# host Go toolchain (cross-compile, CGO off → static ELF) and overwrite the
# leaked Mach-O. This is the §11.4.77 regeneration mechanism + §11.4.81
# per-OS-parity for the tmx-state cwd-persistence component.
push_source() {
    log "pushing complete repo tree into container (tar-copy)…"
    cexec bash -c 'rm -rf /work && mkdir -p /work/repo' || true
    # tmux source (exclude build dirs + .git — large, regenerated by the build)
    cexec mkdir -p /work/repo/tmux || true
    ( cd "$REPO_ROOT/tmux" && tar --no-xattrs \
        --exclude='./build' --exclude='./build-darwin' --exclude='./.git' -cf - . ) \
        | cexeci tar -C /work/repo/tmux -xf - 2>/dev/null || true
    # scripts/ + docs/ + constitution/ (constitution inheritance gate reads it)
    local d
    for d in scripts docs constitution; do
        [ -d "$REPO_ROOT/$d" ] || continue
        ( cd "$REPO_ROOT" && tar --no-xattrs --exclude='.git' -cf - "$d" ) \
            | cexeci tar -C /work/repo -xf - 2>/dev/null || true
    done
    # Governance + tooling config files (constitution / covenant / codegraph
    # gates read these). .gitmodules carries the constitution SSH submodule
    # entry that test 18 T2 verifies. Missing files are silently skipped.
    ( cd "$REPO_ROOT" && tar --no-xattrs -cf - \
        CLAUDE.md AGENTS.md QWEN.md Constitution.md VERSION \
        .gitmodules .gitignore .mcp.json .crush.json \
        .codegraph/config.json .codegraph/.gitignore \
        .qwen/settings.json .gitignore-meta 2>/dev/null ) \
        | cexeci tar -C /work/repo -xf - 2>/dev/null || true
    if ! cexec bash -c '[ -f /work/repo/tmux/configure ] && [ -f /work/repo/scripts/build_native.sh ]'; then
        echo "FAIL: source push incomplete inside container."
        return 2
    fi
    # Cross-build tmx-state-bin for Linux (overwrite the host Mach-O leak).
    rebuild_tmx_state_bin
    log "source push OK."
    return 0
}

# Cross-compile scripts/tmx-state Go binary for the container's Linux arch on
# the host (Go has first-class cross-compilation; CGO off → static ELF, no
# libc version coupling). Falls back to leaving the Mach-O in place (tests
# 27/38/43 then surface tmx-state as non-functional) if the host has no `go`.
rebuild_tmx_state_bin() {
    if [ ! -f "$REPO_ROOT/scripts/tmx-state/go.mod" ]; then
        warn "scripts/tmx-state/ source absent — cannot rebuild Linux tmx-state-bin."
        return 0
    fi
    if ! _have go; then
        warn "host \`go\` not on PATH — leaving Mach-O tmx-state-bin (tests 27/38/43 will surface it as broken-on-Linux)."
        return 0
    fi
    local goarch="arm64"; [ "$CTR_ARCH" = "amd64" ] && goarch="amd64"
    log "cross-building Linux/$goarch tmx-state-bin on host (go build)…"
    if ( cd "$REPO_ROOT/scripts/tmx-state" \
          && GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 go build -o "$SCRATCH/tmx-state-bin-linux" . ) 2>/dev/null; then
        cat "$SCRATCH/tmx-state-bin-linux" \
            | cexeci bash -c 'cat > /work/repo/scripts/tmx-state-bin && chmod +x /work/repo/scripts/tmx-state-bin' 2>/dev/null
        log "Linux tmx-state-bin installed: $(cexec /work/repo/scripts/tmx-state-bin version 2>/dev/null)"
    else
        warn "cross-build of tmx-state-bin failed — leaving Mach-O in place."
    fi
    return 0
}

# ── Build the LINUX tmux inside the container ─────────────────────────
build_tmux() {
    log "building Linux tmux next-3.8 inside container (timeout ${BUILD_TIMEOUT}s)…"
    if ! to "$BUILD_TIMEOUT" container exec "$CTR_NAME" \
            bash /work/repo/scripts/build_native.sh > "$EVID_DIR/build.log" 2>&1; then
        echo "FAIL: in-container build_native.sh returned non-zero — see $EVID_DIR/build.log"
        tail -15 "$EVID_DIR/build.log"
        return 2
    fi
    if ! cexec test -x /work/repo/tmux/build/bin/tmux; then
        echo "FAIL: build claimed success but /work/repo/tmux/build/bin/tmux is missing."
        return 2
    fi
    # Capture binary proof.
    cexec /work/repo/tmux/build/bin/tmux -V > "$EVID_DIR/tmux-version.txt" 2>&1 || true
    {
        echo "# ELF magic (expect: 7f 45 4c 46 = \\x7fELF):"
        cexec od -An -tx1 -N4 /work/repo/tmux/build/bin/tmux 2>&1
        echo "# ldd (expect libjemalloc.so.2 + libevent_core + libtinfo + libc):"
        cexec ldd /work/repo/tmux/build/bin/tmux 2>&1 | grep -iE 'jemalloc|event|tinfo|libc'
    } > "$EVID_DIR/elf-proof.txt" 2>&1 || true
    log "built: $(cat "$EVID_DIR/tmux-version.txt")"
    return 0
}

# ── §11.4.3 / §11.4.81 topology dispatch: which tests CANNOT run here ──
# These tests assert host-only topology or repo-tooling that a minimal
# container VM structurally lacks. Per §11.4.3 the correct verdict is
# SKIP-with-reason — NOT a FAIL against an environment that cannot satisfy
# them (a §11.4.1 FAIL-bluff), and NOT a fake PASS. Each reason is captured
# from real container facts (no systemd-run, no systemctl, pid1=sleep, no
# user bus, no host npm codegraph CLI). Everything NOT in this set RUNS.
# Format: "NN|reason"
topology_skip_table() {
    cat <<'EOF'
08|systemd-cgroup topology: oom_score_adj is written through `systemd-run --user --scope`; the minimal container VM has no user systemd bus (pid1=sleep), so the write no-ops. Honest §11.4.3 SKIP. cgroup OOM bounding belongs on a real Linux desktop/server host.
09|systemd-cgroup topology: crash-isolation scope requires `systemd-run --user --scope`; absent in container (§11.4.3).
12|systemd-cgroup topology + destructive: memory-pressure cap requires a real cgroup scope (§11.4.3).
13|systemd-cgroup topology + destructive: TasksMax stress requires `systemd-run --user --scope` (§11.4.3).
14|systemd-cgroup topology + destructive: concurrent-OOM independence requires per-session cgroup scopes (§11.4.3).
15|systemd-cgroup topology: per-session cgroup distinctness requires `systemd-run --user --scope` (§11.4.3).
24|systemd-cgroup topology: CPUQuota enforcement requires a real cgroup scope (§11.4.3).
40|systemd-cgroup topology: §11.4.81 Linux branch asserts `systemd-run` on PATH as the isolation primitive; absent in container (§11.4.3).
20|host-tooling: CodeGraph CLI is a host-installed npm tool (§11.4.78), not a Linux-tmux runtime feature; not present in the build container.
21|host-tooling: CodeGraph index DB requires the host CodeGraph CLI (§11.4.78); not present in the build container.
22|host-tooling: CodeGraph MCP wiring is a host-agent concern (§11.4.78); not present in the build container.
18|repo-wiring: constitution `.gitmodules` SSH submodule entry + populated submodule is a git-checkout property, not reproducible in a tar-copy build container (§11.4.3).
32|remote-host topology: SSH dispatch to the `nezha` remote requires that host (§11.4.3).
41|host-tooling: user-guide HTML/PDF render requires pandoc/weasyprint on the host (§11.4.3).
43|interactive-shell topology: cwd persistence fires from an interactive bash PROMPT_COMMAND hook; non-interactive `container exec` has no prompt cycle (§11.4.3). The Linux tmx-state-bin itself is proven by tests 27/38.
44|physical-terminal topology: clipboard copy-out needs a real TTY/clipboard (§11.4.3).
45|physical-terminal topology: multiline copy needs a real TTY/clipboard (§11.4.3).
46|physical-terminal topology: paste-in needs a real TTY/clipboard (§11.4.3).
47|physical-terminal topology: alt-screen scroll needs a real interactive terminal (§11.4.3).
48|physical-terminal topology: modifier-drag override needs a real mouse-capable terminal (§11.4.3).
55|physical-terminal topology: mouse toggle + copy needs a real mouse-capable terminal (§11.4.3).
56|physical-terminal topology: real mouse-drag copy needs a real SGR-mouse terminal (§11.4.3).
57|physical-terminal topology: reload+select+copy+paste needs a real interactive terminal (§11.4.3).
58|physical-terminal topology: operator-path select/copy needs a real interactive terminal (§11.4.3).
59|physical-terminal topology: native-mouse unobstructed needs a real mouse-capable terminal (§11.4.3).
EOF
}

# ── Run the Linux-relevant test subset inside the container ───────────
# Drives the SAME per-test classification as scripts/tests/run_all.sh
# (^PASS/^FAIL/^SKIP, FAIL>SKIP>PASS) but applies the topology_skip_table
# so host-only gates SKIP-with-reason instead of FAILing. Tests NOT in the
# table run for real and their genuine PASS/FAIL/SKIP is reported verbatim.
run_suite() {
    log "running Linux-relevant tmx test subset inside container (topology dispatch)…"
    # Push the topology skip-table into the container as a file.
    topology_skip_table | cexeci bash -c 'cat > /work/repo/.ac_skip_table' 2>/dev/null
    to "$BUILD_TIMEOUT" container exec "$CTR_NAME" bash -c '
        set -uo pipefail
        REPO=/work/repo
        JEMALLOC=$(ldconfig -p 2>/dev/null | awk "/libjemalloc\.so\.[0-9]/ {print \$NF; exit}")
        sed -e "s|__TMUX_BIN__|$REPO/tmux/build/bin/tmux|g" \
            -e "s|__JEMALLOC_PATH__|$JEMALLOC|g" \
            -e "s|__RLIMIT_WRAPPER__|$REPO/scripts/tmx-rlimit-wrapper.sh|g" \
            $REPO/scripts/tmx.template > $REPO/scripts/tmx
        chmod +x $REPO/scripts/tmx
        echo "[in-container] tmx wrapper generated (jemalloc=$JEMALLOC)"
        export TMUX_BIN=$REPO/tmux/build/bin/tmux
        export WRAPPER=$REPO/scripts/tmx
        export EXPECTED_VERSION=next-3.8

        # Mirror run_all.sh PATH-augmentation (no-op here; codegraph absent).
        PASS=0; FAIL=0; SKIP=0; FAIL_NAMES=""; SKIP_NAMES=""
        echo "════════════════════════════════════════════════════════════════"
        echo "  tmx Linux-in-Apple-container suite (against $TMUX_BIN)"
        echo "════════════════════════════════════════════════════════════════"
        for t in "$REPO/scripts/tests/"[0-9][0-9]_*.sh; do
            [ -f "$t" ] || continue
            name=$(basename "$t")
            num=$(echo "$name" | cut -c1-2)
            echo ""
            # §11.4.3 topology dispatch: emit SKIP-with-reason for host-only gates.
            reason=$(awk -F"|" -v n="$num" "\$1==n {sub(/^[0-9]+\\|/,\"\"); print; exit}" "$REPO/.ac_skip_table")
            if [ -n "$reason" ]; then
                echo "── $name ──"
                echo "SKIP: $reason"
                SKIP=$((SKIP+1)); SKIP_NAMES="$SKIP_NAMES $name"
                continue
            fi
            out=$(bash "$t" 2>&1)
            echo "$out"
            if echo "$out" | grep -qE "^FAIL"; then
                FAIL=$((FAIL+1)); FAIL_NAMES="$FAIL_NAMES $name"
            elif echo "$out" | grep -qE "^SKIP"; then
                SKIP=$((SKIP+1)); SKIP_NAMES="$SKIP_NAMES $name"
            elif echo "$out" | grep -qE "^PASS"; then
                PASS=$((PASS+1))
            else
                FAIL=$((FAIL+1)); FAIL_NAMES="$FAIL_NAMES $name(unclassified)"
            fi
        done
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "  SUMMARY: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
        [ -n "$SKIP_NAMES" ] && echo "  SKIPped:$SKIP_NAMES"
        echo "════════════════════════════════════════════════════════════════"
        if [ "$FAIL" -gt 0 ]; then echo "FAILED tests:$FAIL_NAMES"; exit 1; fi
        exit 0
    ' > "$EVID_DIR/run_all.log" 2>&1
    local rc=$?
    # rc: 0 = no FAIL, 1 = >=1 FAIL (authoritative).
    return $rc
}

# ── Build (unless --no-build) ─────────────────────────────────────────
if [ "$DO_BUILD" -eq 1 ]; then
    install_build_deps || exit 2
    push_source        || exit 2
    build_tmux         || exit 2
else
    log "--no-build: skipping deps/source/build (reusing prior container state)."
    cexec /work/repo/tmux/build/bin/tmux -V > "$EVID_DIR/tmux-version.txt" 2>&1 || {
        echo "FAIL: --no-build but no prior binary present."; exit 2; }
fi

# ── Run suite + summarise ─────────────────────────────────────────────
run_suite
SUITE_RC=$?

# Parse the SUMMARY line + SKIP list from run_all.log into summary.txt.
{
    echo "Apple container Linux-in-macOS tmx run — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host:           $(uname -s -m)"
    echo "container OS:    $(cat "$EVID_DIR/uname.txt" 2>/dev/null)"
    echo "built binary:    $(cat "$EVID_DIR/tmux-version.txt" 2>/dev/null)"
    echo "image:           $IMAGE"
    echo ""
    grep -E 'SUMMARY:|SKIPped:|FAILED tests:' "$EVID_DIR/run_all.log" 2>/dev/null \
        || echo "(no SUMMARY line — suite did not complete; see run_all.log)"
    echo ""
    echo "# Per-test verdicts (test header + its final PASS/FAIL/SKIP):"
    awk '
        /^── Test|^===== |^── /{hdr=$0}
        /^PASS|^FAIL|^SKIP/{print substr($0,1,100)}
    ' "$EVID_DIR/run_all.log" 2>/dev/null | head -120
} > "$EVID_DIR/summary.txt" 2>&1

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Apple-container Linux-in-macOS run COMPLETE"
echo "════════════════════════════════════════════════════════════════"
sed -n '1,12p' "$EVID_DIR/summary.txt"
echo "────────────────────────────────────────────────────────────────"
echo " Evidence: $EVID_DIR/"
echo "   uname.txt tmux-version.txt elf-proof.txt build.log run_all.log summary.txt"
echo "════════════════════════════════════════════════════════════════"

# Exit code mirrors run_all.sh: 0 = no FAIL, 1 = >=1 FAIL.
exit "$SUITE_RC"
