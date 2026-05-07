# CONTINUATION.md — vasic-digital tmux

**Last updated:** 2026-05-07T19:00 MSK

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

**Status:** PLANNED — see `docs/CONTAINERIZATION_PLAN.md` (in flight via web research agent).

Goal: each tmux session runs in its own podman container with `--memory=2g --cpus=2 --memory-swap=3g`. If one session OOMs/crashes, only that session's container dies; other sessions unaffected.

Wrapper alias: `tmx new <name>` / `tmx ls` / `tmx attach <name>` / `tmx kill <name>`.

Web research dispatched (parallel agent). Findings will populate `docs/CONTAINERIZATION_PLAN.md` once agent completes.

### §3.3 Comprehensive test coverage for the per-session model

**Status:** NOT STARTED. Tests to add when §3.2 lands:

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

