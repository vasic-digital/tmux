# vasic-digital tmux — optimized + verified containerized build

A reproducible, hardened build of [`tmux`](https://github.com/tmux/tmux) with built-in jemalloc support, OOM-protection helper, and a comprehensive verification gate. **Runs natively on any Linux host** (Ubuntu, ALT, Fedora, Arch, openSUSE, Alpine) where podman or docker is available. **macOS hosts** (Apple Silicon + Intel) are supported via a transparent bridge into the podman machine VM — the operator gets a working `tmx` command on the macOS shell with no manual SSH-juggling.

**The 18 verification tests are why this matters**: a typical "build tmux from source" guide assumes the build worked. This project ships a hard wall — `bash scripts/setup.sh` will refuse to PATH-export the binary unless functional tests pass with positive runtime evidence (cgroup interface readbacks, `/proc` files, real session output), backed by a §11.4.4 layer-4 paired-mutation harness that proves the gates aren't themselves bluffs. SKIPs document precondition gates (CAP_SYS_RESOURCE, libjemalloc presence, destructive-test opt-in) explicitly. No PASS-bluffs.

## Quick install (one command)

**Linux host:**

```bash
git clone --recurse-submodules git@github.com:vasic-digital/tmux.git ~/Projects/tmux
cd ~/Projects/tmux
sudo bash scripts/install_deps.sh    # one-time host build deps
bash scripts/setup.sh                 # build + verify + install (no sudo)
```

**macOS host (Apple Silicon or Intel):**

```bash
brew install podman                   # one-time: container runtime
podman machine init && podman machine start
git clone --recurse-submodules git@github.com:vasic-digital/tmux.git ~/Projects/tmux
cd ~/Projects/tmux
bash scripts/setup.sh                 # build + VM-verify + install bridge
```

After `setup.sh` reports GREEN: open a new shell, or source the rc for your shell (`source ~/.bashrc` or `source ~/.zshrc`). Then `tmx new|attach|ls|kill` invokes the verified vasic-digital build; the system `tmux` command stays untouched and reachable side-by-side.

## Architecture (native dual-OS per-session isolation)

```
                    ┌────────────────────────────────────┐
                    │        OPERATOR SHELL              │
                    │   $ tmx new -s mywork              │
                    │   $ tmx new -s build  ← own scope! │
                    └──────────────────┬─────────────────┘
                                       │
                                       │  scripts/tmx (host-native, OS-aware dispatch)
                                       ▼
            ┌──────────────────────────┴──────────────────────────┐
            │                                                     │
       Linux host                                          macOS host (Darwin)
            │                                                     │
            │ for each `tmx new -s NAME`:                         │ for each `tmx new -s NAME`:
            │   systemd-run --user --scope                        │   tmux -L tmx-NAME new-session -d -s NAME \
            │     --unit=tmx-NAME.scope                           │     "tmx-rlimit-wrapper.sh \
            │     -p MemoryMax=<host-adaptive>                    │       <mem-kb> <cpu-sec> <nproc> \
            │     -p CPUQuota=200% -p TasksMax=4096               │       $SHELL -l"
            │     -p Delegate=yes                                 │   set -g default-command "rlimit-wrapper …"
            │   tmux -L tmx-NAME new -s NAME -d                   │
            │                                                     │
            ▼                                                     ▼
   ┌─────────────────────────────────┐         ┌──────────────────────────────────────────┐
   │  cgroup-v2 transient scope      │         │  POSIX rlimit wrapper                    │
   │  tmx-NAME.scope                 │         │  scripts/tmx-rlimit-wrapper.sh           │
   │  ├ MemoryMax = host-adaptive    │         │  ├ ulimit -t  ← RLIMIT_CPU   (enforced)  │
   │  ├ CPUQuota  = 200%             │         │  ├ ulimit -u  ← RLIMIT_NPROC (enforced)  │
   │  ├ TasksMax  = 4096             │         │  └ ulimit -v  ← RLIMIT_AS NOT enforced   │
   │  ├ Delegate  = yes              │         │                  by XNU (documented gap) │
   │  └ tmux 3.6a (Linux ELF)        │         │  tmux 3.6a (Mach-O)                      │
   │  status-bar = DJB2(host)        │         │  status-bar = DJB2(host)                 │
   │  oom_score_adj = -500           │         │  (oom_score_adj N/A on Darwin)           │
   └─────────────────────────────────┘         └──────────────────────────────────────────┘
       Shell sees the operator's              Shell sees the operator's macOS host:
       Linux host: full FS, full PATH,        full FS, full PATH (Homebrew, system tools,
       all system binaries reachable.         all Mach-O binaries), `id` = operator's user.
```

**Native dual-OS per-session isolation** (architecture since 2026-05-13). Each `tmx new -s NAME` invocation creates its own tmux server (socket `tmx-NAME`) with OS-native isolation:

- **Linux** — cgroup-v2 transient scope `tmx-NAME.scope` via `systemd-run --user --scope`. Kernel enforces MemoryMax, CPUQuota, TasksMax per-group. OOM in one session is contained to that scope — every other session AND `user.slice` survive (Constitution §1 invariant).
- **macOS (Darwin)** — POSIX rlimit wrapper sets `RLIMIT_CPU` (CPU time) and `RLIMIT_NPROC` (per-user process count) before exec'ing the operator's `$SHELL`. The Darwin XNU kernel enforces these per-process. Children inherit. **`RLIMIT_AS` (virtual memory) is NOT enforced** by XNU for unprivileged processes — this is a documented gap; full memory containment on macOS requires launchd jobs with `HardResourceLimits` plist (root). See `docs/GUIDE.md` §5.6 for the strength comparison.

Both OS paths deliver the **same operator UX**: plain-vanilla tmux behaviour, the operator's shell with full host PATH (Homebrew on macOS, /usr/local/bin on Linux, all system tools), per-session resource ceilings applied transparently. No VM. No bridge. No `core@localhost`. No bluff.

## What you get

| Component | Why |
|---|---|
| **tmux 3.6a** (latest stable) | Pinned to a known-good upstream tag |
| **Hardened compile flags** | `-O2 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2`, RELRO + immediate-binding link |
| **Build-time `-ljemalloc`** | jemalloc linked at the binary level (more aggressive RAM return than glibc malloc) |
| **Runtime `LD_PRELOAD=libjemalloc.so`** | Wrapper preloads jemalloc even on hosts where the linker resolved a different malloc |
| **OOM-score protection** | Optional setcap-enabled helper (`tmx-oom-set`) sets `oom_score_adj=-500` on the spawned server, making tmux survive most OOM cascades |
| **Bounded `history-limit`** | Explicit `2000` (the default — explicit so future bumps are intentional) |
| **Hermetic install** | Built artifact lives in `tmux/build/`. PATH export points there; system tmux untouched. Removable via `bash scripts/setup.sh --uninstall`. |

## Verification gate

```
SUMMARY: PASS=13  FAIL=0  SKIP=5
GREEN: tmux binary verified — safe to PATH-export.
```

The 18 tests cover: smoke (binary version), session lifecycle, jemalloc loaded, history-limit honored, clear-history releases memory (the "apparent leak"), 10 concurrent panes, 30-s sustained session no-leak, OOM-score wrapper applies -500, crash isolation scope (cgroup-v2 transient), hostname-derived status-bar colour (algorithm + wrapper integration), memory pressure under cap, TasksMax stress, concurrent OOM independence, per-session cgroup distinctness, window-name `.exe` strip, **scrollback + copy-mode scrolling** (operator-path: 3000 lines generated, proven scrolled off-screen, proven reachable via copy-mode), and **HelixConstitution inheritance** (the `constitution/` submodule + every governance doc's inheritance pointer).

Four honest SKIPs document precondition gates:
- `03_jemalloc_loaded` SKIPs if host doesn't have libjemalloc — `sudo bash scripts/install_deps.sh` provides it
- `08_oom_score_adj` SKIPs unless running as root OR the setcap helper is installed — `sudo bash scripts/build_oom_set.sh --install` enables it
- Tests 12 / 13 / 14 (memory-pressure / TasksMax / concurrent-OOM) require `TMX_TEST_DESTRUCTIVE=1` — run only on dedicated test hosts

A layer-4 paired-mutation harness (Constitution §103) lives at `scripts/tests/meta_test_false_positive_proof.sh`: registered mutations M1–M14 plus `CM-CONSTITUTION-INHERITANCE` each break a feature, assert the matching test then FAILs, revert, and assert it PASSes again. On macOS the harness reports **18 caught / 0 escaped / 6 skipped** (the 6 SKIPs are Linux-only isolation mutations); the remainder run on Linux via `META=1 bash scripts/test_vm.sh`. The gate is not considered self-validating until every runnable mutation is caught.

## Roadmap

See [`docs/CONTAINERIZATION_PLAN.md`](docs/CONTAINERIZATION_PLAN.md) for the **per-session containerization plan** — each tmux session running in its own cgroup-bounded container so that:
- 2 CPU + reasonable RAM cap per session
- Crash isolation: if one session OOMs/crashes, only that session dies; other sessions and their processes survive
- One-command bootstrap: `tmx new <session>` transparently creates the container

## Repository conventions

This repo follows the **vasic-digital anti-bluff covenant**: every test that PASSes carries positive evidence of the feature working; every SKIP documents its precondition; every gate has a paired mutation in `meta_test_*.sh` proving the gate isn't itself a bluff. See [`CLAUDE.md`](CLAUDE.md) and [`Constitution.md`](Constitution.md).

## License

Apache 2.0 — see `LICENSE`.
