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
  `systemd-run --user --scope`, **fully elastic ("liquid") memory**:
  `MemoryMax=infinity` (a session is NEVER per-scope OOM-killed) plus a
  `MemoryMin=128M` floor so it is not reclaimed to death. `TMX_MEM` (or
  `TMX_MEM=auto` for the host-adaptive size) adds an OPT-IN *soft*
  `MemoryHigh` throttle (reclaim, never kill). `CPUQuota=200%`,
  `TasksMax=4096`, `Delegate=yes`. Genuine exhaustion is handled
  system-wide by systemd-oomd + zram + the `user.slice` backstop (see the
  OOM-Protect project): a real runaway is stopped at TRUE exhaustion
  without freezing the box, while normal multi-session load never triggers
  a premature kill. Scopes remain independent cgroups (§14 crash isolation).
- **macOS (Darwin)** — POSIX rlimit wrapper as session
  `default-command`: `RLIMIT_CPU` + `RLIMIT_NPROC`, kernel-enforced.
  `RLIMIT_AS` (memory) is NOT enforced by XNU for unprivileged
  processes — documented honestly per §101, see `docs/guide/README.md` §5.6.

The session shell is the operator's host shell with full `$PATH`.
Plain-vanilla tmux UX with OS-native isolation as a safeguard.

### §106 — TMX_MEM memory-budget enforcement (project enforcement of universal §12.6)

Default is **fully elastic**: sessions use all available RAM/zram and are
never per-scope OOM-killed. The universal 60 % host-memory budget is enforced
system-wide at the `user.slice` level (OOM-Protect: `MemoryMax=95%`,
`MemoryHigh=90%`) rather than per session, so genuine exhaustion is caught
without capping individual sessions — "never kill prematurely, never stuck".
`TMX_MEM` is an OPT-IN per-session *soft* `MemoryHigh` throttle (reclaim, never
kill; `TMX_MEM=auto` uses the host-adaptive `max(MemTotal × 60 % / 4, 2 GB)`
size). On macOS the cap is informational only (XNU gap, §105).

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

### §11.4.100 — RETIRED (per §11.4.17/§11.4.35, demoted to consumer project as project-specific)

### §11.4.101 — Autonomous-decision-over-blocking mandate (User mandate, 2026-05-28)

Universal anchor inherited from `constitution/Constitution.md` §11.4.101 (commit `6828ff2`). In autonomous/endless-loop mode, the agent MUST minimize operator-blocking and make the safe, reliable, reversible decision autonomously so work is not stalled waiting for input. Decision rule (ALL hold): action is reversible OR has a captured pre-op backup (§9.2); safe choice from captured evidence (§11.4.6 no-guessing); wrong-choice blast radius bounded AND recoverable. Block only when irreversible AND high-blast-radius AND safe choice cannot be determined from evidence. An unavoidable block parks one work unit, not the loop. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.101 (commit `1576d3d`).

### §11.4.102 — Mandatory systematic-debugging + always-loaded skill-discovery + plugin-dependency availability (User mandate, 2026-05-29)

Universal anchor inherited from `constitution/Constitution.md` §11.4.102 (commit `6828ff2`). On ANY spotted issue/bug/test-failure/gate-failure/regression, the agent MUST activate `superpowers:systematic-debugging` BEFORE proposing/writing/applying any fix — NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST. `superpowers:using-superpowers` MUST be always-loaded and consulted before any task. All skill plugins/dependencies MUST be installed + loadable before dependent work proceeds. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.102.

### §11.4.103 — Continuous parallel-stream working routine (User mandate, 2026-05-29)

Universal anchor inherited from `constitution/Constitution.md` §11.4.103. The main work stream MUST always stay FREE (commit AND push operations run detached). ≥3 parallel background streams at all times with auto-backfill. Audio always top per §11.4.72. Idle ONLY when genuinely externally blocked. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.103.

### §11.4.108 — Four-layer fix-verification + runtime-signature-as-definition-of-done mandate

