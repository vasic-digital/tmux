# vasic-digital tmux — optimized + verified containerized build

A reproducible, hardened build of [`tmux`](https://github.com/tmux/tmux) with built-in jemalloc support, OOM-protection helper, and a comprehensive verification gate. Designed to run on **any Linux host** (Ubuntu, ALT, Fedora, Arch, openSUSE, Alpine) where podman or docker is available.

**The 14 verification tests are why this matters**: a typical "build tmux from source" guide assumes the build worked. This project ships a hard wall — `bash scripts/setup.sh` will refuse to PATH-export the binary unless functional tests pass with positive runtime evidence (cgroup interface readbacks, `/proc` files, real session output), backed by a §11.4.4 layer-4 paired-mutation harness that proves the gates aren't themselves bluffs. SKIPs document precondition gates (CAP_SYS_RESOURCE, libjemalloc presence, destructive-test opt-in) explicitly. No PASS-bluffs.

## Quick install (one command)

```bash
git clone --recurse-submodules git@github.com:vasic-digital/tmux.git ~/Projects/tmux
cd ~/Projects/tmux
sudo bash scripts/install_deps.sh    # one-time host build deps
bash scripts/setup.sh                 # build + verify + install (no sudo)
```

After `setup.sh` reports GREEN: open a new shell or `source ~/.bashrc` → `tmx` invokes the verified vasic-digital build (system `tmux` untouched).

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
SUMMARY: PASS=10  FAIL=0  SKIP=4
GREEN: tmux binary verified — safe to PATH-export.
```

The 14 tests cover: smoke (binary version), session lifecycle, jemalloc loaded via LD_PRELOAD, history-limit honored, clear-history releases memory (the "apparent leak"), 10 concurrent panes, 30-s sustained session no-leak, OOM-score wrapper applies -500, crash isolation scope (cgroup-v2 transient), hostname-derived status-bar colour (algorithm + wrapper integration), memory pressure under cap, TasksMax stress, concurrent OOM independence.

Four honest SKIPs document precondition gates:
- `03_jemalloc_loaded` SKIPs if host doesn't have libjemalloc — `sudo bash scripts/install_deps.sh` provides it
- `08_oom_score_adj` SKIPs unless running as root OR the setcap helper is installed — `sudo bash scripts/build_oom_set.sh --install` enables it
- Tests 12 / 13 / 14 (memory-pressure / TasksMax / concurrent-OOM) require `TMX_TEST_DESTRUCTIVE=1` — run only on dedicated test hosts

A §11.4.4 layer-4 paired-mutation harness lives at `scripts/tests/meta_test_false_positive_proof.sh`: 5 registered mutations against tests 09 / 10 must all be caught (10 PASS / 0 FAIL / 0 SKIP) before the gate is considered self-validating.

## Roadmap

See [`docs/CONTAINERIZATION_PLAN.md`](docs/CONTAINERIZATION_PLAN.md) for the **per-session containerization plan** — each tmux session running in its own cgroup-bounded container so that:
- 2 CPU + reasonable RAM cap per session
- Crash isolation: if one session OOMs/crashes, only that session dies; other sessions and their processes survive
- One-command bootstrap: `tmx new <session>` transparently creates the container

## Repository conventions

This repo follows the **vasic-digital anti-bluff covenant**: every test that PASSes carries positive evidence of the feature working; every SKIP documents its precondition; every gate has a paired mutation in `meta_test_*.sh` proving the gate isn't itself a bluff. See [`CLAUDE.md`](CLAUDE.md) and [`Constitution.md`](Constitution.md).

## License

Apache 2.0 — see `LICENSE`.
