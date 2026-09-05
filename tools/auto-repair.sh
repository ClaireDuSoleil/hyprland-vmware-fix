#!/usr/bin/env bash
#
# auto-repair.sh -- one-shot Hyprland vmwgfx repair for a fresh Arch/Omarchy VMware guest.
#
# Run this once, immediately after you have SSH into a newly provisioned VM. It updates the
# system, confirms the VM is actually affected, rebuilds the distro's hyprland package with
# the vmwgfx dmabuf fix applied, installs it, pins it against future updates, and then asks
# you to confirm before rebooting.
#
#     ssh <user>@<vm-ip>
#     tar -xf ~/hyprland-vmware-fix.tar.gz -C ~     # or: git clone <repo-url> ~/hyprland-vmware-fix
#     ~/hyprland-vmware-fix/tools/auto-repair.sh
#
# Takes 15-40 minutes, nearly all of it compiling. Run it inside tmux if you can.
#
#     --dry-run    print every command that would change the system; change nothing
#     --yes        do not ask before installing the built package (still asks before reboot)
#     --no-reboot  stop after the summary instead of offering a reboot
#
# Everything is logged to ~/hyprland-vmware-fix-<timestamp>.log.
#
# Do NOT run this with sudo. makepkg refuses to run as root, and the script asks for sudo at
# the few points that need it.

set -euo pipefail

# =====================================================================================
# CONFIGURATION -- edit these, or override any of them from the environment:
#     HYPRLAND_VERSION=0.57.0 ./auto-repair.sh
# =====================================================================================

# The Hyprland release this repair targets. A patch named
# patches/hyprland-<HYPRLAND_VERSION>-vmwgfx-dmabuf.patch must exist.
# Set to "auto" to use whatever version the distro currently ships -- convenient, but it
# will fail later if no patch matches that version.
HYPRLAND_VERSION="${HYPRLAND_VERSION:-0.56.2}"

# Optional tag in the Arch packaging repo, e.g. "0.56.2-3". Empty means "use the tip of
# main", i.e. whatever Arch ships today. Set this when Arch has already moved past
# HYPRLAND_VERSION and you want to build the older release anyway.
HYPRLAND_PKG_TAG="${HYPRLAND_PKG_TAG:-}"

# Expected aquamarine version. NOTE: aquamarine is neither downloaded nor patched by this
# script -- it is a dependency pacman installs. This value is only checked, because Hyprland
# links against a specific aquamarine ABI and a mismatch produces confusing runtime failures.
# Set to "any" to skip the check.
AQUAMARINE_VERSION="${AQUAMARINE_VERSION:-0.14.0}"

# Appended to the package's pkgrel, so `pacman -Q hyprland` shows 0.56.2-3.1 and you can tell
# your patched build from a repo build at a glance. Set to "" to keep the repo's version.
PKGREL_SUFFIX="${PKGREL_SUFFIX:-.1}"

# The second patch, for the "Hyprland aborts at startup" variant.
#   auto -- look for an initEGL crash report and decide
#   yes  -- always apply
#   no   -- never apply
APPLY_EGL_PATCH="${APPLY_EGL_PATCH:-auto}"

# Packages needed to build. devtools supplies pkgctl; base-devel supplies makepkg's toolchain.
BUILD_DEPS=(base-devel devtools git)

# How to bring the system up to date before building. Building against half-updated libraries
# is how you get a package that segfaults on load, so do not skip this lightly.
#
#   pacman  -- plain `pacman -Syu` (default). Deterministic and non-interactive, which is what
#              an unattended build script needs.
#   omarchy -- Omarchy's own `omarchy update`: snapshot, keyrings, migrations, post-update
#              hooks, restart checks. The right path for a machine you are keeping. It may
#              prompt, so the script will not be unattended.
#   none    -- refresh package databases only.
#
# On Omarchy, `pacman -Syu` is deliberately blocked by a transaction hook:
#     "Woah partner... This looks like a direct pacman system upgrade."
# The documented bypass is OMARCHY_ALLOW_DIRECT_PACMAN=1, which this script sets on every
# pacman call. That is a considered choice, not an oversight: the VM is minutes old, has no
# migrations worth preserving, and gets rebooted at the end of this script. If you are
# repairing a machine you have been using, prefer SYSTEM_UPDATE_METHOD=omarchy.
SYSTEM_UPDATE_METHOD="${SYSTEM_UPDATE_METHOD:-pacman}"

