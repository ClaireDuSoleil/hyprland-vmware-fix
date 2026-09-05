# Debugging notes

Working notes from the session that diagnosed these two bugs, on 2026-09-02. Kept because the
method generalizes: most of this is about how to debug a compositor that owns the only display
you have, which is a miserable position to be in and not well documented anywhere.

The VM used for the diagnosis has been discarded; everything that mattered is in this repo.

## What this is

Hyprland does not work in VMware guests with 3D acceleration on — and turning 3D acceleration
off is not an escape either (see the last section). Two bugs, both diagnosed and fixed, both
verified working. `PROBLEM-AND-FIX.md` has the full causal chain;
`REPAIR-OMARCHY-VM.md` is the procedure for a real machine. The target was a working
**Omarchy** VM on VMware; a scratch Arch VM was built purely to debug it, which is why the
diagnosis and the repair were done on two different machines.

State of play:

- vmwgfx dmabuf fix — Pascal-0x90's, from Hyprland discussion #12966, **not merged upstream**.
  Verified working here. Watch that discussion; drop the patch when it lands.
- EGL gbm-fallback fix — found here, **not reported anywhere**. `issues/2-*.md` is a
  ready-to-post draft.
- Three issue drafts in `issues/` are written but **not submitted**.
- The ISO section of `REPAIR-OMARCHY-VM.md` — baking the patch into a custom Omarchy image
  rather than repairing an installed one — is researched from docs but **never executed**.

## The debugging playbook that actually worked

Transferable to any "the compositor is broken and it owns the only display" problem.

1. **Enable sshd before anything else.** A second session is the whole game. `gdb` on the same
   seat is a trap — it SIGSTOPs the compositor, freezing the input you need to drive gdb.
   The user's own field note after doing this on a real Omarchy VM: the VMware console is
   *barely usable* — no useful scrollback, no clipboard on a TTY, awkward key handling — so
   installing SSH is genuinely the first action on a fresh VM, ahead of even diagnosing the
   graphics. If a user is fighting the console, stop and get them onto SSH before continuing.
   On **Omarchy** specifically, `openssh` is already installed and the package step is a
   red herring — what is actually missing is `systemctl enable --now sshd` **and**
   `sudo ufw allow ssh`, because Omarchy enables ufw with incoming denied. Confirmed on a real
   Omarchy VM on 2026-09-04.
2. **Separate crash from hang immediately.** `coredumpctl list`. A core means post-mortem
   works and is easy. No core plus a live process means a hang, and there is nothing to
   post-mortem — you must catch it live.
3. **For a hang, ask "is the event loop alive?" before anything else.** `hyprctl version` with
   a timeout. If it answers, the compositor is *healthy* and you are looking at the wrong
   layer. Combined with `/proc/<pid>/task/*/wchan`, this is decisive: `do_epoll_wait` on the
   main thread means idle-and-well; `futex_do_wait` means deadlocked.
4. **`WAYLAND_DEBUG=1` on a client is the highest-signal tool** when clients misbehave. It is
   what cracked this case — it showed the compositor sending
   `zwp_linux_buffer_params_v1.failed` and then killing the client over a dangling buffer id.
   Reach for it early.
5. **Bisect by buffer type.** A minimal `wl_shm` client (`tools/shmtest.c`) maps fine while
   dmabuf clients die. That single experiment localized the bug to the dmabuf path and proved
   the compositor, xdg-shell, rendering and scanout were all fine.
6. **Reproduce the suspect syscall outside the compositor.** `tools/vmwtest.c` is 60 lines and
   turns "the desktop is frozen" into three lines of ioctl results. It proved the fix before
   any rebuild. If you can get a bug out of the big program and into a small one, do it.

## Traps I fell into — do not repeat these

- **Zero CPU does not mean stuck.** Serving an IPC request costs under a tick, so a healthy
  idle compositor and a wedged one both look like 0%. Force real damage (`hyprctl notify`)
  and measure the delta. Here it jumped 267 ticks in 3s, which flipped the diagnosis.
- **Verify that your measurement measured anything.** I "sampled" the scanout framebuffer id
  three times and concluded it never changed — but the command had a `||` fallback to a
  cached file and I was reading the same stale text three times. Check your own instrumentation.
