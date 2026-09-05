# Hyprland on VMware (vmwgfx): diagnosis and fix

Written 2026-09-02 from a throwaway Arch VM built solely to debug this.

## Symptom

On a VMware guest with 3D acceleration enabled, Hyprland is unusable. Depending on the
build you may see either or both of:

1. **Hyprland aborts at startup** with SIGABRT and never draws anything.
2. **Hyprland starts but the desktop appears frozen** — a wallpaper and nothing else. No
   terminal, no windows, no apparent response. GPU applications (kitty, alacritty,
   `hyprland-welcome`, `xdg-desktop-portal-hyprland`) die instantly with:

   ```
   wl_display#1: error 1: invalid arguments for wl_surface#37.attach
   ```

Symptom 2 is the deceptive one. **The compositor is not frozen.** It is healthy, rendering,
and responding to IPC the whole time. The desktop is empty because every GPU client is
killed on its first frame, so there is nothing to draw.

## Environment where this was diagnosed

```
GPU            VMware SVGA II Adapter [15ad:0405], DRM driver vmwgfx
GL renderer    SVGA3D; build: RELEASE; LLVM  (Mesa 26.2.1)
kernel         7.2.2-arch1-1
wayland        1.26.0 / wayland-protocols 1.49
libdrm         2.4.134
hyprland       0.56.2-1 (packaged) and v0.56.0-156-g4a4a5279 (git main)
aquamarine     0.14.0-2 (packaged) / 0.15.0 (git)
```

## Root cause 1 — clients killed on first frame (the "frozen desktop")

`src/protocols/LinuxDMABUF.cpp`, `CLinuxDMABUFParamsResource::commence()`:

```cpp
if (drmPrimeFDToHandle(m_mainDeviceFD.get(), m_attrs->fds.at(i), &handle)) { ... return false; }
if (drmCloseBufferHandle(m_mainDeviceFD.get(), handle)) {
    LOGM(Log::ERR, "Failed to close dmabuf handle");
    return false;                      // <-- a cleanup failure fails the whole buffer
}
```

This is a **validation probe**: import the client's dmabuf fd to a GEM handle, then close it
again, purely to check the fd is sane. Other compositors (mutter, wlroots) do not do this
round trip — which is why Kitty works under GNOME and niri on the very same VM.

On vmwgfx, `drmPrimeFDToHandle` returns a **TTM-backed surface handle, not a GEM object**.
SVGA3D surfaces are host-managed objects, not plain GEM buffers. `DRM_IOCTL_GEM_CLOSE` then
fails, because that handle was never in the GEM table.

Verified directly on the hardware with `tools/vmwtest.c`:

```
driver: vmwgfx
drmPrimeFDToHandle -> ret=0 handle=53364
drmCloseBufferHandle -> ret=-1 errno=22 (Invalid argument)   <- the bug
closeVmwGFXHandle  -> ret=0 errno=0 (ok)                     <- the fix
```

On i915 / amdgpu / nouveau / virtio-gpu the handle is a real GEM object, the close succeeds,
and the probe is an invisible no-op. That is why this is VMware-specific.

### Why one failed ioctl becomes a dead desktop

Three things compound:

1. Hyprland treats a **cleanup** failure as a **buffer creation** failure. The buffer is fine.
2. `create()` then calls `sendFailed()` and returns **without ever creating the `wl_buffer`**.
   The `linux-dmabuf-v1` spec permits sending `failed` for `create_immed`, but only if the
   server "creates an invalid wl_buffer, marks it as failed" — Hyprland skips that half, so
   the client's `new_id` is never bound server-side.
3. The client's next request, `wl_surface.attach(wl_buffer#48, 0, 0)`, references an object
   the server does not know. libwayland-server cannot demarshal it and kills the connection
   with an error naming `wl_surface.attach` — pointing at the surface rather than at a
   failed ioctl three layers down.

That misdirection is why this stayed unsolved in public bug reports: everyone chases display,
scanout and page-flip theories.

### Fix

