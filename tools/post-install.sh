#!/usr/bin/env bash
#
# post-install.sh -- finish the VM after auto-repair.sh has rebooted it.
#
# Three things the patch does not do, in the order you will miss them:
#
#   1. DPMS wake. Hyprland's key_press_enables_dpms and mouse_move_enables_dpms both default
#      to FALSE. When the screen blanks, neither the keyboard nor the mouse brings it back,
#      and a perfectly healthy compositor looks exactly like the bug you just fixed.
#   2. open-vm-tools, for a display that resizes with the VMware window.
#   3. Resolution and scale. Omarchy ships omarchy_gdk_scale = 2, which on a VM gives you
#      enormous UI in every GTK application.
#
# Run it after the reboot, from a terminal in the desktop or over SSH:
#
#     ~/hyprland-vmware-fix/tools/post-install.sh
#
#     --dry-run   show every change, write nothing
#     --yes       do not ask anything
#
# Re-running is safe. Config edits go inside marked blocks that are replaced, not appended,
# and every file touched is backed up first.

set -euo pipefail

# =====================================================================================
# CONFIGURATION -- edit, or override from the environment:
#     MONITOR_MODE=2560x1600@60 ./post-install.sh
# =====================================================================================

# Output name. "auto" asks hyprctl for the first connected monitor. On VMware this is
# normally Virtual-1.
MONITOR_OUTPUT="${MONITOR_OUTPUT:-auto}"

# Resolution and refresh. Must be one of the modes the driver actually offers -- the script
# checks and warns before writing.
MONITOR_MODE="${MONITOR_MODE:-1920x1200@60}"

MONITOR_POSITION="${MONITOR_POSITION:-auto}"

# Hyprland's own scaling. 1 means "no scaling", which is what you want on a VM.
MONITOR_SCALE="${MONITOR_SCALE:-1}"

# GDK_SCALE for GTK applications. Omarchy defaults this to 2. Set to "skip" to leave it.
GDK_SCALE_VALUE="${GDK_SCALE_VALUE:-1}"

# Make key presses and mouse movement wake a blanked screen.
ENABLE_DPMS_WAKE="${ENABLE_DPMS_WAKE:-yes}"

# open-vm-tools: display autofit and host-guest clipboard for X11/XWayland clients.
INSTALL_OPEN_VM_TOOLS="${INSTALL_OPEN_VM_TOOLS:-yes}"

# Turn Omarchy's screensaver off. It is the animated "omarchy" wordmark that appears on idle,
# and in a VM it flickers badly enough to be unpleasant.
#
# The command is `omarchy-toggle-screensaver` -- a TOGGLE, not an off switch, so the script
# checks whether the screensaver is actually armed before calling it. Running a toggle blind
# would switch it back ON for anyone who had already disabled it, and this script is meant to
# be re-runnable. If a future release renames it, the script also discovers candidates; set
# SCREENSAVER_DISABLE_CMD to force a specific command.
DISABLE_SCREENSAVER="${DISABLE_SCREENSAVER:-yes}"
SCREENSAVER_DISABLE_CMD="${SCREENSAVER_DISABLE_CMD:-auto}"

HYPR_DIR="${HYPR_DIR:-$HOME/.config/hypr}"

# =====================================================================================

PACMAN=(sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman)
BEGIN_MARK="-- >>> hyprland-vmware-fix >>>"
END_MARK="-- <<< hyprland-vmware-fix <<<"
DRY_RUN=no
ASSUME_YES=no
STEP=0
CHANGED=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=yes ;;
        --yes|-y)  ASSUME_YES=yes ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

