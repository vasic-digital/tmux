# vasic-digital tmux — Closed Items Tracker

> **Canonical record of every issue that has been fixed AND verified
> with captured runtime evidence.** Companion to
> [`Issues.md`](Issues.md) (open / in-flight items).
>
> Per upstream `vasic-digital` consistency mandate (2026-05-05):
> - **`Issues.md`** holds OPEN, PARTIAL, BLOCKED, RUNNING,
>   INVESTIGATED items.
> - **`Fixed.md`** holds RESOLVED items with the closure commit, the
>   captured-evidence path, and the regression-protection hook
>   (paired mutation in `meta_test_*.sh` per Constitution §11.4.1
>   when applicable).
> - When an item resolves: move it from `Issues.md` to `Fixed.md` in
>   the same commit. Never let a resolved item linger in
>   `Issues.md`. Never delete it outright (history matters for
>   cold-start handover).
>
> Forensic anchor — direct user mandate (verbatim, 2026-04-28 +
> 2026-05-05 + 2026-05-07 + 2026-05-08, propagated from upstream
> `vasic-digital` projects):
>
> > "We had been in position that all tests do execute with success
> > and all Challenges as well, but in reality the most of the
> > features does not work and can't be used! This MUST NOT be the
> > case... MUST guarantee the quality, the completion and full
> > usability by end users... We MUST HAVE full consistency! All
> > fixed and verified items MUST BE moved into Fixed.md... We MUST
> > BE precise, consistent and punctual!"
>
> §11.4.6 forensic anchor (verbatim, 2026-05-08):
>
> > "'LIKELY' is guessing, we MUST NOT have guessing, since it can
> > be or may not be! No bluffing and uncertainity is allowed at any
> > cost! We MUST always know exactly precisly what is happening
> > exactly, in any context, under any conditions, everywhere!"

**Initial compilation:** 2026-05-08 (governance bring-up cycle).

---

## Document conventions

| Field | Meaning |
|---|---|
| **Closure cycle** | Which Phase / version landed the fix |
| **Closure commit** | Git SHA where the fix was committed (this repo) |
| **Source-side fix** | The change at the helper-library / wrapper / test source — never patched in call sites (Constitution §11.4.1) |
| **Captured evidence (4-layer)** | (a) pre-build / static-source check, (b) runtime test producing positive artifact, (c) Challenge entry, (d) paired mutation — for tmux scope, layers (c) and (d) are PENDING per Issues.md A1 / B1 |
| **Regression-protection** | Pre-build gate name + paired mutation name in `scripts/tests/meta_test_*.sh` (when META-MUT-001 lands) |
| **Tracked task** | The Issues.md ID before migration |

---

## A. Tooling / harness gaps — RESOLVED

### A0. Initial migration from ATMOSphere project to standalone `vasic-digital/tmux` repo

