# vasic-digital tmux — QWEN.md

> Qwen Code CLI agent view of this project's governance.
> Base agent rules live at `constitution/QWEN.md` and the
> `constitution/Constitution.md` it references. **READ THOSE FIRST.**
> This file extends them with project-specific rules; it never weakens
> them. Canonical project authority: [`Constitution.md`](Constitution.md)
> — Project Articles §101–§109. For the full agent rule set see
> [`AGENTS.md`](AGENTS.md), which this file mirrors.

**Fresh-conversation workflow:** read `CONTINUATION.md` first
(§0/§3/§8 mandatory), then `Issues.md` for OPEN/PARTIAL/BLOCKED/RUNNING.

## Project overview

Verified hardened tmux 3.6a build with jemalloc, OOM protection, and
per-session isolation via the `tmx` wrapper. Native dual-OS: each
`tmx new -s NAME` spawns its own tmux server with OS-native isolation
— cgroup-v2 scope on Linux, POSIX rlimit wrapper on macOS. Session
shell is the operator's host shell with full PATH. No VM.

## Critical base rules restated (for agents that don't follow @imports)

- **No bluffing.** Every PASS — test OR HelixQA Challenge — carries
  positive runtime evidence (file *content*, not existence). Universal
  §11.4 / Project §101.
- **FAIL-bluffs forbidden.** Fix script-bug failures at the source
  layer, never at call sites. Universal §11.4.1.
- **No-guessing language.** `likely`, `probably`, `maybe`, `seems`,
  `appears` are forbidden when reporting causes — prove with forensic
  evidence or mark `UNCONFIRMED:` / `PENDING_FORENSICS:`. Universal §11.4.6.
- **Operator-path coverage.** Gate tests use `tmx new -s X`. Project §102.
- **Four-layer coverage.** Every defect lands pre-build gate + runtime
  test + HelixQA Challenge + paired mutation. Project §103.
- **Use the commit wrapper.** `bash commit_all.sh "<msg>"` only — no
  direct `git push` on the main repo.
- **Never force-push** without explicit per-operation authorization.
- **CONTINUATION.md** kept in sync in every non-trivial commit.
  Universal §12.10.
- **60 % RAM cap** enforced per-session via `TMX_MEM`. Project §106.

## Commands (exact)

| Step | Command |
|---|---|
| Install build deps | `bash scripts/install_deps.sh` |
| Full pipeline | `bash scripts/setup.sh` |
| Verification gate | `bash scripts/verify.sh` |
| Run all tests | `bash scripts/tests/run_all.sh` |
| Inheritance gate | `bash scripts/tests/test_constitution_inheritance.sh` |
| Meta-test (paired mutation) | `bash scripts/tests/meta_test_false_positive_proof.sh` |
| End-to-end automation | `bash scripts/test_e2e.sh` |
| Commit + push (github+gitlab) | `bash commit_all.sh "message"` |
| Per-session wrapper | `tmx {new\|attach\|ls\|kill}` |

## Project-specific agent rules

### Forbidden in this project

- Editing `tmux/`, `constitution/`, or generated files (`scripts/tmx`,
  `tmux/build*/`).
- Direct `git push` on the main repo — use `commit_all.sh`.
- CI/CD pipeline files; HTTPS Git remotes (SSH only).
- Advancing the `tmux/` submodule off tag `3.6a` without an explicit
  documented decision (Project §107).

### Project-specific workflow

- **Test-interrupt-on-discovery** (§103): a defect found mid-cycle
  STOPS the cycle — fix root cause, land four layers, rebuild, repeat.
- **Topology dispatch** (§104): tests detect host topology and
  SKIP-with-reason; never silently degrade.
- **Destructive tests** (12/13/14): require `TMX_TEST_DESTRUCTIVE=1`.

## Project overrides of universal rules

None.
