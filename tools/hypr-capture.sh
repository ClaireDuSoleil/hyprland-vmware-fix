#!/usr/bin/env bash
# Capture live state of a hung Hyprland. Run over SSH WHILE it is frozen.
set -u
OUT=~/hypr-hang-$(date +%H%M%S)
mkdir -p "$OUT"
PID=$(pgrep -x Hyprland | head -1)
echo "Hyprland pid: ${PID:-NOT RUNNING}" | tee "$OUT/00-pid.txt"
[ -z "${PID:-}" ] && { echo "not running"; exit 1; }

# 1. Is the wayland event loop alive at all? (5s timeout -> hung if it times out)
timeout 5 hyprctl version   > "$OUT/01-hyprctl-version.txt" 2>&1
echo "hyprctl exit: $?"     >> "$OUT/01-hyprctl-version.txt"
timeout 5 hyprctl monitors  > "$OUT/02-hyprctl-monitors.txt" 2>&1

# 2. Where is every thread stuck?
gdb -p "$PID" -batch \
    -ex "set pagination off" \
    -ex "thread apply all bt" > "$OUT/03-threads.txt" 2>&1

# 3. Kernel-side view per thread
for t in /proc/$PID/task/*; do
  echo "== $t wchan=$(cat $t/wchan 2>/dev/null) state=$(awk '{print $3}' $t/stat 2>/dev/null)"
done > "$OUT/04-wchan.txt"

# 4. DRM / page-flip state
sudo cat /sys/kernel/debug/dri/0/state    > "$OUT/05-drm-state.txt" 2>&1
sudo cat /sys/kernel/debug/dri/0/clients  > "$OUT/06-drm-clients.txt" 2>&1

# 5. Kernel blocked-task dump
sudo sh -c 'echo w > /proc/sysrq-trigger' 2>/dev/null
sleep 1
sudo dmesg -T | tail -120 > "$OUT/07-dmesg.txt" 2>&1

echo "captured -> $OUT"