step() { STEP=$((STEP+1)); printf '\n\033[1;36m== %d. %s\033[0m\n' "$STEP" "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '\033[32m   ok: %s\033[0m\n' "$*"; }
warn() { printf '\033[33m   warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[31m   FAILED: %s\033[0m\n\n' "$*" >&2; exit 1; }
run()  { printf '\033[2m   $ %s\033[0m\n' "$*"; [[ $DRY_RUN == yes ]] && return 0; "$@"; }

confirm() {
    [[ $ASSUME_YES == yes ]] && return 0
    [[ -e /dev/tty ]] || return 1
    local r; read -r -p "   $1 [y/N] " r </dev/tty || return 1
    [[ $r == [yY]* ]]
}

backup() {
    local f=$1 b="$1.bak-$(date +%Y%m%d-%H%M%S)"
    [[ $DRY_RUN == yes ]] && { info "would back up $f -> $(basename "$b")"; return 0; }
    cp -p "$f" "$b"
    info "backed up -> $(basename "$b")"
}

# write_block <file> <<< "lua content"
# Replaces any previous block between our markers, so re-running never stacks up copies.
write_block() {
    local f=$1 content; content=$(cat)
    [[ -f $f ]] || die "$f does not exist -- is this an Omarchy system?"
    if [[ $DRY_RUN == yes ]]; then
        info "would write this block into $f:"
        printf '%s\n' "$content" | sed 's/^/     | /'
        return 0
    fi
    backup "$f"
    local tmp; tmp=$(mktemp)
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$f" > "$tmp"
    # collapse any trailing blank lines the strip left behind
    printf '%s\n' "$(cat "$tmp")" > "$tmp.2" && mv "$tmp.2" "$tmp"
    { printf '\n%s\n' "$BEGIN_MARK"; printf '%s\n' "$content"; printf '%s\n' "$END_MARK"; } >> "$tmp"
    mv "$tmp" "$f"
    CHANGED+=("$f")
    ok "updated $f"
}

printf '\033[1m\n  Post-install setup for a patched Omarchy VM\033[0m\n'
[[ $DRY_RUN == yes ]] && printf '\033[33m   DRY RUN -- nothing will be changed\033[0m\n'

# ------------------------------------------------------------------ 1. talk to hyprland

step "Find the running compositor"

[[ $EUID -ne 0 ]] || die "run this as your normal user, not root -- it edits your own config"
[[ -d $HYPR_DIR ]] || die "no $HYPR_DIR -- this script is for Omarchy's Lua config layout"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    # /bin/ls, not ls: Omarchy aliases ls to eza, whose -t means --time FIELD, not sort-by-time.
    HIS=$(/bin/ls -t "/run/user/$UID/hypr" 2>/dev/null | head -1 || true)
    [[ -n ${HIS:-} ]] && export HYPRLAND_INSTANCE_SIGNATURE="$HIS"
fi

HAVE_HYPRCTL=no
if command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; then
    HAVE_HYPRCTL=yes
    info "instance:  ${HYPRLAND_INSTANCE_SIGNATURE:-?}"
else
    warn "cannot reach a running Hyprland -- config files will still be written,"
    warn "but the output name cannot be detected and nothing can be verified"
fi

if [[ $MONITOR_OUTPUT == auto ]]; then
    if [[ $HAVE_HYPRCTL == yes ]]; then
        MONITOR_OUTPUT=$(hyprctl monitors | awk '/^Monitor /{print $2; exit}')
        [[ -n $MONITOR_OUTPUT ]] || die "could not detect an output; set MONITOR_OUTPUT by hand"
    else
        MONITOR_OUTPUT=Virtual-1
        warn "defaulting output to Virtual-1"
    fi
fi
info "output:    $MONITOR_OUTPUT"
info "mode:      $MONITOR_MODE   scale $MONITOR_SCALE   position $MONITOR_POSITION"

if [[ $HAVE_HYPRCTL == yes ]]; then
    WANT=${MONITOR_MODE%@*}
    if hyprctl monitors all | grep -q "$WANT"; then
        ok "$WANT is in the driver's mode list"
    else
        warn "$WANT is not listed by 'hyprctl monitors all' -- it may be rejected"
        warn "available modes:"
        hyprctl monitors all | awk '/availableModes/{print "     " $0}' | head -3
        confirm "write it anyway?" || die "stopped"
    fi
fi

# ------------------------------------------------------------------ 2. dpms wake

step "Wake-on-input (the screensaver fix)"

if [[ $ENABLE_DPMS_WAKE == yes ]]; then
    info "without this, a blanked screen ignores the keyboard and the mouse, and looks hung"
    write_block "$HYPR_DIR/hyprland.lua" <<'LUA'
hl.config({
    misc = {
        key_press_enables_dpms  = true,
        mouse_move_enables_dpms = true,
    },
})
LUA
else
    info "ENABLE_DPMS_WAKE=no -- skipped"
fi

# ------------------------------------------------------------------ 3. open-vm-tools

step "open-vm-tools"

if [[ $INSTALL_OPEN_VM_TOOLS == yes ]]; then
    if pacman -Q open-vm-tools >/dev/null 2>&1; then
        info "already installed: $(pacman -Q open-vm-tools)"
    else
        run "${PACMAN[@]}" -S --needed --noconfirm open-vm-tools
    fi
    run sudo systemctl enable --now vmtoolsd.service vmware-vmblock-fuse.service
    [[ $DRY_RUN == yes ]] || systemctl is-active vmtoolsd.service | sed 's/^/   vmtoolsd: /'
else
    info "INSTALL_OPEN_VM_TOOLS=no -- skipped"
fi

# ------------------------------------------------------------------ 4. screensaver

step "Screensaver"

# hypridle is what arms the screensaver: no hypridle, no idle trigger. Using it as the state
# probe is what makes a toggle safe to call.
screensaver_armed() { pgrep -x hypridle >/dev/null 2>&1; }

if [[ $DISABLE_SCREENSAVER != yes ]]; then
    info "DISABLE_SCREENSAVER=no -- skipped"
elif [[ $SCREENSAVER_DISABLE_CMD != auto ]]; then
    run $SCREENSAVER_DISABLE_CMD
elif ! screensaver_armed; then
    ok "hypridle is not running -- the screensaver is already off"
else
    mapfile -t SS_CMDS < <(compgen -c 2>/dev/null | grep -E '^omarchy-.*(screensaver|idle)' | sort -u || true)
    SS_OFF=""; SS_TOGGLE=""
    # Confirmed name on Omarchy, 2026-09. The discovery below is only a rename safety net.
    command -v omarchy-toggle-screensaver >/dev/null 2>&1 && SS_TOGGLE=omarchy-toggle-screensaver
    for c in "${SS_CMDS[@]:-}"; do
        [[ -z $c ]] && continue
        case "$c" in
            *disable*|*-off*) SS_OFF=$c ;;
            *toggle*)         [[ -z $SS_TOGGLE ]] && SS_TOGGLE=$c ;;
        esac || true
    done

    if [[ -n $SS_OFF ]]; then
        info "using $SS_OFF"
        run "$SS_OFF"
    elif [[ -n $SS_TOGGLE ]]; then
        info "hypridle is running, so the screensaver is on; toggling it off with $SS_TOGGLE"
        run "$SS_TOGGLE"
        if [[ $DRY_RUN == no ]]; then
            sleep 1
            screensaver_armed && warn "hypridle is still running -- toggle may have done something else" \
                              || ok "screensaver disabled"
        fi
    else
        warn "no omarchy screensaver/idle command found; not guessing"
        (( ${#SS_CMDS[@]} )) && { info "candidates seen:"; printf '     %s\n' "${SS_CMDS[@]}"; }
        info "turn it off from Omarchy's menu, or re-run with SCREENSAVER_DISABLE_CMD=<command>"
    fi
fi

# ------------------------------------------------------------------ 5. resolution + scale

step "Resolution and scale"

MON_FILE="$HYPR_DIR/monitors.lua"
[[ -f $MON_FILE ]] || die "no $MON_FILE"

if [[ $GDK_SCALE_VALUE != skip ]]; then
    CURRENT_GDK=$(grep -oP '^\s*omarchy_gdk_scale\s*=\s*\K\S+' "$MON_FILE" 2>/dev/null | head -1 || true)
    if [[ -z ${CURRENT_GDK:-} ]]; then
        warn "no omarchy_gdk_scale line found in $MON_FILE; leaving GTK scaling alone"
    elif [[ ${CURRENT_GDK%%[^0-9.]*} == "$GDK_SCALE_VALUE" ]]; then
        info "omarchy_gdk_scale is already $GDK_SCALE_VALUE"
    else
        info "omarchy_gdk_scale: $CURRENT_GDK -> $GDK_SCALE_VALUE  (Omarchy ships 2)"
        if [[ $DRY_RUN == no ]]; then
            backup "$MON_FILE"
            sed -i -E "s|^(\s*omarchy_gdk_scale\s*=\s*).*|\1$GDK_SCALE_VALUE|" "$MON_FILE"
            CHANGED+=("$MON_FILE")
        fi
    fi
fi

OTHER_MON=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$MON_FILE" | grep -c 'hl\.monitor(' || true)
if (( OTHER_MON > 0 )); then
    info "$MON_FILE already has $OTHER_MON hl.monitor() call(s); ours is appended last,"
    info "and for Hyprland the last rule matching an output wins. Remove the old one if it"
    info "names $MONITOR_OUTPUT explicitly and you want it gone."
fi

write_block "$MON_FILE" <<LUA
hl.monitor({
    output   = "$MONITOR_OUTPUT",
    mode     = "$MONITOR_MODE",
    position = "$MONITOR_POSITION",
    scale    = $MONITOR_SCALE,
})
LUA

# ------------------------------------------------------------------ 6. verify

step "Verify"

if [[ $HAVE_HYPRCTL == yes && $DRY_RUN == no ]]; then
    # Hyprland reloads its Lua config on save, so the mode should already be live.
    sleep 1
    hyprctl monitors | awk '/^Monitor |^\t[0-9]+x[0-9]+/{print "   " $0}' | head -4
    LIVE=$(hyprctl monitors | awk '/^\t[0-9]+x[0-9]+/{print $1; exit}' || true)
    info "live mode: ${LIVE:-unknown}"
    [[ ${LIVE:-} == ${MONITOR_MODE%@*}* ]] && ok "resolution applied" \
        || warn "not applied yet -- 'hyprctl reload', or check the backup files above"
fi

printf '\n\033[1;32m  ================  POST-INSTALL COMPLETE  ================\033[0m\n\n'
if (( ${#CHANGED[@]} )); then
    info "changed:"
    printf '     %s\n' "${CHANGED[@]}" | sort -u
fi
printf '\n'
info "Resolution takes effect on save. GDK_SCALE does not: GTK reads it once at process"
info "start, so applications keep the old scaling until the session restarts."
printf '\n'
info "Two VMware behaviours that are not bugs, so you do not chase them later:"
info "  - to wake a blanked screen you must first CLICK IN the VMware window. Until it has"
info "    focus, VMware does not forward input to the guest at all, so the wake keys the"
info "    step above just enabled never arrive."
info "  - host-guest clipboard works for XWayland clients only. open-vm-tools' clipboard"
info "    plugin needs a real X session; a rootless XWayland is not enough."
printf '\n'

if [[ $DRY_RUN == no ]] && [[ $GDK_SCALE_VALUE != skip ]] && command -v omarchy-system-logout >/dev/null; then
    if confirm "log out now to apply GDK_SCALE? (this closes your desktop session)"; then
        exec omarchy-system-logout
    fi
    info "log out later with: omarchy-system-logout"
fi