# Add hyprland to IgnorePkg in /etc/pacman.conf so the next update does not overwrite the
# patched build with a stock one.
PIN_PACKAGE="${PIN_PACKAGE:-yes}"

# Install open-vm-tools too (screen autofit, host-guest clipboard). It needs a reboot to take
# effect, and this script reboots anyway, so this is the cheapest place to do it.
INSTALL_OPEN_VM_TOOLS="${INSTALL_OPEN_VM_TOOLS:-no}"

# Refuse to continue if the installed Hyprland does not match HYPRLAND_VERSION. Set to "no"
# to downgrade this to a warning.
STRICT_VERSION_CHECK="${STRICT_VERSION_CHECK:-yes}"

# Build directory. The packaging clone and the compiled packages land here.
WORK="${WORK:-$HOME/hyprland-vmware-build}"

# Cap parallel compile jobs, e.g. "-j4" on a VM with little RAM. Empty uses makepkg.conf.
MAKEFLAGS_OVERRIDE="${MAKEFLAGS_OVERRIDE:-}"

# Minimum free space in the build directory, in GB.
MIN_FREE_GB="${MIN_FREE_GB:-8}"

# =====================================================================================
# Nothing below here should need editing.
# =====================================================================================

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Omarchy blocks direct pacman transactions with a hook; this is its documented escape hatch.
# Harmless everywhere else -- a plain Arch pacman just ignores the variable.
PACMAN=(sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman)
PKGDIR="$WORK/hyprland"
DRY_RUN=no
ASSUME_YES=no
DO_REBOOT=yes
STEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=yes ;;
        --yes|-y)    ASSUME_YES=yes ;;
        --no-reboot) DO_REBOOT=no ;;
        -h|--help)   sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

LOGFILE="${LOGFILE:-$HOME/hyprland-vmware-fix-$(date +%Y%m%d-%H%M%S).log}"
if [[ -z ${_AUTOREPAIR_TEED:-} ]]; then
    export _AUTOREPAIR_TEED=1
    exec > >(tee -a "$LOGFILE") 2>&1
fi

