# Changelog — vasic-digital/tmux

All releases use [Semantic Versioning](https://semver.org/). Every release
carries a positive-runtime-evidence verification record per the project's
anti-bluff covenant (Constitution §1, §11.4.x).

---

## [v1.0.0] — 2026-05-13

**Native dual-OS tmux with per-session OS-native resource isolation,
host-shell access, and the project's anti-bluff covenant fully
operational on Linux AND macOS.**

This is the initial public release.

### Highlights

- **Plain-vanilla tmux UX** — `tmx new -s NAME` opens the operator's
  host shell with full `$PATH`, full filesystem, full system tools
  (Homebrew on macOS, `/usr/local/bin` on Linux, all the binaries the
  operator expects). No VM, no SSH bridge, no `core@localhost`. The
  session shell IS the operator's host shell.
- **Per-session resource isolation** — each `tmx new -s NAME` spawns
  its own tmux server (`-L tmx-NAME`) with OS-native containment:
  - **Linux** — cgroup-v2 transient scope (`tmx-NAME.scope`) via
    `systemd-run --user --scope`. Kernel-enforced `MemoryMax`,
    `CPUQuota`, `TasksMax`, `Delegate=yes`. OOM in one scope kills
    only that scope; `user.slice` survives.
  - **macOS (Darwin)** — POSIX rlimit wrapper applied as session
    `default-command`. Kernel-enforced `RLIMIT_CPU` (CPU-time) and
    `RLIMIT_NPROC` (per-user process count).
- **Verified hardened tmux 3.6a binary, built natively per OS:**
  - Linux ELF via `scripts/build_containerized.sh` (podman/docker)
    or `scripts/build_native.sh`.
  - macOS Mach-O via `scripts/build_native.sh` (Homebrew deps).
  - Compile flags: `-O2 -DNDEBUG -fstack-protector-strong
    -D_FORTIFY_SOURCE=2`; jemalloc linked at the binary level
    (`DT_NEEDED` on Linux, `LC_LOAD_DYLIB` on Mach-O); RELRO + bind-
    at-load (Linux) / `-Wl,-search_paths_first` (Mach-O).
- **Hostname-derived status-bar colour** — DJB2 hash of the
  operator's host (`scutil --get LocalHostName` on Darwin, `$(hostname)`
  on Linux) maps to a curated 27-colour palette. Same host always
  produces the same colour across every session (proven by Test 11);
  different hosts produce visibly distinct colours (16/16 unique in
  Test 10 T3).
- **14-test verification gate with positive runtime evidence per
  §11.4.2** — `scripts/verify.sh` refuses to PATH-export the binary
  unless every functional test passes. Tests read `/proc/PID/maps`,
  `/sys/fs/cgroup/.../memory.max`, `tmux show -g status-style`,
  `tmux capture-pane -p`, and similar live state. Zero tests close
  on "exit code 0" alone.
- **§11.4.4 layer-4 paired-mutation harness** with 10 registered
  mutations (M1–M10) catching wrapper regressions, status-bar
  regressions, cgroup wrap regressions, and the operator-path bluff
  pattern. `bash scripts/tests/meta_test_false_positive_proof.sh`
  reports 20 PASS / 0 FAIL on Linux.
- **End-to-end automation** — `bash scripts/test_e2e.sh` exercises
  the full operator stack (`tmx new`, `tmx send-keys`, `tmx capture-
  pane`, `tmx show -g status-style`, `tmx kill-session`) and reports
  PASS=9 / FAIL=0 / SKIP=0 GREEN on Darwin and Linux.
- **OS-aware install** — `bash scripts/setup.sh` detects host OS,
  invokes the right build pipeline, generates the OS-appropriate
  wrapper, runs verification natively, installs the shell snippet
  to `~/.bashrc` AND `~/.zshrc`. Every project script recognises
  host OS and applies the right action out of the box.

### Anti-bluff covenant (Constitution §1, §11.4.x)

This release ships under the verbatim user mandate:

> "We had been in position that all tests do execute with success and
> all Challenges as well, but in reality the most of the features
> does not work and can't be used! This MUST NOT be the case and
> execution of tests and Challenges MUST guarantee the quality, the
> completion and full usability by end users of the product!"

Every test in `scripts/tests/` carries positive runtime evidence
(`/proc`, `/sys/fs/cgroup`, `vmmap`, `ps -o rss=`, `tmux capture-
pane`, `systemctl is-active`, `display-message`, kernel log lines).
Every Challenge in `scripts/challenges/tmux.yaml` specifies real
runtime state as `evidence:`. Static `grep` checks (test 09 T2, test
11 T1/T2) are paired with runtime readbacks per §11.4.7.

Covenant text propagated to root `Constitution.md`, `CLAUDE.md`,
`AGENTS.md`, and the `Containers` submodule's `CONSTITUTION.md`,
`CLAUDE.md`, `AGENTS.md`.

### Architecture overview

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
            │ systemd-run --user --scope                          │ tmx-rlimit-wrapper.sh
            │   --unit=tmx-NAME.scope                             │   ulimit -t (RLIMIT_CPU)
            │   -p MemoryMax=… CPUQuota=200%                      │   ulimit -u (RLIMIT_NPROC)
            │   TasksMax=4096 Delegate=yes                        │   exec $SHELL -l
            │   tmux -L tmx-NAME new -s NAME -d                   │
            ▼                                                     ▼
   cgroup-v2 transient scope                            POSIX rlimit wrapper
   (per-group, kernel-enforced)                         (per-process, kernel-enforced)