Universal anchor inherited from `constitution/Constitution.md` §11.4.108. A fix crosses FOUR distinct layers and "fixed" at one does NOT imply fixed at the next: SOURCE → ARTIFACT → RUNTIME-ON-CLEAN-TARGET → USER-VISIBLE. Every fix declares ONE machine-checkable runtime signature verified on a clean target. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.108.

### §11.4.113 — Absolute no-force-push + merge-onto-latest-main mandate (User mandate, 2026-06-03)

Universal anchor inherited from `constitution/Constitution.md` §11.4.113. Force-push is STRICTLY FORBIDDEN with NO exception. The mandated 6-step integration procedure for any repo/submodule whose local has commits to publish OR whose mirrors diverged: fetch → set base → merge → resolve → commit → push. Each push is a fast-forward because the merge commit descends from every mirror tip. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.113. This project installs a PreToolUse guard that blocks `--force` / `--force-with-lease` at the tool-call boundary.

### §11.4.115 — RED-baseline-on-the-broken-artifact + polarity-switch mandate

Universal anchor inherited from `constitution/Constitution.md` §11.4.115. Every RED test MUST reproduce the defect on the CURRENT pre-fix artifact with positive captured evidence. The SAME test source carries `RED_MODE=1→0` polarity switch — RED-on-broken then GREEN-on-fixed. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.115.

### §11.4.122 — No-silent-removal-of-existing-components-without-operator-confirmation (User mandate, 2026-06-03)

Universal anchor inherited from `constitution/Constitution.md` §11.4.122. No application/component/service/package/feature/driver/module/prebuilt — any end-user capability — may be removed without FIRST interactively asking the operator and receiving an EXPLICIT keep-or-remove decision. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.122.

### §11.4.123 — Rock-solid-proof-or-deep-research mandate (User mandate, 2026-06-03)

Universal anchor inherited from `constitution/Constitution.md` §11.4.123. Every reported issue/fix/claimed completion MUST be 100% validated with rock-solid CAPTURED proof per §11.4.5/§11.4.69/§11.4.107. When unsure how to validate, perform deep web research FIRST — declaring "untestable" without exhausting research is itself a violation. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.123.

### §11.4.124 — Dead/unwired-code investigate-before-remove mandate (User mandate, 2026-06-04)

Universal anchor inherited from `constitution/Constitution.md` §11.4.124. "Zero importers ⇒ dead ⇒ delete" is a GUESS (§11.4.6). Before removing ANY seemingly-dead element, investigate via git history and capture FACT where/how it was wired in and how it became dead. Removal permitted ONLY with captured proof. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.124.

### §11.4.125 — Code-review-agent gate before pre-build + main build (mandatory multi-layer review)

Universal anchor inherited from `constitution/Constitution.md` §11.4.125. After all batch fixes/changes and BEFORE the pre-build sweep + main build, dispatch dedicated code-review agent(s) analyzing all work done + existing data/facts + codebase + git history. Any finding fixed + re-tested + re-reviewed before build proceeds. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.125.

### §11.4.126 — Default autonomous-loop working mode from first prompt (User mandate, 2026-06-04)

Universal anchor inherited from `constitution/Constitution.md` §11.4.126. The endless fully-autonomous loop is the DEFAULT working mode, engaged automatically from the FIRST prompt. Continues until release tag published OR current scope fully completed AND queue empty. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.126.

### §11.4.127 — Session-handoff resumption-prompt mandate (User mandate, 2026-06-06)

Universal anchor inherited from `constitution/Constitution.md` §11.4.127. On fresh-session need OR operator ask, the agent MUST prepare + provide a ready-to-paste resumption prompt valid for that EXACT moment — self-contained, pointing to handoff docs, stating current PHASE/NEXT/terminal-goal, embedding exact live-state anchors. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.127.

### §11.4.131 — Standing session-resumption file mandate (User mandate, 2026-06-07)

