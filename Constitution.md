# vasic-digital tmux — Repository Constitution

This repository is **fully decoupled** from any specific project (ATMOSphere, HelixCode, Catalogizer, etc.). It can be cloned and used standalone on any Linux host. The covenant below applies to this repo's own work.

---

## §1 Anti-bluff covenant — END-USER QUALITY GUARANTEE

**Forensic anchor — direct user mandate (verbatim, 2026-04-28 + 2026-05-07 + 2026-05-08, repeatedly reasserted):**

> "We had been in position that all tests do execute with success and all Challenges as well, but in reality the most of the features does not work and can't be used! This MUST NOT be the case and execution of tests and Challenges MUST guarantee the quality, the completion and full usability by end users of the product!"

This is the historical origin of the project's anti-bluff covenant — propagated from the upstream `vasic-digital` projects (ATMOSphere, HelixCode, Catalogizer, Yole, HelixPlay, HelixTranslate, HelixFlow, MeTube). Every test, every Challenge, every gate, every mutation pair in THIS repo exists to make the failure mode (PASS on broken-for-end-user feature) **mechanically impossible**.

> Every test, every Challenge, every gate, every mutation pair exists to make the failure mode (PASS on broken-for-end-user feature) **mechanically impossible**.

The bar for shipping is NOT "tests pass" but **"users can use the feature."** Every PASS in this codebase MUST carry positive evidence captured during execution that the feature works. Metadata-only PASS, configuration-only PASS, "absence-of-error" PASS, and grep-based PASS without runtime evidence are all critical defects regardless of how green the summary line looks.

**Tests AND Challenges are bound equally** — a Challenge that scores PASS on a non-functional feature is the same class of defect as a unit test that does. Both must produce positive end-user evidence.

**FAIL-bluffs equally forbidden.** A test that crashes for a script-internal reason (undefined variable, regex error, missing argument, missing dependency in PATH) and produces a FAIL exit code is just as misleading as a PASS-bluff. Both let real defects ship undetected. Fix at source layer (helper library, shared lib, test source), never patch in individual call sites.

**Recorded-evidence requirement.** Every PASS for a user-visible feature MUST be cross-checked by captured runtime artifact (e.g., `/proc/<pid>/maps`, `dumpsys`, `getprop`, terminal capture). A PASS that lacks runtime evidence is treated as a PASS-bluff.

**Test-interrupt-on-discovery.** The moment any defect is rediscovered, re-produced, or newly identified during a test cycle, the cycle MUST stop. Then: fix at root cause, land validation/verification tests for the fix (pre-build gate AND on-device test AND paired meta-test mutation), full rebuild, repeat full test cycle from the beginning.

---

### §11.4.1 — FAIL-bluffs equally forbidden (Phase 33, 2026-05-05)

A test that crashes for a script-internal reason (undefined variable
under `set -u`, regex error, malformed assertion, missing argument,
missing dependency in PATH) and produces a FAIL exit code is just as
misleading as a PASS-bluff. Both let real defects ship undetected.
Every test MUST fail ONLY for genuine product defects — script-bug
failures must be fixed at the source layer (helper library, shared
lib, test source), not patched in individual call sites.

This is the explicit numbered anchor for the FAIL-bluff rule already
restated in §1 prose.

### §11.4.2 — Recorded-evidence requirement (Phase 34, 2026-05-06)

Every PASS for a user-visible feature MUST be cross-checked against
captured runtime artifacts. For tmux scope, the captured artifacts are:

- `/sys/fs/cgroup/<scope>/memory.max` and `cpu.max` and `pids.max`
  read-backs (cgroup-v2 interface).
- `systemctl --user list-units --type=scope` + `is-active` output for
  scope lifecycle proof.
- `cgroup.procs` reading the spawned MainPID for membership proof.
- `dmesg | grep -i 'oom-kill'` plus the killed-PID line for OOM proof.
- `systemctl --user status default.target` reading `active` for
  user.slice survival proof.

A PASS that lacks at least one of these matched-to-the-claim artifacts
is treated as a §1 PASS-bluff.

### §11.4.3 — Per-host-topology test dispatch (adapted from §11.4.3)

Tests that depend on host-system topology (systemd version, cgroup v1
vs v2, distro-specific cgroup-controller availability, kernel
namespace-support flags, presence of `loginctl`/`systemd-run --user`)
MUST detect topology at test entry and dispatch the topology-
appropriate variant. A test running the wrong variant for the actual
topology and PASSing is a §1 PASS-bluff.