Fall back to the vmwgfx surface unref when the GEM close fails. Patch by **Pascal-0x90**,
posted in [hyprwm/Hyprland discussion #12966](https://github.com/hyprwm/Hyprland/discussions/12966)
on 2026-08-31. Not merged upstream as of 2026-09-02 — it lives in a discussion, not a PR.

See `patches/*-vmwgfx-dmabuf.patch`. Semantically:

```cpp
#define DRM_VMW_UNREF_SURFACE 10
struct drmVmwSurfaceArg { int32_t sid; uint32_t handleType; };

static int closeVmwGFXHandle(int fd, uint32_t handle) {
    // returns -1 unless the driver is literally "vmwgfx"
    struct drmVmwSurfaceArg arg = {(int32_t)handle, 0};
    return drmCommandWrite(fd, DRM_VMW_UNREF_SURFACE, &arg, sizeof(arg));
}
```

and in `commence()`:

```cpp
if (drmCloseBufferHandle(fd, handle) != 0 && closeVmwGFXHandle(fd, handle) != 0) {
```

The helper no-ops on every non-vmwgfx driver, so it is safe to carry generally.

## Root cause 2 — Hyprland aborts at startup

`src/render/OpenGL.cpp`, `CHyprOpenGLImpl::CHyprOpenGLImpl()`:

```cpp
if (m_eglDevice != EGL_NO_DEVICE_EXT) {
    success = true;      // set BEFORE the call
    initEGL(false);      // signals failure via RASSERT -> abort()
}

if (!success) {          // unreachable once the branch above ran
    ... KHR_platform_gbm fallback ...
}
```

`initEGL` returns `void` and reports failure by `RASSERT(false, ...)`, i.e. `abort()`. So when
the `EXT_platform_device` path fails, the process dies inside `initEGL` and the gbm fallback
below can never run. On vmwgfx that path does fail:

```
[EGL] eglInitialize errored out with EGL_NOT_INITIALIZED (0x12289): DRI2: failed to create screen
```

giving the abort:

```
#13 assertImpl(line=177, filename="OpenGL.cpp", reason="EGL: failed to initialize a platform display")
#14 Render::GL::CHyprOpenGLImpl::initEGL (gbm=false)
#15 Render::GL::CHyprOpenGLImpl::CHyprOpenGLImpl
#17 CCompositor::initManagers (stage=STAGE_BASICINIT)
```

The gbm path works fine on this hardware. This is a genuine missed fallback.

**This bug is mine, found here, and is not reported upstream.** See
`issues/2-initegl-gbm-fallback-unreachable.md`.

### Fix

Make `initEGL` return `bool`, return `false` at its three failure points instead of asserting
(resetting `m_eglDisplay` / `m_eglContextVersion` and calling `eglTerminate` where a display
was already created), and assign `success = initEGL(...)` at both call sites. See
`patches/*-egl-gbm-fallback.patch`.

## Verification

Both fixes confirmed working on the debug VM on 2026-09-02:

```
kitty alive after 15s:            YES
hyprctl clients:                  kitty mapped: 1, size 915,430
"Failed to close dmabuf handle":  0
commence()/verify() failures:     0
new crash reports:                none
```

`hyprland-welcome` — the source of every SIGABRT core on the box since Aug 31 — also mapped.
The user confirmed visually: welcome screen displayed, kitty window behind it. Rendering,
scanout and input were all fine; only client buffer import was broken.

## Two upstream bugs found but not fixed

- **`Compositor.cpp` arms `alarm(15)` around the crash reporter**, which shells out to
  `addr2line`. On a debug build that exceeds 15s, the watchdog `abort()`s, and the report is
  written truncated with no backtrace. Self-defeating: more debug info, less report.
  See `issues/3-*.md`.
- **The `create_immed` unbound-`new_id` behaviour** described above, which is
  driver-independent and disguises every dmabuf import failure on any hardware.
  See `issues/1-*.md` — the highest-value of the three.

## Non-issue, recorded so nobody re-investigates it

Hyprland's log file appears to "stall" a few KB into startup and never grow again, even under
heavy activity. This is **not a bug**: `debug:disable_logs` defaults to `true`
(`ConfigValues.cpp`). Set `debug { disable_logs = false }` to get logs. Not knowing this cost
real time here — with logging on, the dmabuf errors would have been in the log immediately
instead of having to be inferred from a protocol trace.

## Also observed, not investigated

Running ~25 rapid `hyprctl reload` calls in a loop deadlocked the compositor: the main thread
moved from `do_epoll_wait` to `futex_do_wait` with zero CPU, and `hyprctl` stopped responding.
Seen once, not reproduced deliberately, no backtrace captured. Possibly a real reload
concurrency bug, possibly an artifact of a Lua config reloading under itself. Worth a look if
anyone sees a reload-related hang.