* **Closure cycle:** 2026-05-07 (initial standalone repo bring-up).
* **Closure commit:** `08d4ba5` ("Initial vasic-digital/tmux —
  migrated from ATMOSphere project + per-session containerization
  plan + 8-test verification gate").
* **Source-side fix:** carved out `scripts/tmux/`,
  `docker/Dockerfile.tmux-build`, `docs/guides/TMUX_OPTIMIZED_BUILD.md`
  from ATMOSphere; agnostic-ized (zero ATMOSphere / Android-15 /
  atmosphere-tmux references remain in the migrated tree); added
  `tmux/` submodule pinned to upstream tag `3.6a` and `Containers/`
  submodule pointing at `vasic-digital/Containers`.
* **Captured evidence:** `scripts/verify.sh` 8-test suite returned
  6 PASS / 0 FAIL / 2 honest SKIP against ATMOSphere host on
  2026-05-07 (CONTINUATION.md §1 snapshot).
* **Regression-protection:** `scripts/verify.sh` is the gate; failed
  verification refuses to install per Constitution §4.
* **Tracked task:** initial migration ticket (CONTINUATION.md §3.1).

---

## B. Anti-bluff completeness — RESOLVED

### B0. Constitution §1 covenant verbatim user-mandate quote propagated

* **Closure cycle:** 2026-05-08.
* **Closure commit:** `b92bf7f` ("1.1.x — §1 anti-bluff covenant
  verbatim user-mandate quote added to Constitution.md / CLAUDE.md /
  AGENTS.md (per upstream vasic-digital projects 2026-04-28 +
  2026-05-07 + 2026-05-08 mandate)").
* **Source-side fix:** verbatim quote landed in
  `Constitution.md` §1, `CLAUDE.md`, `AGENTS.md`. Test 09
  `09_crash_isolation_scope.sh` authored to §1 standard from line
  one (positive evidence from `/sys/fs/cgroup`).
* **Captured evidence:** Test 09 run on this host on
  2026-05-08T11:25 MSK returned 14 PASS / 0 FAIL / 0 SKIP. T3
  `memory.max` readback = 268435456 bytes (matches set 256M); T3
  `cpu.max` readback = `50000 100000` (50% quota over 100ms period);
  T4 SIGKILL containment verified by reading `cgroup.procs` MainPID
  pre-kill, sending SIGKILL, observing scope inactive post-kill,
  observing `default.target=active` throughout (user.slice survival
  is the load-bearing §1 invariant).
* **Regression-protection:** PENDING — Issues.md A1 (META-MUT-001)
  tracks the paired-mutation harness that will lock this guarantee
  in. Until that lands, the regression check is the human-readable
  test 09 source itself.
* **Tracked task:** CONTINUATION.md §3.3 (test-09 landing).

---

## C. Per-session containerization features — RESOLVED

### C0. Test 09 crash-isolation-scope landed and green

* **Closure cycle:** 2026-05-08.
* **Closure commit:** `b92bf7f` (same commit as B0; landed in one
  cycle).
* **Source-side fix:** `scripts/tests/09_crash_isolation_scope.sh`
  is a 4-section invariant verifier:
  - **T1 (host capability):** systemd v258 + cgroup v2 unified
    mount confirmed.
  - **T2 (wrapper invariants):** `tmx` wrapper invokes
    `systemd-run --user --scope` with `MemoryMax=$TMX_MEM`,
    `CPUQuota=$TMX_CPU`, `TasksMax=4096`, `Delegate=yes`.
  - **T3 (cgroup interface evidence):** transient scope created;
    `/sys/fs/cgroup/.../memory.max` and `/sys/fs/cgroup/.../cpu.max`
    read back the configured values — POSITIVE EVIDENCE per §1
    covenant.
  - **T4 (SIGKILL containment):** spawn scope, read MainPID from
    `cgroup.procs`, SIGKILL it, verify scope inactive AFTER kill,
    verify `default.target=active` THROUGHOUT (user.slice survives).
  - **T6 (concurrent independence-registration):** 3 concurrent
    scopes registered + active simultaneously.
  Updated `scripts/tests/run_all.sh` glob to `0[1-9]_*.sh` so
  test 09 is part of the suite by default.
* **Captured evidence:** 14 PASS / 0 FAIL / 0 SKIP on 2026-05-08T11:25
  MSK (host: operator's daily driver, systemd 258, cgroup v2).
* **Regression-protection:** PENDING META-MUT-001 (Issues.md A1).
* **Tracked task:** CONTINUATION.md §3.3.

---

## D. Migration history — INFORMATIONAL

* **2026-05-07:** Repo carved out of ATMOSphere project (parent at
  `/run/media/milosvasic/DATA4TB/Projects/Android_15/`). New repo
  at `~/Projects/tmux/` + GitHub `vasic-digital/tmux` + GitLab
  `vasic-digital/tmux`.
* **2026-05-08:** §1 anti-bluff covenant verbatim quote added.
  Test 09 (crash-isolation-scope) landed.
* **2026-05-08 (this cycle):** Issues.md and Fixed.md created;
  Constitution explicit §11.4.1 through §11.4.6 anchors added; §9
  / §12.6 / §12.10 anchors added; CLAUDE.md / AGENTS.md updated to
  match.

---

**Last reviewed:** 2026-05-08 (governance bring-up cycle).
