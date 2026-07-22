#!/usr/bin/env bash
# throttle_sampler.sh — time-series evidence sampler for the tmx CPU-quota
# investigation (2026-07-22). Samples cgroup cpu.stat + memory + pids and
# tmux-server RSS/fd every 10 s. Output: TSV to stdout.
D=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice/tmx-atmosphere-0993.scope
TMUX_PID=3394
N=${1:-45}
echo -e "epoch\tnr_periods\tnr_throttled\tthrottled_usec\tusage_usec\tmem_current\tpids_current\ttmux_rss_kb\ttmux_fds\tcpu_max"
i=0
while [ "$i" -lt "$N" ]; do
  s=$(cat "$D/cpu.stat" 2>/dev/null)
  np=$(echo "$s" | awk '/^nr_periods/{print $2}')
  nt=$(echo "$s" | awk '/^nr_throttled/{print $2}')
  tu=$(echo "$s" | awk '/^throttled_usec/{print $2}')
  uu=$(echo "$s" | awk '/^usage_usec/{print $2}')
  mc=$(cat "$D/memory.current" 2>/dev/null)
  pc=$(cat "$D/pids.current" 2>/dev/null)
  cm=$(cat "$D/cpu.max" 2>/dev/null | tr ' ' '/')
  rss=$(awk '/^VmRSS/{print $2}' /proc/$TMUX_PID/status 2>/dev/null)
  fds=$(ls /proc/$TMUX_PID/fd 2>/dev/null | wc -l)
  echo -e "$(date +%s)\t$np\t$nt\t$tu\t$uu\t$mc\t$pc\t$rss\t$fds\t$cm"
  i=$((i+1))
  sleep 10
done
