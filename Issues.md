# vasic-digital tmux — Open Issues Tracker

> **Canonical source of truth for everything currently unfinished, partially
> validated, or at risk of violating the anti-bluff covenant
> (`Constitution.md` §1 + §11.4.1 through §11.4.6).**
>
> Every PASS in this codebase MUST carry positive evidence captured live
> that the feature works for the end user. Metadata-only PASS,
> configuration-only PASS, "absence-of-error" PASS, and grep-based PASS
> without runtime evidence are all critical defects regardless of how
> green the summary line looks. **Tests AND HelixQA Challenges are bound
> equally.**
>
> Forensic anchor — direct user mandate (verbatim, 2026-04-28 +
> 2026-05-07 + 2026-05-08, repeatedly reasserted from upstream
> `vasic-digital` projects):
>
> > "We had been in position that all tests do execute with success
> > and all Challenges as well, but in reality the most of the
> > features does not work and can't be used! This MUST NOT be the
> > case and execution of tests and Challenges MUST guarantee the
> > quality, the completion and full usability by end users of the
> > product!"
>
> §11.4.6 forensic anchor (verbatim, 2026-05-08):
>
> > "'LIKELY' is guessing, we MUST NOT have guessing, since it can
> > be or may not be! No bluffing and uncertainity is allowed at any
> > cost! We MUST always know exactly precisly what is happening
> > exactly, in any context, under any conditions, everywhere!"

**Compiled:** 2026-05-08 (Phase B per-session-containerization cycle).
**Author:** Engineering coordinator
**Working pool source:** the items below feed the active task list directly.
Each item carries a current state, the captured-evidence requirement,
and a fix-direction proposal so future-self can resume cold.

> **Migration policy** (mirrors upstream `vasic-digital` projects):
> resolved items are moved to **[`Fixed.md`](Fixed.md)** in the same
> commit that closes them. **`Issues.md` holds OPEN / PARTIAL /
> BLOCKED / RUNNING / INVESTIGATED only**; once an item is closed and
> verified end-to-end, it migrates to `Fixed.md` and disappears from
> here. Never delete items outright — history matters for cold-start
> handover.

---

## Document conventions

| Code | Meaning |
|---|---|
| `OPEN` | Unfinished work; needs implementation + anti-bluff coverage |
| `PARTIAL` | Implementation exists but coverage gaps remain (positive evidence missing or environmental SKIP unresolved) |
| `BLOCKED` | Cannot progress without external dependency (host capability, third-party tool, distro support, etc.) |
| `RUNNING` | In-flight in this session (background process, ongoing test cycle) |
| `INVESTIGATED` | Forensic investigation produced findings; closure pending decision on fix scope |

**Status reclassification rules (§11.4.6 enforced):**

- A `PARTIAL` may not move to closed without runtime evidence
  (`/sys/fs/cgroup/.../memory.max` readback, `systemctl status` showing
  scope active, `kill -9` survivor proof — never just script exit code).
- A `BLOCKED` reclassifies to `OPEN` when the blocking dependency
  resolves; it must NOT skip directly to closed.
- An `INVESTIGATED` item must record the captured forensic trace
  (file path / command output / log timestamp) — never speculation
  ("likely" / "probably" / "appears to" — see Constitution §11.4.6).

Categories:

* **A** — Tooling / harness gaps
* **B** — Anti-bluff completeness across the existing test surface
* **C** — Per-session containerization features pending evidence
* **D** — Host-capability + topology dispatch gaps
* **E** — Documentation / Continuation drift

---

## A. Tooling / harness gaps

### A2 RUNALL-NATIVE-RESOLVE-001 — standalone run_all.sh mis-resolves the binary on native macOS

**Status:** Queued
**Type:** Task

`scripts/tests/run_all.sh` hardcodes `TMUX_BIN=tmux/build/bin/tmux` (the
`build_containerized.sh` output path) and is the containerized-build validator. On
native macOS the authoritative validator is `setup.sh` (builds + verifies against
`tmux/build-darwin/`). Invoked standalone on macOS with a stale `tmux/build/` present
(a prior Linux containerized build), run_all.sh resolved the wrong-arch binary →
`Exec format error` mass-FAIL (observed 2026-06-16; NOT a product defect — `setup.sh`
run_all `55/0/6` + installed-binary smoke GREEN the same session; removing the stale
`tmux/build/` then gave `not executable` because run_all expects that path). **Fix
direction:** make run_all.sh OS-aware (prefer `tmux/build-darwin/` on Darwin) OR
document that native-macOS validation is `setup.sh`-only and run_all.sh is the
containerized path. Captured-evidence requirement: a clean native-macOS run_all GREEN
after the fix.

---

## B. Anti-bluff completeness across the existing test surface

