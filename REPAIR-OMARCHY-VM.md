# Repairing a real Omarchy VM on VMware

Goal: a working Omarchy desktop in a VMware guest **with 3D acceleration left on**.

Read `PROBLEM-AND-FIX.md` for why any of this is necessary. This file is the procedure.

**In a hurry, or repairing a VM you just built?** `tools/auto-repair.sh` does everything in
Steps 1 and 2 unattended — update, verify affected, patch, build, install, pin — and then asks
you to confirm before rebooting. Read Step 3 afterwards regardless: the post-reboot setup is
not automated, and the section on things that look like the bug and are not will save you an
evening.

### Conventions used here

Nothing in this guide assumes a particular username, hostname or IP address.

| You see | You substitute |
|---|---|
| `<user>` | the login name on the **VM** |
| `<vm-ip>` | the VM's address, from `ip -br -4 addr` in Step 0 |
| `<repo-url>` | wherever you got this bundle from, if you are cloning it |
| `<you>` | your own name, in sample output only — never type it |
| `~` / `$HOME` | left as-is: the shell expands it. Do not replace it with a literal path |

Commands run **on the VM** unless a block says otherwise. Blocks that run on your host say so
in a comment. Where a home directory appears in a command it is written `~`, and where a UID
appears it is written `$UID`, so the commands are safe to paste verbatim whatever your account
is called. Sample *output* is shown as it was actually printed, with identifying parts
replaced by `<you>`.

---

## Step 0 — Get SSH working. Do this before anything else.

**This is the first thing to do on a fresh Omarchy VM, before you even look at the graphics
problem.** The VMware console is barely usable for real work: no scrollback worth the name,
no clipboard on a TTY, awkward key handling, and a compositor failure can take the console
with it. Every step below assumes you are typing into an SSH session from your host, not
squinting at the VMware window.

### 0.0. Escape the broken desktop: `Ctrl+Alt+F3`

If you are staring at a blank desktop with only a cursor, you are not stuck. The graphical
session is one virtual terminal among several, and the others are fine — the compositor is
broken, the machine is not.

**Press `Ctrl+Alt+F3`.** You get a plain text login prompt. Log in with the same username and
password you set during install, and run everything below from there.

- Any of `F2` through `F6` works; `F3` is a safe pick because some setups keep a getty on
  `F2`. `Ctrl+Alt+F1` goes *back* to the graphical session — which is still broken, so it will
  look like nothing happened. Use `Ctrl+Alt+F3` to come back to the text console.
- **Click inside the VM window first**, so the guest has keyboard focus. VMware does not
  forward keystrokes to an unfocused window, and the identical symptom — keys doing nothing —
  is easy to blame on the bug you are chasing. See "VMware does not deliver input to an
  unfocused console" in Step 4.
- This passes straight through to the guest on VMware Workstation, which is where it was
  tested. If your host or hypervisor swallows it instead, look for a "send key" or hot-key
  setting to forward the combination.
- To release the mouse back to the host afterwards: `Ctrl+Alt`.

This one key sequence is the difference between "the VM is bricked" and "the VM has a broken
compositor and a perfectly good shell". Get to that shell, turn on SSH, and stop using the
console.

Keep the typing minimal, because you are doing it on the bad console. This uses **password
authentication**, which is the least fuss on a throwaway VM:

```bash
pacman -Q openssh                        # Omarchy ships it; expect a version
sudo systemctl enable --now sshd
sudo ufw limit 22/tcp && sudo ufw reload
ip -br -4 addr
```

**Do not run `pacman -S openssh` on a fresh install.** The package databases have not been
downloaded yet, so it fails with `target not found: openssh` — which reads like the package
does not exist, when in fact openssh is *already installed* and needs nothing. Check with
`pacman -Q` (queries what is installed) rather than installing.

Only if `pacman -Q openssh` reports it missing:

```bash
sudo pacman -Sy openssh
```

Omarchy ships `ufw` **enabled with incoming traffic denied by default**. Forgetting the
firewall line is the usual reason SSH looks broken on a fresh VM: sshd is listening perfectly
well and the packets never reach it. `ufw limit` rather than `ufw allow` adds rate limiting
against brute force — that is what Omarchy's own tooling uses.

> **Prefer key-based auth?** Omarchy has `omarchy-setup-security-sshd`, which does all of the
> above *and* authorizes a key. Note it **prompts interactively for a key** unless you pass
> one, and typing a public key on the VMware console is unpleasant — so pass it:
> `omarchy-setup-security-sshd --key="ssh-ed25519 AAAA... you@host"`.
> It never touches `PasswordAuthentication`, so it cannot lock you out.

`ip -br -4 addr` prints one short line per interface — connect to the address on the `UP` one,
without the `/24`:

```
lo               UNKNOWN        127.0.0.1/8
ens33            UP             192.168.220.132/24
```

**Do not use `hostname -I`**: `hostname` is not installed by default on Arch (it lives in
`inetutils`), and `command not found` at the very first step is a confusing place to start.
`-br` is *brief*; note that `ip -r` is `--resolve`, which is something else entirely. Then from
your host:

```bash
ssh <user>@<vm-ip>
```

Everything after this point is comfortable.

Notes that save a second trip to the console:

- **Rebuilding VMs? Expect `REMOTE HOST IDENTIFICATION HAS CHANGED`.** A new VM that reuses a
  previous one's IP has a different host key, and SSH refuses to connect. It is benign — you
  built the new machine. Clear the stale entry from the host and reconnect:

  ```powershell
  ssh-keygen -R <vm-ip>
  ```

  `ssh-keygen` ships with Windows' built-in OpenSSH, so this works in PowerShell as-is.
