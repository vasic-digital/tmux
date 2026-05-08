# CLAUDE.md / AGENTS.md — for AI agents working on this repo

> If you are an AI agent (Claude Code, Cursor, Aider, Codex, Gemini CLI, any future LLM), read this file BEFORE making any change.

## Repository purpose

vasic-digital tmux: a hardened, jemalloc-aware, OOM-protected, verified-by-test tmux build that runs on any Linux host. NOT coupled to any specific project. Standalone, reusable.

The canonical authority is [`Constitution.md`](Constitution.md) at the
repo root. Every numbered anchor below cross-references a section
there.

## Critical mandate — anti-bluff covenant (Constitution §1)

**Forensic anchor — direct user mandate (verbatim, 2026-04-28 + 2026-05-07 + 2026-05-08, repeatedly reasserted):**

> "We had been in position that all tests do execute with success and all Challenges as well, but in reality the most of the features does not work and can't be used! This MUST NOT be the case and execution of tests and Challenges MUST guarantee the quality, the completion and full usability by end users of the product!"

> **The bar for shipping is "users can use the feature," not "tests pass."**

Every PASS must carry runtime evidence the feature works. Metadata-only / configuration-only / "absence-of-error" PASS without evidence is a critical defect.

FAIL-bluffs are equally forbidden — a test that exits FAIL because of a script-internal bug (undefined variable, missing dependency, bad regex) is just as misleading as a PASS-bluff. Fix at source layer, never in call sites.

Tests AND Challenges (HelixQA bank entries) are bound equally — both must produce positive runtime evidence.

## §11.4.1 — FAIL-bluffs equally forbidden (Constitution §11.4.1)

A test that crashes for a script-internal reason and exits FAIL is the
same class of defect as a PASS-bluff. Both let real defects ship
undetected. Fix at the source layer, never in call sites.

## §11.4.2 — Recorded-evidence requirement (Constitution §11.4.2)

Every PASS for a user-visible feature MUST be cross-checked against
captured runtime artifacts. For tmux scope: `/sys/fs/cgroup/<scope>/`
read-backs (`memory.max`, `cpu.max`, `pids.max`),
`systemctl --user list-units` lifecycle, `cgroup.procs` membership,
`dmesg | grep oom-kill` proof, `default.target=active` survival
proof. A PASS that lacks at least one matched artifact is a §1
PASS-bluff.

## §11.4.3 — Per-host-topology test dispatch (Constitution §11.4.3)

Tests that depend on host topology (systemd version, cgroup v1 vs v2,
distro-specific controller availability, kernel namespace flags)
MUST detect topology at test entry and dispatch the topology-
appropriate variant. The wrapper at `scripts/tmx` already detects
systemd v240+ and cgroup-v2 unified mount as a precondition — that
is the canonical dispatch seam. Tests on a host that lacks either
MUST SKIP-with-reason, not silently degrade.

## §11.4.4 — Test-interrupt-on-discovery + 4-layer test coverage (Constitution §11.4.4)

The moment any defect is rediscovered, re-produced, or newly
identified during a test cycle, the cycle MUST stop. Then: fix at
root cause, land all four layers (pre-build gate / runtime test /
HelixQA Challenge / paired mutation), full rebuild, repeat from the
beginning.

For tmux scope, layers 1, 3, 4 are PENDING per `Issues.md` A1, B1
(META-MUT-001, CHAL-COVER-001). Layer 2 is met by `scripts/tests/`
(test 09 the canonical example).

## §11.4.5 — Audio + video quality analysis (Constitution §11.4.5)

**N/A for tmux scope** (no audio/video features). The principle still
applies: every captured-artifact PASS MUST analyze artifact CONTENT,
not just artifact PRESENCE. For tmux: `memory.max` file existing is
not enough; the FILE CONTENT must read the configured byte count.
`cgroup.procs` file existing is not enough; the CONTENT must include
the spawned MainPID.

## §11.4.6 — No-guessing mandate (Constitution §11.4.6)

**Forensic anchor — direct user mandate (verbatim, 2026-05-08T18:30 MSK):**

