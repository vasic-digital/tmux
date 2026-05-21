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
| `mouse` | `on` | Wheel + touch scrolling. |
| `WheelUpPane` / `WheelDownPane` | copy-mode override | The wheel **always** scrolls tmux's own buffer — even inside Claude Code. |
| `allow-passthrough` | `on` | Apps can pass escape sequences through tmux. |
| `extended-keys` | `on` | Modified keys (e.g. `Shift+Enter`) reach the app. |

## The Claude Code TUI fix

The Claude Code TUI requests mouse reporting from the terminal. With
tmux's *default* wheel binding, that means the wheel is forwarded to
Claude Code instead of scrolling tmux's scrollback — so you cannot
scroll back through earlier output.

This build overrides `WheelUpPane` / `WheelDownPane` so the wheel (and a
touch-scroll, which terminals deliver as wheel events) **always** drives
tmux copy-mode scrollback. You scroll the real output history regardless
of what the running application does with the mouse.

## How to scroll

### With a mouse or trackpad

- **Scroll up** — wheel up. tmux enters copy-mode and scrolls back.
- **Scroll down** — wheel down. When you reach the bottom, copy-mode
  exits automatically.

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

In copy-mode: press `v` to start a selection, move the cursor, then
press `y` or `Enter` to copy. A mouse drag also selects and copies on
release.

The selection is routed to your system clipboard automatically — the
config detects `pbcopy` (macOS), `wl-copy` (Wayland), `xclip` (X11), or
`termux-clipboard-set` (Termux) at copy time, and also emits OSC-52 so
copying works over SSH and on terminals that support it.

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
