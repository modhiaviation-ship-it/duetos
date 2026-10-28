# Duet 3 (10IGL5) custom Linux: Phase 1

This covers deliverables **1 (feasibility)**, **2 (backup/rollback)** and **3 (hardware discovery)**,
plus the decisions that **don't** depend on which chips are inside the device (distro, filesystem,
desktop, power-manager approach).

Deliverables **4–9** (install guide, kernel and boot parameters, every config file, the idempotent build
script, the benchmark checklist, and maintenance) depend on which chips are actually in your unit.
I'll write them once you send back the output of `discover.sh`. I'm not going to guess chipsets.

Step labels:
- **[SAFE]**: read-only, or only touches the USB stick or external drive.
- **[CAUTION]**: changes something, but it can be undone.
- **[RISKY: optional]**: you can skip it, and it can cost you data or stability.

Nothing in Phase 1 writes to the eMMC.

---

## 1. Feasibility summary

"Expected" is my prior for Gemini Lake tablets of this generation. Discovery confirms or overturns each row.

| Area | Expected status | Confidence | Notes / what decides it |
|---|---|---|---|
| CPU burst to 2.8 GHz | ✅ Works | High | `intel_pstate` supports Goldmont Plus. Whether HWP/EPP is available decides how "race to idle" is tuned. |
| Overclocking (multiplier/BCLK) | ❌ Impossible | Certain | The N4020 is multiplier-locked and there's no BCLK control. Confirmed, moving on. |
| Under/overvolting | ❌ Impossible | Certain | No voltage interface on Gemini Lake. Not attempted. |
| RAM tuning | ❌ Impossible | Certain | Soldered, fixed SPD. Only *software* memory gains (zram, fewer services). |
| Raising RAPL PL1/PL2 | ⚠️ Probably not worth it | Medium | A fanless 6 W chassis is limited by heat, not by the power limit. We'll read the current limits and the lock bit (MSR 0x610 bit 63) first. I'll only recommend a change if the data shows the chip hits PL1 while still cool. |
| `mitigations=off` | ⚠️ Your choice, off by default | High | Goldmont Plus isn't affected by several of the Core-family bugs, so the gain may be small. `/sys/devices/system/cpu/vulnerabilities/*` (collected by the script) tells us exactly what's active. |
| GPU (UHD 600, i915) | ✅ Works | High | Mainline since years ago. |
| HW video decode (VA-API) | ✅ H.264, HEVC 8/10-bit, VP9 8/10-bit. ❌ AV1 | High | `intel-media-driver` (iHD) is the primary driver and `libva-intel-driver` (i965) is the fallback. We'll check with `vainfo`. YouTube will be forced off AV1. |
| Wi-Fi + Bluetooth | ✅ Likely | Medium | Probably an Intel CNVi module (`iwlwifi` + `linux-firmware`), but **unconfirmed**. Discovery settles it. |
| Touchscreen | ✅ Likely | Medium | Almost certainly I2C-HID (`i2c_hid_acpi` + `hid_multitouch`). The controller vendor comes from ACPI. |
| Pogo keyboard + touchpad | ✅ Likely | Medium | These usually enumerate as a USB HID device. The interactive part of the script shows what happens on detach. |
| **Audio (speakers/mics)** | ⚠️ **Biggest risk** | Low | Gemini Lake tablets often use an I2S codec through SOF instead of plain HDA. Some of those codecs (e.g. ES8336, ACPI `ESSX8336`) have working but quirky support: speaker/headphone GPIO swaps, mics needing UCM fixes. We need the ACPI HIDs before predicting anything. |
| Speaker EQ (Dolby replacement) | ✅ Doable | High | A PipeWire `filter-chain` EQ uses far less RAM than EasyEffects. |
| Accelerometer / auto-rotate | ✅ Likely | Medium | Comes either via the Intel ISH (`intel_ish_ipc` → `hid_sensor_*`) or a plain I2C accel. A mount-matrix hwdb fix may be needed. |
| Gyroscope | ⚠️ Present ≠ useful | Medium | Desktop Linux doesn't use it for anything. |
| Ambient light sensor | ❓ Unknown | Low | Auto-brightness only if an ALS shows up in IIO. Otherwise we skip it, as you asked. |
| Hall / tablet-mode switch | ⚠️ Uncertain | Low | It might be a real `SW_TABLET_MODE` event (`intel-vbtn`/`intel-hid`), or we might just infer it from the keyboard USB device disappearing. Either one works for showing the on-screen keyboard. |
| **Cameras (front/rear)** | ❌ **Expect not working** | Medium-high | On Gemini Lake the MIPI sensors hang off the Intel IPU4 ISP, which has no mainline Linux driver. `atomisp` is for older Bay/Cherry Trail and doesn't apply. A USB-C webcam is the real alternative. Discovery will confirm by listing the sensor ACPI HIDs. |
| Battery reporting | ✅ Works | High | Standard ACPI battery. |
| Charge limit (80%) | ❓ Only if firmware exposes it | Low | Only via `charge_control_end_threshold` or `ideapad_laptop` `conservation_mode`. No EC hacking. |
| Suspend | ⚠️ s2idle likely; S3 maybe | Medium | `/sys/power/mem_sleep` shows what the firmware offers. Overnight drain under 2%/h is achievable only if the SoC reaches S0ix/S3. We'll measure it. |
| USB-C DP alt mode | ✅ Likely | Medium | On GLK the mux is handled by the firmware or PD controller, and i915 just sees a DP connector. |
| Backlight, power/volume buttons | ✅ Likely | Medium | `intel_backlight` plus `soc_button_array`/`intel-hid`. |
| TPM 2.0 (fTPM/PTT) | ✅ Works | High | `tpm_crb`. Can auto-unlock LUKS via `systemd-cryptenroll` (optional). |
| Secure Boot | ✅ Either way | High | Either sign your own kernels with `sbctl` (your own keys, no shim needed) or disable it in the BIOS. |
| Idle RAM < 400 MB | ✅ Achievable | High | With labwc. Not with GNOME/KDE (see §4). |
| Boot < 10 s firmware→desktop | ⚠️ Plausible | Medium | The firmware alone takes ~3–5 s, which we can't change. Kernel plus userspace can be about 3–4 s on eMMC. |
| 8 h light use (30 Wh) | ⚠️ Stretch goal | Medium-low | That needs ≤ 3.7 W average. Linux on GLK usually lands at 6–8 h if package C-states and PSR work, less if they don't. Measured in Phase 2. |
| Waydroid | ⚠️ Works, heavy | High | Plan on 0.8–1.2 GB RAM while running. Opt-in only, stopped by default. |
| Wine | ⚠️ Light apps only | High | Small 32/64-bit utilities and Office-2010-era apps run fine. DX11+ games and anti-cheat software don't realistically work on this GPU. |

