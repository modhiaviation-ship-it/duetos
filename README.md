# DuetOS for the Lenovo IdeaPad Duet 3 (10IGL5)

A lightweight, touch-first Arch Linux system:
- **Desktop:** labwc, a dark theme and 1.5× scaling.
- **Touch:** an on-screen keyboard that appears when you detach the keyboard, auto-rotation, and edge swipes.
- **Power:** profiles that switch automatically between plugged in, battery and low battery.
- **Apps:** Firefox and mpv with hardware video decoding.

Installing **wipes the whole eMMC**, including FydeOS.

# Option A: download the DuetOS ISO (built for free by GitHub)

## A1. Put this folder on GitHub (one time, about 5 minutes)
1. Sign in at <https://github.com> (or create a free account).
2. Top right **+** → **New repository**. Name it `duetos`, choose **Public**, and click **Create repository**.
   It must be Public: free private repositories can only store 500 MB of build files, and the ISO is about 2 GB. The repository contains only configuration files and scripts, nothing personal.
3. On the new empty repository page, click **uploading an existing file**.
4. In File Explorer, open the `duet3-linux` folder. Select **everything inside it** (`.github`, `iso`, `README.md`, `discover.sh`, `PHASE1-…md`) and drag it onto the GitHub page. Wait for every file to appear in the list, then click **Commit changes**.

## A2. Wait for the build, then download
1. Open the repository's **Actions** tab. A run called **Build DuetOS ISO** starts by itself. If it doesn't, click it on the left → **Run workflow**.
2. Wait for the green ✓ (30–45 minutes).
3. Open the run, scroll to **Artifacts**, and download **duetos-iso**. It's a zip; extract it to get `duetos-<date>-x86_64.iso`.

## A3. Rufus
1. Choose the `duetos-…iso` file and set GPT / UEFI.
2. Click **START**. When Rufus asks, pick **"Write in DD Image mode"**.

## A4. Boot and install
1. Turn off Secure Boot (F2 → *Security*), then boot the stick (F12).
2. The DuetOS desktop starts on its own as a live session. Nothing you do there is saved.
3. To install for good, swipe down from the top edge (or tap **☰**) → **💾 Install DuetOS to this tablet**. Answer the questions and type `ERASE`. No internet is needed.

If the build fails (red ✗), open the failed run and copy the last ~50 lines of the log to me.

---

# Option B: no ISO build. Official Arch ISO + this folder (needs Wi-Fi during install)

## 1. Make the USB stick (on this Windows PC)
1. Download the latest **Arch Linux ISO** from <https://archlinux.org/download/> (pick an HTTP mirror near you; about 1.2 GB).
2. In **Rufus**:
   1. In **Device**, select your USB stick (≥ 4 GB; it will be erased).
   2. In **Boot selection**, choose the `archlinux-…-x86_64.iso` file.
   3. Set **Partition scheme** to GPT and **Target system** to UEFI.
   4. Click **START**. When Rufus asks, pick **"Write in ISO Image mode (Recommended)"**. **Not DD mode.** ISO mode keeps the stick writable so the next step works.
3. When Rufus finishes, copy the whole **`duet3-linux`** folder (the one this README is in) to the root of the USB stick in File Explorer.

## 2. Boot the stick on the Duet
1. **Turn off Secure Boot.** Power off, attach the keyboard, then power on and tap **F2** to enter the BIOS. On some BIOS versions you hold **Volume Up** while pressing power and choose *BIOS Setup* instead. Set *Security → Secure Boot* to **Disabled**, then save and exit. The Arch ISO isn't signed for Secure Boot, and this change doesn't harm anything.
2. Plug in the stick, power on, and tap **F12**, or use **Volume Up** → *Boot Menu*. Choose the USB device, then **Arch Linux install medium**.
3. You'll get a text prompt (`root@archiso`). Keep the keyboard attached: you'll type a few commands.

## 3. Connect to Wi-Fi
```bash
iwctl station wlan0 connect "Your Network Name"
```
It asks for the Wi-Fi password. Check the connection with `ping -c3 archlinux.org`. If `wlan0` doesn't exist, run `iwctl device list` to see the right name.

## 4. Install DuetOS (wipes the tablet)
```bash
bash /run/archiso/bootmnt/duet3-linux/iso/airootfs/usr/local/bin/duet-install
```
The installer asks for:
- a computer name
- a user name
- a time zone (e.g. `Asia/Kolkata`)
- whether to log in automatically
- the confirmation word `ERASE`

Then it downloads and installs everything, which takes 15–40 minutes depending on your internet speed. At the end it asks you to set your password.

When it says it's done, remove the stick and run `reboot`. You'll land on the DuetOS desktop. Reconnect to Wi-Fi from the 📶 tray icon.

> Optional, later: `iso/build-iso.sh` builds a full DuetOS live ISO, but it needs Arch Linux (WSL or a VM). You don't need it.

## Using it
| Action | How |
|---|---|
| Apps | Tap **▦**, or swipe up from the bottom edge |
| Quick settings (power profile, rotation, Wi-Fi, BT, brightness, suspend) | Tap **☰**, or swipe down from the top edge |
| On-screen keyboard | Shows automatically when the keyboard is detached. Toggle with **⌨** or a swipe in from the right edge |
| Rotation | **🔄/🔒** toggles auto-rotate. A right-click (two-finger click) on it rotates 90° |
| Power profile | **⚡ / ⚖ / 🍃** button. Tap to cycle auto → performance → balanced → power saver → auto |
| Switch / close windows | Tap the app icons in the top bar. Middle-click closes |
| Keyboard shortcuts | Super+Enter terminal, Super+D apps, Super+Q close, Super+K keyboard, Super+P power profile |
| Health check / benchmarks | **DuetOS Health Check** app, or `duet-check`, `duet-check drain 30`, `duet-check load 300` |
| Speaker EQ | In the volume menu (pavucontrol), choose output **Speakers (DuetOS EQ)** |

## If something is off
- **The screen is upside down or portrait at start:** tap ↻ (right-click 🔄) until it's correct with the keyboard attached. That angle is saved.
- **The screen turns the wrong way when you rotate the tablet:** set `INVERT=1` in `~/.config/duet/rotate.conf`.
- **Touch lands in the wrong place after rotating:** set `TOUCH_MATRIX=0` in the same file and rotate again.
- **Wi-Fi is laggy or drops on battery:** set `wifi.powersave = 2` in `/etc/NetworkManager/conf.d/duet.conf`.
- **Screen flicker or freezes:** these are usually caused by panel self-refresh. Add `i915.enable_psr=0` to the `options` line in `/boot/loader/entries/duetos.conf`.
- **No sound:** run `duet-discover` and send me the archive. Audio on this tablet depends on the exact codec.
- **Cameras:** expect them not to work. Their Intel IPU4 camera processor has no Linux driver. A USB-C webcam works.
- **Rolling back a bad update:** `sudo snapper list`, then `sudo snapper undochange <pre>..<post>`.

## Kernel parameters (and why)
| Parameter | Reason |
|---|---|
| `quiet loglevel=3 rd.udev.log_level=3` | Less console output means a faster, cleaner boot |
| `nowatchdog` | Removes a periodic timer interrupt that keeps the CPU out of deep idle |
| `zswap.enabled=0` | zram is used instead, and running both wastes RAM |
| `copytoram=n` (live only) | Don't copy the 2 GB image into the 4 GB of RAM |

Things that are deliberately left alone:
- **CPU security mitigations** stay at the safe defaults.
- **RAPL power limits and thermal trip points** stay at the firmware defaults.
- **Voltages and the EC** aren't touched.
