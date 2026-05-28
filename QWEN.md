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

## MANDATORY ANTI-BLUFF END-USER-QUALITY COVENANT

**Forensic anchor — verbatim user mandate (2026-04-28, reasserted
2026-05-21):**

> "We had been in position that all tests do execute with success and
> all Challenges as well, but in reality the most of the features does
> not work and can't be used! This MUST NOT be the case and execution
> of tests and Challenges MUST guarantee the quality, the completion
> and full usability by end users of the product!"

**Operative rule.** The bar for shipping is **not** "tests pass" but
**"end users can actually use the feature."** Every PASS — test OR
HelixQA Challenge — MUST carry positive captured runtime evidence that
the feature works for the end user. Metadata-only PASS, configuration-
only PASS, "absence-of-error" PASS, and grep-without-runtime PASS are
all critical defects regardless of how green the summary line looks.
Tests and Challenges are bound EQUALLY.

This covenant is restated verbatim in every governance file at the
consumer layer (`CLAUDE.md`, `AGENTS.md`, `QWEN.md`) so any tool that
does not expand `@imports` still reads it. The same verbatim block lives
upstream at `constitution/Constitution.md` §11.4, `constitution/CLAUDE.md`,
and `constitution/AGENTS.md`. Removing or weakening this block is a
§11.4-class release blocker.

Canonical authority: `constitution/Constitution.md` §11.4 and its
sub-anchors §11.4.1 through §11.4.78. Project anchor:
[`Constitution.md`](Constitution.md) §101.

Non-compliance is a release blocker regardless of context.

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

## §11.4.87–98 — newly-inherited anchors (constitution 6828ff2)

Twelve new universal anchors landed in `constitution/Constitution.md`
at commit `6828ff2` (2026-05-28). They apply unconditionally per
§11.4.35.

### §11.4.87 — Endless-loop autonomous work + zero-idle agent dispatch

Inherited from `constitution/Constitution.md` §11.4.87. Continue work
until Issues.md has zero non-terminal items, CONTINUATION.md §3 empty,
no in-flight subagent, no external dependency in-flight. Every closure
carries §11.4.4(b) four-layer coverage + captured-evidence per
§11.4.5/§11.4.69. **Canonical authority:** §11.4.87.

### §11.4.88 — Background-push: commit-flock immediate release, push detached

Inherited from `constitution/Constitution.md` §11.4.88. `commit_all.sh`
releases its commit flock the moment `git commit` returns 0; push runs
detached. Per-remote flock for concurrency control. Only escape:
`--sync-push` for §11.4.41 force-push. **Canonical authority:**
§11.4.88.

### §11.4.89 — Background test execution

Inherited from `constitution/Constitution.md` §11.4.89. Any test > 30 s
MUST be detached via `nohup ... > <log> 2>&1 &` + `disown`; main stream
returns to §11.4.42 priority queue. **Canonical authority:** §11.4.89.

### §11.4.90 — Obsolete status + per-item obsolescence audit

Inherited from `constitution/Constitution.md` §11.4.90. New Status
terminal value `Obsolete (→ Fixed.md)` with `**Obsolete-Details:**`
audit-line (Since + Reason + Superseding-item + Triple-check evidence).
**Canonical authority:** §11.4.90.

### §11.4.91 — Summary-doc clarity

Inherited from `constitution/Constitution.md` §11.4.91. Every summary
one-liner ≥ 6 words OR ≥ 40 chars naming SUBJECT + PROBLEM/GOAL.
Forbidden anti-patterns: section labels, bare metadata, §-letter alone.
**Canonical authority:** §11.4.91.

### §11.4.92 — Multi-pass change-evaluation discipline

Inherited from `constitution/Constitution.md` §11.4.92. 5 passes before
commit: main-task evidence; regression blast radius; cross-feature
interaction; deep research + CodeGraph; anti-bluff confirmation.
Trivial exemption only for zero-source-touch commits. **Canonical
authority:** §11.4.92.

### §11.4.93 — SQLite-backed single source of truth for workable items

Inherited from `constitution/Constitution.md` §11.4.93. Authoritative
DB at `docs/workable_items.db`; Go binary `cmd/workable-items/`
bidirectional sync. Round-trip byte-identical within whitespace
tolerance. `commit_all.sh` refuses non-empty diff. **Canonical
authority:** §11.4.93.

### §11.4.94 — Zero-idle priority-first parallel-by-default operating mode

Inherited from `constitution/Constitution.md` §11.4.94. Idle only when
genuinely externally blocked OR operator STOP OR §12 host-safety.
Before wake/sleep, survey parallel-work feasibility and dispatch
non-contending items via subagent-driven default. **Canonical
authority:** §11.4.94.

### §11.4.95 — Workable-items SQLite DB TRACKED in git, NEVER gitignored

Inherited from `constitution/Constitution.md` §11.4.95. Amends §11.4.93:
the DB is authoritative source data, TRACKED, never gitignored. Every
mutation stages + commits + pushes alongside the MD regen.
WAL-checkpoint before commit-stage. **Canonical authority:** §11.4.95.

### §11.4.96 — Safe-parallel-work-with-long-build catalogue

Inherited from `constitution/Constitution.md` §11.4.96. SAFE during
long builds: docs/scripts/tests/submodule pushes, research, DB ops,
subagent dispatch. UNSAFE: destructive git ops, mass deletes,
host-safety breaches. Conductor consults catalogue at every pause.
**Canonical authority:** §11.4.96.

### §11.4.97 — Maximum-use-of-idle-time + progress-update cadence

Inherited from `constitution/Constitution.md` §11.4.97. Idle minute
during which work could progress and is not genuinely blocked is a
§11.4.97 violation. 1-line operator-facing update at every commit /
subagent return / anchor landing / evidence acquisition / milestone.
**Canonical authority:** §11.4.97.

### §11.4.98 — Full-Automation Anti-Bluff: live tests re-runnable without manual intervention

Inherited from `constitution/Constitution.md` §11.4.98. Every test
fully self-driving end-to-end, emits PASS/FAIL/SKIP-with-reason without
further human action after startup. Only exception: one-time credential
bootstrap OUTSIDE test execution. Re-runnability proof = PASS at
`-count=3` consecutive automated invocations. **Canonical authority:**
§11.4.98.

### §11.4.99 — Latest-Source Documentation Cross-Reference Mandate

Inherited from `constitution/Constitution.md` §11.4.99 (commit `9e3bcc5`
ff 2026-05-28). Operator-facing docs MUST cite LATEST official online
sources verified via WebFetch / MCP / direct browsing. `## Sources
verified <date>` section + commit-footer `Sources verified <date>:
<urls>` MANDATORY. Re-verify cadence: ≤6 mo general / ≤90 d for risk-
class (messengers, cloud, payments, LLM, code-host, package mgrs). Stale
→ §11.4.90 Obsolete after 30-day grace. **Canonical authority:** §11.4.99.