- If SSH refuses your password, you may have no user password set (some installs are
  key-only or rely on autologin). Fix with `passwd` on the console, or drop your key into
  `~/.ssh/authorized_keys`.
- **If it does not connect, the error tells you which of the two steps you missed.**
  `Connection timed out` → the firewall is dropping packets: `sudo ufw limit 22/tcp`.
  `Connection refused` → packets arrive but nothing is listening:
  `sudo systemctl enable --now sshd`. Check both on the guest with `sudo ufw status` (you want
  a `22/tcp LIMIT` line) and `systemctl is-active sshd`.
- If you moved sshd to a non-standard port, limit that number instead of 22.
- Networking: both VMware **NAT** and **Bridged** work for host→guest SSH — expect roughly
  `192.168.x.x` on NAT and your LAN range on bridged. If the address is unreachable *even with
  ufw open*, switch the adapter to the other mode and re-check. NAT users can alternatively add
  a port forward in VMware's Virtual Network Editor.
- Best case, do this from the installer's live environment or immediately after first boot —
  while the console still works — rather than after the desktop has broken.

Finally, get this bundle onto the VM — every step below references files inside it.

**If you have the repo URL, clone it on the VM.** This is the least fuss: no host-side step,
and `git pull` picks up later fixes.

```bash
sudo pacman -Sy --needed git          # -Sy: a fresh install has no package databases yet
git clone <repo-url> ~/hyprland-vmware-fix
```

**Otherwise copy a tarball from your host:**

```bash
# on your HOST, in the directory holding the tarball
scp hyprland-vmware-fix.tar.gz <user>@<vm-ip>:~

# then, back on the VM
tar -xf ~/hyprland-vmware-fix.tar.gz -C ~
```

`scp` works the same in PowerShell as in a Unix shell — it ships with Windows' built-in
OpenSSH. PowerShell tab-completion will write the local file as `.\hyprland-vmware-fix.tar.gz`;
that is fine. The `:~` on the end is the *remote* home directory and must stay exactly that.

Use `tar -xf`, not `-xzf`: depending on how the file was transferred it may arrive
uncompressed as a plain `.tar`, and `-xzf` then fails with `not in gzip format`. `-xf`
auto-detects either.

All paths below assume it landed at `~/hyprland-vmware-fix/`. Confirm it before moving on:

```bash
ls ~/hyprland-vmware-fix
```

**If you skip this, later steps fail confusingly.** Omarchy aliases `cd` to `zoxide`, so
`cd ~/hyprland-vmware-fix` on a directory that does not exist reports
`zoxide: no match found` rather than `No such file or directory` — which reads like a broken
tool instead of a missing directory. `\cd` or `builtin cd` bypasses the alias and gives the
real error.

Once SSH is up, snapshot the VM. Everything below is reversible, but a snapshot is cheaper
than a rebuild.

---

## Step 1 — Confirm the VM is actually affected (60 seconds)

Do not patch blindly. `tools/vmwtest.c` answers it definitively without touching Hyprland:

**On a fresh install, sync the package databases first.** Nothing installs until you do — a
brand-new Omarchy has empty sync databases, and every `pacman -S` fails with
`target not found`, which reads as "no such package":

```bash
sudo pacman -Syu
```

Take the **full** upgrade (`-Syu`), not a bare `-Sy`. `-Sy` followed by installing is a partial
upgrade, which reliably breaks an Arch system later.

**Omarchy blocks that command.** A pacman transaction hook intercepts direct system upgrades:

```
Woah partner...

This looks like a direct pacman system upgrade. Omarchy updates should normally
run through:

  omarchy update
...
error: failed to commit transaction (failed to run transaction hooks)
Errors occurred, no packages were upgraded.
```

Nothing is broken and nothing was upgraded — the hook refused the transaction. You have two
ways forward, and the choice is genuine:

```bash
omarchy update                                          # the blessed path
sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu      # the documented bypass
```

`omarchy update` also takes a snapshot, refreshes keyrings, runs migrations and post-update
hooks, and checks what needs restarting. On a machine you actually use, prefer it. On a VM
that is minutes old and is going to be rebooted at the end of this procedure anyway, the
bypass is deterministic and non-interactive, which is why `tools/auto-repair.sh` defaults to
it — see `SYSTEM_UPDATE_METHOD` in that script to switch.

The bypass variable is harmless on non-Omarchy Arch systems: pacman simply ignores it.

One consequence, worth checking before you go further: `-Syu` may pull a **newer Hyprland**
than the `0.56.2` these patches target.

```bash
pacman -Q hyprland aquamarine
```

Still 0.56.2 → carry on as written. Moved → see 2.3: clone the source at *that* tag and
`git apply --check` there. `commence()` has been stable across releases so the patches will
probably still apply; if not, `PROBLEM-AND-FIX.md` describes the change semantically so it
ports by hand in a couple of minutes.

Then build and run the probe:

```bash
cd ~/hyprland-vmware-fix
sudo pacman -S --needed base-devel libdrm mesa
gcc -o vmwtest tools/vmwtest.c $(pkg-config --cflags --libs libdrm gbm)
./vmwtest
```

Affected VM:

