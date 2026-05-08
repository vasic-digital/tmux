# CONTINUATION.md — vasic-digital tmux

**Last updated:** 2026-05-08T11:30 MSK

## §0 — How to resume work in any CLI agent

Paste this prompt:

> Read `CONTINUATION.md` at the repo root. Identify the topmost item under `§3 Active work` with status IN PROGRESS or BLOCKED. Re-read `Constitution.md`, `CLAUDE.md`, `AGENTS.md` for mandates. Resume from current state. Update this document as you work.

## §1 — Snapshot

| Field | Value |
|---|---|
| Repo | vasic-digital/tmux on GitHub + GitLab |
| Origin | Migrated from ATMOSphere project (`scripts/tmux/`, `docker/Dockerfile.tmux-build`, `docs/guides/TMUX_OPTIMIZED_BUILD.md`) on 2026-05-07 |
| Pinned tmux | upstream tag `3.6a` |
| Verification | `scripts/verify.sh` runs 8-test suite; VERIFIED GREEN against ATMOSphere host (6 PASS / 0 FAIL / 2 honest SKIP) on 2026-05-07 |

## §2 — Mandates

- `Constitution.md` §1 anti-bluff covenant
- `Constitution.md` §5 continuation-doc invariant

## §3 — Active work

### §3.1 Local migration + GH/GL push (this session, 2026-05-07)

**Status:** IN PROGRESS

- ✅ Local repo skeleton at `~/Projects/tmux/`
- ✅ Scripts migrated (8 tests + setup + verify + build_containerized + build_oom_set + oom_set.c)
- ✅ Docker layer migrated
- ✅ docs/GUIDE.md migrated
- ✅ Agnostic-ized: 0 ATMOSphere/Android-15/atmosphere-tmux references remain
- ✅ Constitution + CLAUDE.md + AGENTS.md + README + .gitignore written
- ⏳ Add `tmux/` and `Containers/` submodules
- ⏳ Write `commit_all.sh` for this repo
- ⏳ Initial commit
- ⏳ Create GH repo (`gh repo create vasic-digital/tmux --private`)
- ⏳ Create GL repo (`glab repo create vasic-digital/tmux`)
- ⏳ Add remotes + push

### §3.2 Per-session containerization (Phase B — multi-session work)

**Status:** RESEARCH COMPLETE + WRAPPER LANDED + ISOLATION VERIFIED (2026-05-08).

Web research output: `docs/CONTAINERIZATION_PLAN.md` recommends `systemd-run --user --scope` (cgroup-v2 transient scope) over podman-per-session. Wrapper at `scripts/tmx` implements `tmx {new|attach|ls|kill}` with `MemoryMax=$TMX_MEM` (default 8G), `CPUQuota=$TMX_CPU` (default 200%), `TasksMax=4096`, `Delegate=yes`.

### §3.3 Comprehensive test coverage for the per-session model

**Status:** TEST 09 LANDED + 14/0/0 PASS on this host (2026-05-08T11:25 MSK).

`scripts/tests/09_crash_isolation_scope.sh` — 4-section invariant verifier:

- **T1 (host capability):** systemd 258 + cgroup v2 mounted ✓
- **T2 (wrapper invariants):** tmx wrapper invokes `systemd-run --user --scope` + sets MemoryMax/CPUQuota/TasksMax/Delegate=yes ✓
- **T3 (cgroup interface evidence):** transient scope created; `/sys/fs/cgroup/.../memory.max` reads 268435456 bytes (matches set 256M) + `/sys/fs/cgroup/.../cpu.max` reads `50000 100000` (50% quota over 100ms period) — both POSITIVE EVIDENCE per §1 covenant ✓
- **T4 (SIGKILL containment):** spawn scope, read MainPID from `cgroup.procs`, SIGKILL it, verify scope inactive AFTER kill, verify `default.target=active` THROUGHOUT (user.slice survives — Constitution §1 invariant) ✓
- **T6 (concurrent independence):** 3 concurrent scopes, all registered + active simultaneously ✓

Updated `scripts/tests/run_all.sh` to include test 09 (glob pattern `0[1-9]_*.sh`).

**Remaining tests to add (lower priority):**
- T5 (memory pressure under cap — actually allocate up to MemoryMax and verify enforcement) — risky on shared host, deferred to dedicated test runner
- TasksMax stress — fork bomb resistance
- Concurrent OOM (one scope OOMs, sibling scopes unaffected)

**Constitution §1 covenant propagated 2026-05-08:** verbatim user-mandate quote ("We had been in position that all tests do execute with success and all Challenges as well, but in reality the most of the features does not work and can't be used!") added to Constitution.md, CLAUDE.md, AGENTS.md.

- Crash-isolation test: `tmx new A`, `tmx new B`, kill -9 the A container, verify B's panes still alive
- Memory-cap test: trigger OOM in session A, verify only A dies
- CPU-cap test: stress -c 4 in session, verify cap enforced
- Attach/detach UX test: confirm operator can attach without noticing the container
- Crash recovery: detached session survives container restart
- HelixQA Challenge entries for each test

## §8 — Resumption recipe

1. `cd ~/Projects/tmux`
2. Read this document
3. Read `Constitution.md`, `CLAUDE.md`
4. Find the topmost IN PROGRESS item, resume