Universal anchor inherited from `constitution/Constitution.md` §11.4.131. Every project MUST maintain a SINGLE canonical always-current session-resumption file — the OUT-OF-THE-BOX entry point. (Re)written whenever fresh session needed OR live state materially changes. Points to handoff docs, embeds live-state anchors. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.131.

### §11.4.132 — Risk-ordered validation priority mandate (User mandate, 2026-06-07)

Universal anchor inherited from `constitution/Constitution.md` §11.4.132. Tests/validations MUST run in RISK-DESCENDING order: most-recently-worked → historically-most-problematic → highest-crash-likelihood → most-reopened. Each highest-risk item GREEN with captured proof before the rest runs. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.132.

### §11.4.134 — Code-review iterate-until-GO + rock-solid-evidence mandate (User mandate, 2026-06-08)

Universal anchor inherited from `constitution/Constitution.md` §11.4.134. When code-review returns ANY finding, the review MUST BE RE-RUN after each remediation until a clean GO with ZERO new issues AND ZERO warnings. Every round carries rock-solid physical evidence. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.134.

### §11.4.135 — Standing regression-guard suite + every-fixed-defect-gets-a-permanent-regression-test (User mandate, 2026-06-08)

Universal anchor inherited from `constitution/Constitution.md` §11.4.135. Every project MUST maintain a standing regression-guard suite. Every closed defect MUST register a §11.4.115 RED-on-broken-artifact regression test. The suite runs FIRST in every post-deploy cycle and BLOCKS release tag on failure. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.135.

### §11.4.138 — Operator-escape ⇒ mandatory bluff-audit + permanent guard (User mandate, 2026-06-08)

Universal anchor inherited from `constitution/Constitution.md` §11.4.138. When the operator finds a defect the GREEN test suite passed, this is a §11.4 PASS-bluff — triggers systematic-debugging, a bluff-audit citing the exact assertion that should have caught it, a permanent regression guard, and the audit committed under `docs/research/`. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.138.

### §11.4.139 — Fresh-process clean-artifact runtime-signature mandate (User mandate, 2026-06-08)

Universal anchor inherited from `constitution/Constitution.md` §11.4.139. Before any post-deploy validation, the harness MUST assert `running-artifact == built-artifact` — deployment yields a CLEAN target OR pre-validation proves no stale overlay shadows the deployed code. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.139.

### §11.4.140 — Universal action-prefix system (User mandate, 2026-06-09)

Universal anchor inherited from `constitution/Constitution.md` §11.4.140. When a user prompt's FIRST non-blank line starts with a recognised action token (e.g. `BACKGROUND :: <rest>`), look up the action registry and REPLACE the prefix with the action's expansion text. Four equivalent forms. Unknown tokens matching the grammar are NEVER silently expanded — ask or treat literally. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.140.

### §11.4.141 — Token-efficiency mandate (User mandate, 2026-06-09)

Universal anchor inherited from `constitution/Constitution.md` §11.4.141. Every AI-coding-agent project MUST cut token spend 60–70% via: prompt-cache governance prefix, subagent model-tiering (Haiku for mechanical work), thin always-loaded index + on-demand detail, CodeGraph-first navigation, output-token reduction, tool-call batching. Measured proof with zero regression required. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.141.

### §11.4.142 — Universal code-review mandate — every change reviewed, always, no exception (User mandate, 2026-06-09)

Universal anchor inherited from `constitution/Constitution.md` §11.4.142. EVERY change — without exception — MUST pass through an INDEPENDENT code-review step BEFORE acceptance/commit/build. No "trivial change" or "doc edit" exemption. Reviewer structurally separate from author. Iterates to clean GO per §11.4.134. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.142.

### §11.4.143 — Real-user-journey mandate for video-streaming-app full-automation tests (User mandate, 2026-06-10)

Universal anchor inherited from `constitution/Constitution.md` §11.4.143. Every full-automation test asserting a video player / streaming app plays content MUST drive the REAL end-user journey — launch → catalog browse → specific-title selection → real Play/Resume press → confirm chosen content plays with correct subtitles. No shortcuts/samples/deep-links. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.143.

