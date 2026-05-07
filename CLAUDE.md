# CLAUDE.md / AGENTS.md — for AI agents working on this repo

> If you are an AI agent (Claude Code, Cursor, Aider, Codex, Gemini CLI, any future LLM), read this file BEFORE making any change.

## Repository purpose

vasic-digital tmux: a hardened, jemalloc-aware, OOM-protected, verified-by-test tmux build that runs on any Linux host. NOT coupled to any specific project. Standalone, reusable.

## Critical mandate — anti-bluff covenant

> **The bar for shipping is "users can use the feature," not "tests pass."**

Every PASS must carry runtime evidence the feature works.  Metadata-only / configuration-only / "absence-of-error" PASS without evidence is a critical defect.

FAIL-bluffs are equally forbidden — a test that exits FAIL because of a script-internal bug (undefined variable, missing dependency, bad regex) is just as misleading as a PASS-bluff. Fix at source layer, never in call sites.

Tests AND Challenges (HelixQA bank entries) are bound equally — both must produce positive runtime evidence.

The full mandate is in `Constitution.md` §1 (and propagated from upstream `vasic-digital` projects).

## Test-interrupt-on-discovery

The moment any defect is rediscovered, re-produced, or newly identified during a test cycle, the cycle MUST stop. Then: fix at root cause + paired mutation + full rebuild + repeat cycle.

## Structure (don't deviate)

| Path | Purpose |
|---|---|
| `tmux/` | upstream tmux submodule (don't modify) |
| `Containers/` | vasic-digital/Containers submodule (cgroup helpers) |
| `scripts/` | build + verify + install + tests + challenges |
| `docker/` | container definitions for build + per-session |
| `docs/` | guides + containerization plan |
| `commit_all.sh` | the official commit + push entrypoint |

## Mandatory operations

- `commit_all.sh "message"` — never `git push` directly
- `scripts/verify.sh` — never bypass when modifying tmux build
- All changes that touch a script must add or update a paired mutation in `scripts/tests/meta_test_*.sh` (when that file exists in v2)

## Continuation invariant (Constitution §5)

Update `CONTINUATION.md` in the same commit as any non-trivial state change.