(none open at this time — B3 P5-M20/P5-M21 escapes CLOSED in v1.0.16
[tests 49/50 + meta-test retarget], state-verified 2026-05-29 with
`MUTATIONS CAUGHT 45 / ESCAPED 0`, and migrated to `Fixed.md` §B3;
B1 CHAL-COVER-001, B2 TEST-AUDIT-001 also landed in `Fixed.md`.)

---

## C. Per-session containerization features pending evidence

(none open at this time — C1 TMX-T5, C2 TMX-T7, C3 TMX-T8 landed in `Fixed.md`.)

---

## D. Host-capability + topology dispatch gaps

### D2 TMPDIR-HARDCODE-001 — tests hardcoding /tmp false-FAIL under host disk-pressure

**Status:** Queued
**Type:** Task

Several tests create scratch under a hardcoded `/tmp` (e.g. `27_state_persistence.sh`
target `tmx-test-18-target-*`). When the host root volume is full (observed 2026-06-16
on macOS, `/` at <200 MiB during the operator's away-window), the `cd`/mkdir into `/tmp`
fails → `pane_current_path=''` false-FAIL instead of an honest §11.4.3 SKIP-with-reason.
The tests pass normally + standalone (27 `3/3`, 38 `3/3`, 43 `15/0` re-run the same
session) — the failure is purely the abnormal host-disk condition (a §11.4.1 FAIL-bluff
class: environment, not product). **Fix direction:** route test scratch through `$TMPDIR`
(operator now sets `/Volumes/T7/tmp` via ~/.zshrc + ~/.bashrc) OR guard each test on
`/tmp` writability and SKIP-with-reason (§11.4.3/§11.4.50). Captured-evidence requirement:
an induced-disk-full run shows SKIP-with-reason, not FAIL.

---

## E. Documentation / Continuation drift

(none open at this time; CONTINUATION.md §3 entries that resolve land in `Fixed.md` per Constitution §5 / §12.10.)

---

## F. Runtime crash — operator-gated reproduction

(none open — F1 `tmx` session named "HelixCode" crashes the whole terminal RESOLVED 2026-06-13, operator-confirmed, migrated to `Fixed.md` A45 with reproduced root cause [stale wrapper `TMUX_BIN` pointing at a non-existent prior-checkout path → `exec` of missing binary → login shell dies → terminal closes] + 4-layer regression guard [test 60 + verify gate `CM-TMX-WRAPPER-TMUXBIN-VALID` + meta `M-WRAPPER-TMUXBIN`]).

---

**Last reviewed:** 2026-06-17 (v1.0.25 RELEASED; A49 test-17 flake closed to `Fixed.md`.
Two minor Queued robustness Tasks added from the v1.0.25 cycle: A2 RUNALL-NATIVE-RESOLVE-001
[run_all.sh containerized-path vs native-macOS binary resolution] + D2 TMPDIR-HARDCODE-001
[tests hardcoding /tmp false-FAIL under host disk-pressure → should SKIP-with-reason / use
$TMPDIR]. Both are environment/tooling robustness gaps, NOT product defects — the tmux
product + all feature tests pass normally on both hosts.)

---

### M24-ESCAPE-001 — meta-test M24 (hostname 4-surface color) escapes: test 26 misses a 3-set-line removal

**Status:** OPEN
**Type:** Bug
**Severity:** Minor (test-coverage gap, no user-facing break — hostname color still applies via the surviving set-lines; but the paired-mutation guarantee is incomplete)

**What:** The §1.1 paired-mutation `M24` in `scripts/tests/meta_test_false_positive_proof.sh` removes three of the four `tmux set -g …` lines in `_apply_host_color()` and expects test 26 to FAIL. The harness reports `MUTATION ESCAPED` — test 26 does not FAIL, because it asserts only a subset of the four surfaces, so removing the un-asserted set-lines leaves the test green.

**Evidence:** `bash scripts/tests/meta_test_false_positive_proof.sh 2>&1 | grep M24` → `FAIL: M24: MUTATION ESCAPED — test 26 did not FAIL with the three set-lines removed`. Confirmed pre-existing (M24 added in commit `f151d13`, v1.0.9 — before the per-session-color feature). Surfaced 2026-06-19 during the per-session-color M25/M26 verification run.

**Fix direction:** strengthen test 26 to assert ALL FOUR surfaces (`status-style`, `pane-active-border-style`, `clock-mode-colour`, `window-status-current-style`) so the M24 mutation (removing any 3) reliably FAILs it — mirroring the all-4-surfaces assertion already proven in test 63 T3 for the per-session path. (This also closes the symmetry gap: the per-session path has a 4-surface guard; the hostname path should too.)

**Out of scope:** the per-session-color feature (ATM-051). Tracked separately so the color release is not blocked by an unrelated pre-existing test-gap.