### §11.4.144 — Tracked/recorded-device availability-following mandate (User mandate, 2026-06-10)

Universal anchor inherited from `constitution/Constitution.md` §11.4.144. Every tracked/recorded device MUST be availability-FOLLOWED — connection state monitored, any drop logged as an honest offline event → wait → re-attach → escalate. A silent corpus hole is a §11.4 PASS-bluff. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.144.

### §11.4.145 — Independent multi-angle impact-research per change (User mandate, 2026-06-10)

Universal anchor inherited from `constitution/Constitution.md` §11.4.145. For EVERY change, INDEPENDENT impact-research agents MUST research across 8 CLOSED-SET angles: correctness/logic, regression, latent/dangerous-code, security, performance, host/data/target-hardware safety, cross-feature interaction, business-logic conformance. Output = GO/NO-GO; iterates to clean GO. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.145.

### §11.4.146 — Reproduce-first test + same-test-confirms-fix + mandatory extend-to-all-cases workflow (User mandate, 2026-06-10)

Universal anchor inherited from `constitution/Constitution.md` §11.4.146. Three-step workflow: (STEP 1) RED test as §11.4.115 reproduce-first + forensic characterisation; (STEP 2) SAME test `RED_MODE=1→0` GREEN confirmation; (STEP 3) fan-out across full case-space with enumerated coverage. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.146.

### §11.4.147 — Crashed-agent respawn-until-complete + no-work-loss registry mandate (User mandate, 2026-06-10)

Universal anchor inherited from `constitution/Constitution.md` §11.4.147. Every dispatched agent MUST be tracked through its full lifecycle (durable registry with CLOSED SET statuses: dispatched/in-flight/crashed/respawned/complete). Crash ≠ done — mechanical respawn until complete. Partial state preserved → quiescence-checked → resume-or-clean-restart. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.147.

### §11.4.148 — Workable-item integrity (status+type+id) + comprehensive structured description + bidirectional external-tracker sync (User mandate, 2026-06-10)

Universal anchor inherited from `constitution/Constitution.md` §11.4.148. No item without valid status+type+stable id on ALL surfaces. Comprehensive structured description mandatory. BLOCKED items carry WHY + enumerated unblock choices. Regular bidirectional DB↔docs↔tracker sync via idempotent push. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.148.

### §11.4.149 — Per-workable-item testing-diary mandate (User mandate, 2026-06-10)

Universal anchor inherited from `constitution/Constitution.md` §11.4.149. Every workable item carries an append-only TESTING DIARY (date_time, tested_by, result, observations, evidence_path). PASS requires non-empty evidence path (schema constraint). Four-format exports + tracker SUB-TASK model. Minimal-LLM deterministic tooling. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.149.

### §11.4.150 — Mandatory deep multi-angle web research per change/issue (User mandate, 2026-06-11)

Universal anchor inherited from `constitution/Constitution.md` §11.4.150. For EVERY fix/improvement/closure, perform a documented deep multi-angle web research pass (≥2 distinct angles). No closure-as-fixed/structural WITHOUT documented pass. Latest-source cited. Run in parallel with main stream. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.150.

### §11.4.151 — Project-prefixed release-tag/version-naming mandate (User mandate, 2026-06-12)

