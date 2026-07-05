# Frequently Asked Questions

**Revision:** 1
**Last modified:** 2026-07-05T00:00:00Z

## Why did I get asked for a password twice when opening a session?

Prior to 2026-07-05 this could happen for a session that had been
idle-recycled — a bug, now fixed. See
`docs/guides/tmx-session-passwords.md` for the current (single-prompt)
behavior. If you still see this, please report it — it should not occur.

## How do I get an exact session name for scripting instead of the random suffix?

Set `TMX_EXACT_NAME=1` in the environment before invoking the wizard (or
just call `tmx new -s NAME` directly — the wrapper itself never appends
anything; only the interactive wizard adds the random suffix).

## How do I pick an existing session instead of creating a new one?

Press Enter (blank input) at the wizard's "Enter session name to create"
prompt. If you have existing sessions, you'll see a numbered menu; pick a
number to join that session, or `0` to leave the wizard.