```
driver: vmwgfx
drmPrimeFDToHandle -> ret=0 handle=53364
drmCloseBufferHandle -> ret=-1 errno=22 (Invalid argument)
closeVmwGFXHandle  -> ret=0 errno=0 (ok)

RESULT: GEM close FAILED, vmwgfx unref SUCCEEDED -> PATCH IS CORRECT.
```

Unaffected VM prints `RESULT: GEM close SUCCEEDED - this driver does not exhibit the bug.`
If you see that, your problem is something else — stop here and diagnose separately.

Run this **before and after** any change. It is the cheapest signal you have.

---

## Not an option: turning off 3D acceleration

The obvious workaround — VM settings → Display → uncheck *Accelerate 3D graphics* — does not
work. Recording why, so nobody proposes it again.

Hyprland requires EGL explicit-sync **unconditionally**. In `src/render/OpenGL.cpp`, in the
`CHyprOpenGLImpl` constructor, before any platform selection or fallback logic runs:

```cpp
RASSERT(m_proc.eglCreateSyncKHR,           "Display driver doesn't support eglCreateSyncKHR");
RASSERT(m_proc.eglDupNativeFenceFDANDROID, "Display driver doesn't support eglDupNativeFenceFDANDROID");
RASSERT(m_proc.eglWaitSyncKHR,             "Display driver doesn't support eglWaitSyncKHR");
```

`RASSERT` is `abort()`. There is no config option and no fallback path — these three run on
every startup regardless of driver. `eglDupNativeFenceFDANDROID` comes from
`EGL_ANDROID_native_fence_sync`, which needs real sync FDs from a kernel driver and which the
software rasterizer does not implement. So with 3D acceleration off, Hyprland aborts in its
OpenGL constructor — *earlier* than either bug this bundle fixes, and for a reason no patch
here addresses.

Turning off 3D acceleration trades a broken desktop for a differently broken one. Patch
instead.

Confidence: the hard requirement is verified by reading the source (the three `RASSERT`s are
unconditional and precede everything else). That llvmpipe lacks the extension is the standard
situation but was not run on a 3D-disabled VM here.

---

## Step 2 — Patch Hyprland (the only fix)

### 2.1. Get a shell

You should already be on SSH from Step 0. If you are not, go back and do that first — the
rest of this is genuinely unpleasant on the VMware console.

If the desktop is broken and you never set SSH up, **`Ctrl+Alt+F3`** gets you a text console to
log in and run Step 0 from — see 0.0 above. A compositor failure takes the graphical session
with it; the other virtual terminals and an SSH session both survive it.

### 2.2. Identify which Hyprland you have

```bash
pacman -Q hyprland aquamarine                            # what is installed
pacman -Si hyprland | grep -E '^(Repository|Version)'    # which repo serves it
grep -E '^\[' /etc/pacman.conf                           # which repos are enabled at all
```

Use `-Si`, not `-Qi`. **`pacman -Qi` has no Repository field** — that field exists only in the
sync database. Running `pacman -Qi hyprland | grep Repository` silently returns nothing, which
looks like "no repo" rather than "wrong command".

The **Repository** line decides where the PKGBUILD comes from:

- `extra` → Arch's package. Use `pkgctl repo clone --protocol=https hyprland`.
- `omarchy` → Omarchy's own build. Get the PKGBUILD from
  `https://github.com/omacom-io/omarchy-pkgs` under `pkgbuilds/hyprland/`.

Observed on a stock Omarchy install, 2026-09-04: an `[omarchy]` repo **is** enabled in
`pacman.conf`, but `pacman -Si hyprland` returns only an `extra` block — Omarchy does not
carry Hyprland in its own repo. Expect the `extra` path. If `-Si` prints more than one block,
the first one wins, and that is the repo pacman would install from.

Note the version — the patches in `patches/` are version-specific (see 2.3). Note
`aquamarine` too: Hyprland and aquamarine are released in lockstep and a mismatch will bite
you at build time.

### 2.3. Pick the right patch set

`patches/` contains two sets:

| Set | Target | Status |
|---|---|---|
| `hyprland-0.56.2-*.patch` | Hyprland **0.56.2** release | verified to apply cleanly to a pristine v0.56.2 checkout |
| `hyprland-git-main-*.patch` | git main @ `4a4a5279` (v0.56.0-156) | verified building and running |

If your Omarchy ships something else, the patches will probably still apply — `commence()` has
been byte-identical across 0.56.x and main — but check. Checking needs a Hyprland source tree,
so clone one at the version you actually have:

```bash
sudo pacman -S --needed git
git clone --depth 1 --branch v0.56.2 https://github.com/hyprwm/Hyprland.git ~/hyprland-src
#                              ^^^^^^^ the tag matching `pacman -Q hyprland` from 2.2

cd ~/hyprland-src
git apply --check ~/hyprland-vmware-fix/patches/hyprland-0.56.2-vmwgfx-dmabuf.patch
git apply --check ~/hyprland-vmware-fix/patches/hyprland-0.56.2-egl-gbm-fallback.patch
```

Each check prints nothing when it succeeds, so add `&& echo OK` to the end of each line if you
want positive confirmation. `git clone --branch <tag>` leaves you in **detached HEAD** and
prints a paragraph about it — that is normal and not an error; you are not going to commit
anything here.

This clone is **only** for the check and for hand-porting if a patch rejects. The build in 2.5
downloads its own copy of the source from a different URL (a release tarball, not this git
repo). You can delete this tree afterwards.

Confirmed 2026-09-04 on a real Omarchy VM: hyprland 0.56.2-1 / aquamarine 0.14.0-2, and both
0.56.2 patches reported OK against a freshly cloned pristine `v0.56.2`.

