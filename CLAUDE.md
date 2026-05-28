# vasic-digital tmux — CLAUDE.md

## INHERITED FROM constitution/CLAUDE.md

All rules in `constitution/CLAUDE.md` and the
`constitution/Constitution.md` it references apply **unconditionally** to
this project. Project-specific rules below **extend** them — they do NOT
weaken or override any universal clause. When this file disagrees with
the constitution submodule, **the constitution wins**.

@constitution/CLAUDE.md

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

> **Read first on a fresh conversation:** `CONTINUATION.md` (§0/§3/§8 are
> mandatory), then `Issues.md` for OPEN/PARTIAL/BLOCKED/RUNNING items.
> Canonical project authority: [`Constitution.md`](Constitution.md)
> (Project Articles §101–§109) which extends `constitution/Constitution.md`.

---

## Project overview

Verified hardened tmux 3.6a build with jemalloc, OOM protection, and
per-session isolation via the `tmx` wrapper. Built around a hard
verification gate that refuses to expose the binary unless functional
tests pass. **Native dual-OS** (since 2026-05-13): runs as a host
process on Linux AND macOS — no VM in the daily-use path. Each
`tmx new -s NAME` creates its own tmux server with OS-native isolation:
cgroup-v2 transient scope (`systemd-run --user --scope`) on Linux; POSIX
rlimit wrapper (`RLIMIT_CPU` + `RLIMIT_NPROC`) on macOS. The session
shell is the operator's host shell with full `$PATH`. Honest gap:
`RLIMIT_AS` (memory) is NOT enforced by XNU for unprivileged processes
— see `docs/guide/README.md` §5.6.

## Critical base rules restated (for sessions that don't expand @imports)

- **No bluffing.** Every PASS — test OR HelixQA Challenge — carries
  positive runtime evidence (cgroup/`/proc` file *content*, `capture-pane`
  output, kernel log lines), never just an exit code. Universal §11.4 /
  Project §101.
- **FAIL-bluffs equally forbidden.** A test that exits FAIL for a
  script bug (not a product defect) is fixed at the source layer, never
  at call sites. Universal §11.4.1.
- **No-guessing.** Never use `likely`/`probably`/`maybe`/`seems`/`appears`
  in cause descriptions — prove with forensic evidence or mark
  `UNCONFIRMED:` / `PENDING_FORENSICS:`. Universal §11.4.6.
- **Operator-path coverage.** Every gate test exercises the SAME entry
  point an end-user invokes (`tmx new -s X`, not hand-spawned
  equivalents). Project §102.
- **Four-layer coverage.** Every defect lands all four layers before the
  cycle closes. Project §103.
- **CONTINUATION.md** updated in the SAME commit as any non-trivial
  state change. Universal §12.10.
- **commit_all.sh only.** Never `git push` directly on the main repo.

## Commands (exact)

| Step | Command |
|---|---|
| Install build deps (one-time; Linux needs root, macOS uses brew) | `bash scripts/install_deps.sh` |
| Full pipeline | `bash scripts/setup.sh` |
| Build only | `bash scripts/setup.sh --build-only` |
| Verify only | `bash scripts/setup.sh --verify-only` |
| Verification gate | `bash scripts/verify.sh` |
| Run all tests | `bash scripts/tests/run_all.sh` |
| Single test | `bash scripts/tests/NN_*.sh` (zero-padded, 01..17) |
| Constitution inheritance gate | `bash scripts/tests/test_constitution_inheritance.sh` |
| Meta-test (paired mutation) | `bash scripts/tests/meta_test_false_positive_proof.sh` |
| Containerized test run (bounded subset) | `bash scripts/test_containerized.sh` |
| VM test run (full suite) | `bash scripts/test_vm.sh` (`TMX_TEST_DESTRUCTIVE=1` for tests 12/13/14; `META=1` for meta-test) |
| End-to-end automation | `bash scripts/test_e2e.sh` |
| Commit + push (github+gitlab) | `bash commit_all.sh "message"` |
| Per-session wrapper | `tmx {new\|attach\|ls\|kill}` |

