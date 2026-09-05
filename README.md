# Hyprland on VMware — and getting Omarchy to run in a VM

Hyprland does not work in a VMware guest with 3D acceleration enabled. It either **aborts at
startup**, or it starts to a **permanently empty desktop** — the wallpaper and bar are there,
but no application window ever appears, because every GPU client is disconnected on its first
frame.

Two distinct bugs. Both are diagnosed here, both have patches, and both are verified working
on a real machine.

**This started as an attempt to run [Omarchy](https://omarchy.org) in VMware**, which is
where most people will meet this: Omarchy is built on Hyprland, so a VMware install completes
perfectly and then boots to a desktop where nothing can open. That is not an Omarchy bug and
there is nothing wrong with your install — it is the Hyprland/`vmwgfx` bug below, and it hits
any Hyprland-based distro in a VMware guest. Everything here works on plain Arch too; the
repair guide is written against Omarchy because that is the machine it was proven on.

If you got here by searching, these are the strings that lead to this repo:

- `zwp_linux_buffer_params_v1.failed` followed by the client being killed
- `error 0: invalid ... id` / `wl_display@1.error` on a freshly created dmabuf buffer
- `EGL: failed to initialize a platform display`
- Hyprland black screen / empty desktop / "frozen" in VMware Workstation, Fusion, Player or ESXi
- Omarchy installs fine and then boots to nothing usable / Omarchy VMware black screen
- "Omarchy in a VM doesn't work" — it does, with the patch here

## Is this you?

Sixty lines of C answer it in about a second, without touching your install:

```bash
gcc -o vmwtest tools/vmwtest.c $(pkg-config --cflags --libs libdrm gbm)
./vmwtest
```

It exercises the exact kernel call that fails. If it reports `PATCH IS CORRECT`, you have
bug 1 and the patches in this repo fix your machine.

## The two bugs

| | What you see | Cause | Patch |
|---|---|---|---|
| **1. dmabuf import** | Desktop starts, no window ever maps | `vmwgfx` returns a prime handle that `DRM_IOCTL_GEM_CLOSE` rejects with `EINVAL`; Hyprland treats the buffer as invalid and kills the client. The right call on this driver is `DRM_VMW_UNREF_SURFACE`. | `patches/*-vmwgfx-dmabuf.patch` |
| **2. EGL init** | Hyprland aborts before the desktop appears | The gbm fallback path in `initEGL` is unreachable, so a platform-display failure is fatal instead of falling back. | `patches/*-egl-gbm-fallback.patch` |

Most affected machines need **only patch 1**. Apply patch 2 only if Hyprland aborts at
startup — the repair guide tells you how to tell the two apart.

**Turning off VMware's 3D acceleration is not a workaround.** Hyprland `RASSERT`s — that is,
`abort()`s — on `eglCreateSyncKHR`, `eglDupNativeFenceFDANDROID` and `eglWaitSyncKHR`
unconditionally, in the `CHyprOpenGLImpl` constructor, before any fallback logic runs.
`eglDupNativeFenceFDANDROID` comes from `EGL_ANDROID_native_fence_sync`, which the software
rasterizer does not implement. With 3D off, Hyprland dies earlier and for a different reason.
Patching is the only route.

## Fix your machine

**[`REPAIR-OMARCHY-VM.md`](REPAIR-OMARCHY-VM.md)** is the procedure: rebuild the distro's
`hyprland` package with the patch applied, install it, pin it against updates, and verify the
fix took. It is written against **Omarchy** and Arch's `hyprland` PKGBUILD, and was executed
end to end on a real Omarchy VM — it is a transcript, not a sketch. On another Arch-based
distro the steps are the same; on a non-Arch distro the patches still apply, only the
packaging differs.

It also covers the Omarchy-specific things that waste an evening if you meet them cold: the
`pacman -Syu` guard hook, the screensaver and DPMS behaviour that looks exactly like the bug
you just fixed, `omarchy_gdk_scale` defaulting to 2, and why opening a terminal is *not* a
valid test that the fix worked (Omarchy's foot is an SHM client and maps even on a broken
system).

Two things before you start:

1. **Get SSH working first.** Not optional advice. The VMware console is barely usable for
   this work — no scrollback worth the name, no clipboard on a TTY — and a broken compositor
   can take the console with it. Step 0 of the guide is entirely about this.
2. **Get this repo onto the VM**, since every later step references files in it:

   ```bash
   git clone <repo-url> ~/hyprland-vmware-fix
   ```

Then follow the guide from Step 1.

Prefer not to type it? Two scripts run the same procedure:

- **`tools/auto-repair.sh`** — one shot, start to finish. Run it the moment you have SSH into
  a freshly provisioned VM: it updates the system, confirms the VM is affected, rebuilds and
  installs the patched package, pins it, and then asks you to confirm before rebooting.
  Versions and every other knob are variables at the top of the file.
- **`tools/repair-hyprland-vmware.sh`** — the same work in resumable phases
  (`check` / `prepare` / `build` / `install` / `verify`), stopping before it installs
  anything. Use this one if you want to inspect each stage.

After the reboot, **`tools/post-install.sh`** does the three things the patch does not:
turns on wake-on-keypress and wake-on-mouse (off by default in Hyprland, and the reason a
blanked screen looks exactly like the bug you just fixed), installs open-vm-tools, and sets
the resolution and scale.

Read the guide first either way — the scripts do not explain what they are doing or why.

## Read in this order

| File | What it is |
|---|---|
| [`REPAIR-OMARCHY-VM.md`](REPAIR-OMARCHY-VM.md) | **Start here if you just want a working VM.** Step-by-step repair for an installed system, plus post-repair setup (DPMS wake, open-vm-tools, resolution) and a "things that look like the bug and are not" section. |
| [`PROBLEM-AND-FIX.md`](PROBLEM-AND-FIX.md) | Full diagnosis: root causes, the evidence for each, why it is VMware-specific, why it looks like a freeze. |
| [`DEBUGGING-NOTES.md`](DEBUGGING-NOTES.md) | Debugging playbook, dead ends, environment traps, open items. Useful if you are debugging a *different* compositor problem where the compositor owns your only display. |

## Repo layout

```
patches/
  hyprland-0.56.2-vmwgfx-dmabuf.patch        <- the essential fix (0.56.2 release)
  hyprland-0.56.2-egl-gbm-fallback.patch     <- only if Hyprland aborts at startup
  hyprland-git-main-vmwgfx-dmabuf.patch      <- same fixes against git main @ 4a4a5279
  hyprland-git-main-egl-gbm-fallback.patch

tools/
  auto-repair.sh            <- one shot: update, patch, build, install, pin, reboot
  post-install.sh           <- after the reboot: wake-on-input, open-vm-tools, resolution
  vmwtest.c                 <- run this first: says in seconds whether a VM is affected
  patch-pkgbuild.py         <- adds the patches to an Arch PKGBUILD correctly (source, sums, prepare)
  repair-hyprland-vmware.sh <- phased, resumable: check / prepare / build / install / verify
  vmw-flip-watch.sh         <- samples vmwgfx IRQs + scanout FB id; tells a blank screen from a stall
  shmtest.c                 <- minimal wl_shm client; isolates dmabuf failures from everything else
  hypr-capture.sh           <- captures live state of a hung compositor, run over SSH

issues/
  1-dmabuf-create-immed-unbound-id.md            <- highest value, driver-independent
  2-initegl-gbm-fallback-unreachable.md
  3-crashreporter-alarm-truncates-debug-reports.md
```

The three issue drafts are **written but not submitted**.

## Building the tools

`vmwtest.c` needs only `libdrm` and `gbm`:

```bash
gcc -o vmwtest tools/vmwtest.c $(pkg-config --cflags --libs libdrm gbm)
```

`shmtest.c` needs generated xdg-shell protocol sources alongside it:

```bash
X=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
wayland-scanner private-code   $X xdg-shell.c
wayland-scanner client-header  $X xdg-shell.h
gcc -I. -o shmtest tools/shmtest.c xdg-shell.c -lwayland-client
```

The `-I.` matters: the generated header lands in your build directory, not next to the source.

Run `shmtest` against a live compositor with `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` set. A
magenta 400x300 window means `wl_shm` works — so if GPU clients are dying, the problem is
dmabuf import, not the compositor. This distinction matters when you verify the fix: on
Omarchy the default terminal (foot) is an SHM client and maps *even on a broken system*, so
"a terminal opens" proves nothing. Verify with a dmabuf client such as Chromium.

## Versions this was verified against

| | |
|---|---|
| Hyprland | 0.56.2 (Arch `extra`, `pkgrel` 3) |
| aquamarine | 0.14.0 |
| Distro | Omarchy (Arch-based); the patches are not Omarchy-specific |
| Host | VMware Workstation, 3D acceleration **on** |
| Diagnosed | 2026-09-02 |
| Repair verified on a real VM | 2026-09-04 |

The patches are small and target code that changes rarely, so they will likely apply to
neighbouring releases. `git main` variants are included for building from source.

## Upstream status

Neither fix is in Hyprland yet.

- The **dmabuf fix** exists only in a GitHub discussion (see Credit). Once it is merged, drop
  the patch and use a stock package.
- The **EGL fallback fix** has not been reported at all; `issues/2-*.md` is a ready-to-post
  draft.

There is also an open question this repo does not answer: whether `vmwgfx` returning a prime
handle that `GEM_CLOSE` rejects is a kernel-side bug. If it is, fixing it there would spare
every compositor from carrying a vmwgfx quirk. That is a question for dri-devel, not a bug
report.

## Credit

The vmwgfx dmabuf fix is **[Pascal-0x90](https://github.com/Pascal-0x90)'s**, posted
2026-08-31 in [hyprwm/Hyprland discussion #12966](https://github.com/hyprwm/Hyprland/discussions/12966).
This repo packages it, explains it, and provides a tested procedure for applying it — the fix
itself is theirs.

The EGL gbm-fallback fix, the diagnosis, the tools and the repair guide were produced while
debugging this on a real VM.

## License

BSD 3-Clause — see [`LICENSE`](LICENSE). This matches Hyprland's own license, so the patches
here can flow back upstream without a licensing question.