The wrapper at `scripts/tmx` already detects systemd v240+ and
cgroup-v2 unified hierarchy as a precondition — codified here as the
canonical dispatch seam. Tests on a host that lacks either MUST
SKIP-with-reason (recording the topology probe output as positive
evidence of the SKIP rationale), not silently degrade to no-isolation.

The same principle applies generically: distro family (Debian / Fedora
/ Arch / Ubuntu / Alpine), systemd version range, cgroup hierarchy,
and kernel-controller set form the dispatch matrix.

### §11.4.4 — Test-interrupt-on-discovery + 4-layer test coverage (User mandate, 2026-05-06)

Already restated in §1 prose. Explicit numbered anchor:

- **Layer 1:** pre-build / static-source check (gate that catches at
  source).
- **Layer 2:** runtime test producing positive artifact (anti-bluff
  per §1, captured-evidence per §11.4.2, topology-dispatched per
  §11.4.3).
- **Layer 3:** HelixQA Challenge entry (Challenge-driven dispatch — a
  bank entry without Challenge coverage is a §1 PASS-bluff).
- **Layer 4:** paired mutation in `meta_test_*.sh` proving the gate
  catches its own negation.

For tmux scope, layers 1, 3 and 4 are PENDING per `Issues.md` A1, B1,
META-MUT-001. Layer 2 is met by `scripts/tests/` (test 09 the
canonical example).

The cycle-discipline half: the moment any defect is rediscovered,
re-produced, or newly identified during a test cycle, the cycle MUST
stop. Then fix at root cause, land all four layers, full rebuild,
repeat from the beginning.

### §11.4.5 — Audio + video quality analysis comprehensiveness (User mandate, 2026-05-07)

**N/A for tmux scope.** This anchor exists in upstream `vasic-digital`
projects to require quality analysis on captured audio/video evidence
(non-zero RMS, channel-count ffprobe assertion, frame-count >0,
SSIM >0.99 freeze-detection, Tesseract OCR for hostile overlays).
tmux is a terminal multiplexer — there are no audio/video features.

The principle still applies generically: every captured-artifact PASS
MUST analyze artifact CONTENT, not just artifact PRESENCE. A 0-byte
recording file existing is the canonical PASS-bluff. For tmux scope,
the analogous discipline is: `memory.max` file existing is not enough;
the FILE CONTENT must read the configured byte count. `cgroup.procs`
file existing is not enough; the CONTENT must include the spawned
MainPID. Test 09 already implements this discipline.

### §11.4.6 — No-guessing mandate (User mandate, 2026-05-08)

**Forensic anchor — direct user mandate (verbatim, 2026-05-08T18:30 MSK):**

> "'LIKELY' is guessing, we MUST NOT have guessing, since it can
> be or may not be! No bluffing and uncertainity is allowed at any
> cost! We MUST always know exactly precisly what is happening
> exactly, in any context, under any conditions, everywhere!"

**The mandate.** Tests, gates, status reports, closure narratives,
commit messages, `Issues.md` / `Fixed.md` / `CONTINUATION.md` entries,
and any operator-facing text MUST NOT use words like `likely`,
`probably`, `maybe`, `might`, `possibly`, `presumably`, `seems`,
`appears to`, or their synonyms when describing CAUSES of test
failures, system behaviour, or fix effectiveness. Either:

1. **Prove the cause** with captured forensic evidence
   (`journalctl -k`, `dmesg`, `/sys` readings, `getent passwd`,
   `cgroup.events`, `systemctl --user status`, strace, etc.) and
   state it as fact, OR
2. **Explicitly mark `UNCONFIRMED:` / `UNKNOWN:` / `PENDING_FORENSICS:`**
   with a tracked-task ID for follow-up forensics. Do not paper over
   with speculative language.

**Operative test:** every "X likely caused Y" sentence in the
codebase or documentation is a §11.4.6 violation. Every "appears to be
benign" without a concrete forensic-trace is a §11.4.6 violation.
Every hand-wave that closes a defect on plausibility-instead-of-proof
is the exact PASS-bluff pattern §1 forbids translated into prose form.

