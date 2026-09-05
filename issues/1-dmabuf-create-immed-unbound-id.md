# linux-dmabuf: create_immed import failure leaves buffer_id unbound, killing the client with a misleading error

## Summary

When `zwp_linux_buffer_params_v1.create_immed` fails to import, Hyprland sends `failed`
but never creates the `wl_buffer` object. The client's `new_id` is therefore never bound
server-side. The client's next request referencing that id — normally `wl_surface.attach` —
fails to demarshal, and libwayland-server kills the connection with:

```
wl_display#1: error 1: invalid arguments for wl_surface#37.attach
```

The error names `wl_surface.attach`, so it points at the surface rather than at the failed
buffer import several layers below. This is driver-independent: any import failure on any
hardware is disguised the same way.

## Spec

`linux-dmabuf-v1.xml`, `create_immed`, permits two failure behaviours:

> - the client is terminated with one of the following fatal protocol errors:
>   [...] INVALID_WL_BUFFER, in case the cause for failure is unknown or platform specific.
> - the server creates an invalid wl_buffer, marks it as failed and sends a 'failed' event

Hyprland does neither in full: it sends `failed` (second option) without creating the
wl_buffer that option requires. Either behaviour is fine; the current mix is not, because
the client is left holding an id the server does not know.

## Where

`src/protocols/LinuxDMABUF.cpp`, `CLinuxDMABUFParamsResource::create()`. Both failure paths
leave the id unbound:

```cpp
if UNLIKELY (!commence()) {
    LOGM(Log::ERR, "Failed creating a dmabuf: commence() said no");
    m_resource->sendFailed();          // no wl_buffer created for `id`
    return;
}
...
if UNLIKELY (!buf->good() || !buf->m_buffer->m_success) {
    m_resource->sendFailed();
    PROTO::linuxDma->m_buffers.pop_back();   // destroys the resource bound to `id`
    return;
}
```

## Reproduction

Any environment where dmabuf import fails. I hit it on VMware/vmwgfx, where `commence()`
always fails (see the separate vmwgfx report), but the disguising behaviour is independent
of why the import failed.

`WAYLAND_DEBUG=1 kitty`, tail:

```
-> zwp_linux_buffer_params_v1#49.create_immed(new id wl_buffer#48, 1830, 860, 875713089, 0)
-> zwp_linux_buffer_params_v1#49.destroy()
-> wl_surface#37.attach(wl_buffer#48, 0, 0)
discarded [unknown]#49.[event 1](0 fd, 8 byte)     <- the 'failed' event
wl_display#1.error(wl_display#1, 1, "invalid arguments for wl_surface#37.attach")
```

## Suggested fix

Raise the fatal `INVALID_WL_BUFFER` error on the params resource for `create_immed`
failures (`id != 0`), and keep `sendFailed()` for `create` (`id == 0`), which is the request
`failed` is designed for. That reports the real cause at the point of failure and terminates
the client cleanly instead of via a demarshal error.

## Impact

The message cost me and at least two other reporters hours of misdirected debugging
(hyprwm/Hyprland#12966, omacom/omarchy#8113 both chased display/page-flip theories). A
correct error would have named the import immediately.

## Environment

Hyprland v0.56.0-156-g4a4a5279 (also reproduces with packaged 0.56.2)
Arch Linux, kernel 7.2.2-arch1-1, wayland 1.26.0, wayland-protocols 1.49, mesa 26.2.1