---

## 2. Decisions that don't depend on discovery (provisional)

### 2.1 Base distro: **Arch Linux (minimal)**

Scores are 1–5, higher is better.

| Distro | Idle RAM | Driver/firmware freshness | Maintenance ease | Touch stack availability | Total |
|---|---|---|---|---|---|
| **Arch (minimal)** | 5 | 5 | 3 | 5 | **18** |
| Void (glibc) | 5 | 4 | 3 | 3 | 15 |
| Alpine | 5 | 4 | 3 | 3 | 15 |
| Debian minimal (stable) | 4 | 2 (needs backports for SOF/kernel) | 5 | 3 | 14 |
| Fedora minimal | 3 | 5 | 4 | 4 | 16 |

Why Arch:
- Audio is the riskiest item, and SOF, `alsa-ucm-conf` and kernel fixes for Gemini Lake codecs keep landing upstream. Arch ships them within days.
- Every tool in the touch stack (labwc, wvkbd, lisgd, iio-sensor-proxy) is in the repos or the AUR.
- It's the best-documented distro for exactly this kind of hand-tuning.

The maintenance risk is a rolling-release breakage. We neutralize it with btrfs snapshots that boot straight from the bootloader (§9 in Phase 2).

Why not the others:
- Alpine's musl makes Chromium, Waydroid and Flatpak/glibc apps more painful.
- Void has a smaller ecosystem for the touch tools.
- Fedora minimal pulls in more services by default.

### 2.2 Filesystem: **btrfs with `compress=zstd:1,noatime`**