```

### Forensic transparency

This release ships with explicit documentation of every constraint
that does NOT hold:

- **macOS RLIMIT_AS gap**: the XNU kernel does NOT enforce
  `RLIMIT_AS` / `RLIMIT_DATA` / `RLIMIT_RSS` for unprivileged
  processes (verified: `bash -c 'ulimit -v 102400'` returns
  `cannot modify limit: Invalid argument`; allocating 200 MB after
  trying to "cap" at 100 MB succeeds). The wrapper applies only
  what's enforced (`RLIMIT_CPU`, `RLIMIT_NPROC`). Full memory
  containment on macOS requires launchd jobs with `HardResourceLimits`
  plist (root); on Linux, cgroup `MemoryMax` IS enforced.
- **Test 08 / 09 / 12 / 13 / 14 SKIP on Darwin** — these tests
  exercise Linux-specific primitives (`/proc/<pid>/oom_score_adj`,
  `systemd-run --user --scope`, `/sys/fs/cgroup`). SKIP-with-reason
  per Constitution §11.4.3 (per-host-topology test dispatch).

See `docs/GUIDE.md` §5.6 for the full strength-gap table.

### Bluffs caught and fixed during the development cycle

Documented in `Fixed.md`. 24 distinct §1 / §11.4.x bluffs were caught
and remediated before this release, including:

- A1: META-MUT-001 paired-mutation harness landed
- A4: Build pipeline three-defect fix (Dockerfile GID-20 collision,
  jemalloc not actually linked, make-clean missing)
- A6: Install-mechanism side-by-side bluffs (phantom directory path,
  `alias tmux='tmx'` shadowing system tmux, stale ATMOSphere branding)
- A8: macOS bridge + side-by-side coexistence (later superseded by
  native dual-OS in this release)
- A10: Status-bar colour silently defaulted to green; bridge ignored
  macOS hostname
- A11: Triple-layer regression protection so A10 cannot re-occur
- A12: Constitution §11.4.7 — operator-path test coverage rule (every
  gate test MUST exercise the same entry point an end-user invokes)
- A13: Per-session cgroup isolation (each `tmx new -s X` in its own
  scope, OOM in one doesn't kill others)
- A14: This-release verification cycle — fresh runtime evidence
  captured for every claim

### Install

**macOS** (Darwin Apple Silicon or Intel):

```bash
brew install podman  # optional, for build_containerized.sh
git clone --recurse-submodules git@github.com:vasic-digital/tmux.git ~/Projects/tmux
cd ~/Projects/tmux
bash scripts/setup.sh
```

**Linux**:

```bash
git clone --recurse-submodules git@github.com:vasic-digital/tmux.git ~/Projects/tmux
cd ~/Projects/tmux
sudo bash scripts/install_deps.sh
bash scripts/setup.sh
```

After `setup.sh` reports GREEN: open a new shell (`source ~/.zshrc`
or `source ~/.bashrc`). Then `tmx new -s anything` drops you into a
session as your host user with the full host environment and
kernel-enforced resource caps.

### Usage

```bash
tmx new -s mywork             # interactive — attaches
tmx new -s build -d            # detached
tmx ls                         # list all your sessions
tmx attach -t mywork           # re-attach
tmx send-keys -t mywork "echo hello" Enter
tmx capture-pane -t mywork -p
tmx kill-session -t mywork
tmx kill-server                # nuke all our sessions
```

Per-session resource overrides:

```bash
TMX_MEM=8G tmx new -s heavy            # 8 GB MemoryMax (Linux)
TMX_CPU=400 tmx new -s build           # 400% CPUQuota (Linux)
TMX_CPU_HARD_SEC=3600 tmx new -s timeboxed  # 1-hour RLIMIT_CPU (Darwin)
```

### Verification commands

Operators can confirm anti-bluff covenant compliance at any time:

```bash
bash scripts/setup.sh --verify-only   # full 14-test gate → expect GREEN
bash scripts/test_e2e.sh              # end-to-end → expect PASS=9/0/0
TMX_TEST_DESTRUCTIVE=1 bash scripts/test_vm.sh   # Linux destructive suite
META=1 bash scripts/test_vm.sh        # paired-mutation harness
```

### Coexistence with system tmux

`tmx` and the system `tmux` (Homebrew on macOS, distro package on
Linux) coexist side-by-side. The bashrc/zshrc snippet PATH-prepends
`scripts/` so `tmx` is the project's wrapper; `tmux` resolves to
whatever was on PATH before. No alias shadowing.

### Submodules

- `tmux/` — upstream `tmux/tmux` pinned to tag `3.6a` (do not modify).
- `Containers/` — `vasic-digital/Containers` Go module providing
  generic container orchestration primitives. Anti-bluff covenant
  + §11.4.7 propagated. Tag: `b077f2c` at release time.

### Known limitations

- macOS memory cap is per-process via launchd-bsd-style limits
  (informational only — Darwin doesn't enforce `RLIMIT_AS`). For true
  per-session memory containment, run on Linux.
- The destructive test suite (tests 12 / 13 / 14) requires
  `TMX_TEST_DESTRUCTIVE=1` and is Linux-only; on Darwin these SKIP
  per topology dispatch.

### Acknowledgements

Built on the shoulders of:
- `tmux/tmux` upstream (3.6a tag)
- jemalloc (linked at build time)
- libevent + ncurses + utf8proc (Mach-O), libtinfo + libevent_core (ELF)
- systemd-run + cgroup-v2 (Linux isolation primitive)
- Homebrew (macOS dependency provider)

Released under Apache 2.0 (see `LICENSE`).

---

## [Unreleased]

(no work in flight between v1.0.0 and the next tag)
