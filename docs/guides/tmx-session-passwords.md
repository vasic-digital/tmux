# tmx session passwords — user guide

**Revision:** 1
**Last modified:** 2026-07-05T00:00:00Z

## What this is

Every `tmx` session can optionally be password-protected. The password is
stored as a salted hash in `~/.tmx/state.json` (or `$TMX_STATE_FILE`),
never in plaintext, and is checked by `scripts/tmx-state-bin` — a small Go
binary that ships alongside the wrapper.

## Creating a password-protected session

Run `tmx new -s NAME` (directly, or by typing `NAME` at the interactive
wizard prompt — see `docs/guides/tmx-shell-integration.md`). If `NAME` has
never been protected before, you are prompted:

```
[tmx] Enter session name "NAME" (blank = none):
```

Leave it blank for no password. Type anything else and you are asked to
confirm it:

```
[tmx] Confirm password:
```

The two entries must match exactly (masked with `*` as you type, both
times). If they don't match, you get:

```
[tmx] passwords did not match, try again
```

and are prompted again — up to 3 attempts. After the 3rd mismatch, the
session is **not** created at all (no half-configured session is left
behind) and `tmx` exits with an error.

## Opening an already-protected session

Whether the session is currently running, or was torn down by the idle
recycler after a period of inactivity (its password always survives that
teardown), opening it — via `tmx attach -t NAME`, `tmx new -s NAME`, or
picking it from the wizard's existing-session menu — always shows exactly
**one** prompt:

```
[tmx] Session "NAME" is password-protected. Enter password:
```

The correct password attaches you immediately; nothing else is asked.
A wrong password is rejected and the session is left completely alone.

## Resetting a session's password

`tmx delete -t NAME` tears the session down **and** clears all of its
persisted state, including its password. The next `tmx new -s NAME` (or
re-typing that exact name if you used `TMX_EXACT_NAME=1`) is treated as
genuinely fresh — you'll get the create-and-confirm flow again.

## Why you might have seen "asked twice" before 2026-07-05

Prior to this date, reopening a session that had been idle-recycled could
show a confusing SECOND prompt that looked like it might reset your
password. That was a bug (root-caused and fixed the same day — see
`docs/superpowers/specs/2026-07-05-tmx-wizard-password-redesign-design.md`
for the full forensic write-up); it no longer happens.

## Decision flow

The diagram below traces the full decision path both entry points take —
`tmx new -s NAME` and `tmx attach -t NAME` — from the `has-password`
probe through verify-once (existing password) or set-and-confirm (brand-new
name). The diagram source is `docs/guides/tmx-session-passwords-decision-flow.mmd`;
the rendered image is `docs/guides/tmx-session-passwords-decision-flow.png`.

![tmx session-password create/attach decision flow](docs/guides/tmx-session-passwords-decision-flow.png)