- **btrfs + zstd:1**: snapshots give you your rollback requirement (§9). Compression saves 30–40% of the 64 GB and reduces eMMC writes. zstd level 1 costs very little CPU, even on an N4020.
- **f2fs** is designed for flash and is slightly faster on small random writes. But it has no snapshots, so rollback would need A/B partitions, which wastes half of a 64 GB disk.
- **ext4** is the most robust, but has no compression and no snapshots.

The I/O scheduler for eMMC will be `mq-deadline` or `none`. I'll measure both in Phase 2. We'll also run weekly `fstrim.timer` and keep `/tmp` on tmpfs.

### 2.3 Desktop: **labwc + a hand-built touch layer**

| Option | Idle RAM (approx.) | Touch / convertible polish | Keyboard+touchpad | Verdict |
|---|---|---|---|---|
| Stripped GNOME | 0.9–1.1 GB | ★★★★★ (auto OSK, rotation, edge swipes, fractional scaling built in) | ★★★★★ | Best UX, **fails the 400 MB target** |
| Phosh | 0.5–0.6 GB | ★★★★☆ (OSK, rotation built in) | ★★☆☆☆ (phone UI, weak in laptop mode) | Good Plan B if DIY gets tiresome |
| Hyprland + hyprgrass | ~0.35 GB | ★★★☆☆ | ★★★★☆ | Plugin API breaks often, and heavier GPU use |
| Sway + lisgd | ~0.25 GB | ★★☆☆☆ (tiling is awkward with fingers) | ★★★★★ | Great with the keyboard, poor as a tablet |
| **labwc + wvkbd + lisgd + sfwbar/waybar** | **~0.25–0.3 GB** | ★★★☆☆ → ★★★★☆ with our scripts | ★★★★☆ | **Pick.** Stacking WM, maximize-by-default feels tablet-like, wlroots fractional scaling 1.5 |

Here's what we build on top of it:
- `wvkbd` on-screen keyboard, shown and hidden automatically by a tablet-mode watcher.
- `lisgd` edge swipes: top = launcher, bottom = OSK, left/right = switch windows.
- Rotation through `iio-sensor-proxy` → `wlr-randr`.
- 48 px touch targets in the panel and launcher.
- A dark theme.

There's a trade-off here. GNOME is genuinely smoother as a convertible. labwc gets you about 85% of that at roughly a quarter of the RAM.

### 2.4 Power management: **a small custom udev+script setup, no daemon** (provisional)

- **power-profiles-daemon** sets EPP well, but it doesn't switch profiles on AC/battery or battery level by itself.
- **TLP** covers AC/battery and runtime power management, but has no battery-level trigger. Adding one means a second tool.
- **auto-cpufreq** is a Python daemon that polls, which costs RAM and wakeups, and it fights with EPP on HWP chips.
- **Custom**: a udev rule on `power_supply` change, plus a battery-capacity trigger, plus one shell script. It writes EPP, max frequency, brightness cap, runtime power management, Wi-Fi power save and i915 settings. It costs zero resident RAM and gives you exactly three profiles with a manual override (panel button and gesture).

This becomes final once discovery confirms HWP/EPP. If HWP is missing, the profiles switch `scaling_governor` and `scaling_max_freq` instead.

### 2.5 Browser: **Firefox**

- Firefox enables VA-API on Intel/Mesa by default on Wayland and is easy to verify via `about:support`.
- Its built-in tab unloading handles tab sleeping.
- `media.av1.enabled=false` makes YouTube serve VP9 (hardware-decoded) without any extension.

Chromium is an option, but its Linux VA-API support has flip-flopped between releases. Exact prefs and flags come in Phase 2.

---

## 3. Backup and rollback (before anything touches the eMMC)

### 3.0 What you need
- **USB stick #1** (≥ 4 GB): the live system. The **Fedora Workstation Live** ISO is recommended for discovery. It boots with Secure Boot **on** (signed shim), so you don't have to change the BIOS yet, and its GNOME desktop gives a quick baseline for touch, rotation and sound.
- **External drive** (≥ 64 GB free, ext4 or exFAT) for the image.
- **A USB-C hub with power passthrough**, ideally. Without one you'll have the live stick in one port and the drive in the other, with no charging. In that case, start at ≥ 80% battery.
- Know your BIOS supervisor password if one is set. You'll need it later to change Secure Boot or boot settings.