If it rejects, apply the change by hand. It is small, and `PROBLEM-AND-FIX.md` gives the
semantics rather than just a diff, so it ports easily. The vmwgfx one is the essential one.

### 2.4. Do you need the EGL patch too?

Two separate bugs, two separate patches:

- **`*-vmwgfx-dmabuf.patch`** — always needed. This is what makes GPU clients work.
- **`*-egl-gbm-fallback.patch`** — needed only if Hyprland **aborts at startup** rather than
  starting to a blank desktop with only a cursor.

One command decides it:

```bash
ls -la ~/.cache/hyprland/ 2>/dev/null || echo "no crash reports"
```

- **Directory absent, or no crash reports in it** → Hyprland is starting fine and dying later.
  This is the empty-desktop variant. **You need only the dmabuf patch.**
- **Crash reports present** → open the newest and look for `initEGL` or
  `"EGL: failed to initialize a platform display"`. If it is there, add the EGL patch as well.

Prefer applying **only** the dmabuf patch when the symptom does not call for the other one.
Applying both is harmless in principle — the EGL patch only changes behaviour on a failure
path — but the dmabuf fix is third-party and reviewed in a public discussion, whereas the EGL
patch is unreported and unreviewed. Fewer changes, fewer variables when something goes wrong.

Observed 2026-09-04: on the real Omarchy VM `~/.cache/hyprland/` did not exist at all, so only
the dmabuf patch was applied.

### 2.5. Build and install

Everything below was executed on a real Omarchy VM on 2026-09-04 against Arch's
`hyprland` 0.56.2 PKGBUILD. It is a transcript, not a sketch.

You are rebuilding the **package**, not the raw source, so pacman owns the result and 2.6 and
the rollback section work. Two separate downloads are involved:

1. the **packaging repo** — just the `PKGBUILD`, cloned by you;
2. the **Hyprland source** — a release tarball fetched by `makepkg` from `source=()`.
   You never download this by hand.

#### Clone the packaging repo

```bash
sudo pacman -S --needed base-devel devtools git
cd ~
pkgctl repo clone --protocol=https hyprland
cd ~/hyprland
```

(For the `omarchy` case instead: `git clone --depth 1 https://github.com/omacom-io/omarchy-pkgs.git`
then `cd omarchy-pkgs/pkgbuilds/hyprland`.)

#### Read the PKGBUILD before editing it

```bash
cat PKGBUILD
```

Do not skip this, and do not paste in a `prepare()` from a guide. Arch's Hyprland PKGBUILD has
three properties that break naive instructions:

- **It is a split package**: `pkgname=(hyprland hyprpm)` is an *array*. Any guide telling you
  to `cd "$pkgname-$pkgver"` is wrong — in scalar context that is `hyprland-0.56.2`, which
  does not exist. The real variable is `_archive="${pkgname^}-$pkgver"` → `Hyprland-0.56.2`.
- **The source is a release tarball**, not a git checkout, and it extracts to a directory
  literally named `hyprland-source`. `prepare()` then does `ln -sf hyprland-source "$_archive"`,
  so the tree has two names.
- **`prepare()` already exists** and does real work (an rpath `sed` and a glaze version `sed`).
  You *insert into* it. Replacing it silently drops those fixes.

Also expect the packaging `pkgrel` to be ahead of what you have installed — 0.56.2-1 was
installed while the PKGBUILD said `pkgrel=3`. That is normal; you will build `-3`.

#### Add the patch

```bash
cd ~/hyprland
cp ~/hyprland-vmware-fix/patches/hyprland-0.56.2-vmwgfx-dmabuf.patch .
```

Then apply the PKGBUILD edits with the bundled tool:

```bash
cd ~/hyprland
python3 ~/hyprland-vmware-fix/tools/patch-pkgbuild.py \
        --pkgrel-suffix .1 hyprland-0.56.2-vmwgfx-dmabuf.patch
```

It appends the patch to `source=()`, appends one `'SKIP'` to every checksum array present
(keeping indices aligned), and inserts `patch -Np1 -i "$srcdir/<name>"` into the **existing**
`prepare()` right after its first `cd`, copying that line's indentation — Arch PKGBUILDs are
tab-indented, and a space-indented insert is a diff full of noise.

It is deliberately unhelpful when it is unsure. If `prepare()` is missing it refuses rather
than inventing one, because a PKGBUILD's `prepare()` usually contains fixes the build needs.
If the patch is already referenced it refuses too, so re-running it is safe. It writes a
`PKGBUILD.orig` backup either way.

`--pkgrel-suffix .1` turns `pkgrel=3` into `pkgrel=3.1`. That is a valid pacman version which
sorts above `3`, so `pacman -Q hyprland` prints `0.56.2-3.1` and you can tell your build from a
repo build at a glance, with no `strings` needed. Omit it if you would rather keep the version
identical to the repo's.

Verify the edit — a `pkgctl` clone is a git repo, so the diff is free:

```bash
git diff
```

You want exactly four hunks: `pkgrel`, the `source=()` line, the `sha256sums=()` line, and one
added `patch -Np1` line sitting between the existing `cd "$_archive"` and the first `sed`.

#### Download the source and confirm the patch landed — before paying for the build

```bash
cd ~/hyprland
makepkg -so
```

