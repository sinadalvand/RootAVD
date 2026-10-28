# root-emulator — one-command Magisk root for Android Studio AVDs

Root an **Android emulator (AVD)** with **Magisk**, including the fixes needed for
**modern images**: Android 15+/API 35+, **16 KB page-size** system images, and
Magisk's **new unified binary layout**.

One script does it all — detect the running emulator, fetch the right Magisk, patch
the ramdisk, cold-boot, and verify. Built on top of
[rootAVD](https://gitlab.com/newbit/rootAVD) and [Magisk](https://github.com/topjohnwu/Magisk).

---

## Quick start

```bash
# 1. Start your AVD from Android Studio (or: emulator -avd <name>) and let it boot.
# 2. Then:
./root-emulator.sh
```

That's it. On first run it downloads the pinned Magisk (needs internet once), patches
the emulator's ramdisk, cold-boots it, and prints how to use root. Root persists
across reboots.

Multiple emulators running? Pass the serial:

```bash
./root-emulator.sh emulator-5554
```

Other modes:

```bash
./root-emulator.sh --restore [SERIAL]     # un-root: restore stock ramdisk + cold-boot
./root-emulator.sh --no-reboot [SERIAL]   # patch only; cold-boot yourself later
./root-emulator.sh --help
```

---

## Requirements

- **macOS or Linux** with **bash** (the script re-execs itself under bash if needed).
  Windows: use WSL, or run `rootAVD.sh` per the upstream docs (`rootAVD.bat` is included).
- **Android SDK** with **platform-tools** (`adb`) and **emulator**. Found via
  `ANDROID_SDK_ROOT`/`ANDROID_HOME`, else `~/Library/Android/sdk` (macOS) or `~/Android/Sdk` (Linux).
- **curl or wget** (first run only, to download Magisk).
- The target emulator **running** before you start (rootAVD patches it live over adb).
- Best results on a **non-Play-Store** image (Google APIs or AOSP).

---

## Using root after it's installed

- **Interactive adb root** (most reliable on an emulator — it's a `userdebug` build):
  ```bash
  adb root        # restarts adbd as root
  adb shell id    # -> uid=0(root)
  adb unroot
  ```
- **App root**: open the **Magisk** app inside the emulator; grant root per app.
  The script sets Magisk `root_access` to *apps + ADB*.
- **Check Magisk**: `adb root && adb shell /debug_ramdisk/magisk -c` → e.g. `31.1:MAGISK:R`.

> The AVD ships its own `/system/xbin/su` which **shadows** Magisk's `su` in `PATH` and
> uses `su <uid> <cmd>` syntax (not `-c`). For scripted root use `adb root`.

---

## Why a custom script (what goes wrong on modern images)

Plain rootAVD fails on a 16 KB-page, recent-API image. Root causes found & handled:

1. **16 KB page size.** The Magisk **26.4** rootAVD bundles has 4 KB-aligned native
   binaries that **segfault** on a 16 KB kernel → rootAVD aborts at the busybox check.
   → Use **Magisk 28.1+** (16 KB-aligned). This script pins **v31.1**.

2. **New Magisk layout.** v28.1+ replaced `libmagisk32/64.so` with a single
   `libmagisk.so` (+ `libinit-ld.so`). rootAVD already handles it (its `INITLD` path),
   so a modern Magisk just works — no payload hacking.

3. **The boot-panic trap.** These images contain multiple concatenated cpio archives,
   so rootAVD **repacks the ramdisk with busybox `cpio`**. A *foreign* busybox (e.g. the
   osm0sis one) produces a malformed ramdisk → `magiskinit: : No such file or directory`
   → `Kernel panic - Attempted to kill init` (black screen / boot loop).
   → Let **Magisk's own busybox** do the repack. Don't substitute a third-party busybox.

4. **busybox probe quirk (minor).** `rootAVD.sh` here is patched so
   `FindWorkingBusyBox`/`TestingBusyBoxVersion` probe candidates under the exact name
   `busybox` (strict builds only act as a dispatcher under that name).

**Rule of thumb:** modern/16 KB image → recent Magisk (28.1+) + Magisk's own busybox.

---

## Repo layout

| Path | Purpose | In git? |
|------|---------|---------|
| `root-emulator.sh` | The automation. **Start here.** | ✅ |
| `rootAVD.sh` | rootAVD (GPL) + the busybox-probe patch. Called by the wrapper. | ✅ |
| `rootAVD.bat` | Upstream Windows launcher (unmodified). | ✅ |
| `LICENSE` | GPL-3.0 (rootAVD). | ✅ |
| `Apps/.gitkeep` | Keeps the `Apps/` dir (rootAVD installs/pulls APKs here at runtime). | ✅ |
| `Magisk.zip` | Magisk payload — **auto-downloaded on first run**. | 🚫 `.gitignore` |
| `Apps/*.apk`, `*.img`, `*.txt`, `*.log`, … | Runtime downloads/artifacts. | 🚫 `.gitignore` |

Everything the script fetches or generates is git-ignored, so the repo stays small and
clean. To pin a different Magisk, edit `MAGISK_VERSION` near the top of `root-emulator.sh`
(must be ≥ v28.1 for 16 KB images), or drop your own `Magisk-vXX.apk` in as `Magisk.zip`.

---

## Troubleshooting

- **Black screen / boot loop after patching** → too-old Magisk (#1) or a bad busybox
  repack (#3). `./root-emulator.sh --restore`, then re-run (default v31.1 is correct).
- **"No running emulator found"** → start the AVD first; confirm with `adb devices`.
- **Inspect a boot hang** → `emulator -avd <name> -no-snapshot-load -show-kernel` and
  look for `magiskinit` / `Kernel panic` lines; the script also keeps `.emulator-<avd>.log`.
- **`su -c` errors** → that's the AVD's built-in su, not Magisk. Use `adb root`, or grant
  via the Magisk app.
- **Manual restore** → `cp <sysimg>/ramdisk.img.backup <sysimg>/ramdisk.img`, then cold-boot.

---

## Credits & license

- **rootAVD** by **NewBit** — <https://gitlab.com/newbit/rootAVD> (GPL-3.0). `rootAVD.sh`
  here is a lightly modified copy (busybox-probe patch described above); see `LICENSE`.
- **Magisk** by **topjohnwu** — <https://github.com/topjohnwu/Magisk>. Downloaded at
  runtime, not redistributed here.
- `root-emulator.sh` and this README are provided under the same GPL-3.0 terms.