Universal anchor inherited from `constitution/Constitution.md` §11.4.151. Every release tag and version name MUST be prefixed `<PREFIX>-<version>`. Prefix resolution: `HELIX_RELEASE_PREFIX` from `.env` (authoritative) else lowercased project-root dir name. SAME prefix across main repo + all owned submodules in one release. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.151. (Note: this project's current tag history uses `vN.N.N` without prefix — operator decision to adopt prefix deferred to a future major release.)

### §11.4.152 — Crashlytics-recorded-data continuous monitoring + systematic-debug + regression-test-coverage mandate (User mandate, 2026-06-13)

Universal anchor inherited from `constitution/Constitution.md` §11.4.152. Every project with Firebase Crashlytics enabled MUST continuously monitor ALL four surfaces (fatal crashes, ANRs, performance traces, non-fatals), systematic-debug each, and cover every closed issue with a permanent §11.4.135 regression guard. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.152.

### §11.4.153 — Comprehensive per-feature Status + Status_Summary document set with mandatory video-recording confirmation (User mandate, 2026-06-15)

Universal anchor inherited from `constitution/Constitution.md` §11.4.153. Every project MUST maintain under `docs/features/` a comprehensive feature Status set enumerating EVERY component/app/surface/feature. Per-feature fields include Video-recording confirmation (path to real-use video). Four-format export (HTML+PDF+DOCX). **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.153.

### §11.4.154 — Window-scoped capture + fresh-corpus rotation for feature/QA recordings (User mandate, 2026-06-15)

Universal anchor inherited from `constitution/Constitution.md` §11.4.154. Every video MUST capture ONLY the target app/service window, NEVER the whole desktop. Fresh-corpus rotation: remove agent's own prior in-scope stale recordings before new recording begins. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.154.

### §11.4.155 — Project-name-prefixed feature/QA recording filenames (User mandate, 2026-06-15)

Universal anchor inherited from `constitution/Constitution.md` §11.4.155. Every recording filename MUST start with the project-name prefix (from `HELIX_RELEASE_PREFIX` or lowercased project-root dir). Format: `<PREFIX>---<feature>---<run-id>.<ext>`. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.155.

### §11.4.156 — All CI/CD automation MUST be disabled (User mandate, 2026-06-15)

Universal anchor inherited from `constitution/Constitution.md` §11.4.156. All governed repos MUST ship with ALL server-side CI/CD automation DISABLED — no live `.github/workflows/*.yml` or `.gitlab-ci.yml` in any authored repo. Enforcement via local git hooks + pre-tag sweep. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.156.

### §11.4.157 — GEMINI.md maintained in lockstep with CLAUDE.md / AGENTS.md / QWEN.md (User mandate, 2026-06-15)

Universal anchor inherited from `constitution/Constitution.md` §11.4.157. GEMINI.md is a FIRST-CLASS governance carrier EQUAL to CLAUDE.md/AGENTS.md/QWEN.md — no governance change is complete until GEMINI.md carries it alongside the other three mirrors. No silent drift. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.157.

### §11.4.158 — Intensive all-feature/flow/edge-case video-recording + read-the-screen content-verification mandate (User mandate, 2026-06-16)

Universal anchor inherited from `constitution/Constitution.md` §11.4.158. Every project MUST be covered by intensive automated testing that exercises + RECORDS every feature/flow/use-case/edge-case. The System MUST ACTUALLY READ every shown log line/message and VERIFY it is a genuine working result. HelixQA drives the exercise→record→read→score pass. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.158.

### §11.4.159 — Mandatory window-specific video recording + vision validation mandate (User mandate, 2026-06-20)

Universal anchor inherited from `constitution/Constitution.md` §11.4.159. Every feature test/validation/QA session producing video MUST: window-specific capture only, MP4 format (H.264), project-name prefixed, mandatory vision validation after recording with content-verification workflow (SPECIFY→RECORD→EXTRACT→VERIFY→ACCEPT/REJECT). **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.159.

### §11.4.160 — Vision-verified recording + HelixQA bridge mandate (User mandate, 2026-06-21)

Universal anchor inherited from `constitution/Constitution.md` §11.4.160. Every video recording MUST be processed through a vision/OCR pipeline against SPECIFY-phase patterns before acceptance. Bridge to HelixQA for automated verification (≤5s frame interval, self-validated analyzer). **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.160.

### §11.4.161 — Rootless container runtime mandate (User mandate, 2026-06-21)

Universal anchor inherited from `constitution/Constitution.md` §11.4.161. Every project MUST use Podman in rootless mode for ALL containerized workloads. The `vasic-digital/containers` Submodule is the sole container orchestration layer; extend upstream, never reimplement. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.161. (This project's `Containers/` submodule already complies.)

### §11.4.162 — OpenDesign UI design system mandate (User mandate, 2026-06-21)

Universal anchor inherited from `constitution/Constitution.md` §11.4.162. Every project producing user-facing interfaces MUST use OpenDesign as the mandatory UI design-and-refinement system — design tokens for color (light+dark), typography, spacing, component-level tokens. Extend upstream per §11.4.74. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.162.

### §11.4.163 — Universal Media Validation & Verification Mandate (User mandate, 2026-06-21)

Universal anchor inherited from `constitution/Constitution.md` §11.4.163. Every recorded artifact MUST pass a MEDIA VALIDATION pipeline before acceptance — OCR/transcription/text parsing vs expected patterns, self-validated golden-good/golden-bad analyzer. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.163.

### §11.4.164 — Universal Constitution Auto-Propagation & Hook System (User mandate, 2026-06-21)

Universal anchor inherited from `constitution/Constitution.md` §11.4.164. Every constitution fetch+pull MUST trigger `constitution/scripts/post_update_hook.sh` (inherited by reference, NEVER copied) that detects changed files, registers new skills/MCP/hooks/scripts, validates syntax. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.164.

### §11.4.165 — Universal Independent Verification Agent Mandate (User mandate, 2026-06-21)

Universal anchor inherited from `constitution/Constitution.md` §11.4.165. Every code change OR recorded media artifact MUST pass an INDEPENDENT verifier structurally separate from the author, producing structured findings with evidence paths, iterating to GO per §11.4.134. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.165.

### §11.4.166 — REPEALED (operator decision, 2026-06-22)

The Universal Semgrep static-analysis mandate is repealed — Semgrep no longer mandatory. Anchor 11.4.166 retired.

### §11.4.167 — Big-work-item feature work-stream lifecycle (User mandate, 2026-06-23)

Universal anchor inherited from `constitution/Constitution.md` §11.4.167. Every BIG work item MUST be developed as its own isolated feature work-stream — CoW/reflink sibling copy, own `feature/<slug>` branch, own per-feature builds + tags, kept separate from trunk until operator approves. Trunk merged INTO every live stream frequently. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.167.

### §11.4.168 — Exported-document independent content + textual + full-visual validation mandate (User mandate, 2026-06-23)

Universal anchor inherited from `constitution/Constitution.md` §11.4.168. Every exported document MUST pass INDEPENDENT validation across THREE layers: (1) CONTENT — faithful, (2) TEXTUAL — no raw diagram-source as body text, (3) FULL VISUAL — embedded diagrams render as images. Self-validated analyzer per §11.4.107(10). **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.168.

### §11.4.169 — Mandatory comprehensive test-type coverage with anti-bluff captured evidence (User mandate, 2026-06-25)

Universal anchor inherited from `constitution/Constitution.md` §11.4.169. Every project MUST have this CLOSED enumerated test-type set aiming 100% coverage: unit, integration, e2e, full-automation, Challenges, HelixQA, DDoS/load-flood, security, stress+chaos, concurrency/atomicity, race-condition/deadlock, memory, benchmarking/performance. Each PASS cites §11.4.5/.69/.107 physical evidence. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.169.

### §11.4.170 — Device-independent host-side rendered-UI visual-proof mandate (User mandate, 2026-06-25)

Universal anchor inherited from `constitution/Constitution.md` §11.4.170. Every UI change MUST be proven by host-side rendered pixels (Compose→Roborazzi/Paparazzi, web→Playwright, SwiftUI→snapshot) for EVERY screen×state×{light,dark} theme. VALUE/token-equality UI tests FORBIDDEN as proof. Self-validated analyzer. "Device offline" is NEVER a valid skip. **Canonical authority:** constitution submodule [`Constitution.md`](constitution/Constitution.md) §11.4.170.

---

*This Project Constitution governs the `vasic-digital/tmux` repository.
It is subordinate to and extends `constitution/Constitution.md`.*