### 3.1 Save what's inside FydeOS first [SAFE]
- Sync or export your browser bookmarks and passwords. Copy everything in *My files* that matters to the external drive.
- **Important about the TPM:** FydeOS, like ChromeOS, encrypts user data with keys tied to the TPM. A raw image restore brings FydeOS back exactly **only if the TPM hasn't been cleared**. So **don't clear the TPM in the BIOS** until you're sure you'll never roll back to FydeOS. If it does get cleared, a restored FydeOS still boots, but it wipes ("powerwashes") your user profile.

### 3.2 Make the live USB [SAFE]
Download the Fedora Workstation Live ISO from fedoraproject.org and write it to stick #1 with **Fedora Media Writer** or **Rufus** (DD mode) from this Windows PC.

To get to the boot menu on the Duet 3, power it off, attach the keyboard and plug in the stick. Then power on and tap **F12**. If that doesn't work, power on while holding **Volume Up** to get Lenovo's Novo/boot menu. Which one works can vary with BIOS version.

### 3.3 Identify the eMMC (don't skip) [SAFE]
In the live session, open a terminal:

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINTS
```

```bash
cat /sys/block/mmcblk*/device/name /sys/block/mmcblk*/device/type
```

The eMMC is the ~58 GiB `mmcblk0` (or `mmcblk1`) with type `MMC`. Your USB devices show `TRAN=usb`. Set a variable so no command below can hit the wrong disk:

```bash
EMMC=/dev/mmcblk0   # <-- change if lsblk showed mmcblk1
```

Make sure nothing on it is mounted. This should print nothing:

```bash
findmnt -rn -o SOURCE | grep "$EMMC"
```

### 3.4 Mount the external drive [SAFE]

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,TRAN    # find it, e.g. /dev/sda1
```

```bash
sudo mkdir -p /mnt/ext && sudo mount /dev/sda1 /mnt/ext && df -h /mnt/ext
```

### 3.5 Full eMMC image, compressed, with checksum [SAFE]
This only *reads* the eMMC.

```bash
sudo dd if="$EMMC" bs=4M status=progress conv=noerror,sync | zstd -T0 -3 -o /mnt/ext/duet3-emmc-fydeos.img.zst
```

Expect 20–40 minutes and roughly 10–25 GB, because empty space compresses to almost nothing.

Then save the partition table separately, plus the two hardware boot partitions. On a PC these are usually unused, but we keep a copy and **never write them**:

```bash
sudo sfdisk --dump "$EMMC" | tee /mnt/ext/duet3-emmc-partitions.sfdisk
```

```bash
for p in boot0 boot1; do [ -e "${EMMC}$p" ] && sudo dd if="${EMMC}$p" of=/mnt/ext/duet3-emmc-$p.bin bs=1M; done
```

Verify the image:

```bash
zstd -t /mnt/ext/duet3-emmc-fydeos.img.zst && echo "archive OK"
```

```bash
sudo dd if="$EMMC" bs=4M status=progress | sha256sum | tee /mnt/ext/duet3-emmc.sha256
```

```bash
zstd -dc /mnt/ext/duet3-emmc-fydeos.img.zst | sha256sum   # must match the line above
```

```bash
sync && sudo umount /mnt/ext
```

Copy those files to a second place, such as this PC. One backup isn't a backup.