**Captured-evidence enforcement.** A scanner gate (planned as part of
META-MUT-001) greps `Issues.md` / `Fixed.md` / `CONTINUATION.md` /
recently-modified test scripts / commit-message inputs for the
forbidden vocabulary outside of explicit `UNCONFIRMED:` /
`UNKNOWN:` / `PENDING_FORENSICS:` blocks. Any hit FAILs the gate.

**No escape hatch.** §11.4.6 has NO operator-facing override flag.
The discipline exists for the operator's own protection — every
"likely" that ships is a future debugging session that finds the
real cause hours late, after already shipping a stale or wrong
narrative.

Non-compliance is a release blocker regardless of context.

---

## §9 Absolute data safety — zero risk

Every destructive repository operation (history rewrite, force-push,
branch deletion, bulk file removal, submodule de-init, object
pruning) is a **safety-critical** operation. Data loss from a wrong
force-push is irreversible once the remote garbage-collects dangling
objects.

**Mandatory protocol** (mirrors upstream `vasic-digital` projects):

1. **Backup first, always.** A hardlinked mirror of `.git` to a
   sibling backup directory (`cp -al .git <backup>/repo.git.mirror`)
   is near-instant and uses zero additional disk.
2. **Record metadata** before the destructive op: refs, tags,
   submodule pointers, HEAD commit, HEAD tree hash.
3. **Define expected post-op state.** If the operation should
   preserve HEAD content, the expected tree hash is unchanged. If it
   changes content, the expected new state is written down before the
   op, not invented after.
4. **Never bypass hooks.** No `--no-verify`. No `--force` that
   bypasses signing. No silent retry of failed pushes.
5. **Post-op gate:** HEAD tree identical to expected, all tags
   preserved, all submodule pointers intact, full `scripts/verify.sh`
   8-test suite green.
6. **Force-push authorization** is NEVER automatic. `commit_all.sh`
   in this repo does NOT auto-force-push as a recovery path. Each
   force-push event requires explicit human authorization in that
   session AND requires the post-op gate to have passed first.

The hardlinked backup is so cheap (zero disk, sub-second) that there
is NEVER an excuse to skip it. Operating without a backup on a
destructive op is a §9 violation regardless of confidence level.

---

## §12.6 60% host memory budget (User mandate, 2026-04-30)

**Forensic anchor — direct user mandate (verbatim, propagated from
upstream `vasic-digital` projects):**

> "We had to restart this session 3rd time in a row! The system of
> the host stays with no RAM memory for some reason! First make sure
> that whatever we do through our procedures related to this project
> MUST NOT use more than 60% of total system memory! All processes
> MUST be able to function normally!"

**The mandate.** Project procedures MUST NOT use more than **60% of
total system RAM**. The remaining 40% is reserved for the operator's
other workloads.

**For tmux scope, the per-session containerization (`scripts/tmx`)
IS the enforcement mechanism.** Each session is wrapped in
`systemd-run --user --scope` with `MemoryMax=$TMX_MEM` (default 8G).
A runaway workload inside any one session is OOM-killed at the scope
level — the kernel never escalates to user.slice — so concurrent
sessions cannot collectively starve the host.

Operator default `TMX_MEM=8G` is conservative for 32 GiB+ hosts.
On 16 GiB hosts, set `TMX_MEM=4G` and limit concurrent sessions to
match the 60% ceiling. On 64 GiB+ hosts, raising `TMX_MEM` is
acceptable as long as `Σ(active TMX_MEM) ≤ 0.6 × MemTotal`.

**No escape hatch.** §12.6 has NO operator-facing override flag for
the per-host total. The cap exists for the operator's own
protection. Operators who need more headroom should reduce concurrent
sessions, close other workloads, or add RAM — NOT raise the
percentage.

---

## §2 Repository structure invariants

| Path | Purpose | Coupling |
|---|---|---|
| `tmux/` | Submodule pinned to upstream `tmux/tmux` | Generic upstream |
| `Containers/` | Submodule pointing to `vasic-digital/Containers` (cgroup orchestration helpers) | Shared library |
| `scripts/` | All build / verification / install scripts | Project-agnostic |
| `scripts/tests/` | 8 functional verification tests | Generic |
| `scripts/challenges/` | HelixQA Challenge specs | Generic |
| `docker/` | Build container + per-session container definitions | Generic |
| `docs/` | User guide + containerization plan | Generic |
| `commit_all.sh` | This repo's own commit + push to all upstreams | Self-contained |