Never `git push` directly — use `commit_all.sh`.

## Structure

| Path | Role |
|---|---|
| `constitution/` | HelixConstitution submodule — universal governance (pinned `7f738df`) — **do not modify** |
| `tmux/` | upstream submodule (tag `3.6a`) — **do not modify** |
| `Containers/` | vasic-digital cgroup helpers submodule |
| `tmux/build*/` | build output (`.gitignore`'d) |
| `scripts/` | build, verify, install, 17 tests + inheritance gate, challenges, wrapper + conf templates |
| `scripts/tmx` | generated dispatcher (`.gitignore`'d) — from `tmx.template` (Linux) or `tmx-mac.template` (macOS bridge) |
| `scripts/tmux.conf.template` | the tmux config template (scrollback, copy-mode, Claude-Code TUI passthrough, clipboard) |
| `scripts/tests/meta_test_false_positive_proof.sh` | §103 layer-4 paired-mutation harness |
| `scripts/challenges/tmux.yaml` | HelixQA Challenge specs |
| `commit_all.sh` | only allowed push mechanism |
| `Constitution.md` | project authority — Project Articles §101–§109 (extends `constitution/`) |
| `Issues.md` | OPEN / PARTIAL / BLOCKED / RUNNING only |
| `Fixed.md` | RESOLVED items with closure SHA + evidence |
| `CONTINUATION.md` | live handoff state (must stay fresh) |

## Project-specific MANDATORY constraints

### Build / packaging

- `scripts/setup.sh` detects host OS and invokes the right build
  pipeline (Linux ELF / macOS Mach-O) — Project §108.
- `scripts/tmux.conf.template` is the source for the generated tmux
  config; `setup.sh` substitutes OS-specific placeholders (clipboard
  command). Never hand-edit the generated `~/.tmux.conf` / wrapper.

### Test / verification

- **Test-interrupt-on-discovery** (§103): any defect found during a
  test cycle STOPS the cycle. Fix at root cause + land all four layers
  (pre-build gate / runtime test / HelixQA Challenge / paired mutation)
  + rebuild + repeat from the beginning.
- **Operator-path coverage** (§102): gate tests use `tmx new -s X`.
- **Topology dispatch** (§104): tests detect topology and SKIP-with-
  reason — never silently degrade.
- **Destructive tests** (tests 12/13/14): require `TMX_TEST_DESTRUCTIVE=1`
  — run only on dedicated test hosts.
- **Constitution inheritance** is itself gated:
  `scripts/tests/test_constitution_inheritance.sh` + the
  `CM-CONSTITUTION-INHERITANCE` paired mutation.

### Deployment / release

- `bash commit_all.sh "<msg>"` is the ONLY push mechanism — pushes to
  `github` + `gitlab`.
- `VERSION` is the single source of truth (`version=` semver +
  `versionCode=` monotonic). Both bump together with a `CHANGELOG.md`
  entry on every release.

### Project-specific Applied Fixes Reference

| # | Fix | Key files |
|---|---|---|
| A13 | Per-session cgroup isolation (OOM contained per scope) | `scripts/tmx.template` |
| A15 | Status bar showed `claude.exe` — strip `.exe` from window name | `scripts/tmux.conf.template` |
| A16 | tmux scrolling fix for Claude Code TUI + mobile/Termux | `scripts/tmux.conf.template`, `scripts/tests/17_*.sh` |
| A17 | HelixConstitution submodule + verified governance inheritance | `constitution/`, `scripts/tests/test_constitution_inheritance.sh` |

Full forensic detail: `Fixed.md`.

## Files to never edit directly

- `scripts/tmx` — generated by `setup.sh` from `scripts/tmx.template`
- `tmux/build*/` — build output (in `.gitignore`)
- `tmux/` — upstream submodule pinned to tag `3.6a`
- `constitution/` — HelixConstitution submodule (governance authority)

---

## Project overrides of universal rules

None. This project introduces no override of any universal clause.

## §11.4.87–98 — newly-inherited anchors (constitution 6828ff2)

The constitution submodule was ff-merged to `6828ff2` (2026-05-28).
Twelve new universal anchors §11.4.87 through §11.4.98 apply
unconditionally per §11.4.35. Long-form bodies live in
`constitution/Constitution.md`; the short-form covenant mirrors below
are operative.

### §11.4.87 — Endless-loop autonomous work + zero-idle agent dispatch

Inherited from `constitution/Constitution.md` §11.4.87. Agent work
continues until ALL of: Issues.md has zero non-terminal entries,
CONTINUATION.md §3 active-work empty, no in-flight subagent, no
external dependency in-flight. Every closure carries §11.4.4(b)
four-layer coverage + captured-evidence per §11.4.5/§11.4.69. Tests
AND HelixQA Challenges bound equally per the §11.4 forensic anchor.
**Canonical authority:** `constitution/Constitution.md` §11.4.87.

### §11.4.88 — Background-push (commit-flock released immediately, push detached)

Inherited from `constitution/Constitution.md` §11.4.88. `commit_all.sh`
MUST release the commit flock as soon as `git commit` returns 0; the
push runs detached via `nohup ... &` + `disown`. Per-remote
`.git/.push.<remote>.lock` serialises same-remote concurrent pushes
but allows different-remote parallelism. The only escape hatch is
`--sync-push` for §11.4.41 force-push paths. **Canonical authority:**
`constitution/Constitution.md` §11.4.88.

### §11.4.89 — Background test execution

Inherited from `constitution/Constitution.md` §11.4.89. Any test
expected to exceed ~30 s (`run_all.sh`, `meta_test_false_positive_proof.sh`,
`test_e2e.sh`, etc.) MUST spawn via `nohup ... > <log> 2>&1 &` + `disown`;
main work stream returns to the §11.4.42 priority queue immediately.
Hard-dependent next steps poll the exit-status file. **Canonical
authority:** `constitution/Constitution.md` §11.4.89.

### §11.4.90 — Obsolete status + per-item obsolescence audit

Inherited from `constitution/Constitution.md` §11.4.90. The §11.4.15
Status closed-set gains terminal value `Obsolete (→ Fixed.md)` with
mandatory `**Obsolete-Details:**` audit-line (Since + Reason from a
closed vocabulary + Superseding-item + Triple-check evidence). The
§11.4.23 colorizer marks Obsolete rows light-gray + strikethrough.
**Canonical authority:** `constitution/Constitution.md` §11.4.90.

### §11.4.91 — Summary-doc clarity

Inherited from `constitution/Constitution.md` §11.4.91. Every summary
one-liner MUST be self-contained — ≥ 6 words OR ≥ 40 chars naming
SUBJECT + PROBLEM/GOAL. Forbidden anti-patterns: section labels
(`Composes with`, etc.), bare metadata (`Critical`, `Bug`, `In progress`),
§-letter alone. Generators extract from the H1/H2 heading line per
§11.4.54 ATM-NNN convention. **Canonical authority:**
`constitution/Constitution.md` §11.4.91.

### §11.4.92 — Multi-pass change-evaluation discipline

Inherited from `constitution/Constitution.md` §11.4.92. Every
non-trivial change passes 5 evaluation passes BEFORE commit:
(1) main-task captured evidence; (2) regression blast radius;
(3) cross-feature interaction; (4) deep research + CodeGraph queries;
(5) anti-bluff confirmation. Trivial exemption applies only when zero
source code is touched and the commit message cites it. **Canonical
authority:** `constitution/Constitution.md` §11.4.92.

### §11.4.93 — SQLite-backed single source of truth for workable items

Inherited from `constitution/Constitution.md` §11.4.93. Text trackers
(Issues / Fixed / Summary / CONTINUATION) become derived views of an
authoritative SQLite DB at `docs/workable_items.db` with a Go binary
at `cmd/workable-items/` providing bidirectional `md-to-db` / `db-to-md`
sync. Round-trip must be byte-identical within tolerated whitespace.
`commit_all.sh` refuses to commit while the diff is non-empty.
**Canonical authority:** `constitution/Constitution.md` §11.4.93.

### §11.4.94 — Zero-idle priority-first parallel-by-default operating mode

Inherited from `constitution/Constitution.md` §11.4.94. Idle is
permissible ONLY when every queued item is genuinely externally
blocked, OR operator STOP, OR §12 host-safety demand. Before any
wake/sleep the conductor MUST survey parallel-work feasibility per
§11.4.42 / §11.4.72 / §11.4.87 and dispatch non-contending items via
§11.4.20 / §11.4.70 subagent-driven default. **Canonical authority:**
`constitution/Constitution.md` §11.4.94.

### §11.4.95 — Workable-items SQLite DB TRACKED in git, NEVER gitignored

Inherited from `constitution/Constitution.md` §11.4.95. Amends §11.4.93:
`docs/workable_items.db` is authoritative source data, NOT a build
artefact — TRACKED in git, never gitignored. Every md-to-db mutation
stages + commits + pushes the DB alongside the MD regen per §11.4.19
atomic-move + §2.1 multi-upstream push. **Canonical authority:**
`constitution/Constitution.md` §11.4.95.

### §11.4.96 — Safe-parallel-work-with-long-build catalogue

Inherited from `constitution/Constitution.md` §11.4.96. Classifies
parallel work during long builds as SAFE (docs/scripts/tests/submodule
pushes per §11.4.88, research, DB ops, subagent dispatch per §11.4.20)
vs UNSAFE (destructive git ops on source tree, mass deletes on hot
subtrees, host-safety breaches). Conductor consults the catalogue at
every pause point. **Canonical authority:**
`constitution/Constitution.md` §11.4.96.

### §11.4.97 — Maximum-use-of-idle-time + progress-update cadence

Inherited from `constitution/Constitution.md` §11.4.97. Strengthens
§11.4.87 + §11.4.94 + §11.4.96: any idle minute during which work
could autonomously progress and is not genuinely blocked is a §11.4.97
violation. Progress-update cadence: emit a 1-line operator-facing
update at every commit landed / subagent return / anchor landing /
captured-evidence acquisition / milestone closure. **Canonical
authority:** `constitution/Constitution.md` §11.4.97.

### §11.4.98 — Full-Automation Anti-Bluff: live tests re-runnable without manual intervention

Inherited from `constitution/Constitution.md` §11.4.98. Closes the
manual-intervention gap §11.4.85/§11.4.87/§11.4.89/§11.4.94 did not
explicitly forbid: every test (unit / integration / e2e / Challenge /
stress / chaos / live) MUST be fully self-driving end-to-end and emit
PASS/FAIL/SKIP-with-reason without further human action after startup.
One-time credential bootstrap OUTSIDE test execution is the only
permissible exception. Re-runnability = PASS at `-count=3` consecutive
automated invocations. **Canonical authority:**
`constitution/Constitution.md` §11.4.98.

### §11.4.99 — Latest-Source Documentation Cross-Reference Mandate

Inherited from `constitution/Constitution.md` §11.4.99 (commit
`9e3bcc5` ff 2026-05-28). Before committing any operator-facing
instruction / guide / manual / setup walkthrough / troubleshooting
cookbook, the author MUST fetch the LATEST official online docs of
the third-party service / library being documented (WebFetch, MCP
server, direct browsing — NOT training data) and cross-reference
each instruction. A `## Sources verified <date>` section at the
bottom of the document + a `Sources verified <date>: <urls>` footer
in the commit message are MANDATORY. Re-verification cadence: every
major release boundary; ≤ 6 months for general docs; ≤ 90 days for
risk-classified families (messengers, cloud APIs, payments, LLM
providers, code-hosting, OS/package managers). Stale docs graduate
to §11.4.90 Obsolete after the 30-day grace. **Canonical
authority:** `constitution/Constitution.md` §11.4.99 (commit
`9e3bcc5`). Forensic anchor: Herald MTProto guide near-miss case
study where stale guidance could have caused Telegram account ban.
