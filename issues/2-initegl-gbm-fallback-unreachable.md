# render: the KHR_platform_gbm fallback in CHyprOpenGLImpl is unreachable

## Summary

In `CHyprOpenGLImpl::CHyprOpenGLImpl()`, `success` is set to `true` *before*
`initEGL(false)` is called, and `initEGL` reports failure by `RASSERT(false, ...)`
(i.e. `abort()`). So when the `EXT_platform_device` path fails, the process dies inside
`initEGL` and the `KHR_platform_gbm` fallback immediately below can never run.

The fallback reads as a working fallback but is dead code whenever the device path fails.

## Where

`src/render/OpenGL.cpp` (as of 4a4a5279):

```cpp
bool success = false;
if (EGLEXTENSIONS.contains("EXT_platform_device") || !m_proc.eglQueryDevicesEXT || !m_proc.eglQueryDeviceStringEXT) {
    m_eglDevice = eglDeviceFromDRMFD(m_drmFD);

    if (m_eglDevice != EGL_NO_DEVICE_EXT) {
        success = true;       // <-- set before the call
        initEGL(false);       // <-- aborts on failure, never returns
    }
}

if (!success) {
    Log::logger->log(Log::WARN, "EGL: EXT_platform_device or EGL_EXT_device_query not supported, using gbm");
    if (EGLEXTENSIONS.contains("KHR_platform_gbm")) {
        success = true;
        ...
        initEGL(true);
    }
}

RASSERT(success, "EGL does not support KHR_platform_gbm or EXT_platform_device, ...");
```

`initEGL` returns `void` and asserts at three points, e.g.:

```cpp
if (eglInitialize(m_eglDisplay, &major, &minor) == EGL_FALSE)
    RASSERT(false, "EGL: failed to initialize a platform display");
```

Note the final `RASSERT(success, ...)` is also unreachable as written — `success` is `true`
on every path that gets there.

## Observed

On VMware/vmwgfx, `eglInitialize` on the device platform fails:

```
ERR from aquamarine ]: [EGL] Command eglInitialize errored out with EGL_NOT_INITIALIZED (0x12289): DRI2: failed to create screen
```

and Hyprland aborts at startup:

```
#13 assertImpl(line=177, filename="OpenGL.cpp", reason="EGL: failed to initialize a platform display")
#14 Render::GL::CHyprOpenGLImpl::initEGL (gbm=false)  OpenGL.cpp:177
#15 Render::GL::CHyprOpenGLImpl::CHyprOpenGLImpl      OpenGL.cpp:346
#17 CCompositor::initManagers (stage=STAGE_BASICINIT) Compositor.cpp:701
```

The gbm path works fine on this hardware — making `initEGL` return `bool` and assigning
from it lets Hyprland start normally. So this is a genuine missed fallback, not just a
cosmetic ordering issue.

## Suggested fix

Make `initEGL` return `bool`, return `false` at the three failure points instead of
asserting (resetting `m_eglDisplay`/`m_eglContextVersion` and calling `eglTerminate` where
a display was already created), and assign:

```cpp
if (m_eglDevice != EGL_NO_DEVICE_EXT)
    success = initEGL(false);
...
        success = initEGL(true);
```

leaving the final `RASSERT(success, ...)` to fire only if both platforms genuinely failed.

I have this running locally; happy to open a PR if the approach is acceptable.

## Environment

Hyprland v0.56.0-156-g4a4a5279 (also reproduces with packaged 0.56.2)
VMware SVGA II / vmwgfx, Arch Linux, kernel 7.2.2-arch1-1, mesa 26.2.1
