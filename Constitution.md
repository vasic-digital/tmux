# vasic-digital tmux — Project Constitution

| Field | Value |
|---|---|
| Revision | 3 |
| Created | 2026-05-07 |
| Last modified | 2026-05-21 |
| Status | active |
| Extends | `constitution/Constitution.md` — Helix Universal Constitution, pinned `7f738df` |
| Status summary | R3 (2026-05-21): full refactor to the HelixConstitution extends-template form. Universal clauses now inherited from the `constitution/` submodule; this file holds only Project Articles §101–§109. No universal clause weakened — inheritance is verified by `scripts/tests/test_constitution_inheritance.sh` + its paired mutation. |

This constitution **extends** the Helix Universal Constitution at
[`constitution/Constitution.md`](constitution/Constitution.md). Every
clause there — the anti-bluff covenant (§11.4), absolute data safety
(§9), the 60 % host-memory budget, the continuation-document invariant
(§12.10), the no-guessing mandate (§11.4.6), commit/push discipline,
credentials handling — applies to this repository **unconditionally**.

The Project Articles below **extend** those universal clauses with
tmux-specific rules. They never weaken or override a universal clause.
**When this file disagrees with the constitution submodule, the
constitution wins.**

> **Inheritance is verified, not assumed.**
> `scripts/tests/test_constitution_inheritance.sh` asserts the submodule
> is present at the pinned revision and that the §11.4 *End-user Quality
> Guarantee* anchor physically exists in `constitution/Constitution.md`.
> Its paired mutation — `constitution/meta_test_inheritance.sh`, wired as
> the `CM-CONSTITUTION-INHERITANCE` entry in
> `scripts/tests/meta_test_false_positive_proof.sh` — deletes that anchor
> and proves the gate then FAILs. The gate cannot itself be a bluff gate.

---

## Project Articles

### §101 — Anti-bluff covenant binding (origin anchor)

This repository is one of the historical origins of the Helix anti-bluff
covenant. The verbatim user mandate that the universal §11.4 codifies is
preserved here for forensic continuity — it MUST remain in this project's
Constitution regardless of inheritance:

> "We had been in position that all tests do execute with success and
> all Challenges as well, but in reality the most of the features does
> not work and can't be used! This MUST NOT be the case and execution
> of tests and Challenges MUST guarantee the quality, the completion
> and full usability by end users of the product!"

**The bar for shipping is "users can use the feature," not "tests
pass."** Every PASS in this codebase — unit test OR HelixQA Challenge —
MUST carry positive runtime evidence captured *during execution* that
the feature works for the end user. Metadata-only PASS, configuration-
only PASS, "absence-of-error" PASS, and grep-only PASS are critical
defects regardless of how green the summary line is. **FAIL-bluffs**
(a test that exits FAIL for a script-internal reason, not a product
defect) are equally forbidden and MUST be fixed at the source layer.

The full covenant — recorded-evidence requirement, FAIL-bluff
prohibition, no-guessing mandate, test-interrupt-on-discovery — is
universal §11.4.1 through §11.4.6. This article binds this project to
it and adds the project-specific articles below.

### §102 — Operator-path test coverage (project rule, User mandate 2026-05-13)

**Forensic anchor:** `Fixed.md` A12 + A13. Tests 11 and 14 reported
GREEN while their operator-facing equivalents (`tmx new -s X`) were
broken — test 11 only exercised the explicit-socket path; test 14
hand-spawned `systemd-run --user --scope` units while the real
`tmx new` workflow placed all sessions in one shared cgroup.

**The mandate.** Every gate test for a feature MUST exercise the SAME
entry point an end-user would invoke in production. Tests that bypass
the operator's wrapper / helper / install path and reproduce its
effects with hand-crafted equivalents DO NOT satisfy the universal
§11.4.2 captured-evidence requirement. When the operator's path and
the test's path diverge:

1. The test header MUST EXPLICITLY name the divergence
   (e.g. "test invokes `tmux` directly; operator path is `tmx new`").
2. A SEPARATE end-to-end test MUST close that divergence with captured
   evidence on the operator-facing entry point.

**Operative test:** for every test under `scripts/tests/`, ask "would
an operator hit this code path in their normal workflow?" If no, that
test is supplementary; the operator-path test must exist alongside it.