`-s` installs the build dependencies (sudo prompt: cmake, meson, ninja, glaze,
hyprwayland-scanner and friends). `-o` downloads `source=()`, extracts it, runs `prepare()`,
and stops. A patch that does not apply fails here, in a couple of minutes, instead of an hour
into a compile.

```bash
ls src/
grep -n 'vmwgfx\|DRM_VMW_UNREF_SURFACE\|closeVmwGFXHandle' \
     src/hyprland-source/src/protocols/LinuxDMABUF.cpp
```

`ls src/` shows the two-names-one-tree layout, which is worth seeing once:

```
Hyprland-0.56.2 -> hyprland-source
hyprland-source
hyprland-0.56.2-vmwgfx-dmabuf.patch -> /home/<you>/hyprland/hyprland-0.56.2-vmwgfx-dmabuf.patch
Hyprland-0.56.2.tar.gz -> /home/<you>/hyprland/Hyprland-0.56.2.tar.gz
```

The grep should return about five hits — the `#define`, the struct, `closeVmwGFXHandle`, the
`strncmp` against `"vmwgfx"`, and the call site inside `commence()` (line 301 in 0.56.2):

```
 24:#define DRM_VMW_UNREF_SURFACE 10
 31:static int closeVmwGFXHandle(int fd, uint32_t handle) {
 36:    isVmwgfx = version && version->name && strncmp(version->name, "vmwgfx", version->name_len) == 0;
 43:    return drmCommandWrite(fd, DRM_VMW_UNREF_SURFACE, &arg, sizeof(arg));
301:            closeVmwGFXHandle(PROTO::linuxDma->m_mainDeviceFD.get(), handle) != 0) {
```

Grep the real directory (`src/hyprland-source/...`), not a glob — a glob also matches the
symlink and double-reports every hit.

An empty grep here means `prepare()` patched a different tree than `build()` compiles. Stop
and work that out; do not start the build.

#### Build

Protect the build from an SSH disconnect first — losing the connection kills it:

```bash
command -v tmux && tmux new -s build
```

Then:

```bash
cd ~/hyprland
time makepkg -e 2>&1 | tee ~/hyprland-build.log
```

`-e` reuses the `src/` you just verified: no re-download, no re-extract, no re-`prepare()`. It
compiles exactly the tree you inspected. Detach from tmux with `Ctrl+b` then `d`; reattach
with `tmux attach -t build`. The `tee` means a failure is readable without rebuilding.

Roughly 10–25 minutes on 8 cores. Resource note from a real run: 8 cores / 15 GiB RAM /
75 GB free was ample and needed no job-count cap. Constrained VMs (say 4 GiB with 8 cores) can
OOM mid-link — cap with `MAKEFLAGS="-j4" makepkg -e` if that is your shape.

#### Install

```bash
cd ~/hyprland
ls -la *.pkg.tar.zst
```

You get **three** files, not two: `pkgname=(hyprland hyprpm)` gives two, and makepkg adds
`hyprland-debug` on top. Install only `hyprland`, rather than using `makepkg -i`, which
installs everything it built. Match the name exactly — `hyprland-debug-0.56.2-...` also starts
with `hyprland-`:

```bash
sudo pacman -U ./hyprland-0.56.2-3.1-x86_64.pkg.tar.zst
```

Keep the `.pkg.tar.zst` files. Reinstalling later is then a `pacman -U`, with no rebuild.

### 2.6. Stop the next update from undoing it

This is the step people skip and then re-debug from scratch. In `/etc/pacman.conf`:

```
IgnorePkg = hyprland
```

**Verified on a real Omarchy VM, 2026-09-04:** a full `omarchy-update` (run from the update
indicator in the status bar) left `hyprland 0.56.2-3.1` and `aquamarine 0.14.0-2` untouched,
with the vmwgfx string still in the binary. The pin does hold against Omarchy's own updater,
not just against plain `pacman -Syu`.

Re-check after any update anyway — it costs two seconds, and an aquamarine bump is the thing
that would break you, since your Hyprland links against `libaquamarine.so` with a version
dependency:

```bash
pacman -Q hyprland aquamarine                  # expect your pkgrel, and an unchanged aquamarine
strings /usr/bin/Hyprland | grep -c vmwgfx     # 0 = unpatched, 1 = your build
```

Expect **1**, not 5 — only the `"vmwgfx"` literal used by `strncmp` survives compilation.
Any nonzero value means your build is installed.

If `aquamarine` moves off the version you built against, Hyprland may fail to start on the
next login. Rebuild against the new pair rather than trying to force the old one.

### 2.7. Verify

First, confirm the binary on disk is yours:

```bash
pacman -Q hyprland                              # expect your pkgrel, e.g. 0.56.2-3.1
strings /usr/bin/Hyprland | grep -c vmwgfx      # expect exactly 1
```

**Expect 1, not 5.** Only the `"vmwgfx"` string literal used by `strncmp` survives
compilation — the `#define`, the struct and the function name are identifiers, not strings.
Any nonzero value means your build is installed; `0` means the stock package still is.

Then reboot, log in, and connect over SSH for the rest.

#### Do not verify with a terminal

The obvious check — "open a terminal, see if it stays" — **is invalid on Omarchy**, and this
cost real time on the first live run. Omarchy's terminal is **foot**, which renders through
`wl_shm`, not dmabuf. `wl_shm` clients mapped perfectly well on the *broken* system too; that
is exactly what `tools/shmtest.c` was written to demonstrate. A working terminal on Omarchy
tells you nothing about this bug.

