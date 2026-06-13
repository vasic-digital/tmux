# Scrolling terminal output in `tmx`

This build is configured so you can scroll back through terminal output
**from any device** — a desktop mouse, a laptop trackpad, or a phone
(Termux on Android) — and it works the same inside full-screen TUIs such
as the Claude Code TUI.

All of this is set up automatically by `bash scripts/setup.sh`. The
settings live in [`scripts/tmux.conf.template`](../scripts/tmux.conf.template),
which the `tmx` wrapper loads on every `tmx new`.

## What you get

| Setting | Value | Why |
|---|---|---|
| `history-limit` | `50000` lines | Output history survives — you can scroll a long way back. |
| `mode-keys` | `vi` | vi-style navigation in copy-mode. |
| `mouse` | **`off` (default)** | The **terminal** owns the mouse, so native click-drag selection (including multi-line), right-click → Copy, and the terminal's own scrollbar / wheel scroll all work — identically on Linux and macOS, on every emulator (iTerm2, Terminal.app, GNOME Terminal, WezTerm, …). |
| `prefix m` | toggle `mouse on` | On demand: enable tmux's own mouse so the **wheel drives tmux scrollback inside full-screen TUIs** (Claude Code / HelixCode), plus tmux drag-select that copies to the OS clipboard. Press `prefix m` again to return to native. |
| `WheelUpPane` / `WheelDownPane` | copy-mode override | While tmux mouse is ON, the wheel **always** scrolls tmux's own buffer — even inside Claude Code. |
| `allow-passthrough` | `on` | Apps can pass escape sequences through tmux. |
| `extended-keys` | `on` | Modified keys (e.g. `Shift+Enter`) reach the app. |

## Default: native terminal scrolling (mouse off)

The shipped config ships with **`mouse off`** as the default. With mouse
off tmux emits **zero** mouse-tracking enables (no `CSI ?1000h` /
`?1002h` / `?1006h`), so the emulator's own mouse is unobstructed: scroll
with the **wheel / trackpad / scrollbar exactly as in any terminal**, and
select text with a native click-drag → `Cmd-C` / right-click → Copy.
This is the path that works everywhere — Linux and macOS, every emulator,
inside or outside a TUI — proven at the wire level by test 59.

## Scrolling tmux's own scrollback inside a TUI (`prefix m`)

A full-screen TUI such as the Claude Code / HelixCode TUI runs on the
terminal's **alternate screen**, which has no scrollback of its own. With
the default `mouse off`, your wheel scrolls the *terminal's* buffer, not
tmux's 50 000-line history.

To page back through tmux's scrollback inside such a TUI, press
**`prefix m`** to toggle tmux mouse **ON**. The shipped config overrides
`WheelUpPane` / `WheelDownPane` so that, while mouse is on, the wheel
(and a touch-scroll, which terminals deliver as wheel events) **always**
drives tmux copy-mode scrollback regardless of what the running
application does with the mouse. Press `prefix m` again to return to
native terminal scrolling. The status line confirms the new state each
time.

## How to scroll

### Default (mouse off) — native terminal scroll

- **Scroll up / down** — wheel, trackpad, or the terminal's scrollbar,
  exactly as in any other terminal window. tmux is not involved.

### Inside a TUI, after `prefix m` (mouse on) — tmux scrollback

- **Scroll up** — wheel up. tmux enters copy-mode and scrolls back.
- **Scroll down** — wheel down. When you reach the bottom, copy-mode
  exits automatically.
- Press **`prefix m`** again to return to native terminal scrolling.

### Without a mouse — keyboard (and phones)

- `Ctrl-b` then `[` — enter copy-mode.
- `Ctrl-b` then `PageUp` — enter copy-mode **and** page up in one motion.
- In copy-mode: `k`/`j` line up/down, `Ctrl-u`/`Ctrl-d` half-page,
  `PageUp`/`PageDown`, `g`/`G` top/bottom, `/` search forward,
  `?` search back, `q` to exit.

### On a phone (Termux / Android)

- **Touch-scroll** the terminal — Termux delivers the swipe as wheel
  events, so it enters copy-mode and scrolls, exactly like a mouse.
- The `Ctrl-b [` route also works using Termux's extra-keys row
  (enable it with a long-press on the keyboard area if hidden).

## Copying text

**Default (mouse off):** just select with the **native terminal** —
click-drag (including across multiple lines), then `Cmd-C` /
right-click → Copy. This works in every emulator on Linux and macOS, and
it is the recommended copy path. To paste the OS clipboard back into a
pane: native paste (`Cmd-V` / right-click → Paste), or `prefix P` to
paste via a keyboard binding.

**On demand (after `prefix m`, mouse on):** a tmux mouse drag selects and
copies on release; or in copy-mode press `v` to start a selection, move
the cursor, then `y` or `Enter` to copy. The tmux selection is routed to
your system clipboard automatically — the config detects `pbcopy`
(macOS), `wl-copy` (Wayland), `xclip` (X11), or `termux-clipboard-set`
(Termux) at copy time, and also emits OSC-52 so copying works over SSH and
on terminals that support it.

> Why the default flipped to `mouse off`: with `mouse on`, tmux emitted
> mouse-tracking enables that **suppressed** the emulator's native
> selection and right-click → Copy — the root cause of the long-standing
> "can't select / copy" reports. With `mouse off` the native mouse is
> unobstructed (proven by test 59), and `prefix m` gives you the tmux
> mouse on demand.

## Verifying it works

The behaviour is covered by `scripts/tests/17_scrollback_copy_mode.sh`,
which runs as part of the verification gate. It spawns a real session
via `tmx new`, generates 3000 lines of output, proves the first line
scrolled off the visible screen, then proves copy-mode can scroll back
to it and copy it — all with captured runtime evidence per the
anti-bluff covenant.

```bash
bash scripts/tests/17_scrollback_copy_mode.sh
# → PASS=13  FAIL=0  SKIP=0
```

## Re-applying after a config change

`scripts/tmux.conf.template` is the single source. After editing it (or
pulling an update), re-run `bash scripts/setup.sh` — or, in a running
session, `tmx` picks up the template on the next `tmx new`. To reload
into an already-running session: `Ctrl-b` then `:source-file ~/.tmux.conf`.

## Sources verified 2026-06-13

- **tmux upstream man page** — <https://man.openbsd.org/tmux.1> (re-verified
  2026-06-13 via WebFetch; OpenBSD ships the canonical upstream `tmux.1`).
  Confirms `set-clipboard external` semantics ("tmux will attempt to set
  the terminal clipboard but ignore attempts by applications to set tmux
  buffers" — the OSC-52 copy-out path) and that a flag/choice option set
  with its value omitted toggles its value (the `prefix m` / `set -g mouse`
  toggle). The `mouse off` ⇒ no mouse-tracking DECSET enables behaviour is
  proven at the wire level in this repo by test 59
  (`scripts/tests/59_*.sh`), which is the load-bearing authority for the
  default-architecture claims above.