**No grep-on-script-content alone.** A `grep` on a script for a literal
string is allowed AS A STATIC CHECK *in addition to* a runtime readback
— never as the only assertion.

**Layer-4 mutations MUST target the operator-path code.** Mutations
target `scripts/tmx-vm` / `scripts/tmx.template` / `scripts/tmux.conf.template`
(the code that runs in production), not synthetic-test code.

Non-compliance is a release blocker.

### §103 — Four-layer test coverage for tmux defects (User mandate 2026-05-06)

Every defect found, fixed, or introduced in this repo MUST land all
four layers before the cycle closes:

- **Layer 1 — pre-build / static-source gate.** A check in
  `scripts/verify.sh` (or the relevant build script) that catches the
  defect class at source.
- **Layer 2 — runtime test.** A numbered test in `scripts/tests/NN_*.sh`
  producing positive runtime artifacts, anti-bluff per §101,
  operator-path per §102, topology-dispatched per §104.
- **Layer 3 — HelixQA Challenge.** An entry in
  `scripts/challenges/tmux.yaml` carrying captured-evidence semantics.
  A test without a paired Challenge is a §101 PASS-bluff.
- **Layer 4 — paired mutation.** A mutation in
  `scripts/tests/meta_test_false_positive_proof.sh` proving the
  Layer-2 test catches its own negation (mutation CAUGHT) and that the
  feature is restored afterwards (RESTORED).

**Test-interrupt-on-discovery.** The moment any defect is rediscovered,
re-produced, or newly identified during a test cycle, the cycle STOPS.
Fix at root cause → land all four layers → full rebuild → repeat the
full cycle from the beginning.

### §104 — Per-host-topology test dispatch for tmux (User mandate 2026-05-05)

Tests that depend on host topology (systemd version, cgroup v1 vs v2,
distro-specific controller availability, presence of `systemd-run
--user`, Linux vs Darwin) MUST detect topology at test entry and
dispatch the topology-appropriate variant — recording the probe output
as positive evidence of the SKIP rationale. A test running the wrong
variant for the actual topology and PASSing is a §101 PASS-bluff.
Silent degradation to a no-isolation path is forbidden.

`scripts/tmx` classifies the host as `tmx-supported` / `tmx-degraded` /
`tmx-unsupported` via `_probe_topology()` — the canonical dispatch seam.

### §105 — Per-session isolation architecture (default since 2026-05-13)

Each `tmx new -s NAME` spawns its OWN tmux server on socket `tmx-NAME`
inside its OWN OS-native isolation boundary:

- **Linux** — cgroup-v2 transient scope `tmx-NAME.scope` via
  `systemd-run --user --scope`. `MemoryMax` host-adaptive
  (`max(MemTotal × 60 % / 4, 2 GB)` unless `TMX_MEM` overrides),
  `CPUQuota=200%`, `TasksMax=4096`, `Delegate=yes`. OOM in any one
  scope affects ONLY that scope — `user.slice` survives.
- **macOS (Darwin)** — POSIX rlimit wrapper as session
  `default-command`: `RLIMIT_CPU` + `RLIMIT_NPROC`, kernel-enforced.
  `RLIMIT_AS` (memory) is NOT enforced by XNU for unprivileged
  processes — documented honestly per §101, see `docs/guide/README.md` §5.6.

The session shell is the operator's host shell with full `$PATH`.
Plain-vanilla tmux UX with OS-native isolation as a safeguard.

### §106 — TMX_MEM memory-budget enforcement (project enforcement of universal §12.6)

The universal 60 % host-memory budget is enforced in this project by
the per-session containerization in `scripts/tmx`. Invariant:
`Σ(active TMX_MEM) ≤ 0.6 × MemTotal`. Operator default `TMX_MEM=8G`.
On Linux the cgroup `MemoryMax` is kernel-enforced; on macOS the cap is
informational only (XNU gap, §105). There is NO operator-facing
override of the per-host total.

### §107 — Upstream tmux submodule pinned + immutable

`tmux/` references `tmux/tmux` at tag `3.6a` (commit `cc117b5`). It is a
third-party upstream submodule: **never modified**, never advanced off
the tag without an explicit, documented decision in `Fixed.md` + a
governance-doc update in the same commit. Silent pin-drift is a §101 /
universal §11.4.6 violation (forensic precedent: `Fixed.md` §3.8).