Omarchy's screensaver (`org.omarchy.screensaver`) also runs foot, so seeing that in
`hyprctl clients` proves nothing either.

#### Verify with a GPU client

You need a client that actually imports dmabuf. Chromium is ideal — it is preinstalled on
Omarchy and needs no arguments:

```bash
export XDG_RUNTIME_DIR=/run/user/$UID
export WAYLAND_DISPLAY=$(cd /run/user/$UID && /bin/ls -d wayland-[0-9]* | grep -v '\.lock$' | head -1)
chromium --new-window about:blank &
sleep 10
```

If a Chromium window appears on screen and **stays**, the fix works. Before the patch, GPU
clients died within roughly 200 ms with
`invalid arguments for wl_surface#37.attach`.

Two things that will trip you up launching clients from SSH:

- Running a client with no `WAYLAND_DISPLAY` gives `Failed to create window`, which looks like
  the bug but is only missing environment.
- `/bin/ls -d wayland-[0-9]*` also matches `wayland-N.lock`, hence the `grep -v`.
- Use `/bin/ls`, not `ls`. **Omarchy aliases `ls` to `eza`, whose `-t` means `--time <FIELD>`,
  not sort-by-time.** `HYPRLAND_INSTANCE_SIGNATURE=$(ls -t ...)` fails outright, leaving the
  variable empty, so `hyprctl` silently reports **zero** clients — a false negative on the
  exact number you are trying to measure.

For the strict check, get the protocol trace:

```bash
WAYLAND_DEBUG=1 chromium --new-window about:blank 2>&1 \
  | grep -oE 'zwp_linux_buffer_params_v1@[0-9]+\.(created|failed)' | sort | uniq -c
```

`created` and no `failed` is the fix working. `failed` followed by a `wl_surface.attach` error
is the original bug.

#### `hyprctl` from SSH, on a Lua config

```bash
export XDG_RUNTIME_DIR=/run/user/$UID
export HYPRLAND_INSTANCE_SIGNATURE=$(/bin/ls -t /run/user/$UID/hypr | head -1)
hyprctl clients | grep -cE '^Window'
```

Omarchy uses a **Lua** Hyprland config, so `hyprctl dispatch` does not take classic string
dispatchers. It wraps your argument in `hl.dispatch(...)`, so pass the dispatcher expression
only:

```bash
hyprctl dispatch 'hl.dsp.exec_cmd("foot")'          # NOT: hyprctl dispatch exec foot
hyprctl dispatch 'hl.dsp.dpms({ action = "on" })'
```

Note `exec_cmd`, not `exec`.

---

## Step 3 — After the patch: make the VM usable

`tools/post-install.sh` does everything in this step — run it after the reboot and skip to
Step 4, or work through it by hand below. It is idempotent, backs up every file it touches,
and takes `--dry-run`.

Short checklist. None of this is about the bug — it is what turns a repaired VM into a
pleasant one. Do it in this order and log out once at the end.

**1. Let input wake the screen.** Append to `~/.config/hypr/hyprland.lua`, under Omarchy's
"Add any other personal Hyprland configuration below" comment:

```lua
hl.config({
    misc = {
        key_press_enables_dpms  = true,
        mouse_move_enables_dpms = true,
    },
})
```

Both ship as `false`. Without this, once the screen blanks nothing you type wakes it and the
VM looks locked up. See Step 4 for the full explanation.

**2. Install open-vm-tools** — needed for resolution autofit:

```bash
sudo pacman -S --needed open-vm-tools
sudo systemctl enable --now vmtoolsd.service vmware-vmblock-fuse.service
```

**3. Fix the display size in `~/.config/hypr/monitors.lua`.** Two separate settings, and both
matter:

```lua
omarchy_gdk_scale = 1        -- Omarchy DEFAULTS THIS TO 2

hl.monitor({
    output   = "Virtual-1",
    mode     = "1920x1200@60",   -- or "preferred" to let autofit drive it
    position = "auto",
    scale    = 1,
})
```

`omarchy_gdk_scale = 2` is the stock value — sensible on a HiDPI laptop, wrong in a VM. It
doubles every GTK app, so a correct 1920x1200 still looks huge and blurry. This is the single
most likely thing to make you think the repair failed when it did not.

Confirm the mode is on offer before pinning it, and note that pinning disables autofit:

```bash
hyprctl monitors all | grep -oE '1920x1200@[0-9.]+' | sort -u
```

**4. Log out and back in.** `GDK_SCALE` is read at process startup, so Hyprland's auto-reload
will not fix already-running GTK apps:

```bash
omarchy-system-logout
```

Then verify — you want `scale: 1.00` and the mode you asked for:

```bash
hyprctl monitors | grep -E '^Monitor|scale:|^\s+[0-9]+x[0-9]+'
```

Optional, but worth it on a VM you are testing with:

```bash
omarchy-toggle-screensaver     # the idle animation obscures whatever you are watching
```

And on a **Windows host, run the VMware console fullscreen** (`Ctrl+Alt+Enter`). Windows grabs
Super-key combinations in windowed mode, and Omarchy binds nearly everything to Super — so in
a window the desktop feels broken when it is not.

---

## Step 4 — Three things that look like the bug and are not

Everything in this section was hit on a real Omarchy VM *after* the fix was installed and
working. All three present as "the screen went black and the system is locked up." None is a
Hyprland bug. Read this before concluding the patch failed.

### One command tells them apart

```bash
sudo grep -m1 -oE 'fb=[0-9]+' /sys/kernel/debug/dri/0/state
```

