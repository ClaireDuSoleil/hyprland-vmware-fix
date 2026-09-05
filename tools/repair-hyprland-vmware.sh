#!/usr/bin/env bash
# Rebuild Hyprland with the vmwgfx dmabuf fix, on Arch/Omarchy in a VMware guest.
#
# Phased and resumable. Run with no arguments to go as far as a finished package:
#
#     ./repair-hyprland-vmware.sh
#
# It deliberately STOPS before installing. Installing a broken compositor build costs you
# the desktop you would need to fix it, so that step stays a decision you make, not one a
# script makes for you. The final line tells you the exact command.
#
#     ./repair-hyprland-vmware.sh check      # read-only: what have I got, am I affected
#     ./repair-hyprland-vmware.sh prepare    # clone, patch PKGBUILD, fetch+prepare source
#     ./repair-hyprland-vmware.sh build      # compile
#     ./repair-hyprland-vmware.sh install    # pacman -U + IgnorePkg  (asks first)
#     ./repair-hyprland-vmware.sh verify     # post-reboot checks
#
# Each phase re-checks its own preconditions, so re-running after a failure is safe.

set -euo pipefail

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DEPS=(base-devel devtools git)

# Omarchy blocks direct pacman transactions with a hook. This is its documented escape hatch,
# and a plain Arch pacman just ignores the variable.
PACMAN=(sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman)
WORK="${WORK:-$HOME/hyprland-vmware-build}"
PKGDIR="$WORK/hyprland"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[33m   warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m   error: %s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' -- install it first"; }

# ----------------------------------------------------------------- check

phase_check() {
    say "Environment"
    [[ $EUID -ne 0 ]] || die "do not run this as root; makepkg refuses, and it does not need it"

    local drv
    drv=$(basename "$(readlink -f /sys/class/drm/card0/device/driver 2>/dev/null)" 2>/dev/null || echo unknown)
    info "DRM driver:  $drv"
    [[ $drv == vmwgfx ]] || warn "driver is '$drv', not vmwgfx -- this fix targets VMware guests"

    HYPRVER=$(pacman -Q hyprland 2>/dev/null | awk '{print $2}') || die "hyprland is not installed"
    AQVER=$(pacman -Q aquamarine 2>/dev/null | awk '{print $2}' || echo '(not installed)')
    HYPRBASE=${HYPRVER%%-*}
    info "hyprland:    $HYPRVER  (base $HYPRBASE)"
    info "aquamarine:  $AQVER"

    REPO=$(pacman -Si hyprland 2>/dev/null | awk -F': *' '/^Repository/{print $2; exit}')
    info "repository:  ${REPO:-unknown}"       # -Si, not -Qi: -Qi has no Repository field
    [[ ${REPO:-} == extra ]] || warn "expected 'extra'; if this is an Omarchy-built package, use omarchy-pkgs"

    say "Which patches"
    PATCH_DMABUF="$BUNDLE/patches/hyprland-${HYPRBASE}-vmwgfx-dmabuf.patch"
    PATCH_EGL="$BUNDLE/patches/hyprland-${HYPRBASE}-egl-gbm-fallback.patch"
    if [[ ! -f $PATCH_DMABUF ]]; then
        warn "no patch set for $HYPRBASE in $BUNDLE/patches/"
        warn "available: $(cd "$BUNDLE/patches" && ls | tr '\n' ' ')"
        die  "check the patch applies to your version by hand (see step 2.3) before continuing"
    fi
    info "dmabuf patch: $(basename "$PATCH_DMABUF")"

    # crash reports present => the startup-abort variant => EGL patch needed too
    NEED_EGL=no
    if compgen -G "$HOME/.cache/hyprland/*" >/dev/null 2>&1; then
        if grep -qls 'initEGL\|failed to initialize a platform display' "$HOME"/.cache/hyprland/* 2>/dev/null; then
            NEED_EGL=yes
            info "egl patch:    NEEDED (crash report mentions initEGL)"
        else
            warn "crash reports exist but none mention initEGL."
            warn "That is NOT proof you do not need the EGL patch: a truncated crash report"
            warn "(Hyprland's alarm(15) bug cuts the backtrace on slow/debug builds) looks"
            warn "identical to a clean one here. Read the newest yourself:"
            warn "  /bin/ls -t ~/.cache/hyprland/ | head -3"
            info "proceeding WITHOUT the EGL patch -- if Hyprland then aborts at startup,"
            info "re-run with NEED_EGL=yes forced in $WORK/.state and redo prepare"
        fi
    else
        info "egl patch:    not needed (no crash reports; empty-desktop variant)"
    fi
    [[ $NEED_EGL == no || -f $PATCH_EGL ]] || die "EGL patch needed but $PATCH_EGL is missing"

    say "Is this VM actually affected"
    need gcc
    local t="$WORK/vmwtest"
    mkdir -p "$WORK"
    gcc -o "$t" "$BUNDLE/tools/vmwtest.c" $(pkg-config --cflags --libs libdrm gbm) \
        || die "could not build vmwtest -- need base-devel, libdrm and mesa"
    if "$t"; then
        info "vmwtest says this VM exhibits the bug -- patching is the right call"
    else
        warn "vmwtest did not report the bug; patching may not help. Read its output above."
    fi

    say "Resources"
    info "cores: $(nproc)   free on $HOME: $(df -h --output=avail "$HOME" | tail -1 | tr -d ' ')   ram: $(free -h | awk '/^Mem:/{print $2}')"
    (( $(df --output=avail -k "$HOME" | tail -1) > 8*1024*1024 )) || warn "under 8G free; the build may not fit"

    printf '%s\n' "HYPRVER=$HYPRVER" "HYPRBASE=$HYPRBASE" "NEED_EGL=$NEED_EGL" > "$WORK/.state"
    say "check passed"
}

load_state() {
    [[ -f $WORK/.state ]] || die "run '$0 check' first"
    # shellcheck disable=SC1090
    source "$WORK/.state"
    PATCH_DMABUF="$BUNDLE/patches/hyprland-${HYPRBASE}-vmwgfx-dmabuf.patch"
    PATCH_EGL="$BUNDLE/patches/hyprland-${HYPRBASE}-egl-gbm-fallback.patch"
}

# --------------------------------------------------------------- prepare

phase_prepare() {
    load_state
    if ! command -v pkgctl >/dev/null || ! command -v git >/dev/null || ! command -v make >/dev/null; then
        say "Build dependencies"
        info "installing: ${BUILD_DEPS[*]}   (pkgctl comes from devtools)"
        info "if this fails with 'target not found', the package databases are empty --"
        info "run a full upgrade first:  ${PACMAN[*]} -Syu"
        "${PACMAN[@]}" -S --needed "${BUILD_DEPS[@]}" || die "could not install build dependencies"
    fi
    need pkgctl; need git; need python3

    say "Packaging repo"
    mkdir -p "$WORK"
    if [[ -d $PKGDIR/.git ]]; then
        info "reusing existing clone at $PKGDIR"
    else
        ( cd "$WORK" && pkgctl repo clone --protocol=https hyprland )
    fi
    cd "$PKGDIR"

    local pkgbuild_ver
    pkgbuild_ver=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
    [[ $pkgbuild_ver == "$HYPRBASE" ]] \
        || warn "PKGBUILD is pkgver=$pkgbuild_ver but you have $HYPRBASE installed; the patch set targets $HYPRBASE"

    say "Patching the PKGBUILD"
    local patches=("$PATCH_DMABUF")
    [[ $NEED_EGL == yes ]] && patches+=("$PATCH_EGL")
    cp -v "${patches[@]}" .

    if grep -q 'vmwgfx-dmabuf.patch' PKGBUILD; then
        info "PKGBUILD already references the patch; leaving it alone"
    else
        python3 "$BUNDLE/tools/patch-pkgbuild.py" --pkgrel-suffix .1 \
            $(printf '%s\n' "${patches[@]}" | xargs -n1 basename)
        git --no-pager diff
    fi

    say "Fetching source and running prepare()"
    makepkg -so

    say "Confirming the patch is in the tree that will be compiled"
    local f
    f=$(find src -maxdepth 4 -type f -path '*/src/protocols/LinuxDMABUF.cpp' | head -1)
    [[ -n $f ]] || die "could not find LinuxDMABUF.cpp under src/"
    info "checking $f"
    grep -q 'closeVmwGFXHandle' "$f" || die "patch is NOT in the extracted source -- do not build"
    grep -c 'vmwgfx\|DRM_VMW_UNREF_SURFACE\|closeVmwGFXHandle' "$f" | xargs -I{} info "{} matching lines"
    say "prepare passed -- ready to build"
}

# ----------------------------------------------------------------- build

phase_build() {
    load_state
    cd "$PKGDIR" || die "run '$0 prepare' first"
    [[ -d src ]] || die "no src/ -- run '$0 prepare' first"

    if [[ -z ${TMUX:-} ]] && command -v tmux >/dev/null; then
        warn "not inside tmux: an SSH disconnect will kill this build"
        warn "consider: tmux new -s build   then re-run this phase"
    fi

    say "Building (10-25 min on 8 cores)"
    time makepkg -e 2>&1 | tee "$WORK/build.log"

    say "Packages built"
    ls -la ./*.pkg.tar.zst
    local pkg
    pkg=$(/bin/ls -t ./hyprland-*.pkg.tar.zst 2>/dev/null | head -1) || die "no hyprland package produced"

    say "NOT installing automatically"
    cat <<EOF
   A bad compositor build costs you the desktop you would use to fix it, so this is yours
   to run when you are ready -- ideally from an SSH session, with a VM snapshot taken:

       $0 install

   or by hand:

       ${PACMAN[*]} -U $PKGDIR/$(basename "$pkg")
EOF
}

# --------------------------------------------------------------- install

phase_install() {
    load_state
    cd "$PKGDIR" || die "nothing built yet"
    local pkg
    pkg=$(/bin/ls -t ./hyprland-*.pkg.tar.zst 2>/dev/null | head -1) || die "no hyprland package found; run build"

    say "About to install $(basename "$pkg")"
    info "this replaces your running compositor's binary; take a VM snapshot first"
    read -rp "   type 'yes' to continue: " ans
    [[ $ans == yes ]] || die "aborted"

    "${PACMAN[@]}" -U "$pkg"

    say "Pinning so the next update does not silently undo it"
    if grep -qE '^\s*IgnorePkg\s*=.*\bhyprland\b' /etc/pacman.conf; then
        info "already pinned in /etc/pacman.conf"
    else
        warn "add this to the [options] section of /etc/pacman.conf:"
        warn "    IgnorePkg = hyprland"
        warn "not editing pacman.conf automatically -- it is yours"
    fi
    say "installed -- log out and back into Hyprland, then run: $0 verify"
}

# ---------------------------------------------------------------- verify

phase_verify() {
    say "Is the installed binary the patched one"
    local n
    n=$(strings /usr/bin/Hyprland | grep -c vmwgfx || true)
    if (( n > 0 )); then
        info "yes: /usr/bin/Hyprland contains the vmwgfx fallback ($n match, 1 is expected)"
    else
        die "no: /usr/bin/Hyprland has no vmwgfx string -- the stock package is installed"
    fi
    info "installed version: $(pacman -Q hyprland)"

    say "Is the compositor alive"
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID}
    # /bin/ls, not ls: Omarchy aliases ls to eza, whose -t means --time FIELD, not sort-by-time
    export HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE:-$(/bin/ls -t "/run/user/$UID/hypr" 2>/dev/null | head -1)}
    if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || ! hyprctl version >/dev/null 2>&1; then
        warn "hyprctl not answering -- run this from inside the graphical session, or check"
        warn "  HYPRLAND_INSTANCE_SIGNATURE (currently '${HYPRLAND_INSTANCE_SIGNATURE:-unset}')"
        return 0
    fi
    local P A B
    P=$(pgrep -x Hyprland | head -1)
    A=$(awk '{print $14+$15}' "/proc/$P/stat")
    hyprctl notify 1 2000 0 "vmwgfx repair probe" >/dev/null 2>&1
    sleep 3
    B=$(awk '{print $14+$15}' "/proc/$P/stat")
    info "cpu ticks used forcing a redraw: $((B-A))  (a few hundred = rendering normally)"

    say "Display pipeline"
    if [[ -r /sys/kernel/debug/dri/0/state ]]; then
        local f1 f2
        f1=$(grep -m1 -oE 'fb=[0-9]+' /sys/kernel/debug/dri/0/state | cut -d= -f2)
        sleep 2
        f2=$(grep -m1 -oE 'fb=[0-9]+' /sys/kernel/debug/dri/0/state | cut -d= -f2)
        if [[ $f1 == 0 || $f2 == 0 ]]; then
            warn "fb=0 -- the output is DISABLED (DPMS/idle), not stalled. See 'Step 3' in"
            warn "REPAIR-OMARCHY-VM.md. Wake it with:"
            warn "  hyprctl dispatch 'hl.dsp.dpms({ action = \"on\" })'"
        elif [[ $f1 == "$f2" ]]; then
            info "fb pinned at $f1 across 2s -- INCONCLUSIVE. An idle desktop with nothing to"
            info "redraw looks identical to a stall. Force damage and re-check:"
            info "  hyprctl notify 1 3000 0 probe"
            info "  sudo bash $BUNDLE/tools/vmw-flip-watch.sh 2"
        else
            info "fb changing ($f1 -> $f2): flips are landing, display pipeline healthy"
        fi
    else
        info "cannot read /sys/kernel/debug/dri/0/state (needs root); skipping"
    fi

    say "Wake-from-blank settings"
    local k m
    k=$(hyprctl getoption misc:key_press_enables_dpms 2>/dev/null | awk '/int:|bool:/{print $2; exit}')
    m=$(hyprctl getoption misc:mouse_move_enables_dpms 2>/dev/null | awk '/int:|bool:/{print $2; exit}')
    info "misc:key_press_enables_dpms  = ${k:-?}"
    info "misc:mouse_move_enables_dpms = ${m:-?}"
    if [[ ${k:-0} == 0 || ${m:-0} == 0 ]]; then
        warn "both default to false: once the screen blanks, input will NOT wake it, and the"
        warn "VM will look locked up. Add to ~/.config/hypr/hyprland.lua, then reload ONCE:"
        warn "  hl.config({ misc = { key_press_enables_dpms = true, mouse_move_enables_dpms = true } })"
    fi

    say "How to actually confirm the dmabuf fix"
    cat <<'EOF'
   Do NOT use a terminal. Omarchy's terminal is foot, which renders via wl_shm, not dmabuf --
   it mapped fine on the BROKEN system too. Use a GPU client:

       export XDG_RUNTIME_DIR=/run/user/$UID
       export WAYLAND_DISPLAY=$(cd /run/user/$UID && /bin/ls -d wayland-[0-9]* | grep -v '\.lock$' | head -1)
       chromium --new-window about:blank &

   A window that appears and STAYS is the fix. Strict version:

       WAYLAND_DEBUG=1 chromium --new-window about:blank 2>&1 \
         | grep -oE 'zwp_linux_buffer_params_v1@[0-9]+\.(created|failed)' | sort | uniq -c

   'created' with no 'failed' = working.

   And if the screen looks dead: VMware only delivers input to a FOCUSED console window.
   Click inside it first, then press Enter.
EOF
}

case "${1:-all}" in
    check)   phase_check ;;
    prepare) phase_prepare ;;
    build)   phase_build ;;
    install) phase_install ;;
    verify)  phase_verify ;;
    all)     phase_check; phase_prepare; phase_build ;;
    *)       die "usage: $0 [check|prepare|build|install|verify]" ;;
esac