---

## §3 Tooling invariants (every change MUST honor)

1. **Source rebrands flow to shipped binary** — pinning tmux to a specific tag means `tmx -V` reports that tag, not "master".
2. **Test coverage for every change** — pre-build gate + post-build gate + functional test + paired mutation in `meta_test_*.sh`.
3. **All commits via `commit_all.sh`** at the repo root. Pushes to BOTH GitHub (`vasic-digital/tmux`) and GitLab (`vasic-digital/tmux`).
4. **Submodule pointer integrity** — `tmux/` pointer references a known-good upstream tag; `Containers/` references our own canonical SHA.
5. **One-command bootstrap** — operator runs `bash scripts/setup.sh` after `sudo bash scripts/install_deps.sh` and gets a verified `tmx` in PATH.
6. **No project coupling** — any reference to "ATMOSphere", "Android-15", "Orange Pi 5 Max" anywhere in this repo is a regression. (Historical context in commit messages OK.)

---

## §4 Anti-bluff verification gate (load-bearing)

`scripts/verify.sh` is the single decision point for whether the binary is operator-safe. It runs the 8-test suite + reports a single verdict:

```
GREEN  →  exit 0  →  setup.sh proceeds to PATH export
RED    →  exit 1  →  setup.sh REFUSES to install
```

Per §1, `setup.sh` does NOT bypass the gate under any flag. There is no "force install" mode.

---

## §5 / §12.10 — Continuation document sacred invariant (User mandate, 2026-05-07)

**Forensic anchor — direct user mandate (verbatim, propagated from
upstream `vasic-digital` projects):**

> "during any work we perfrom, during Phases implementation,
> debugging and fixing, during ANY effort we have the Continuation
> document MUST BE maintained and it MUST NOT BE out of sync with
> current work we are doing! If for any reson we stop our work, we
> MUST BE able to continue any time, with current work, exactly
> where we have left of and from any CLI agent or any LLM model we
> chose! Nothing can be broken or faulty in maintained Continuation
> document!"

**The mandate.** A `CONTINUATION.md` document at the repo root MUST
always reflect the live state of work in this repo. Any agent (human,
Claude Code, Cursor, Aider, Codex, Gemini CLI, any future LLM) must
be able to resume work **exactly where the previous session left off**
by reading this single file. Conversation history is ephemeral; this
document is the durable handoff.

**Mandatory protections (no escape hatch):**

1. **`CONTINUATION.md` MUST exist** at the repo root. Its absence is
   a release blocker.
2. **Every non-trivial state change** — work item started / completed
   / blocked, new bug discovered, phase transition, fix applied,
   gate added, mutation paired — MUST update this document **in the
   same commit** as the work itself. Commits that change source /
   tests / docs but leave `CONTINUATION.md` stale are non-compliant.
3. **Top-of-file `Last updated:`** ISO timestamp updated on every
   edit. Stale timestamps trigger gate failure.
4. **Section §3 "Active work"** must list every IN PROGRESS / BLOCKED
   item with concrete commands, file paths, monitor IDs, and
   percentages where relevant — enough that any agent can resume
   without conversation context.
5. **Section §0 "How to use this document"** must contain the
   verbatim resumption prompt — a single block any operator can
   paste into any CLI agent.
6. **Document MUST be self-contained** — no hyperlinks to ephemeral
   external systems (Slack threads, ticket systems) as the only
   source of truth. URLs are reference, not load-bearing state.

**§11.4.6 forbidden-vocabulary scan.** `CONTINUATION.md` is
specifically scanned for `likely / probably / maybe / presumably /
seems / appears to` outside of explicit `UNCONFIRMED:` /
`UNKNOWN:` / `PENDING_FORENSICS:` blocks. Any hit is a §11.4.6
violation.

Stale `CONTINUATION.md` = release blocker. Pre-build gate
`CM-CONTINUATION-DOC-INSYNC` (planned with META-MUT-001) enforces
freshness.

**No escape hatch.** §12.10 has NO operator-facing override flag.
The discipline exists for the operator's own protection — the moment
the document drifts from reality is the moment session-loss becomes
catastrophic.

---

This Constitution applies to **this repo only**. The parent project
(vasic-digital, ATMOSphere, etc.) may have its own constitution; the
two are independent.