### §108 — Native dual-OS build discipline

The hardened tmux binary is built natively per OS — Linux ELF and macOS
Mach-O — from the same `tmux/` submodule. `scripts/setup.sh`,
`scripts/install_deps.sh`, and every project script MUST detect host OS
and apply the correct action out of the box (no manual per-OS flags).
Compile hardening, jemalloc linkage, and the verification gate apply to
both targets.

### §109 — Anti-bluff verification gate (load-bearing)

`scripts/verify.sh` is the single decision point for whether the binary
is operator-safe. GREEN → `setup.sh` proceeds to PATH export; RED →
`setup.sh` REFUSES to install. There is no "force install" mode and no
flag that bypasses the gate.

---

## Overrides of the Universal Constitution

None. This project introduces **no override** of any universal clause.
Any future override MUST appear here under an explicit
`### Override §X.Y — <reason>` heading with justification.

---

## Owned-submodule set

Submodules this project owns and is responsible for:

```
Containers     git@github.com:vasic-digital/Containers.git   (cgroup orchestration helpers)
constitution   git@github.com:HelixDevelopment/HelixConstitution.git   (governance; pinned 7f738df)
```

`tmux/` is a **third-party upstream** submodule (`tmux/tmux` tag `3.6a`)
— excluded from the owned set; immutable per §107.

---

## Project-specific remotes

| Repo | Remotes | Push mechanism |
|---|---|---|
| Main — `vasic-digital/tmux` | `github` + `gitlab` | `bash commit_all.sh "<msg>"` — ONLY allowed mechanism |
| `Containers` | `github` + `gitlab` | the Containers repo's own commit wrapper |

Never `git push` directly on the main repo. SSH remotes only — no HTTPS
for Git. No CI/CD pipeline files. Force-push is never automatic and
requires explicit per-operation authorization per universal §9.

---

## §11.4.87–98 — universal anchors inherited from constitution 6828ff2 (cycle 2026-05-28)

The constitution submodule was ff-merged from `84c948d` to `6828ff2`
(2026-05-28). Anchors §11.4.87 through §11.4.98 are universal additions
that apply to this project unconditionally per §11.4.35. Long-form bodies
live in `constitution/Constitution.md`; short-form mirrors follow.

### §11.4.87 — Endless-loop autonomous work + zero-idle agent dispatch + anti-bluff testing

Universal anchor inherited from `constitution/Constitution.md` §11.4.87
(commit 6828ff2). Operative for this project: agent work continues
autonomously until ALL of (a) Issues.md has no In-progress / Ready /
In-testing / Reopened items, (b) CONTINUATION.md §3 active-work empty,
(c) no in-flight subagent, (d) no external dependency in-flight.
Every closed item carries §11.4.4(b) four-layer coverage + captured
evidence per §11.4.5/§11.4.69. Tests AND HelixQA Challenges bound
equally. **Canonical authority:** constitution submodule
`Constitution.md` §11.4.87 (6828ff2).

### §11.4.88 — Background-push: commit-lock release immediately, push detached

Universal anchor inherited from `constitution/Constitution.md` §11.4.88
(commit 6828ff2). Operative: `commit_all.sh` MUST release its commit
flock the moment `git commit` returns 0; `git push` runs detached via
`nohup ... &` + `disown`; per-remote `.git/.push.<remote>.lock` serialises
same-remote concurrent pushes but allows different-remote parallelism.
Backgrounded push failures land under `qa-results/push_failures/`. The
only escape is `--sync-push` for §11.4.41 force-push paths. **Canonical
authority:** constitution submodule `Constitution.md` §11.4.88 (6828ff2).

### §11.4.89 — Background test execution (long tests run detached)

Universal anchor inherited from `constitution/Constitution.md` §11.4.89
(commit 6828ff2). Operative for this project's >30 s tests
(`bash scripts/tests/run_all.sh`, `meta_test_false_positive_proof.sh`,
`test_e2e.sh`, etc.): MUST spawn via `nohup ... > <log> 2>&1 &` +
`disown`; main work stream returns to the §11.4.42 priority queue;
hard-dependent next steps poll exit-status. Per-script flock serialises
same-script invocations. **Canonical authority:** constitution submodule
`Constitution.md` §11.4.89 (6828ff2).