> "'LIKELY' is guessing, we MUST NOT have guessing, since it can
> be or may not be! No bluffing and uncertainity is allowed at any
> cost! We MUST always know exactly precisly what is happening
> exactly, in any context, under any conditions, everywhere!"

Tests, gates, status reports, closure narratives, commit messages,
`Issues.md` / `Fixed.md` / `CONTINUATION.md` entries, and any
operator-facing text MUST NOT use words like `likely`, `probably`,
`maybe`, `might`, `possibly`, `presumably`, `seems`, `appears to`,
or their synonyms when describing CAUSES of test failures, system
behaviour, or fix effectiveness. Either:

1. **Prove the cause** with captured forensic evidence
   (`journalctl -k`, `dmesg`, `/sys` readings, `systemctl --user
   status`, `cgroup.events`, strace, etc.) and state it as fact, OR
2. **Explicitly mark `UNCONFIRMED:` / `UNKNOWN:` / `PENDING_FORENSICS:`**
   with a tracked-task ID for follow-up forensics.

Non-compliance is a release blocker regardless of context.

## §9 — Absolute data safety (Constitution §9)

Every destructive repository operation (history rewrite, force-push,
branch delete, bulk file removal, submodule de-init, object pruning)
requires backup-first protocol: hardlinked `.git` mirror, recorded
metadata, expected post-op state defined in advance, post-op gate
green before considered done. Force-push is NEVER automatic and
requires explicit per-session authorization.

## §12.6 — 60% host memory budget (Constitution §12.6)

Project procedures MUST NOT use more than 60% of total system RAM.
For tmux scope, the per-session containerization (`scripts/tmx`
wrapper invoking `systemd-run --user --scope` with `MemoryMax=$TMX_MEM`)
IS the enforcement mechanism. Default `TMX_MEM=8G` is conservative
for 32 GiB+ hosts. Operators MUST keep `Σ(active TMX_MEM) ≤ 0.6 ×
MemTotal`.

## §12.10 — Continuation document sacred invariant (Constitution §5 / §12.10)

`CONTINUATION.md` at the repo root MUST always reflect live work
state. Every non-trivial state change updates this document in the
SAME commit as the work itself. `Last updated:` ISO timestamp on
first 10 lines. Sections §0 / §3 / §8 mandatory. Self-contained — no
hyperlinks to ephemeral systems as the only source of truth.

Stale `CONTINUATION.md` = release blocker.

## Test-interrupt-on-discovery

The moment any defect is rediscovered, re-produced, or newly identified during a test cycle, the cycle MUST stop. Then: fix at root cause + paired mutation + full rebuild + repeat cycle.

## Issues / Fixed migration

- **`Issues.md`** holds OPEN, PARTIAL, BLOCKED, RUNNING, INVESTIGATED items.
- **`Fixed.md`** holds RESOLVED items with closure commit + captured
  evidence + regression-protection hook.
- When an item resolves, move it from `Issues.md` to `Fixed.md` in
  the SAME commit. Never let resolved items linger in `Issues.md`;
  never delete them outright.

## Structure (don't deviate)

| Path | Purpose |
|---|---|
| `tmux/` | upstream tmux submodule (don't modify) |
| `Containers/` | vasic-digital/Containers submodule (cgroup helpers) |
| `scripts/` | build + verify + install + tests + challenges |
| `docker/` | container definitions for build + per-session |
| `docs/` | guides + containerization plan |
| `commit_all.sh` | the official commit + push entrypoint |
| `Constitution.md` | canonical authority for every numbered anchor |
| `Issues.md` | open / in-flight tracker |
| `Fixed.md` | closed-with-evidence archive |
| `CONTINUATION.md` | live handoff state |

## Mandatory operations

- `commit_all.sh "message"` — never `git push` directly
- `scripts/verify.sh` — never bypass when modifying tmux build
- All changes that touch a script must add or update a paired mutation in `scripts/tests/meta_test_*.sh` (when META-MUT-001 lands per `Issues.md` A1)

## Continuation invariant

Update `CONTINUATION.md` in the same commit as any non-trivial state change.