- **A stalled log file is not evidence.** `debug:disable_logs` defaults to **true**. I nearly
  filed a bug about the log "never flushing" before checking the default. Set
  `debug { disable_logs = false }` first thing and you get the errors directly instead of
  inferring them from protocol traces.
- **Do not run 25 `hyprctl reload`s in a loop.** It deadlocked the compositor (main thread to
  `futex_do_wait`, zero CPU, IPC dead). Possibly a real reload bug, never reproduced
  deliberately. Mentioned in `PROBLEM-AND-FIX.md` under "Also observed".
- **`pkill -f './foo'` matches your own wrapper shell** and kills the session running it.
  Use `pkill -x foo`.

## Environment gotchas

- `ptrace_scope=1` — `gdb -p` needs sudo for a process you did not spawn.
- **Hyprland will not start headless over SSH**: no seat, so `CBackend::create()` fails
  outright even though the headless backend is marked MANDATORY. You cannot test the
  compositor without a real VT. Test ioctl-level things standalone instead (see `vmwtest.c`).
- `--socket` requires `--wayland-fd`; it is for socket handover, not for naming a second
  instance. Hyprland auto-picks a free `wayland-N` anyway.
- The config here was **Lua** (`hyprland.lua` / `hyprlandd.lua`). `hyprctl dispatch` takes Lua
  form (`hl.dsp.…`), not the classic string dispatchers, and the mapping is not obvious.
  `hyprctl keyword` may not behave as expected either.
- A debug build of Hyprland is ~431 MB and its crash reports come out truncated — see the
  `alarm(15)` issue draft. Prefer `RelWithDebInfo` unless you specifically need `-O0`.
- Instance signature lives at `/run/user/$UID/hypr/<sig>/` (uid 1000 for a first user, but
  never hardcode it); export
  `HYPRLAND_INSTANCE_SIGNATURE` to use `hyprctl` from SSH. Clear stale instance dirs before
  restarting or `/bin/ls -t | head -1` picks the wrong one.
- **Omarchy aliases `ls` to `eza`, and `eza -t` means `--time <FIELD>`, not sort-by-time.**
  So `HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/$UID/hypr | head -1)` fails outright, HIS
  stays unset, and `hyprctl clients | grep -c` then returns `0` — which reads as "no windows
  mapped", a false negative on the exact measurement this whole bug is diagnosed by. Always
  spell it `/bin/ls -t`. Aliases do not apply inside scripts, only in the interactive shell
  you are pasting into.

## Open items — where to take this next

In rough order of value:

- **File the three issue drafts.** They carry exact code references, evidence and environment.
  Re-read them before posting: they were drafted against Hyprland @ `4a4a5279` and line
  numbers will have moved.
- **Open a PR for the vmwgfx fix.** It only exists in a discussion, which is likely why it is
  unmerged. Credit Pascal-0x90. A PR plus `vmwtest.c` as a reproducer is the shortest path to
  getting this fixed for everyone.
- **Build the custom Omarchy ISO.** Never executed here, and worth resisting for one or two
  VMs: patching an installed system is far less work, and adding `hyprland` to `omarchy-pkgs`
  means owning it against upstream forever.
- **Ask whether vmwgfx should be fixed kernel-side.** `drmPrimeFDToHandle` returning a handle
  that `DRM_IOCTL_GEM_CLOSE` rejects with `EINVAL` looks like a broken API contract; otherwise
  every compositor carries a vmwgfx quirk forever. Whether that is intended was never
  established here, so frame it as a question to dri-devel rather than a bug report —
  confidence on this one is low.

## Settled after the fact: 3D acceleration cannot simply be turned off

An earlier draft of `REPAIR-OMARCHY-VM.md` offered "disable VMware 3D acceleration" as a
no-patching workaround, flagged as unverified. It is wrong, and it has been removed.

Hyprland `RASSERT`s — i.e. `abort()`s — on `eglCreateSyncKHR`, `eglDupNativeFenceFDANDROID`
and `eglWaitSyncKHR` **unconditionally**, in the `CHyprOpenGLImpl` constructor, before any
platform selection or fallback logic. `eglDupNativeFenceFDANDROID` comes from
`EGL_ANDROID_native_fence_sync`, which the software rasterizer does not implement. With 3D
off, Hyprland therefore dies earlier than either bug fixed here, for a reason no patch in this
repo touches.

Patching is the only route. Do not re-suggest the workaround.
