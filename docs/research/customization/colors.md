# Tmux colors customizations

How can we change the bottom green panel from green color to some other in tmux? Is it possible to be parametrized or we have to modify source code?

## Answer

To change the color of that green bottom bar (called the **status line**), you don’t need to modify any source code. It’s completely configurable through tmux’s own options. You can set the color directly from the command line, or make it permanent in your `~/.tmux.conf` file.

### 🔧 The Quick Way (temporary change)
1. Press your prefix key (usually `Ctrl+b`), then type `:` to enter command mode.
2. Type the following command and press Enter:
   ```
   set -g status-style bg=blue,fg=white
   ```
   Replace `blue` and `white` with whatever colors you prefer. For example, to replicate the classic black background:
   ```
   set -g status-style bg=black,fg=white
   ```

### ⚙️ The Permanent Way (through your config file)
Add this line to your `~/.tmux.conf` file:
```bash
# Set status bar background and foreground colors
set -g status-style 'bg=black,fg=white'
```
After saving the file, reload the configuration with:
```
tmux source-file ~/.tmux.conf
```
Or, from within tmux, use `Prefix` + `:` and run:
```
source-file ~/.tmux.conf
```

### 🎨 Available Color Options
You can use:
- **Basic color names**: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`
- **Extended 256‑color palette**: `colour0` to `colour255` (e.g., `colour240` is a nice dark gray)
- **Hexadecimal RGB values**: `#ff0000` (requires terminal support for true color)
- **`default`**: makes the status bar transparent (inherits the terminal’s background)

Example:
```bash
set -g status-style 'bg=colour240,fg=colour255'
```

### 💡 Making It Dynamic (Parameterization)
Yes, you can dynamically change the status bar color based on conditions. Tmux supports `%if` statements and format variables. For instance, this snippet changes the bar to red when running on a host named “myhost”, green on “myotherhost”, or blue otherwise:
```bash
%if "#{==:#{host},myhost}"
  set -g status-style bg=red
%elif "#{==:#{host},myotherhost}"
  set -g status-style bg=green
%else
  set -g status-style bg=blue
%endif
```
You can even use shell commands or environment variables to set the color, for example:
```bash
run "tmux set -g status-style bg=$MY_TMUX_COLOR"
```

### 🕶️ Hiding the Status Bar Altogether
If you’d rather not see the bar at all, add this to your config:
```bash
set -g status off
```

### 📖 Further Reading
- [tmux man page (status-style)](https://www.nevis.columbia.edu/cgi-bin/man.sh?man=tmux) – official documentation.
- [tmux bottom status bar color change (Unix & Linux Stack Exchange)](https://unix.stackexchange.com/questions/60968) – community discussion with multiple methods.
- [tmux の status line の色を変更 (Qiita)](https://qiita.com/mnishiguchi/items/18ff80c0cb8269ff6dd8) – a clear, step‑by‑step guide.

So, to answer your question directly: **No source modification is required.** Everything you need is already built into tmux’s configuration system.


---

## Implementation: Hostname-Derived Status-Bar Color

The vasic-digital tmux project implements an algorithm that maps each host's
hostname to a deterministic colour from a curated 27-colour palette, making
visually distinguishable tmux sessions across different connected machines.

### Algorithm

File: `scripts/hostname_color.sh`

1. **DJB2 hash** of the hostname string (31-bit, positive)
2. **Palette index** = hash modulo palette size (27)
3. **Output** = `colourNNN` (xterm 256-colour name)

The palette selects visually distinct colours that work well as tmux
`status-bg` backgrounds with white foreground text:

```
colour1   colour3   colour4   colour5   colour6
colour9   colour11  colour12  colour13  colour14
colour52  colour88  colour130 colour166 colour172
colour178 colour190 colour196 colour198 colour199
colour200 colour202 colour208 colour214 colour220
colour226 colour240
```

### Integration

The `scripts/tmx` wrapper invokes `hostname_color.sh` after the tmux server
starts and applies the colour via:

```
tmux set -g status-style bg=<colour>
```

The colour is set both on session creation (`new-session`, `start-server`)
and on re-attach, so it always reflects the current host.

### Verification

| Test | Scope | Evidence |
|------|-------|----------|
| `10_hostname_color_algorithm.sh` | 5 invariants: deterministic, valid format, palette membership, spread, empty-fallback | Captured hash/index/colour output |
| `11_hostname_color_integration.sh` | Wrapper applies correct colour to tmux server | `show -g status-style` readback matched to algorithm output |

### Usage

```bash
# Manually query the colour for any hostname
bash scripts/hostname_color.sh                      #  colour52 (this host)
bash scripts/hostname_color.sh myserver.example.com  #  colour166
```

### Anti-bluff covenant (Constitution 1)

- Every PASS in both tests carries positive runtime evidence:
  - The algorithm test prints hash, index, and colour for known inputs.
  - The integration test reads `status-style` back from the running
    tmux server and compares it to the algorithm's expected output.
- The colour computation is deterministic -- same hostname always
  produces the same colour. No randomness. No state.
- FAIL-bluff protection: all scripts use `set -uo pipefail` and guard
  every variable reference.
