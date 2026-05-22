# tmx-shell-init

**Revision:** 1
**Last modified:** 2026-05-22T12:20:00Z
**Authority:** vasic-digital tmux project
**Maintainer:** milosvasic
**Scope:** §11.4.18 script companion doc for `scripts/tmx-shell-init.sh`

## Purpose

Single project-owned entry point sourced from the operator's
`.bashrc` / `.zshrc`. Replaces the hand-pasted, drift-prone snippet
that previously lived in every operator's rc file. On every interactive
login it prompts for a session name, defaulting to `default` (the
literal token `default` AND blank input both mean SKIP — bare shell, no
tmx wrapping). Any other name routes through the `tmx` wrapper, which
in turn restores the session's last cwd via the Go state daemon. Design
authority:
`docs/superpowers/specs/2026-05-22-tmx-shell-session-resume-design.md`
§4.A + §5.2.

## Usage

One-time install — append to `~/.bashrc` AND `~/.zshrc`:

```sh
# vasic-digital tmx shell integration
. /path/to/tmux/scripts/tmx-shell-init.sh
```

(or use the generated `scripts/bashrc_snippet.template` produced by
`scripts/setup.sh`, which already embeds the project's resolved path
plus the `PATH` block).

Manual one-shot probe (no install required):

```sh
# Source it interactively to test.
. scripts/tmx-shell-init.sh

# Or run it under a sub-shell, with stdin redirected (non-TTY guard
# MUST silently no-op, never block, never error):
bash -c '. scripts/tmx-shell-init.sh' </dev/null
echo "exit=$?  ← MUST be 0"
```

Concrete operator session walk-through:

```text
$ ssh nezha
[tmx] session name (default = skip, blank = skip): work
[tmx] resuming 'work' (last cwd: /home/m/Projects/tmux)
... tmx new -s work runs, attaches, drops you in the recalled cwd ...
```

```text
$ ssh nezha
[tmx] session name (default = skip, blank = skip): <enter>
... no tmx; you're in a bare login shell ...
```

## Inputs

- **stdin (TTY)** — single line read; trimmed; coerced to `default`
  on empty input.
- **`$TMUX`** — if non-empty, script silently returns (don't nest tmux
  servers per spec §6 edge case 4).
- **`$TMX_SHELL_INIT_SKIP`** — operator escape hatch; if non-empty,
  script silently returns. Useful in CI and one-off `bash -c` flows.
- **`$TMX_HOSTNAME`** — optional override propagated downstream to
  the wrapper for status-bar colour stability.
- **TTY check** — `[ -t 0 ] && [ -t 1 ]`; non-TTY contexts (scp,
  rsync, IDE remote shells, automated SSH commands) silently no-op
  per spec §6 edge case 5.

## Outputs

- **stdout** — the operator prompt and one-line `[tmx] resuming X`
  banner on session entry.
- **stderr** — name-validation rejection messages (forbidden
  characters per spec §6 edge case 3).
- **process exec** — on success, `exec`s the `tmx` wrapper, which in
  turn `exec`s `tmux attach`. The operator's shell is replaced; no
  fork is left behind.

## Side-effects

- Reads one line from stdin (only when TTY-guarded).
- May `exec tmx new -s <name>` or `exec tmx attach -t <name>`,
  replacing the calling shell.
- Never writes to disk directly. The downstream wrapper + state
  daemon handle persistence per
  `docs/scripts/tmx-state.md`.

## Dependencies

- POSIX sh (works in bash 3.2+ — the macOS default — and in zsh 5+;
  parses clean under `sh -n` per §11.4.67).
- The `tmx` wrapper on `$PATH` (or referenced via the project path the
  template substitution baked in).
- Optional but recommended: `scripts/tmx-state-bin` for cwd restore;
  absence is non-fatal (wrapper falls back to `$HOME`).

## Cross-references

- Design spec: `docs/superpowers/specs/2026-05-22-tmx-shell-session-resume-design.md`
- Operator user guide: `docs/guides/tmx-shell-integration.md`
  (P8 deliverable)
- Companion script docs: `docs/scripts/tmx-state.md`,
  `docs/scripts/tmx-ssh-dispatch.md`,
  `docs/scripts/tmx-ssh-install.md`
- Wrapper integration: `scripts/tmx.template` (P4 — the cwd-restore +
  hook-install machinery)
- Runtime tests:
  - `scripts/tests/19_default_skip.sh` (literal `default` SKIPs)
  - `scripts/tests/20_default_skip_blank.sh` (blank SKIPs)
  - `scripts/tests/21_non_tty_skip.sh` (non-TTY SKIPs silently)
  - `scripts/tests/26_session_name_validation.sh` (forbidden chars)
  - `scripts/tests/28_nested_tmux_skip.sh` (`$TMUX` set SKIPs)
- Constitution: §11.4.18 (script docs), §11.4.6 (no-guessing —
  every prompt response handled deterministically), §11.4.67
  (POSIX parseability), §11.4.81 (cross-platform — same script
  works on macOS bash 3.2 and Linux bash 5 / zsh).

## Last verified

2026-05-22 — sibling PWU P2 published the script and its `sh -n`
parse-clean evidence; this companion doc tracks its contract.
Full on-device runtime coverage gated on PWU P6.