Sample it a few seconds apart:

| `fb=` across samples | Meaning |
|---|---|
| changes | display pipeline healthy — look elsewhere |
| `fb=0` | the output was **disabled** — DPMS / idle. Configuration, not a fault |
| same nonzero value, pinned | **inconclusive on its own** — see below |

**A pinned `fb` does not by itself mean a stall.** An idle desktop with nothing to redraw
produces exactly the same signature: zero interrupts and an unchanging framebuffer. Measured
on a healthy machine, 2026-09-04:

```
15:48:30 irq=116695  d_irq=-   fb=111  same
15:48:42 irq=116695  d_irq=0   fb=111  same     <- idle, healthy, indistinguishable
```

To tell a stall from an idle desktop you **must force damage** and see whether flips resume:

```bash
hyprctl notify 1 3000 0 probe        # or start something animated
```

Healthy, once something is actually drawing — this is fullscreen 25 fps video, one interrupt
per frame, `fb` rotating through a triple buffer:

```
15:48:44 irq=116963  d_irq=268  fb=112  FLIP
15:48:46 irq=117014  d_irq=51   fb=112  same
15:48:48 irq=117064  d_irq=50   fb=111  FLIP
15:48:50 irq=117114  d_irq=50   fb=115  FLIP
```

A real stall is a pinned `fb` **that stays pinned while something is demonstrably rendering**
— confirm with the CPU-tick probe at the end of this section.

**The cheapest test of all: wait 60 seconds.** An idle Omarchy desktop is not completely
static — the status bar clock repaints once a minute, producing exactly one flip on the
minute boundary. Measured on a healthy idle machine:

```
15:50:00 irq=118676  d_irq=2  fb=111  FLIP      <- clock ticks
15:50:02 ... 15:50:58  d_irq=0  fb=111  same    <- nothing else redraws
15:51:00 irq=118678  d_irq=2  fb=112  FLIP      <- clock ticks again
```

So if you watch for a full minute and see **no** flip at all, the display is genuinely stalled.
If you see the once-a-minute tick, the pipeline is alive and idle.

`tools/vmw-flip-watch.sh` samples this alongside the vmwgfx interrupt count and labels each
sample, which is far easier than eyeballing it:

```bash
sudo bash tools/vmw-flip-watch.sh 5 | tee ~/flip-watch.log
```

Healthy looks like `d_irq` in the hundreds per 5 s with `fb` cycling between two or three ids
(triple buffering). The failure looked like this — note `fb` reaching `0` *before* the
interrupts stop, which is what proves the blank is deliberate rather than a stall:

```
14:07:31 irq=16128  d_irq=408  fb=111  FLIP
14:07:36 irq=16325  d_irq=197  fb=0    FLIP     <- output disabled here
14:07:41 irq=16325  d_irq=0    fb=0    same     <- interrupts stop as a CONSEQUENCE
```

### 1. The screensaver

Omarchy's screensaver draws an animated "omarchy" wordmark. On vmwgfx it flickers hard enough
to be unpleasant. This is the "screen going bonkers" phase and it is by design.

While the screensaver is **painting, the display is on** — DPMS is not involved yet. It
dismisses on a **key press**; mouse movement alone may not do it.

`omarchy-toggle-screensaver` turns it off — but note two things. It is a **toggle**, not an
off switch, so running it twice brings the screensaver back; query the state first with
`omarchy-toggle-enabled screensaver-off`, which is what Omarchy's own scripts use.

And it is **not enough on its own.** The screensaver and the lock are separate parts of
Omarchy's idle chain, so turning the screensaver off still leaves you locked out a few minutes
later. What you almost certainly want on a VM is:

```bash
omarchy-toggle-idle stay-awake      # no lock, no screensaver, no blanking
omarchy-toggle-idle allow-idle      # put it back
omarchy-toggle-idle status          # JSON: {"enabled":true,...} means idling is allowed
```

Those subcommands set state rather than flipping it, so they are safe to re-run. The state is
a single file — `~/.local/state/omarchy/indicators/stay-awake`, present means "stay awake" —
which is also the easiest thing to check from a script. `tools/post-install.sh` does both.

### 2. Idle DPMS off, with no way to wake it

After the screensaver, the idle chain blanks the display (`fb=0`) and locks the session.
Hyprland ships **both** DPMS wake options off (`ConfigValues.cpp`):

```
misc:mouse_move_enables_dpms   false
misc:key_press_enables_dpms    false
```

So once blanked, input does not wake the display — normally hypridle does it, and if you have
killed hypridle (as you might while debugging) nothing is listening at all. The only way back
is IPC:

```bash
hyprctl dispatch 'hl.dsp.dpms({ action = "on" })'
```

To make input wake it, append to `~/.config/hypr/hyprland.lua`, under Omarchy's own
"Add any other personal Hyprland configuration below" comment:

```lua
hl.config({
    misc = {
        key_press_enables_dpms  = true,
        mouse_move_enables_dpms = true,
    },
})
```

Then `hyprctl reload` — **once**. Repeated rapid reloads deadlocked the compositor during this
work. Confirm it took:

```bash
hyprctl getoption misc:key_press_enables_dpms
```

This does not stop the blanking or the locking; it only makes input wake the screen.

### 3. VMware does not deliver input to an unfocused console

This is the one that makes the other two look catastrophic. **VMware Workstation forwards
keyboard and mouse to the guest only while its console window has focus.** If you are working
over SSH with the VM window in the background — which this guide actively encourages — nothing
you type ever reaches the guest.

