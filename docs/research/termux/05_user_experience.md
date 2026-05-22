# §05 — End-User Experience on Termux

**Revision:** 1
**Last modified:** 2026-05-22T07:20:02Z
**Authority:** vasic-digital tmux project (research-only)
**Maintainer:** milosvasic
**Scope:** Day-to-day UX considerations for operators using `tmx` inside Termux on a phone or tablet

---

## 1. Where to install Termux from

**Use F-Droid. Not Google Play.**

The Play Store version of Termux is **frozen at 2022** and unmaintained. From the official announcement (<https://github.com/termux/termux-app/discussions/4000>): Google's Play policies in 2022 began requiring `targetSdkVersion=30+`, which (combined with Google's W^X mitigation in Android 10+) prevents Termux from executing files in its private data directory. Termux's only viable path forward was to abandon the Play release and update only via F-Droid + GitHub.

The XDA write-up confirms: *"The last version was released in 2022 due to Google Play policy requirements"* (<https://www.xda-developers.com/termux-terminal-linux-google-play-updates-stopped/>).

| Source | Status | Recommendation |
|---|---|---|
| F-Droid (<https://f-droid.org/en/packages/com.termux/>) | actively maintained | **use this** |
| GitHub releases (<https://github.com/termux/termux-app/releases>) | actively maintained | also acceptable; direct APK download |
| Google Play Store | frozen 2022, missing fixes | **do NOT use** |

A migration guide for operators who have the Play version installed: <https://docs.andronix.app/termux/migrating-to-f-droid> — uninstall Play version, install F-Droid version. Configuration is lost (it lives in app data) so the operator should back up `~/.ssh/` and other personal state first.

## 2. First-time install steps

```bash
# 1. Install Termux from F-Droid.
# 2. Open Termux.

# 3. Update the system:
pkg upgrade -y

# 4. Install Termux:Boot (separately, from F-Droid):
#    f-droid.org/en/packages/com.termux.boot/
#    Open it once after install to enable boot autostart.

# 5. Install Termux:API (optional but useful, also from F-Droid):
#    f-droid.org/en/packages/com.termux.api/
#    Required for termux-wake-lock and other system integrations.

# 6. Install our dependencies:
pkg install -y bash zsh openssh git tmux libevent libjemalloc \
              build-essential clang make autoconf automake pkg-config \
              bison ncurses-dev golang

# 7. Clone our project:
git clone https://github.com/vasic-digital/tmux ~/tmux-project
cd ~/tmux-project
git submodule update --init --recursive

# 8. Build:
bash scripts/setup.sh

# 9. Source the shell-init into ~/.bashrc:
echo '. ~/tmux-project/scripts/tmx-shell-init.sh' >> ~/.bashrc

# 10. Restart Termux session; verify:
tmx ls
```

## 3. Touch keyboard UX

A tmux prefix is hard to type on a touch keyboard. Termux provides several mitigations:

- **Volume Down = Ctrl emulation.** "VOLUME DOWN + L" sends Ctrl+L. Built-in, works everywhere. Source: <https://www.learntermux.tech/2024/02/blog-post.html>.
- **Volume Up = Esc / function-keys.** "VOLUME UP + Q" toggles the extra-keys row visibility; "VOLUME UP + K" same. Source: <https://termuxtools.com/tmux-screen-terminal-multiplexing-termux/>.
- **Extra Keys row.** A configurable bottom-of-screen row of keys (Ctrl, Alt, Esc, arrows, Tab, function keys) — visible by default. Customisable via `~/.termux/termux.properties` since Termux v0.66. Each key supports a popup (swipe-up gesture) since Termux v0.95. Source: <https://mobile-coding-hub.github.io/termux/customisation/extra_keys/>.
- **External keyboard.** Bluetooth + USB-OTG keyboards work natively; if the operator has one, the experience approaches a Linux desktop.

For our `tmx`'s default behaviour, no special config is needed. The standard tmux prefix `Ctrl-b` is typed as VolDown+b. For heavier users we'd recommend `unbind C-b ; set -g prefix C-a ; bind a send-prefix` (already a common community choice) — but that's NOT a Termux-specific change. Project default stays.

## 4. Scrollback / copy mode

The existing scrolling work (project Applied Fix A16) explicitly mentions Termux compatibility. From `CLAUDE.md`:

> | A16 | tmux scrolling fix for Claude Code TUI + mobile/Termux | `scripts/tmux.conf.template`, `scripts/tests/17_*.sh` |

So scrollback is already a tested concern. Termux + tmux community guidance:
- Enter copy-mode with `Prefix + [`.
- Arrow keys + PgUp/PgDn navigate the scrollback buffer.
- Mouse support (`set -g mouse on`) lets the operator scroll with two-finger swipe on the touchscreen.
Source: <https://termuxtools.com/tmux-screen-terminal-multiplexing-termux/>.

`A16` should already give us a baseline operator experience. A Termux test run of `scripts/tests/17_*.sh` would confirm the fix carries through to the Android port.

## 5. Background survival — the wake-lock dance

The biggest UX trap is that Android suspends background apps aggressively. Without intervention, `tmx new -s work`, switching to the home screen, and coming back an hour later finds the session dead and the wrapper unable to attach.

Mitigations the operator must apply:

1. **`termux-wake-lock`** — acquires an Android partial wake lock for Termux. CPU stays available with screen off. Run once per Termux session (or once at boot via `~/.termux/boot/start-sshd`).
2. **Battery optimization → Unrestricted.** Phone Settings → Apps → Termux → Battery → Unrestricted. This excludes Termux from Doze. (Path varies by OEM but the option exists everywhere.) Source: <https://github.com/termux/termux-app/issues/377>.
3. **Disable Phantom Process Killer (Android 12+).** Either via Developer Options "Disable child process restrictions" (Android 14+ has the toggle) or ADB: `adb shell "settings put global settings_enable_monitor_phantom_procs false"`. Source: <https://maheshtechnicals.com/fix-termux-error-process-completed-signal-9-disable-phantom-process-killer-in-android-12-13/>.
4. **OEM-specific.** Xiaomi MIUI, Oppo ColorOS, Vivo FunTouchOS, Huawei HarmonyOS each have their own aggressive memory managers stacked on top of stock Android. Adding Termux to "Autostart" / "Locked apps" / "Allowed in background" in the OEM settings is a per-vendor incantation. <https://dontkillmyapp.com> is a community-maintained directory of these workarounds.

Our wrapper should DETECT Termux and print a one-time first-run notice listing the above. Possibly add a `tmx doctor` subcommand that probes:
- `termux-wake-lock` available? (yes/no)
- Battery optimization setting (queryable via `dumpsys deviceidle`)
- Phantom killer setting (queryable via `settings get global settings_enable_monitor_phantom_procs`)
- OEM family (queryable via `getprop ro.product.manufacturer`)

## 6. Fonts and colours

Termux supports custom fonts (`~/.termux/font.ttf`) and colour schemes (`~/.termux/colors.properties`). Defaults are sane and our hostname-colour palette (Applied Fix A12 family) renders correctly — confirmed by the existing scrolling/colour work that ALREADY mentions Termux.

UNCONFIRMED: whether `scripts/hostname_color.sh`'s deterministic palette assignment produces enough contrast against Termux's default dark background for every hostname. Resolution: visual check on actual device once a port lands.

## 7. Filesystem visibility

Termux's `$HOME` is isolated — other Android apps cannot read it (SELinux denies). For the operator this means:
- Project files cloned with `git clone` live in `~/tmux-project` and are SAFE from accidental phone-app data corruption.
- BUT: Android's external storage (`/sdcard`, `/storage/emulated/0`) is shared with other apps. Termux can request access via `termux-setup-storage` (creates `~/storage/` symlinks). Useful for sharing files with editor apps.

For our use case (running tmux + Claude Code TUI inside tmux) the operator stays in `~/`.

## 8. Networking — how is the phone reachable?

Three options for the SSH dispatch use case:
1. **Same Wi-Fi LAN.** Phone gets an IP from the router; laptop ssh's `-p 8022` to it. Easiest setup. Phone IP changes on reconnect (DHCP) → use mDNS (`<phone-name>.local` works on most home routers) or fixed reservation.
2. **Tailscale.** Install Tailscale on phone (Play Store version IS fine — Tailscale is not subject to the Termux issue). Run `tailscale up` from Termux. Phone gets a fixed `100.x.x.x` IP visible from any other Tailscale node. Recommended for road warriors.
3. **Cellular network.** Phone behind carrier NAT — no inbound SSH possible without a relay. Tailscale or a reverse-tunnel script (`autossh -R 8022:localhost:8022 jumphost`) needed.

Document option 2 in operator guide as the recommended remote-access path.

## 9. Storage cost

Termux base install + our deps + the project tree is approximately:
- Termux app + OpenSSH: ~150 MB
- Build deps (clang, make, libevent-dev, etc.): ~400 MB
- Project tree + submodules + build output: ~50-100 MB

Total: ~600-700 MB. Comfortable on any modern phone (32 GB+ storage standard). UNCONFIRMED — exact disk usage measurement requires running the install on a real device.

## 10. Charging consideration

Active tmux + Claude Code TUI + wake-lock + screen-on drains a phone at 5-15%/hour depending on workload. For multi-hour sessions plug in. For background-only sessions (wake-lock held, screen off) drain is 2-5%/hour — viable for overnight tasks. UNCONFIRMED — measurements depend on phone model.

## 11. Recommended `~/.bashrc` snippet for Termux

Once the port lands, the snippet our `setup.sh` installs would be:
```sh
# ─── vasic-digital optimized tmux (Termux) ───
export PATH="$HOME/tmux-project/scripts:$PATH"
[ -f "$HOME/tmux-project/scripts/tmx-shell-init.sh" ] && \
    . "$HOME/tmux-project/scripts/tmx-shell-init.sh"
# ─── end vasic-digital optimized tmux (Termux) ───
```

Same shape as the Linux/macOS snippet. The `[ -f ... ]` guard means subsequent uninstalls cleanly remove the dependency without breaking shell startup.

## 12. Summary: UX gaps

| Gap | Severity | Mitigation |
|---|---|---|
| Touch keyboard for tmux prefix | Medium | VolDown+Ctrl emulation; recommend remap to `C-a` |
| Background suspension by Doze | High | `termux-wake-lock` + battery-opt unrestricted |
| Phantom Process Killer (Android 12+) | High | ADB-disable via developer options |
| OEM aggressive memory managers | Medium-High | dontkillmyapp.com per-vendor instructions |
| Play Store version is frozen | High (first-time installs) | Document F-Droid as the only supported source |
| Storage cost of build deps | Low | Already small fraction of modern phone storage |
| Charging during long sessions | Low | Operator practical concern only |

## Sources

- <https://github.com/termux/termux-app/discussions/4000> — official Termux Play Store frozen announcement
- <https://www.xda-developers.com/termux-terminal-linux-google-play-updates-stopped/>
- <https://f-droid.org/en/packages/com.termux/>
- <https://docs.andronix.app/termux/migrating-to-f-droid>
- <https://github.com/termux/termux-boot>
- <https://www.learntermux.tech/2024/02/blog-post.html> — touch keyboard guide
- <https://termuxtools.com/tmux-screen-terminal-multiplexing-termux/> — tmux on Termux specifics
- <https://mobile-coding-hub.github.io/termux/customisation/extra_keys/> — extra-keys row
- <https://github.com/termux/termux-app/issues/377> — Doze + wake-lock interaction
- <https://maheshtechnicals.com/fix-termux-error-process-completed-signal-9-disable-phantom-process-killer-in-android-12-13/>
- <https://dontkillmyapp.com> — OEM-specific battery-killer workarounds
