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

**Status:** Fixed (→ Fixed.md)
**Type:** Task

CLOSED v1.0.27. `scripts/tests/run_all.sh` hardcodes `TMUX_BIN=tmux/build/bin/tmux` (the
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

### A50 GO-TOOLCHAIN-OBTAIN-001 — obtain Go toolchain locally for the tmx-state + workable-items Go build — `OPEN`

**TMX-ID:** TMX-057
**Status:** `OPEN`
**Type:** Task
**Severity:** MEDIUM

On hosts lacking a system Go toolchain (e.g. `amber`), the `scripts/tmx-state/` and
`cmd/workable-items/` Go binaries cannot be (re)built — blocking per-session cwd
persistence AND the §11.4.93 workable-items SSoT tooling. **Fix direction:** extend the
existing §11.4.77 local-deps mechanism (`obtain_local_deps.sh`, which already
sha256-obtains libevent 2.1.12 + ncurses 6.5 into git-ignored `.local-deps/`) to
resolve-or-obtain a pinned Go toolchain into `.local-deps/`, consumed by the Go build
steps via `GOROOT`/`PATH`. **Acceptance:** on a host with no system `go`, a clean
`go build ./cmd/workable-items` succeeds against the obtained local toolchain (exit 0;
control without it → `go: command not found`).

### A54 NO-SUDO-PROJECTWIDE-FOLLOWUP-001 — convert print-only sudo/setcap hints outside the install path and extend the no-sudo gate project-wide — `OPEN`

**TMX-ID:** TMX-064
**Status:** `OPEN`
**Type:** Task
**Severity:** MEDIUM

Follow-up to TMX-062: convert the remaining print-only `sudo`/`setcap` hints OUTSIDE the install path (`scripts/build_oom_set.sh`, `scripts/test_vm.sh`, `scripts/tests/08_oom_score_adj.sh`, and the `scripts/oom_set.c` comment) to "(as root)" phrasing, and extend the no-sudo gate project-wide so it detects `sudo`/`su` EXECUTION rather than mere mention. Status Queued. Acceptance: project-wide 0 `sudo`/`su` execution paths, and the gate is scoped to flag execution only — no false positives on legitimate "(as root)" documentation strings.

---

## B. Anti-bluff completeness across the existing test surface

(Prior B-items closed: B3 P5-M20/P5-M21 escapes CLOSED in v1.0.16
[tests 49/50 + meta-test retarget], state-verified 2026-05-29 with
`MUTATIONS CAUGHT 45 / ESCAPED 0`, migrated to `Fixed.md` §B3 as TMX-054;
B1 CHAL-COVER-001, B2 TEST-AUDIT-001 also in `Fixed.md`. New open work below.)

### B50 TEST-COVERAGE-G1-G5-001 — close test-coverage gaps G1-G5 for the v1.0.30 cross-platform install hardening — `OPEN`

**TMX-ID:** TMX-059
**Status:** `OPEN`
**Type:** Task
**Severity:** MEDIUM

v1.0.30 added native-build fallback (`setup.sh`), `build_native.sh` local-deps wiring
(`-I`/`-L` + `PKG_CONFIG_PATH`), `obtain_local_deps.sh` libevent/ncurses obtain, and the
escaped-colon session-color fix; the CHANGELOG tracks "test-coverage gaps G1-G5" but they
are NOT yet enumerated distinctly nor each covered by an anti-bluff test + paired §1.1
mutation. **Fix direction:** first enumerate G1-G5 precisely, then add four-layer coverage
(§11.4.4(b)) for each. **Acceptance:** each of G1-G5 has a named runtime test with captured
evidence PLUS a paired meta-test mutation that FAILs when its guard is stripped.

### B51 DB-FIXEDMD-SSOT-DRIFT-001 — reconcile DB↔Fixed.md SSoT drift (Fixed.md A46-A49 absent from the items table) — `INVESTIGATED`

**TMX-ID:** TMX-060
**Status:** `Ready for testing`
**Type:** Task
**Severity:** MEDIUM

The §11.4.93 workable-items DB is missing four RESOLVED `Fixed.md` entries — A46 (libtinfo
version warning), A47 (test-harness timing races), A48 (distribution orchestrator binary),
A49 (test 17 scrollback load flake). A full `md-to-db` over `Fixed.md` reports
`inserted=4 updated=1 allocated=4`, proving the items table never captured them (the
CHANGELOG names this "DB↔Fixed.md SSoT drift" as a tracked follow-up). **Fix direction:**
reconcile carefully — confirm none are reworded duplicates of an existing id before
allocating, identify the `updated=1` item, then sync so `validate` + `diff` stay clean.
**Acceptance:** `md-to-db` over the full corpus reports `inserted=0 updated=0` (idempotent)
and `validate` is 0-findings.
**Reconcile (2026-06-29, this session):** ran `sync md-to-db` over the full corpus — the
four entries ingested as TMX-067 (A49 → Completed), TMX-068 (A48 → Implemented), TMX-069
(A46 → Fixed) and TMX-070 (A47 → Fixed); the `updated=1` item was TMX-045 ("Per-host-topology
dispatch probe") whose stored `raw_body` was stale (2140→7648 chars) and was refreshed from
the current `Fixed.md` — no other field changed, so it is not a reworded duplicate. The run
also re-captured the stale `document_sources[Fixed]` so a future `db-to-md` no longer
regresses `Fixed.md`. A second `md-to-db` reports `inserted=0 updated=0` (idempotent) and
`validate` is 0-findings — pending conductor verification + close.

---

## C. Per-session containerization features pending evidence

(none open at this time — C1 TMX-T5, C2 TMX-T7, C3 TMX-T8 landed in `Fixed.md`.)

---

## D. Host-capability + topology dispatch gaps

### D2 TMPDIR-HARDCODE-001 — tests hardcoding /tmp false-FAIL under host disk-pressure

**Status:** Fixed (→ Fixed.md)
**Type:** Task

CLOSED v1.0.27. Several tests create scratch under a hardcoded `/tmp` (e.g. `27_state_persistence.sh`
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

(CONTINUATION.md §3 entries that resolve land in `Fixed.md` per Constitution §5 / §12.10. New open work below.)

### E50 INSTALL-DOC-PODMAN-HTTPS-001 — document the rootless-Podman subuid fix and the curl-installer HTTPS-rewrite edge — `OPEN`

**TMX-ID:** TMX-058
**Status:** `OPEN`
**Type:** Task
**Severity:** LOW

v1.0.30 shipped a native-build fallback when rootless Podman exhausts `/etc/subuid` +
`/etc/subgid` (`lchown … invalid argument`) and a `curl` one-liner installer, but the
operator-facing repair guidance lives only in the CHANGELOG. **Fix direction:** document the
`usermod --add-subuids/--add-subgids` + `podman system migrate` repair recipe AND the
install HTTPS-rewrite edge in `docs/guides` + `docs/scripts` so an end user hitting either
can self-recover. **Acceptance:** a docs page (synced HTML/PDF per §11.4.65) reproduces the
repair steps, verified against the v1.0.30 `setup.sh` fallback path.

---

## F. Runtime crash — operator-gated reproduction

(none open — F1 `tmx` session named "HelixCode" crashes the whole terminal RESOLVED 2026-06-13, operator-confirmed, migrated to `Fixed.md` A45 with reproduced root cause [stale wrapper `TMUX_BIN` pointing at a non-existent prior-checkout path → `exec` of missing binary → login shell dies → terminal closes] + 4-layer regression guard [test 60 + verify gate `CM-TMX-WRAPPER-TMUXBIN-VALID` + meta `M-WRAPPER-TMUXBIN`]).

---

**Last reviewed:** 2026-06-19 (v1.0.27 WIP burn-down. §11.4.138 operator-escape A51
[name:color prompt rejection] FIXED — shell-init + SSH-dispatcher char-set now
allows `:` and `#`, max-length 64→80; test 65 operator-escape guard PASS=6/6.
M24/A2/D2 in parallel streams per §11.4.103.)

---

### M24-ESCAPE-001 — meta-test M24 (hostname 4-surface color) escapes: test 26 misses a 3-set-line removal

**Status:** Fixed (→ Fixed.md)
**Type:** Bug
**Severity:** Minor (test-coverage gap, no user-facing break — closed v1.0.27: `count=1` removed from M24 regex → strips from BOTH `_apply_color` and `_apply_host_color`, test 26 now FAILs on the mutation → CAUGHT)
**Closure:** meta-test 37 CAUGHT / 0 ESCAPED (was 34 CAUGHT / 3 ESCAPED pre-fix)

**What:** The §1.1 paired-mutation `M24` in `scripts/tests/meta_test_false_positive_proof.sh` removes three of the four `tmux set -g …` lines in `_apply_host_color()` and expects test 26 to FAIL. The harness reports `MUTATION ESCAPED` — test 26 does not FAIL, because it asserts only a subset of the four surfaces, so removing the un-asserted set-lines leaves the test green.

**Evidence:** `bash scripts/tests/meta_test_false_positive_proof.sh 2>&1 | grep M24` → `FAIL: M24: MUTATION ESCAPED — test 26 did not FAIL with the three set-lines removed`. Confirmed pre-existing (M24 added in commit `f151d13`, v1.0.9 — before the per-session-color feature). Surfaced 2026-06-19 during the per-session-color M25/M26 verification run.

**Fix direction:** strengthen test 26 to assert ALL FOUR surfaces (`status-style`, `pane-active-border-style`, `clock-mode-colour`, `window-status-current-style`) so the M24 mutation (removing any 3) reliably FAILs it — mirroring the all-4-surfaces assertion already proven in test 63 T3 for the per-session path. (This also closes the symmetry gap: the per-session path has a 4-surface guard; the hostname path should too.)

**Out of scope:** the per-session-color feature (TMX-051). Tracked separately so the color release is not blocked by an unrelated pre-existing test-gap.
