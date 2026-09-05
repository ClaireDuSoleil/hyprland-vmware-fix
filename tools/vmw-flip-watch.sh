#!/usr/bin/env bash
# Watch whether a VMware guest's display pipeline is alive.
#
# Samples two numbers that together distinguish "the compositor is broken" from
# "the display pipeline stopped":
#
#   irq  -- total interrupts on the vmwgfx line. Frozen => the device is delivering no
#           vblank / page-flip-completion events.
#   fb   -- the framebuffer id currently committed to the CRTC. Frozen => no page flips.
#
# A healthy idle desktop still flips periodically. Both numbers frozen while the compositor
# burns CPU is the signature of a stalled flip, NOT of a hung compositor.
#
# Run as root (it reads debugfs), from SSH, and leave it running:
#
#     sudo bash vmw-flip-watch.sh 5 | tee ~/flip-watch.log
#
# Mark phases as you go so the log is readable afterwards:
#
#     echo "=== window foregrounded $(date +%T)" >> ~/flip-watch.log

set -u
INTERVAL=${1:-5}
STATE=/sys/kernel/debug/dri/0/state

[[ $EUID -eq 0 ]] || { echo "run me as root: sudo bash $0 $*" >&2; exit 1; }
[[ -r $STATE ]] || { echo "cannot read $STATE (is debugfs mounted?)" >&2; exit 1; }

prev_irq=; prev_fb=
while true; do
    # sum every numeric per-CPU column on the vmwgfx line
    irq=$(awk '/vmwgfx/{s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s; exit}' /proc/interrupts)
    fb=$(grep -m1 -oE 'fb=[0-9]+' "$STATE" | cut -d= -f2)
    d_irq=$([[ -n $prev_irq ]] && echo $(( irq - prev_irq )) || echo -)
    flip=$([[ -n $prev_fb && $fb != "$prev_fb" ]] && echo FLIP || echo same)
    printf '%s irq=%-10s d_irq=%-8s fb=%-6s %s\n' "$(date +%H:%M:%S)" "${irq:-?}" "$d_irq" "${fb:-?}" "$flip"
    prev_irq=$irq; prev_fb=$fb
    sleep "$INTERVAL"
done
