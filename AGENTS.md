# vasic-digital tmux — AGENTS.md

> Base agent rules live at `constitution/AGENTS.md` and the
> `constitution/Constitution.md` it references. **READ THOSE FIRST.**
> This file extends them with project-specific rules; it never weakens
> them. Canonical project authority: [`Constitution.md`](Constitution.md)
> — Project Articles §101–§109.

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
`tmx new -s NAME` spawns its own tmux server on the host with
OS-native isolation — cgroup-v2 scope on Linux, POSIX rlimit wrapper on
macOS. Session shell is the operator's host shell with full PATH. No
VM. macOS memory-cap gap documented honestly (XNU doesn't enforce
`RLIMIT_AS`) — see `docs/guide/README.md` §5.6.

## Critical base rules restated (for agents that don't follow @imports)

- **No bluffing.** Every PASS — test OR HelixQA Challenge — carries
  positive runtime evidence (file *content*, not existence). Universal
  §11.4 / Project §101.
- **FAIL-bluffs forbidden.** A test that exits FAIL for a script bug
  is fixed at the source layer, never at call sites. Universal §11.4.1.
- **No-guessing language.** `likely`, `probably`, `maybe`, `seems`,
  `appears` are forbidden when reporting causes — prove with forensic
  evidence or mark `UNCONFIRMED:` / `PENDING_FORENSICS:`. Universal §11.4.6.
- **Operator-path coverage.** Every gate test exercises the SAME entry
  point an end-user invokes (`tmx new -s X`). Project §102.
- **Four-layer coverage.** Every defect lands pre-build gate + runtime
  test + HelixQA Challenge + paired mutation. Project §103.
- **Use the commit wrapper.** `bash commit_all.sh "<msg>"` only — no
  direct `git add` / `git commit` / `git push` on the main repo.
- **Never force-push.** Explicit per-operation authorization required.
- **CONTINUATION.md** kept in sync in every non-trivial commit.
  Universal §12.10.
- **60 % RAM cap** enforced per-session via `TMX_MEM`. Project §106.

## Commands (exact)

| Step | Command |
|---|---|
| Install build deps | `bash scripts/install_deps.sh` (Linux: root; macOS: brew) |
| Full pipeline | `bash scripts/setup.sh` |
| Build only / Verify only | `bash scripts/setup.sh --build-only` / `--verify-only` |
| Verification gate | `bash scripts/verify.sh` |
| Run all tests | `bash scripts/tests/run_all.sh` |
| Single test | `bash scripts/tests/NN_*.sh` (01..17) |
| Inheritance gate | `bash scripts/tests/test_constitution_inheritance.sh` |
| Meta-test (paired mutation) | `bash scripts/tests/meta_test_false_positive_proof.sh` |
| End-to-end automation | `bash scripts/test_e2e.sh` |
| Commit + push (github+gitlab) | `bash commit_all.sh "message"` |
| Per-session wrapper | `tmx {new\|attach\|ls\|kill}` |

## Structure