step() { STEP=$((STEP+1)); printf '\n\033[1;36m== %d. %s\033[0m\n' "$STEP" "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '\033[32m   ok: %s\033[0m\n' "$*"; }
warn() { printf '\033[33m   warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[31m   FAILED: %s\033[0m\n\n   log: %s\n\n' "$*" "$LOGFILE" >&2; exit 1; }

# run: echo a system-changing command, then run it (or not, under --dry-run).
run() {
    printf '\033[2m   $ %s\033[0m\n' "$*"
    [[ $DRY_RUN == yes ]] && return 0
    "$@"
}

confirm() {   # confirm "question" -- true on yes
    [[ $ASSUME_YES == yes ]] && return 0
    [[ -e /dev/tty ]] || die "no terminal to ask '$1' -- re-run with --yes if that is what you want"
    local reply
    read -r -p "   $1 [y/N] " reply </dev/tty || return 1
    [[ $reply == [yY]* ]]
}

cleanup() { [[ -n ${SUDO_KEEPALIVE_PID:-} ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

printf '\033[1m\n  Hyprland vmwgfx repair -- one-shot\033[0m\n'
info "bundle:      $BUNDLE"
info "work dir:    $WORK"
info "log:         $LOGFILE"
info "hyprland:    $HYPRLAND_VERSION       aquamarine: $AQUAMARINE_VERSION"
[[ $DRY_RUN == yes ]] && printf '\033[33m\n   DRY RUN -- nothing will be changed\033[0m\n'

# ------------------------------------------------------------------ 1. preflight

step "Preflight"

[[ $EUID -ne 0 ]] || die "do not run this as root or with sudo; makepkg refuses to run as root"

for c in pacman git python3 gcc awk sed; do
    command -v "$c" >/dev/null || die "missing '$c'"
done

[[ -f $BUNDLE/tools/patch-pkgbuild.py ]] || die "bundle looks incomplete: no tools/patch-pkgbuild.py under $BUNDLE"

if [[ -r /etc/os-release ]]; then
    info "distro:      $(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
fi
command -v pacman >/dev/null || die "this script is Arch-specific (pacman not found)"

DRIVER=$(basename "$(readlink -f /sys/class/drm/card0/device/driver 2>/dev/null)" 2>/dev/null || echo unknown)
info "DRM driver:  $DRIVER"
[[ $DRIVER == vmwgfx ]] || warn "driver is '$DRIVER', not vmwgfx -- this fix targets VMware guests with 3D acceleration on"

info "cores:       $(nproc)"
info "RAM:         $(free -h | awk '/^Mem:/{print $2}')"
mkdir -p "$WORK"
FREE_KB=$(df --output=avail -k "$WORK" | tail -1 | tr -d ' ')
info "free space:  $((FREE_KB/1024/1024)) GB in $WORK"
(( FREE_KB > MIN_FREE_GB*1024*1024 )) || die "under ${MIN_FREE_GB}G free in $WORK; the build will not fit"

if [[ -z ${TMUX:-} && -n ${SSH_CONNECTION:-} ]]; then
    warn "you are on SSH and not inside tmux -- a dropped connection will kill the build"
    if command -v tmux >/dev/null; then
        warn "consider: tmux new -s fix   then re-run this script inside it"
        confirm "continue anyway?" || die "stopped; re-run inside tmux"
    fi
fi

# Take sudo once, and keep the timestamp alive across the long compile.
if [[ $DRY_RUN == no ]]; then
    info "sudo is needed for: system update, build deps, package install, pacman.conf"
    sudo -v || die "sudo failed"
    ( while true; do sleep 50; sudo -n true 2>/dev/null || exit; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
fi
ok "preflight passed"

# ------------------------------------------------------------------ 2. system update

step "System update  (method: $SYSTEM_UPDATE_METHOD)"

# Any of these also builds the package databases, which a fresh install does not have. Without
# that, every `pacman -S` fails with a bare "target not found", which reads like the package
# does not exist rather than like a missing database.
case "$SYSTEM_UPDATE_METHOD" in
    omarchy)
        if command -v omarchy >/dev/null 2>&1; then
            info "using Omarchy's own update path; it may prompt"
            run omarchy update
        elif command -v omarchy-update >/dev/null 2>&1; then
            run omarchy-update
        else
            die "SYSTEM_UPDATE_METHOD=omarchy but neither 'omarchy' nor 'omarchy-update' is installed"
        fi ;;
    pacman)
        info "bypassing Omarchy's pacman guard with OMARCHY_ALLOW_DIRECT_PACMAN=1 (no-op elsewhere)"
        run "${PACMAN[@]}" -Syu --noconfirm ;;
    none)
        warn "SYSTEM_UPDATE_METHOD=none -- only refreshing databases"
        run "${PACMAN[@]}" -Sy --noconfirm ;;
    *)
        die "SYSTEM_UPDATE_METHOD must be one of: pacman, omarchy, none (got '$SYSTEM_UPDATE_METHOD')" ;;
esac

step "Build dependencies"
run "${PACMAN[@]}" -S --needed --noconfirm "${BUILD_DEPS[@]}"
[[ $DRY_RUN == yes ]] || command -v pkgctl >/dev/null || die "pkgctl still missing after installing devtools"

# ------------------------------------------------------------------ 3. what have we got

step "Installed versions"

INSTALLED_HYPR=$(pacman -Q hyprland 2>/dev/null | awk '{print $2}') || die "hyprland is not installed -- this repairs an existing desktop, it does not install one"
INSTALLED_BASE=${INSTALLED_HYPR%%-*}
INSTALLED_AQ=$(pacman -Q aquamarine 2>/dev/null | awk '{print $2}' || echo none)
info "hyprland:    $INSTALLED_HYPR  (base $INSTALLED_BASE)"
info "aquamarine:  $INSTALLED_AQ"

if [[ $HYPRLAND_VERSION == auto ]]; then
    HYPRLAND_VERSION=$INSTALLED_BASE
    info "HYPRLAND_VERSION=auto resolved to $HYPRLAND_VERSION"
fi

if [[ $INSTALLED_BASE != "$HYPRLAND_VERSION" ]]; then
    if [[ $STRICT_VERSION_CHECK == yes ]]; then
        warn "installed Hyprland is $INSTALLED_BASE but this run targets $HYPRLAND_VERSION"
        warn "the system update above may have moved Hyprland past the version the patch targets"
        warn "either set HYPRLAND_VERSION=$INSTALLED_BASE (if a patch exists for it),"
        warn "or set HYPRLAND_PKG_TAG to build the older release, or STRICT_VERSION_CHECK=no"
        die  "version mismatch"
    fi
    warn "version mismatch ($INSTALLED_BASE vs $HYPRLAND_VERSION) -- continuing because STRICT_VERSION_CHECK=no"
fi

if [[ $AQUAMARINE_VERSION != any && ${INSTALLED_AQ%%-*} != "$AQUAMARINE_VERSION" ]]; then
    warn "aquamarine is ${INSTALLED_AQ%%-*}, expected $AQUAMARINE_VERSION"
    warn "not fatal -- aquamarine is not patched here -- but note it if the rebuilt Hyprland misbehaves"
fi

PATCH_DMABUF="$BUNDLE/patches/hyprland-${HYPRLAND_VERSION}-vmwgfx-dmabuf.patch"
PATCH_EGL="$BUNDLE/patches/hyprland-${HYPRLAND_VERSION}-egl-gbm-fallback.patch"
[[ -f $PATCH_DMABUF ]] || {
    warn "available patches: $(cd "$BUNDLE/patches" && ls | tr '\n' ' ')"
    die "no dmabuf patch for $HYPRLAND_VERSION at $PATCH_DMABUF"
}
info "dmabuf patch: $(basename "$PATCH_DMABUF")"

case "$APPLY_EGL_PATCH" in
    yes) NEED_EGL=yes ;;
    no)  NEED_EGL=no ;;
    *)   NEED_EGL=no
         if compgen -G "$HOME/.cache/hyprland/*" >/dev/null 2>&1 &&
            grep -qls 'initEGL\|failed to initialize a platform display' "$HOME"/.cache/hyprland/* 2>/dev/null; then
             NEED_EGL=yes
         fi ;;
esac
info "egl patch:    $NEED_EGL"
[[ $NEED_EGL == no ]] || [[ -f $PATCH_EGL ]] || die "EGL patch requested but $PATCH_EGL does not exist"

# ------------------------------------------------------------------ 4. confirm affected

step "Is this VM actually affected?"

if pkg-config --exists libdrm gbm 2>/dev/null; then
    VMWTEST=$WORK/vmwtest
    # shellcheck disable=SC2046
    gcc -o "$VMWTEST" "$BUNDLE/tools/vmwtest.c" $(pkg-config --cflags --libs libdrm gbm) \
        || die "could not build vmwtest.c"
    VMWOUT=$("$VMWTEST" 2>&1 || true)
    printf '%s\n' "$VMWOUT" | sed 's/^/   | /'
    # vmwtest returns 0 both for "not affected" and for "patch is correct", so read the text.
    if grep -q 'PATCH IS CORRECT' <<<"$VMWOUT"; then
        ok "affected, and this patch is the right fix"
    elif grep -q 'does not exhibit the bug' <<<"$VMWOUT"; then
        warn "this machine does NOT exhibit the dmabuf bug -- patching it will not help"
        confirm "build and install anyway?" || die "stopped"
    else
        warn "vmwtest was inconclusive"
        confirm "continue anyway?" || die "stopped"
    fi
else
    warn "libdrm/gbm pkg-config files not found; skipping the vmwtest check"
fi

# ------------------------------------------------------------------ 5. packaging repo

step "Clone the packaging repo"

if [[ -d $PKGDIR/.git ]]; then
    info "reusing existing clone at $PKGDIR"
    run git -C "$PKGDIR" checkout -- PKGBUILD 2>/dev/null || true
else
    run bash -c "cd '$WORK' && pkgctl repo clone --protocol=https hyprland"
fi

if [[ -n $HYPRLAND_PKG_TAG ]]; then
    info "pinning packaging repo to tag $HYPRLAND_PKG_TAG"
    run git -C "$PKGDIR" checkout "$HYPRLAND_PKG_TAG" \
        || die "tag '$HYPRLAND_PKG_TAG' not found; list them with: git -C $PKGDIR tag --list"
fi

if [[ $DRY_RUN == no ]]; then
    cd "$PKGDIR"
    PKGBUILD_VER=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
    info "PKGBUILD pkgver: $PKGBUILD_VER"
    if [[ $PKGBUILD_VER != "$HYPRLAND_VERSION" ]]; then
        warn "the packaging repo is at $PKGBUILD_VER, but the patch targets $HYPRLAND_VERSION"
        warn "Arch has moved on. Set HYPRLAND_PKG_TAG to a tag for $HYPRLAND_VERSION:"
        warn "    git -C $PKGDIR tag --list '${HYPRLAND_VERSION}*'"
        [[ $STRICT_VERSION_CHECK == yes ]] && die "packaging version mismatch"
    fi
fi

# ------------------------------------------------------------------ 6. patch the PKGBUILD

step "Patch the PKGBUILD"

PATCHES=("$PATCH_DMABUF")
[[ $NEED_EGL == yes ]] && PATCHES+=("$PATCH_EGL")

run cp -v "${PATCHES[@]}" "$PKGDIR/"

if [[ $DRY_RUN == no ]] && grep -q 'vmwgfx-dmabuf.patch' PKGBUILD; then
    info "PKGBUILD already references the patch -- leaving it alone"
else
    PATCH_ARGS=()
    for p in "${PATCHES[@]}"; do PATCH_ARGS+=("$(basename "$p")"); done
    SUFFIX_ARG=()
    [[ -n $PKGREL_SUFFIX ]] && SUFFIX_ARG=(--pkgrel-suffix "$PKGREL_SUFFIX")
    run python3 "$BUNDLE/tools/patch-pkgbuild.py" "${SUFFIX_ARG[@]}" "${PATCH_ARGS[@]}"
    [[ $DRY_RUN == yes ]] || git --no-pager diff || true
fi

# ------------------------------------------------------------------ 7. fetch + prepare

step "Fetch the source and run prepare()"
info "this downloads the Hyprland release tarball and applies the patch -- a bad patch fails"
info "here, in a minute, rather than an hour into the compile"

run makepkg -so --noconfirm

step "Confirm the patch is in the tree that will be compiled"
if [[ $DRY_RUN == no ]]; then
    DMABUF_CPP=$(find src -maxdepth 5 -type f -path '*/src/protocols/LinuxDMABUF.cpp' | head -1)
    [[ -n $DMABUF_CPP ]] || die "could not find LinuxDMABUF.cpp under src/"
    info "checking $DMABUF_CPP"
    grep -q 'closeVmwGFXHandle' "$DMABUF_CPP" \
        || die "the patch is NOT in the extracted source -- do not build. prepare() patched a different tree."
    ok "$(grep -c 'vmwgfx\|DRM_VMW_UNREF_SURFACE\|closeVmwGFXHandle' "$DMABUF_CPP") matching lines found"
