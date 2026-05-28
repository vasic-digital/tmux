#!/usr/bin/env python3
# synthetic_alt_screen_app.py — minimal TUI surrogate for tests 47 / 48.
#
# Forensic anchor: operator mandate (this turn) — "we MUST BE able to
# scroll vertically everywhere and copy/paste anything! Especially in
# Claude Code (claude command)!" Real Claude Code TUIs request mouse
# tracking, which makes tmux's default MouseDrag1Pane forward the drag
# to the application instead of starting a tmux selection. We can't
# easily drive `claude` itself from a test (OAuth, interactive prompts,
# §11.4.98 full-automation anti-bluff). So this script emulates the
# exact surface that breaks the selection path:
#
#   CSI ?1049h  Switch to alternate-screen buffer (#{alternate_on}=1).
#   CSI ?1003h  Enable any-event mouse tracking (#{mouse_any_flag}=1).
#   CSI ?1006h  Switch to SGR mouse-encoding (modern apps use this).
#
# It then sits in a stdin read loop printing repr(data) to stdout so
# the spawning test can poll the pane for liveness via capture-pane.
#
# Cleanup on exit: restore (`CSI ?1003l`, `CSI ?1006l`, `CSI ?1049l`)
# so a stuck instance does not leave the operator's terminal in a bad
# state. Per Constitution §11.4.14 test playback cleanup.
#
# §11.4.18 + §11.4.81 — pure stdlib Python 3, no extra deps;
# runs on macOS arm64 and Linux x86_64 host.

import os
import signal
import sys


CSI = b"\x1b["
ENABLE_SEQUENCES = (
    CSI + b"?1049h",  # alt-screen ON
    CSI + b"?1003h",  # any-event mouse tracking
    CSI + b"?1006h",  # SGR mouse encoding
)
DISABLE_SEQUENCES = (
    CSI + b"?1003l",
    CSI + b"?1006l",
    CSI + b"?1049l",
)
READY_MARKER = "SYNTHETIC_ALT_SCREEN_READY"


def emit(seq_tuple):
    for seq in seq_tuple:
        try:
            os.write(sys.stdout.fileno(), seq)
        except OSError:
            return


def restore_and_exit(_signum=None, _frame=None):
    emit(DISABLE_SEQUENCES)
    try:
        sys.stdout.flush()
    except Exception:
        pass
    os._exit(0)


def main():
    # Enable alt-screen + mouse tracking + SGR encoding.
    emit(ENABLE_SEQUENCES)
    # Liveness marker — tests poll capture-pane for this string. Stays
    # printed even after the alt-screen swap because we emit it AFTER
    # ?1049h, so the marker lives on the alternate buffer (which is
    # what `capture-pane` sees by default).
    sys.stdout.write(READY_MARKER + "\n")
    sys.stdout.flush()

    # Restore on common signals so the test's trap-on-EXIT cleanup is
    # effective even if tmux kills the pane.
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(sig, restore_and_exit)
        except (ValueError, OSError):
            pass

    # Block forever reading stdin. The test never sends anything; it
    # just needs the pane to stay alive with the modes active.
    try:
        while True:
            data = sys.stdin.buffer.read(4096)
            if not data:
                # stdin closed — exit cleanly.
                break
            # Echo what we got so a test could verify it.
            sys.stdout.write("RX " + repr(data) + "\n")
            sys.stdout.flush()
    except Exception:
        pass
    finally:
        restore_and_exit()


if __name__ == "__main__":
    main()