### §11.4.90 — Obsolete status + per-item obsolescence audit

Universal anchor inherited from `constitution/Constitution.md` §11.4.90
(commit 6828ff2). The §11.4.15 Status closed-set gains terminal value
`Obsolete (→ Fixed.md)` (orthogonal to Type). Reasons drawn from closed
vocabulary: `superseded-by-design-change | superseded-by-later-mandate |
feature-removed | duplicate-of | unsupported-topology`. Every Obsolete
heading carries `**Obsolete-Details:**` (Since + Reason + Superseding-item
+ Triple-check evidence) within 8 non-blank lines. §11.4.23 colorizer
adds `cell-status-obsolete` class (light-gray + strikethrough). **Canonical
authority:** constitution submodule `Constitution.md` §11.4.90 (6828ff2).

### §11.4.91 — Summary-doc clarity mandate

Universal anchor inherited from `constitution/Constitution.md` §11.4.91
(commit 6828ff2). Every summary one-liner (Issues_Summary.md,
Fixed_Summary.md, README doc-link, Status_Summary pages) MUST be
self-contained — ≥ 6 words OR ≥ 40 chars naming SUBJECT + PROBLEM/GOAL.
Forbidden anti-patterns: section labels (`Composes with`, etc.); bare
metadata fragments (`Critical`, `Bug`, `In progress`); §-letter alone.
Generators MUST extract from H1/H2 heading line per §11.4.54 ATM-NNN
convention and refuse anti-pattern rows. **Canonical authority:**
constitution submodule `Constitution.md` §11.4.91 (6828ff2).

### §11.4.92 — Multi-pass change-evaluation discipline

Universal anchor inherited from `constitution/Constitution.md` §11.4.92
(commit 6828ff2). Every non-trivial change passes 5 evaluation passes
BEFORE commit-ready: (1) main-task captured-evidence verification;
(2) regression blast-radius enumeration of every dependent file;
(3) cross-feature interaction analysis (shared state/timing/hardware);
(4) deep-research per §11.4.8 + CodeGraph queries per §11.4.78/§11.4.79;
(5) anti-bluff confirmation. Per-pass written documentation required.
Trivial exemption only for zero-source-touch revision-bump / typo
commits citing the exemption. **Canonical authority:** constitution
submodule `Constitution.md` §11.4.92 (6828ff2).

### §11.4.93 — SQLite-backed single source of truth for workable items

Universal anchor inherited from `constitution/Constitution.md` §11.4.93
(commit 6828ff2). Text-based Issues/Fixed/Summary/CONTINUATION
constellation converts to SQLite-DB-backed single source of truth at
`docs/workable_items.db` (TRACKED per §11.4.95, not gitignored). A Go
binary at `cmd/workable-items/` provides bidirectional sync (`md-to-db` /
`db-to-md` / `diff` / `validate` / `add` / `close`). Round-trip MUST be
byte-identical within whitespace-and-section-order tolerance.
`commit_all.sh` refuses to commit while diff is non-empty. **Canonical
authority:** constitution submodule `Constitution.md` §11.4.93 (6828ff2).

### §11.4.94 — Zero-idle priority-first parallel-by-default operating mode

Universal anchor inherited from `constitution/Constitution.md` §11.4.94
(commit 6828ff2). Binds §11.4.20+§11.4.42+§11.4.58+§11.4.70+§11.4.72+
§11.4.82+§11.4.87+§11.4.88+§11.4.89 into a single always-on enforcement:
idle ONLY when every queued item is genuinely externally blocked OR
operator STOP OR §12 host-safety; before any wake/sleep the conductor
MUST survey parallel-work feasibility, identify non-contending items,
dispatch in parallel per §11.4.20/§11.4.70 subagent-driven default +
§11.4.58 PWU disjoint scope + §11.4.89 background long tests. **Canonical
authority:** constitution submodule `Constitution.md` §11.4.94 (6828ff2).

### §11.4.95 — Workable-items SQLite DB TRACKED in git, NEVER gitignored

