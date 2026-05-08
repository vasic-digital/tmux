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

