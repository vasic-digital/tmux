# tmx wizard + session-password redesign — design spec

**Revision:** 1
**Last modified:** 2026-07-05T00:00:00Z
**Status:** approved (brainstorming phase) — pending implementation

## Forensic anchor — verbatim user mandate (2026-07-05)

> "1. When asked for name of new session at the end of name it must be
> appended random 4 number suffix. ... 2. When we are entering passwords,
> they MUST not be visible to a naked eye but presented with "*" characters
> as we are typing! 3. When we open sessions which are password protected,
> and we enter valid password, we are then asked twice to enter (maybe new)
> password! ... We MUST BE asked twice to enter password if we create new
> session password protected - the password and confirmation. 4. When user
> presses enter, so he does not want to create new session, he should have
> a choice of choosing one of existing sessions, or the option of none, to
> leave wizard..."

## Root cause of requirement #3 (the double-password-prompt bug)

The interactive wizard (`scripts/tmx-shell-init.sh.template`) runs:

```sh
tmx attach -t "$1" 2>/dev/null || exec tmx new -s "$1"
```

The `attach` verb (`scripts/tmx.template`) checks for a persisted password
**before** checking whether a live tmux session actually exists. For a
session that was idle-recycled (killed by `tmx-recycler.sh` for inactivity,
but whose password/state persists in `tmx-state-bin`'s JSON store), this
means: the operator is prompted to *verify* the (still-valid) password,
succeeds, then the wrapper's final `exec "$TMUX_BIN" ... attach -t "$NAME"`
fails because the socket is dead. That failure propagates back to the
wizard's `||`, which falls through to `tmx new -s "$1"` — and the `new`
verb *unconditionally* re-prompts "Enter password for session NAME
(blank = none)" and overwrites the stored hash with whatever is typed. This
is not a real confirmation dialog; it is an accidental password-reset
triggered by a stale-session attach failure.

## Scope decisions (resolved via brainstorming Q&A, 2026-07-05)

1. **Suffix scope:** applies to **both** the interactive wizard and direct
   `tmx new -s NAME` CLI usage — but the wrapper (`tmx.template`) itself
   never invents the suffix; only the wizard (`tmx-shell-init.sh.template`)
   generates and appends it before calling `tmx new -s <name>-<suffix>`.
   This keeps `tmx new -s NAME` byte-exact for scripting/tests by
   construction, while still satisfying "both" — the wizard is the only
   caller that ever adds anything, and it does so unconditionally by
   default.
2. **Suffix opt-out:** `TMX_EXACT_NAME=1` (env var), read only by the
   wizard. When set, the wizard uses the typed name literally, still going
   through the always-create path (no attach-first probe).
3. **Existing-session picker UX:** numbered list (`1) name1`, `2) name2`,
   ...) + `0) None (leave, bare shell)`. Zero existing sessions → skip the
   menu, go straight to bare shell (unchanged current default). Invalid
   selection → one re-prompt, then bare shell.
4. **Password confirmation mismatch:** retry up to 3 times; on the 3rd
   failure, abort — if the tmux session was already created in this
   invocation, tear it down (fail-closed: no half-configured session left
   behind).

## Architecture

### Components touched

| Component | Change |
|---|---|
| `scripts/tmx-state/state.go` + `main.go` | New `has-password <session>` subcommand: exit 0 = has password, 1 = record exists/no password, 2 = no record. Additive only. |
| `scripts/tmx.template` | New `_read_password_masked()` helper (bash, `*`-echo, backspace support). `new` verb restructured: password decision (verify-existing OR collect-new-with-confirm) moves **before** tmux session creation. `attach` verb restructured: `has-session` check moves **before** the password guard. |
| `scripts/tmx-shell-init.sh.template` | Replace "Enter session name" → attach-else-new chain with: name typed → generate 4-digit suffix (POSIX `awk`) → always `exec tmx new -s "name-NNNN"`; blank → numbered existing-session picker → attach chosen or bare shell. |
| `scripts/tests/68_session_lifecycle.sh` | Rewrite C6 (recreate-after-recycle: now verify-once, correct-accepts/wrong-rejects, no re-set) and C7 (post-delete recreate: now set+confirm-twice) per §11.4.120 gate reconciliation. |
| `scripts/tests/66_session_password.sh` | Add `has-password` exit-code cases (0/1/2). |
| New tests 77–84 | See test plan below. |
| Docs | README, `docs/guides/tmx-shell-integration.md`, new `docs/guides/tmx-session-passwords.md`, FAQ, diagrams, workable-items DB entries, CONTINUATION.md, CHANGELOG/VERSION at release. |

### Data flow — `tmx new -s NAME`

1. Resolve `NAME` (existing sanitize/color-parse logic, unchanged).
2. `has-password NAME` → 0 / 1 / 2.
3. Exit 0 (password exists — live or recycled-dead): masked prompt "Session
   is password-protected. Enter password:" → verify → **wrong → print
   error, exit 1, no tmux session touched**; correct → proceed silently,
   no further password prompts.
4. Exit 1 or 2 (no password currently set): proceed to existing
   collision-check + tmux session create/recreate, unchanged.
5. Only in the exit-1-or-2 case, after the session is confirmed up: masked
   "Enter password for session (blank = none):" → blank → done, no
   password. Non-blank → masked "Confirm password:" → match → `set-password`
   → attach. Mismatch → "passwords did not match, try again" → retry (max
   3) → 3rd failure → kill the session just created, print error, exit 1.

### Data flow — `tmx attach -t NAME`

`has-session -t NAME` first. Not live → `tmx: no session named "NAME"` to
stderr, exit 1, **no password prompt at all**. Live → existing
has-password → verify-once logic (unchanged) → exec attach.

### Data flow — wizard (`tmx-shell-init.sh.template`)

```
printf '[tmx] Enter session name to create (blank = choose existing session): '
read session_name

if [ -z "$session_name" ] || [ "$session_name" = "default" ]:
    list existing sessions (parse `tmx ls` output, names before first ':')
    if none exist: return 0 (bare shell, unchanged)
    else: print numbered menu + "0) None (leave, bare shell)"
          read choice
          valid 1..N -> exec sh -c 'exec tmx attach -t "$1"' ... "$chosen_name"
          "0"/blank/invalid-after-retry -> return 0 (bare shell)
else:
    validate charset/length (existing rule: [A-Za-z0-9_.-:#]{1,80})
    suffix = awk-generated 4 random digits (unless TMX_EXACT_NAME=1)
    real_name = "${session_name}-${suffix}" (or literal if opted out)
    exec sh -c 'exec tmx new -s "$1"' tmx-shell-init "$real_name"
```

### Masked password reader (bash, `tmx.template` only)

Reads one character at a time via `read -rsn1` from `/dev/tty`, echoes `*`
per printable character, handles backspace/DEL (erase one `*` + one
buffered char), terminates on Enter, returns the full string on stdout.
Used at all three password-prompt call sites.

### `has-password` Go contract

```
tmx-state has-password <session>
  exit 0 — record exists AND PasswordHash != ""
  exit 1 — record exists AND PasswordHash == ""
  exit 2 — no record for this session
  (no stdout — pure exit-code contract, mirrors verify-password's shape)
```
Replaces the double-call-verify-password-with-empty-guess trick currently
in the `attach` verb — one primitive answers "does this session have a
password" instead of two implementations of the same question.

## Error handling & edge cases

- Wrong password on verify (either verb): error + exit 1, no session
  touched. No retry loop (security gate, not typo-recovery).
- Confirmation mismatch on brand-new password: 3 retries, then abort +
  tear down the just-created session if one was made.
- `attach` on a name with no live session: clean error, no `/dev/tty`
  interaction, exit 1.
- Wizard, zero existing sessions on blank input: skip menu, bare shell.
- Wizard, invalid selection: one re-prompt, then bare shell.
- Wizard, suffix collision (~1/10000): surfaced as today's existing
  "already active" error — no silent retry-with-new-suffix (honestly
  documented residual gap, not hidden).
- Ctrl-D/EOF during masked read: treated as empty input (matches current
  `read` EOF behavior).
- `TMX_EXACT_NAME` + genuine name collision: unchanged existing
  collision-refusal (exit 4).

## Test plan

- **Unit (Go):** `TestHasPassword` — 0/1/2 cases, existing set/verify
  tests untouched.
- **77_password_masked_echo.sh** — PTY-driven, asserts `*` echo + backspace,
  never plaintext.
- **78_wizard_suffix_appended.sh** — PTY-driven, asserts created name
  matches `^name-[0-9]{4}$`, two runs with the same base name produce
  different suffixes.
- **79_tmx_exact_name_optout.sh** — `TMX_EXACT_NAME=1` → literal name, no
  suffix.
- **80_wizard_select_existing.sh** — PTY-driven, menu lists pre-created
  sessions + "0) None"; selection attaches; "0"/invalid → bare shell.
- **81_wizard_select_password_protected.sh** — same, chosen session is
  password-protected: exactly one prompt, wrong rejects, correct attaches.
- **82_new_password_confirm_flow.sh** — fresh name: password+confirm
  double-prompt, match succeeds, mismatch retries + message, 3x mismatch
  aborts and session is torn down (`has-session` fails afterward).
- **83_open_existing_password_single_prompt.sh** — root-cause regression
  guard (§11.4.115 RED-on-broken-artifact): reproduce recycle-then-reopen,
  assert exactly ONE password prompt, correct attaches, persisted hash
  unchanged after reopen.
- **84_attach_dead_session_no_prompt.sh** — `attach` on a dead session
  with a persisted password: no prompt, clean error, exit 1.
- **66_session_password.sh**: add `has-password` 0/1/2 cases.
- **68_session_lifecycle.sh**: rewrite C6 (verify-once semantics) and C7
  (set+confirm-twice semantics) per §11.4.120 gate reconciliation, citing
  this design doc in the commit.
- **Challenges bank** (`scripts/challenges/tmux.yaml`): new entries for
  suffix-on-create, single-prompt-reopen, double-prompt-create,
  wizard-picker-on-blank — each scored PASS only on captured PTY evidence.
- **HelixQA:** no HelixQA submodule is currently wired into this project
  (confirmed absent during exploration) — honest gap, tracked as a
  follow-up item rather than fabricated.
- **Meta-test (§1.1):** paired mutation per new gate (e.g. mutate the
  masking function to echo plaintext → test 77 must FAIL; mutate
  `has-password` to always return 2 → test 83 must FAIL).

## Documentation plan

| Doc | Update |
|---|---|
| `README.md` | Commands table note on new password/wizard semantics. |
| `docs/guides/tmx-shell-integration.md` | Rewrite wizard section: suffix, picker, masking, `TMX_EXACT_NAME`. |
| `docs/guides/tmx-session-passwords.md` (new) | Standalone password-subsystem guide: create-flow, open-flow, masking, recycle interaction, delete-reset semantics. |
| FAQ | New Q&As: double-password-prompt history, exact-name scripting, existing-session picker. |
| Diagrams | Wizard decision tree + new/attach password decision flow (Mermaid, rendered as images per §11.4.168). |
| Workable-items DB | 4 new ATM-NNN tickets (suffix, masking, double-prompt bug, wizard picker), full descriptions, closure evidence on Fixed.md migration. |
| `docs/CONTINUATION.md` | Live state, same commit as code. |
| `CHANGELOG.md` + `VERSION` | Bumped at release phase. |

## Out of scope

- No change to `tmx ls`, `tmx kill-session`, `tmx delete`, `tmx reload`
  verb contracts beyond what's described above.
- No change to color parsing, cwd-restore, recycler timing, or OS-native
  isolation (systemd scope / rlimit wrapper) mechanics.
- No HelixQA autonomous session (submodule not present in this project —
  tracked as a follow-up, not fabricated).