Universal anchor inherited from `constitution/Constitution.md` §11.4.95
(commit 6828ff2). Amends §11.4.93: `docs/workable_items.db` IS authoritative
source data, NOT a build artefact — it is TRACKED in git, NEVER gitignored.
Every `workable-items sync md-to-db` mutation stages + commits + pushes
the DB alongside the MD regen per §11.4.19 atomic-move + §2.1 multi-upstream
push. WAL-checkpoint (`PRAGMA wal_checkpoint(TRUNCATE)`) required before
commit-stage. Destructive DB ops require §9.2 hardlinked-backup. **Canonical
authority:** constitution submodule `Constitution.md` §11.4.95 (6828ff2).

### §11.4.96 — Safe-parallel-work-with-long-build catalogue + mandate

Universal anchor inherited from `constitution/Constitution.md` §11.4.96
(commit 6828ff2). Operational catalogue for long-running build workloads
classifies parallel work as SAFE (docs/scripts/tests/submodule pushes
under §11.4.88 + research + DB ops + subagent dispatch) vs UNSAFE
(destructive git ops on source tree, mass deletes under hot subtrees,
container destruction, host-safety breaches). Conductor MUST consult
catalogue at every pause point and dispatch ≥1 safe item per §11.4.20/
§11.4.70 subagent default + §11.4.89 background. **Canonical authority:**
constitution submodule `Constitution.md` §11.4.96 (6828ff2).

### §11.4.97 — Maximum-use-of-idle-time + progress-update cadence

Universal anchor inherited from `constitution/Constitution.md` §11.4.97
(commit 6828ff2). Strengthens §11.4.87+§11.4.94+§11.4.96: every idle
minute during which work could autonomously progress and is not genuinely
blocked = §11.4.97 violation. Progress-update cadence: emit operator-facing
1-line update at every commit landed / subagent return / constitutional
anchor landing / captured-evidence acquisition / milestone closure —
no operator prompt required. Continuous physical-proof gathering per
§11.4.5+§11.4.6+§11.4.69. **Canonical authority:** constitution submodule
`Constitution.md` §11.4.97 (6828ff2).

### §11.4.98 — Full-Automation Anti-Bluff — live tests re-runnable end-to-end without manual intervention

Universal anchor inherited from `constitution/Constitution.md` §11.4.98
(commit 6828ff2). Closes the manual-intervention gap §11.4.85/§11.4.87/
§11.4.89/§11.4.94 did not explicitly forbid: every test (unit /
integration / e2e / Challenge / stress / chaos / live) MUST be fully
self-driving end-to-end and report PASS/FAIL/SKIP-with-reason without
any further human action after startup. One-time credential bootstrap
OUTSIDE test execution is the only permissible exception. Re-runnability
proof = PASS at `-count=3` consecutive automated invocations with
self-cleaning state. Manual-dependency tests not rewritten within 30
days graduate to §11.4.90 Obsolete citing §11.4.98 as the reason.
**Canonical authority:** constitution submodule `Constitution.md`
§11.4.98 (6828ff2).

### §11.4.99 — Latest-Source Documentation Cross-Reference Mandate

Universal anchor inherited from `constitution/Constitution.md` §11.4.99
(commit `9e3bcc5` ff 2026-05-28). Before committing any operator-facing
instruction / guide / manual / setup walkthrough / troubleshooting
cookbook / API how-to, the author MUST cross-reference each instruction
against the LATEST official online documentation of the service /
library being documented via WebFetch / MCP / direct browsing — NOT
training data. A `## Sources verified <date>` section in the doc and
a `Sources verified <date>: <urls>` footer in the commit message are
MANDATORY. Re-verification cadence: every major-release boundary; ≤ 6
months for general docs; ≤ 90 days for risk-classified service families
(messengers, cloud APIs, payments, LLM/AI providers, code-hosting,
OS/package managers). Stale docs → §11.4.90 Obsolete after the 30-day
grace window. **Canonical authority:** constitution submodule
`Constitution.md` §11.4.99 (`9e3bcc5`). Forensic anchor: Herald MTProto
guide near-miss case study where stale guidance could have caused a
Telegram account ban.

---

*This Project Constitution governs the `vasic-digital/tmux` repository.
It is subordinate to and extends `constitution/Constitution.md`.*