else
    info "(dry run: would grep the extracted source for closeVmwGFXHandle)"
fi

# ------------------------------------------------------------------ 8. build

step "Build (10-25 minutes on 8 cores -- this is the slow part)"
BUILD_START=$SECONDS
if [[ -n $MAKEFLAGS_OVERRIDE ]]; then
    info "MAKEFLAGS=$MAKEFLAGS_OVERRIDE"
    run env MAKEFLAGS="$MAKEFLAGS_OVERRIDE" makepkg -e --noconfirm
else
    run makepkg -e --noconfirm
fi
info "build took $(( (SECONDS-BUILD_START)/60 ))m $(( (SECONDS-BUILD_START)%60 ))s"

# ------------------------------------------------------------------ 9. install

step "Install the patched package"

if [[ $DRY_RUN == no ]]; then
    PKGVER_F=$(awk -F= '/^pkgver=/{print $2; exit}' PKGBUILD)
    PKGREL_F=$(awk -F= '/^pkgrel=/{print $2; exit}' PKGBUILD)
    [[ -n $PKGVER_F && -n $PKGREL_F ]] || die "could not read pkgver/pkgrel from PKGBUILD"
    FULLVER="$PKGVER_F-$PKGREL_F"
    CARCH_LOCAL=$(uname -m)
    info "expecting hyprland-$FULLVER-$CARCH_LOCAL"
    ls -la ./*.pkg.tar.* 2>/dev/null | sed 's/^/   | /'

    # A split package builds hyprland, hyprland-debug and hyprpm. Only the first is wanted:
    # `makepkg -i` would install all of them. Match the exact prefix so hyprland-debug-* does
    # not sneak in.
    mapfile -t CANDIDATES < <(find . -maxdepth 1 -name "hyprland-$FULLVER-$CARCH_LOCAL.pkg.tar.*" ! -name '*.sig' -print)
    (( ${#CANDIDATES[@]} == 1 )) \
        || die "expected exactly one hyprland-$FULLVER-$CARCH_LOCAL package, found ${#CANDIDATES[@]}"
    PKGFILE=${CANDIDATES[0]}
    info "will install: $(basename "$PKGFILE")"
else
    PKGFILE="./hyprland-<version>-$(uname -m).pkg.tar.zst"
fi

if [[ $ASSUME_YES != yes ]]; then
    warn "this replaces the running compositor's binary. The current session keeps running;"
    warn "the new one takes effect at the reboot at the end of this script."
    confirm "install it?" || die "stopped before install; the package is in $PKGDIR"
fi
run "${PACMAN[@]}" -U --noconfirm "$PKGFILE"

# ------------------------------------------------------------------ 10. pin

step "Pin the package against future updates"

if [[ $PIN_PACKAGE == yes ]]; then
    if grep -qE '^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])hyprland([[:space:]]|$)' /etc/pacman.conf; then
        info "hyprland is already in IgnorePkg"
    elif grep -qE '^[[:space:]]*IgnorePkg[[:space:]]*=' /etc/pacman.conf; then
        run sudo cp /etc/pacman.conf "/etc/pacman.conf.bak-$(date +%s)"
        run sudo sed -i -E 's/^([[:space:]]*IgnorePkg[[:space:]]*=.*)$/\1 hyprland/' /etc/pacman.conf
    else
        # Omarchy's pacman.conf has no commented #IgnorePkg template to uncomment, so insert.
        run sudo cp /etc/pacman.conf "/etc/pacman.conf.bak-$(date +%s)"
        run sudo sed -i '0,/^\[options\]/s//[options]\nIgnorePkg   = hyprland/' /etc/pacman.conf
    fi
    [[ $DRY_RUN == yes ]] || grep -nE '^[[:space:]]*IgnorePkg' /etc/pacman.conf | sed 's/^/   | /'
else
    warn "PIN_PACKAGE=no -- the next 'pacman -Syu' will overwrite your patched build"
fi

# ------------------------------------------------------------------ 11. optional extras

if [[ $INSTALL_OPEN_VM_TOOLS == yes ]]; then
    step "open-vm-tools"
    run "${PACMAN[@]}" -S --needed --noconfirm open-vm-tools
    run sudo systemctl enable --now vmtoolsd.service vmware-vmblock-fuse.service
fi

# ------------------------------------------------------------------ 12. verify

step "Verify"

if [[ $DRY_RUN == no ]]; then
    NOW=$(pacman -Q hyprland | awk '{print $2}')
    info "pacman -Q hyprland  -> $NOW"
    [[ $NOW == "$FULLVER" ]] && ok "the installed package is the one just built" \
                             || warn "installed version is $NOW, expected $FULLVER"

    HITS=$(strings /usr/bin/Hyprland 2>/dev/null | grep -c vmwgfx || true)
    info "strings /usr/bin/Hyprland | grep -c vmwgfx  -> $HITS"
    (( HITS >= 1 )) && ok "the patch is present in the installed binary" \
                    || die "the installed binary has no vmwgfx string -- the patch did not make it in"
fi

# ------------------------------------------------------------------ summary

printf '\n\033[1;32m  ================  BUILD AND INSTALL COMPLETE  ================\033[0m\n\n'
info "hyprland:     ${FULLVER:-?}  (patched)"
info "packages:     $PKGDIR/*.pkg.tar.*    -- keep these, reinstalling is a pacman -U"
info "log:          $LOGFILE"
printf '\n'
info "After the reboot, run:"
info "  $BUNDLE/tools/post-install.sh"
info "It enables wake-on-keypress and wake-on-mouse (both default to false, and a blanked"
info "screen with neither looks exactly like the bug you just fixed), installs open-vm-tools,"
info "and sets the resolution and scale. See Step 3 of REPAIR-OMARCHY-VM.md to do it by hand."
printf '\n'
info "Verify the fix with a dmabuf client, NOT a terminal:"
info "  chromium --new-window about:blank    (foot is an SHM client and maps even when broken)"
printf '\n'

if [[ $DO_REBOOT != yes ]]; then
    info "--no-reboot given. Reboot when ready:  sudo reboot"
    exit 0
fi

printf '\033[1m'
read -r -p "  Does everything look OK? Press Return to reboot (Ctrl-C to stay here) " _ </dev/tty
printf '\033[0m'

sync
[[ $DRY_RUN == yes ]] && { info "dry run: would now run 'sudo reboot'"; exit 0; }
sleep 1
sudo reboot