What actually works: **click once inside the VMware console window, then press Enter.**

### Known limitation: no host↔guest clipboard

VMware's copy/paste does **not** work in a Wayland guest. Ruled out the following on a real
Omarchy VM, so nobody repeats it:

- "Enable copy and paste" **was** ticked in VM → Settings → Options → Guest Isolation.
- `vmtoolsd -n vmusr` **is** running, started by open-vm-tools' own autostart.
- Its environment **already** contains `DISPLAY=:0` (checked via `/proc/<pid>/environ`).
- XWayland **is** running, and the plugin **is** installed
  (`/usr/lib/open-vm-tools/plugins/vmusr/libdndcp.so`).
- Restarting the daemon after XWayland was up changed nothing.

VMware's copy/paste plugin needs a real X session to own selections and receive host events;
a rootless XWayland instance is not enough. This is a limitation of VMware's implementation,
not something to fix in the guest.

**Workaround:** do your typing in an SSH session from the host, where copy/paste is the host's
own clipboard. To get text *out* of the guest, redirect to a file and `cat` it over SSH, or
take a screenshot with `grim`. Inside the guest, foot's own bindings work normally —
`Ctrl+Shift+C` / `Ctrl+Shift+V`.

Reading `/proc/<pid>/environ` needs the privilege on the *reading* side:
`sudo cat /proc/<pid>/environ | tr '\0' '\n'`. Writing `sudo tr ... < /proc/<pid>/environ`
fails with permission denied, because your shell opens the file before sudo runs.

### How to tell this whole class apart from the real bug

The dmabuf bug is none of the above. There, the display works fine and the *clients* die: you
get a wallpaper, `hyprctl clients` shows nothing GPU-backed, and `WAYLAND_DEBUG=1` shows
`zwp_linux_buffer_params_v1.failed`. If your display itself is blank or frozen, you are in this
section, not that one.

Confirm the compositor is alive before assuming anything, from SSH:

```bash
P=$(pgrep -x Hyprland)
A=$(awk '{print $14+$15}' /proc/$P/stat); hyprctl notify 1 3000 0 probe; sleep 3
B=$(awk '{print $14+$15}' /proc/$P/stat); echo "cpu ticks: $((B-A))"
```

A few hundred ticks means it is rendering normally and your problem is downstream of it.

---

## What was tested, and what works

Verified end to end on a real Omarchy VM on 2026-09-04, after applying the dmabuf patch:

| Test | Result |
|---|---|
| GPU client (Chromium, native Wayland) | maps and stays — **this is the fix working** |
| XWayland (`chromium --ozone-platform=x11`) | window maps, `xwayland: 1`, renders correctly |
| Screencopy (`grim`) | 447 KB PNG at full resolution |
| Direct scanout (fullscreen `mpv`) | steady flips, one interrupt per frame at 25 fps |
| VMware suspend / resume | display returns unaided, IRQ counter survives |
| Multi-monitor (second virtual display) | enumerated, and per-monitor window placement works |
| `IgnorePkg` against a real `omarchy-update` | patched build survived, aquamarine unchanged |

Non-fatal noise you can ignore, seen in Chromium's stderr on a healthy system:
`vaInitialize failed` (no VA-API on vmwgfx), `MESA-LOADER: failed to open dri: ...
Permission denied` and `ContextResult::kTransientFailure` (Chromium's own GPU sandbox),
`DEPRECATED_ENDPOINT` (Google push registration).

After the patch, the display stack on vmwgfx is sound. Everything else that looks broken —
see Step 3 — is configuration or host-side VMware behaviour.

---

## Rollback

```bash
sudo pacman -S hyprland          # reinstall the stock package
# remove the IgnorePkg line from /etc/pacman.conf
```

Keep the `.pkg.tar.zst` that `makepkg` produced — reinstalling your fix later is then just
`sudo pacman -U ./hyprland-*.pkg.tar.zst`, with no rebuild.

---

## When to stop carrying these patches

The vmwgfx fix is Pascal-0x90's, from
[hyprwm/Hyprland discussion #12966](https://github.com/hyprwm/Hyprland/discussions/12966).
Once it merges upstream, drop that patch and un-pin the package. Watch that discussion.

The EGL patch is not upstream and nobody else is carrying it. It is yours until filed and
merged — the draft report is in `issues/2-initegl-gbm-fallback-unreachable.md`.

---

## If you want this baked into a custom Omarchy ISO

`omarchy-pkgs` takes per-package patches at `pkgbuilds/<pkg>/.omarchy/patches/`, which is
exactly the shape of the files in `patches/`. Rough flow:

```bash
git clone https://github.com/omacom-io/omarchy-iso
git clone https://github.com/omacom-io/omarchy-installer
git clone https://github.com/omacom-io/omarchy-pkgs

# add pkgbuilds/hyprland/ with the patches in .omarchy/patches/
cd omarchy-pkgs && bin/repo build
cd ../omarchy-iso && ./bin/omarchy-iso-make --local-source ../omarchy-installer ../omarchy-pkgs
# ISO lands in ./release
```

Caveats, stated plainly: this build has **not** been run here, so the flags come from the
project's docs rather than testing. And `hyprland` is not currently one of the packages `omarchy-pkgs`
carries — adding it means you also own keeping it current with upstream Hyprland. That
maintenance, not the build, is the real cost of the ISO route.

For one or two VMs, patching an installed system (Step 2) is far less work.