| Path | Role |
|---|---|
| `constitution/` | HelixConstitution submodule — universal governance — **do not modify** |
| `tmux/` | upstream submodule (tag `3.6a`) — **do not modify** |
| `Containers/` | vasic-digital cgroup helpers submodule |
| `scripts/` | build, verify, install, 17 tests + inheritance gate, challenges, templates |
| `scripts/tmx` | generated dispatcher (`.gitignore`'d — edit `tmx.template`) |
| `scripts/tmux.conf.template` | tmux config template (scrollback / copy-mode / clipboard) |
| `commit_all.sh` | only allowed push mechanism |
| `Constitution.md` | project authority (extends `constitution/`) |
| `Issues.md` / `Fixed.md` / `CONTINUATION.md` | open work / closed archive / live handoff |

## Project-specific agent rules

### Allowed CLI tools

- `git`, `gh`, `glab` (releases), `bash`, the project's own scripts.
- macOS: Homebrew (`brew`) for build deps. Linux: distro package
  manager via `install_deps.sh`.

### Forbidden in this project

- Editing `tmux/`, `constitution/`, or generated files (`scripts/tmx`,
  `tmux/build*/`).
- Direct `git push` on the main repo — use `commit_all.sh`.
- CI/CD pipeline files (`.github/workflows/`, `.gitlab-ci.yml`).
- HTTPS Git remotes — SSH only.
- Advancing the `tmux/` submodule off tag `3.6a` without an explicit
  documented decision (Project §107).

### Project-specific workflow

- **Test-interrupt-on-discovery** (§103): a defect found mid-cycle
  STOPS the cycle — fix root cause, land four layers, rebuild, repeat.
- **Topology dispatch** (§104): tests detect host topology and
  SKIP-with-reason; never silently degrade.
- **Destructive tests** (12/13/14): require `TMX_TEST_DESTRUCTIVE=1`.
- **Releases**: bump `VERSION` (`version=` + `versionCode=` together) +
  `CHANGELOG.md` entry; tag + `gh release create` + `glab release create`.

## Project overrides of universal rules

None.

## §11.4.87–98 — newly-inherited anchors (constitution 6828ff2)

Twelve new universal anchors landed in `constitution/Constitution.md`
at commit `6828ff2` (2026-05-28). They apply unconditionally per
§11.4.35. Short-form mirrors follow.

### §11.4.87 — Endless-loop autonomous work + zero-idle agent dispatch

Inherited from `constitution/Constitution.md` §11.4.87. Continue work
until all of: Issues.md has zero non-terminal items, CONTINUATION.md
§3 active-work empty, no in-flight subagent, no external dependency
in-flight. Every closure carries §11.4.4(b) four-layer coverage +
captured-evidence per §11.4.5/§11.4.69. **Canonical authority:**
`constitution/Constitution.md` §11.4.87.

### §11.4.88 — Background-push: commit-flock release immediate, push detached

Inherited from `constitution/Constitution.md` §11.4.88. `commit_all.sh`
releases its commit flock as soon as `git commit` returns 0; push runs
detached via `nohup ... &` + `disown`. Per-remote flock serialises
same-remote concurrent pushes. Only escape: `--sync-push` for §11.4.41
force-push paths. **Canonical authority:** `constitution/Constitution.md`
§11.4.88.

### §11.4.89 — Background test execution

Inherited from `constitution/Constitution.md` §11.4.89. Any test
> 30 s (`run_all.sh`, `meta_test_false_positive_proof.sh`, `test_e2e.sh`)
MUST run detached via `nohup ... > <log> 2>&1 &` + `disown`; main
stream returns to the §11.4.42 priority queue. **Canonical authority:**
`constitution/Constitution.md` §11.4.89.

### §11.4.90 — Obsolete status + per-item obsolescence audit

Inherited from `constitution/Constitution.md` §11.4.90. New §11.4.15
Status terminal value `Obsolete (→ Fixed.md)` with mandatory
`**Obsolete-Details:**` (Since + Reason from closed vocabulary +
Superseding-item + Triple-check evidence). Colorizer marks rows
light-gray + strikethrough. **Canonical authority:**
`constitution/Constitution.md` §11.4.90.

### §11.4.91 — Summary-doc clarity

Inherited from `constitution/Constitution.md` §11.4.91. Every summary
one-liner ≥ 6 words OR ≥ 40 chars, naming SUBJECT + PROBLEM/GOAL.
Anti-patterns forbidden: section labels, bare metadata fragments,
§-letter alone. Generators extract from H1/H2 heading per §11.4.54
ATM-NNN convention. **Canonical authority:**
`constitution/Constitution.md` §11.4.91.

### §11.4.92 — Multi-pass change-evaluation discipline

Inherited from `constitution/Constitution.md` §11.4.92. 5 passes before
commit: (1) main task evidence; (2) regression blast radius; (3) cross-
feature interaction; (4) deep research + CodeGraph; (5) anti-bluff
confirmation. Trivial exemption only for zero-source-touch commits
that cite it. **Canonical authority:** `constitution/Constitution.md`
§11.4.92.

### §11.4.93 — SQLite-backed single source of truth for workable items

Inherited from `constitution/Constitution.md` §11.4.93. Text trackers
become views of `docs/workable_items.db`. Go binary `cmd/workable-items/`
provides `md-to-db` / `db-to-md` / `diff` / `validate`. Round-trip is
byte-identical within whitespace tolerance. `commit_all.sh` refuses
non-empty diff. **Canonical authority:** `constitution/Constitution.md`
§11.4.93.

### §11.4.94 — Zero-idle priority-first parallel-by-default operating mode

Inherited from `constitution/Constitution.md` §11.4.94. Idle only when
genuinely externally blocked OR operator STOP OR §12 host-safety.
Before any wake/sleep, survey parallel-work feasibility per §11.4.42 /
§11.4.72 / §11.4.87 and dispatch non-contending items via §11.4.20 /
§11.4.70. **Canonical authority:** `constitution/Constitution.md`
§11.4.94.

### §11.4.95 — Workable-items SQLite DB TRACKED in git, NEVER gitignored

Inherited from `constitution/Constitution.md` §11.4.95. Amends §11.4.93:
`docs/workable_items.db` is authoritative source data, TRACKED in git,
never gitignored. Every mutation stages + commits + pushes alongside
the MD regen. WAL-checkpoint before commit-stage. **Canonical
authority:** `constitution/Constitution.md` §11.4.95.

### §11.4.96 — Safe-parallel-work-with-long-build catalogue

Inherited from `constitution/Constitution.md` §11.4.96. Operational
catalogue classifies parallel work as SAFE (docs/scripts/tests/submodule
pushes, research, DB ops, subagent dispatch) vs UNSAFE (destructive
git ops, mass deletes, host-safety breaches). Conductor consults
catalogue at every pause point. **Canonical authority:**
`constitution/Constitution.md` §11.4.96.

### §11.4.97 — Maximum-use-of-idle-time + progress-update cadence

Inherited from `constitution/Constitution.md` §11.4.97. Idle minute
during which work could progress and is not genuinely blocked =
§11.4.97 violation. Emit 1-line operator-facing update on every commit
landed / subagent return / anchor landing / evidence acquisition /
milestone closure. **Canonical authority:**
`constitution/Constitution.md` §11.4.97.

### §11.4.98 — Full-Automation Anti-Bluff: live tests re-runnable without manual intervention

Inherited from `constitution/Constitution.md` §11.4.98. Every test
MUST be fully self-driving end-to-end and emit PASS/FAIL/SKIP-with-reason
without further human action after startup. Only exception: one-time
credential bootstrap OUTSIDE test execution. Re-runnability proof =
PASS at `-count=3` consecutive automated invocations. **Canonical
authority:** `constitution/Constitution.md` §11.4.98.

### §11.4.99 — Latest-Source Documentation Cross-Reference Mandate

Inherited from `constitution/Constitution.md` §11.4.99 (commit `9e3bcc5`
ff 2026-05-28). Before committing operator-facing instruction docs
(guides, manuals, setup walkthroughs, troubleshooting cookbooks, API
how-tos), fetch LATEST official online docs via WebFetch / MCP / direct
browsing (NOT training data). Cross-reference every instruction. `##
Sources verified <date>` section in doc + `Sources verified <date>:
<urls>` footer in commit message MANDATORY. Re-verification cadence:
≤6 mo general; ≤90 d for risk-classified (messengers, cloud, payments,
LLM, code-host, package mgrs). Stale → §11.4.90 Obsolete after 30-day
grace. **Canonical authority:** `constitution/Constitution.md` §11.4.99.
