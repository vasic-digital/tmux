# vasic-digital tmux — Repository Constitution

This repository is **fully decoupled** from any specific project (ATMOSphere, HelixCode, Catalogizer, etc.). It can be cloned and used standalone on any Linux host. The covenant below applies to this repo's own work.

---

## §1 Anti-bluff covenant — END-USER QUALITY GUARANTEE

> Every test, every Challenge, every gate, every mutation pair exists to make the failure mode (PASS on broken-for-end-user feature) **mechanically impossible**.

The bar for shipping is NOT "tests pass" but **"users can use the feature."** Every PASS in this codebase MUST carry positive evidence captured during execution that the feature works. Metadata-only PASS, configuration-only PASS, "absence-of-error" PASS, and grep-based PASS without runtime evidence are all critical defects regardless of how green the summary line looks.

**Tests AND Challenges are bound equally** — a Challenge that scores PASS on a non-functional feature is the same class of defect as a unit test that does. Both must produce positive end-user evidence.

**FAIL-bluffs equally forbidden.** A test that crashes for a script-internal reason (undefined variable, regex error, missing argument, missing dependency in PATH) and produces a FAIL exit code is just as misleading as a PASS-bluff. Both let real defects ship undetected. Fix at source layer (helper library, shared lib, test source), never patch in individual call sites.

**Recorded-evidence requirement.** Every PASS for a user-visible feature MUST be cross-checked by captured runtime artifact (e.g., `/proc/<pid>/maps`, `dumpsys`, `getprop`, terminal capture). A PASS that lacks runtime evidence is treated as a PASS-bluff.

**Test-interrupt-on-discovery.** The moment any defect is rediscovered, re-produced, or newly identified during a test cycle, the cycle MUST stop. Then: fix at root cause, land validation/verification tests for the fix (pre-build gate AND on-device test AND paired meta-test mutation), full rebuild, repeat full test cycle from the beginning.

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

## §5 §12.10 — Continuation Document Sacred Invariant

A `CONTINUATION.md` document at the repo root MUST always reflect the live state of work in this repo. Any agent (human, Claude Code, Cursor, Aider, Codex, any LLM) must be able to resume work exactly where the previous session left off by reading this single file. Conversation history is ephemeral; this document is the durable handoff.

Stale CONTINUATION.md = release blocker. Pre-build gate `CM-CONTINUATION-DOC-INSYNC` enforces freshness.

---

This Constitution applies to **this repo only**. The parent project (vasic-digital, ATMOSphere, etc.) may have its own constitution; the two are independent.