### 3.6 Restore (full rollback to FydeOS) [CAUTION]
This overwrites the whole eMMC. Only run it when you mean it. Boot the live USB, then:

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,TRAN    # re-identify; set EMMC again
```

```bash
EMMC=/dev/mmcblk0
```

```bash
sudo mount /dev/sda1 /mnt/ext
```

```bash
zstd -dc /mnt/ext/duet3-emmc-fydeos.img.zst | sudo dd of="$EMMC" bs=4M status=progress conv=fsync
```

```bash
sudo dd if="$EMMC" bs=4M status=progress | sha256sum   # compare with duet3-emmc.sha256
```

Afterwards, if you've changed Secure Boot, set it back to the original setting in the BIOS. Also restore "Windows Boot Manager / FydeOS" as the first boot entry if the BIOS dropped it.

### 3.7 Lighter rollback once Arch is installed
Btrfs snapshots will be bootable from the menu (Phase 2, §9). The full image above stays your "factory reset".

---

## 4. Hardware discovery [SAFE, read-only]

### 4.1 Install the tools in the live session
Fedora Live runs from RAM, so this installs nothing on the eMMC:

```bash
sudo dnf install -y acpica-tools i2c-tools evtest libva-utils iw powertop libinput-utils msr-tools kernel-tools v4l-utils
```

On an Arch ISO the equivalent is `pacman -Sy acpica i2c-tools evtest libva-utils iw powertop libinput msr-tools turbostat v4l-utils`.

### 4.2 Run the script
Copy `discover.sh` from this folder onto the USB stick (or the external drive), then run:

```bash
sudo bash /run/media/liveuser/<stick>/discover.sh
```

It's read-only. It never writes to the eMMC, the EC, MSRs or sysfs tunables. It does:
- collects PCI/USB/ACPI/I2C/IIO/input/sound/power/thermal/RAPL/C-state/VA-API/suspend information
- masks MAC addresses and skips serial numbers
- in an interactive part (~1 minute), asks you to **detach the keyboard**, **rotate the tablet**, and **close the cover**, and records what changes

The result is `duet3-discovery-<date>.tar.gz` in the current directory. It includes the raw `acpidump`, which is too big to paste.

### 4.3 What I'll be looking for (so you can follow along)
| Question | Where it shows up |
|---|---|
| Wi-Fi/BT chipset | `lspci -nnk` (network controller + driver in use), `lsusb` (BT USB ID), `dmesg` iwlwifi/btusb lines |
| Touch controller | ACPI HIDs (e.g. `GDIX…`, `ELAN…`, `WCOM…`), `/sys/bus/i2c/devices/*/name`, `/proc/bus/input/devices` |
| Audio path | ACPI HIDs (`ESSX8336`, `10EC5682`, `INT34C2`, …), `lspci` audio device, `aplay -l`, dmesg `sof`/`snd` lines |
| Sensors | `lspci` "Integrated Sensor Hub", `/sys/bus/iio/devices/*/name`, `monitor-sensor` output |
| Tablet mode | the input-device diff before/after detaching, `SW_TABLET_MODE` in evtest |
| Cameras | ACPI sensor HIDs (`OVTI…`, `INT3471`, `INT3472`, …), any `Multimedia/Imaging` PCI device, `/dev/video*` |
| cpufreq/HWP | `scaling_driver`, `hwp` flag in cpuinfo, `energy_performance_available_preferences` |
| Power limits | `/sys/class/powercap/intel-rapl*`, MSR 0x610 lock bit |
| Suspend | `/sys/power/mem_sleep`, `low_power_idle_*_residency_usec` |
| Charge limit | `charge_control_*_threshold`, `ideapad_acpi/*/conservation_mode` |

### 4.4 Quick live-USB smoke test (2 minutes, on Fedora's GNOME) [SAFE]
Write down ✅/❌ for each, because they tell us a lot:
1. Touch with 2 fingers.
2. Rotate: does the screen follow, and is it the right way round?
3. Detach the keyboard: does the on-screen keyboard appear in a text field?
4. Wi-Fi and Bluetooth.
5. Speakers.
6. Mic (Settings → Sound input level).
7. Headphones/USB-C audio.
8. Brightness keys.
9. Volume buttons.
10. Suspend via the power button, then wake.
11. YouTube in Firefox (`about:support` → *Media* → hardware decoding).
12. Camera in the "Camera" app.

---

## 5. What comes in Phase 2 (after you send the discovery output)
4. Full install guide: GPT layout (ESP 1 GB + btrfs subvolumes `@ @home @var_log @snapshots`), systemd-boot or Limine with snapshot boot, sbctl, kernel, firmware, desktop and apps.
5. Kernel choice (stock `linux` vs `linux-zen` vs a trimmed custom build) and every boot parameter with a one-line reason.
6. Every config file: sysctl, zram-generator, udev, the power-profile script, i915, PipeWire EQ, labwc/wvkbd/lisgd, rotation and tablet-mode scripts, Firefox prefs.
7. `build.sh`: idempotent and commented, turning fresh Arch into this OS.
8. Benchmark checklist with expected numbers per profile: idle RAM, boot, sustained clock and temperature, YouTube drops, and battery drain for idle, web, 1080p and load.
9. Update and rollback procedure.
