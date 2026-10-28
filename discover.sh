#!/usr/bin/env bash
# discover.sh: read-only hardware discovery for the Lenovo IdeaPad Duet 3 10IGL5.
#
# Run from a LIVE USB as root:  sudo bash discover.sh [--no-interactive]
#
# Safety: this script only READS. It does not write to the eMMC, sysfs tunables,
# the EC or MSRs (rdmsr is a read). Output goes to the current directory.
# Privacy: MAC addresses are masked and serial numbers / UUIDs are skipped.

set -u
INTERACTIVE=1
[ "${1:-}" = "--no-interactive" ] && INTERACTIVE=0

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo bash $0" >&2
    exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$PWD/duet3-discovery-$STAMP"
mkdir -p "$OUT"
REPORT="$OUT/report.txt"

# Mask MAC addresses and drop serial-number / UUID lines from everything we record.
scrub() {
    sed -E 's/([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}/XX:XX:XX:XX:XX:XX/g' |
        grep -viE 'serial[_ ]?num|iserial|^ *serial:|uuid'
}

# run "Section title" command...  -> appends a titled section to report.txt
run() {
    local title=$1; shift
    {
        echo
        echo "=================================================================="
        echo "== $title"
        echo "== \$ $*"
        echo "=================================================================="
        if command -v "$1" >/dev/null 2>&1; then
            timeout 60 "$@" 2>&1 | scrub
        else
            echo "(command '$1' not installed, skipped)"
        fi
    } >>"$REPORT"
}

# sh "Section title" 'shell snippet'  -> same, for pipelines / loops
sh() {
    local title=$1 snippet=$2
    {
        echo
        echo "=================================================================="
        echo "== $title"
        echo "=================================================================="
        timeout 60 bash -c "$snippet" 2>&1 | scrub
    } >>"$REPORT"
}

# Print every readable file under a glob as "path: value" (single-line values only).
dumpfiles() { for f in "$@"; do [ -f "$f" ] && [ -r "$f" ] && printf '%s: %s\n' "$f" "$(head -c 300 "$f" 2>/dev/null | tr '\n' ' ')"; done; }
export -f dumpfiles

echo "Collecting into $OUT ..."

# --- Identity ---------------------------------------------------------------
sh  "DMI (non-serial fields)" 'cd /sys/class/dmi/id && for f in sys_vendor product_name product_version product_family board_vendor board_name bios_vendor bios_version bios_date chassis_type; do printf "%s: %s\n" $f "$(cat $f 2>/dev/null)"; done'
run "Kernel" uname -a
sh  "Kernel cmdline" 'cat /proc/cmdline'
sh  "OS release" 'cat /etc/os-release'

# --- CPU / power / thermal ----------------------------------------------------
run "lscpu" lscpu
sh  "cpuinfo (cpu0 only)" 'awk "/^$/{exit} {print}" /proc/cpuinfo'
sh  "cpufreq" 'dumpfiles /sys/devices/system/cpu/cpu0/cpufreq/* /sys/devices/system/cpu/intel_pstate/*'
sh  "cpuidle states" 'for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do echo "$s: $(cat $s/name) latency=$(cat $s/latency) disable=$(cat $s/disable) usage=$(cat $s/usage) time=$(cat $s/time)"; done; dumpfiles /sys/devices/system/cpu/cpuidle/*'
sh  "S0ix / low-power-idle residency" 'dumpfiles /sys/devices/system/cpu/cpuidle/low_power_idle_* /sys/kernel/debug/pmc_core/* 2>/dev/null'
sh  "CPU vulnerabilities / mitigations" 'dumpfiles /sys/devices/system/cpu/vulnerabilities/*'
sh  "RAPL powercap (limits)" 'for d in /sys/class/powercap/intel-rapl*; do echo "--- $d"; dumpfiles $d/name $d/enabled $d/constraint_*; done'
sh  "RAPL MSR 0x610 / 0x606 (READ ONLY, needs msr-tools)" 'command -v rdmsr >/dev/null || { echo "rdmsr not installed"; exit; }; modprobe msr; echo "MSR_PKG_POWER_LIMIT 0x610 = $(rdmsr -X -c 0x610)"; echo "MSR_RAPL_POWER_UNIT 0x606 = $(rdmsr -X -c 0x606)"; echo "bit 63 of 0x610 = lock: $(( ($(rdmsr -c 0x610) >> 63) & 1 ))"'
sh  "Thermal zones + trip points" 'for z in /sys/class/thermal/thermal_zone*; do echo "--- $z type=$(cat $z/type) temp=$(cat $z/temp) policy=$(cat $z/policy 2>/dev/null)"; for t in $z/trip_point_*_temp; do [ -f "$t" ] && echo "  $(basename $t)=$(cat $t) type=$(cat ${t%_temp}_type)"; done; done; for c in /sys/class/thermal/cooling_device*; do echo "$c: $(cat $c/type) cur=$(cat $c/cur_state)/$(cat $c/max_state)"; done'
run "turbostat 10 s idle sample (C-states, PkgWatt)" turbostat --quiet --interval 10 --num_iterations 1

# --- Buses / devices ------------------------------------------------------
run "lspci -nnk" lspci -nnk
run "lspci -vv (capabilities, ASPM)" lspci -vv
run "lsusb" lsusb
run "lsusb -t" lsusb -t
sh  "ACPI devices: HID / status (15 = present+enabled)" 'for d in /sys/bus/acpi/devices/*; do h=$(cat $d/hid 2>/dev/null); [ -n "$h" ] && printf "%-22s %-12s status=%s %s\n" "$(basename $d)" "$h" "$(cat $d/status 2>/dev/null)" "$(cat $d/path 2>/dev/null)"; done | sort -k2'
sh  "I2C devices" 'for d in /sys/bus/i2c/devices/*; do printf "%s name=%s driver=%s\n" "$(basename $d)" "$(cat $d/name 2>/dev/null)" "$(basename "$(readlink $d/driver 2>/dev/null)")"; done'
run "i2cdetect -l (bus list only, no probing)" i2cdetect -l
sh  "Platform drivers / devices of interest" 'ls /sys/bus/platform/drivers/ | grep -iE "ideapad|vbtn|intel.hid|soc_button|gpio.keys|ish|sof|tablet|lenovo|wmi"; echo; ls /sys/bus/platform/devices/'
sh  "WMI GUIDs" 'ls /sys/bus/wmi/devices/ 2>/dev/null'
run "lsmod" lsmod

# --- Input / touch / sensors ----------------------------------------------
sh  "/proc/bus/input/devices" 'cat /proc/bus/input/devices'
run "libinput list-devices" libinput list-devices
sh  "IIO devices" 'for d in /sys/bus/iio/devices/iio:device*; do echo "--- $d name=$(cat $d/name 2>/dev/null)"; ls $d | grep -E "in_|mount_matrix|scale"; dumpfiles $d/*mount_matrix*; done'
sh  "hwdb / udev properties for accelerometer" 'for d in /sys/bus/iio/devices/iio:device*; do udevadm info -q property -p $d 2>/dev/null | grep -iE "ACCEL|IIO|NAME"; done'

# --- Graphics / display ---------------------------------------------------
sh  "DRM connectors" 'for c in /sys/class/drm/card*-*; do echo "$(basename $c): status=$(cat $c/status 2>/dev/null) enabled=$(cat $c/enabled 2>/dev/null) modes=$(head -1 $c/modes 2>/dev/null)"; done'
sh  "i915 parameters" 'dumpfiles /sys/module/i915/parameters/*'
sh  "i915 PSR / FBC status (debugfs)" 'mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug; cat /sys/kernel/debug/dri/0/i915_edp_psr_status /sys/kernel/debug/dri/0/i915_fbc_status 2>&1 | head -40'
sh  "Backlight" 'for b in /sys/class/backlight/*; do echo "$b: type=$(cat $b/type) max=$(cat $b/max_brightness) cur=$(cat $b/brightness)"; done'
run "vainfo (VA-API)" vainfo
sh  "vainfo with i965 driver" 'command -v vainfo >/dev/null && LIBVA_DRIVER_NAME=i965 vainfo 2>&1 | head -40'

# --- Audio -----------------------------------------------------------------
sh  "ALSA cards" 'cat /proc/asound/cards; echo; aplay -l 2>&1; echo; arecord -l 2>&1'
sh  "HDA codecs (if any)" 'for f in /proc/asound/card*/codec#*; do [ -f "$f" ] && { echo "--- $f"; head -20 "$f"; }; done'
sh  "SOF / ASoC components" 'cat /sys/kernel/debug/asoc/components 2>/dev/null; ls /sys/bus/platform/devices | grep -iE "sof|essx|rt5|cx20|hdmi|dmic"'
sh  "ALSA UCM verbs (alsaucm)" 'command -v alsaucm >/dev/null && for c in $(awk "/^ *[0-9]+ \\[/ {print \$1}" /proc/asound/cards); do echo "--- card $c"; alsaucm -c hw:$c list _verbs 2>&1; done'

# --- Network / Bluetooth -----------------------------------------------------
run "rfkill" rfkill list
run "iw dev" iw dev
sh  "iw phy (capabilities, first 60 lines)" 'iw phy 2>&1 | head -60'
sh  "Wi-Fi power save" 'for i in $(iw dev 2>/dev/null | awk "/Interface/{print \$2}"); do echo "$i: $(iw dev $i get power_save 2>&1)"; done'
run "bluetoothctl show" bluetoothctl show

# --- Power supply / suspend / platform --------------------------------------
sh  "Power supplies" 'for p in /sys/class/power_supply/*; do echo "--- $p"; cat $p/uevent; ls $p | grep -iE "charge_control|behaviour|threshold"; done'
run "upower -d" upower -d
sh  "Suspend modes" 'echo "mem_sleep: $(cat /sys/power/mem_sleep)"; echo "state: $(cat /sys/power/state)"; dumpfiles /sys/power/pm_*'
sh  "Ideapad ACPI (conservation mode etc.)" 'ls -la /sys/bus/platform/drivers/ideapad_acpi/ 2>&1; dumpfiles /sys/bus/platform/drivers/ideapad_acpi/*/conservation_mode /sys/bus/platform/drivers/ideapad_acpi/*/fn_lock'
sh  "Platform profile" 'dumpfiles /sys/firmware/acpi/platform_profile*'
sh  "Runtime PM status of PCI/USB/I2C devices" 'for d in /sys/bus/pci/devices/* /sys/bus/usb/devices/* /sys/bus/i2c/devices/*; do [ -f $d/power/control ] && echo "$d control=$(cat $d/power/control) status=$(cat $d/power/runtime_status 2>/dev/null)"; done'
sh  "PCIe ASPM policy" 'cat /sys/module/pcie_aspm/parameters/policy'

# --- Storage ---------------------------------------------------------------
run "lsblk" lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,TRAN,MOUNTPOINTS
sh  "eMMC details" 'for b in /sys/block/mmcblk*; do [ -d $b/device ] || continue; echo "--- $b"; dumpfiles $b/device/name $b/device/type $b/device/manfid $b/device/rev $b/device/fwrev $b/device/life_time $b/device/pre_eol_info $b/queue/scheduler $b/queue/rotational $b/queue/discard_max_bytes; done'

# --- Cameras / TPM / Secure Boot / boot ------------------------------------
sh  "Video devices" 'ls -la /dev/video* /dev/media* 2>&1; command -v v4l2-ctl >/dev/null && v4l2-ctl --list-devices 2>&1'
sh  "TPM" 'ls /sys/class/tpm/ 2>&1; dumpfiles /sys/class/tpm/tpm0/tpm_version_major /sys/class/tpm/tpm0/device/description'
sh  "Secure Boot / firmware" 'command -v mokutil >/dev/null && mokutil --sb-state; bootctl status 2>/dev/null | head -25; ls /sys/firmware/efi >/dev/null 2>&1 && echo "UEFI boot: yes"; dumpfiles /sys/firmware/efi/fw_platform_size'

# --- Kernel log ----------------------------------------------------------------
dmesg 2>&1 | scrub >"$OUT/dmesg.txt"
sh  "dmesg: errors / firmware / key drivers" 'dmesg | grep -iE "error|fail|firmware|sof|snd|i2c_hid|hid-multitouch|iwlwifi|bluetooth|btusb|i915|ish|tpm|acpi.*bug|thermal|rapl" | head -400'

# --- ACPI tables (large, saved as files) --------------------------------------
if command -v acpidump >/dev/null 2>&1; then
    acpidump >"$OUT/acpidump.dat" 2>/dev/null
    if command -v acpixtract >/dev/null 2>&1 && command -v iasl >/dev/null 2>&1; then
        (cd "$OUT" && mkdir -p acpi && cd acpi && acpixtract -a ../acpidump.dat >/dev/null 2>&1 && iasl -d dsdt.dat >/dev/null 2>&1)
    fi
else
    echo "acpidump not installed, ACPI tables skipped" >>"$REPORT"
fi

# --- Interactive part: what changes on detach / rotate / lid -------------------
if [ "$INTERACTIVE" -eq 1 ]; then
    snap() { { echo "### $1"; lsusb; echo; grep -E "^N: Name" /proc/bus/input/devices; } >"$OUT/state-$2.txt"; }

    echo
    echo ">>> Interactive part. Keep the keyboard ATTACHED for now, then press Enter."
    read -r _
    snap "keyboard attached" attached

    echo ">>> DETACH the keyboard now. Watching events for 15 s ..."
    { timeout 15 udevadm monitor --udev --subsystem-match=input --subsystem-match=usb &
      command -v libinput >/dev/null && timeout 15 libinput debug-events --show-keycodes 2>&1 | grep -iE "SWITCH|tablet|lid" ; wait; } >"$OUT/events-detach.txt" 2>&1
    snap "keyboard detached" detached
    diff "$OUT/state-attached.txt" "$OUT/state-detached.txt" >"$OUT/diff-detach.txt"

    echo ">>> Re-attach the keyboard and press Enter."
    read -r _

    if command -v monitor-sensor >/dev/null 2>&1; then
        echo ">>> Rotate the tablet: portrait, landscape, upside down, back. Recording 20 s ..."
        timeout 20 monitor-sensor >"$OUT/monitor-sensor.txt" 2>&1
    else
        echo "monitor-sensor not available (iio-sensor-proxy missing)" >"$OUT/monitor-sensor.txt"
    fi

    echo ">>> FOLD the keyboard cover closed for ~3 s, then open it again. Recording 15 s ..."
    command -v libinput >/dev/null && timeout 15 libinput debug-events 2>&1 | grep -iE "SWITCH|lid|tablet" >"$OUT/events-lid.txt"
    echo ">>> Done with interactive tests."
fi

# --- Package it up ------------------------------------------------------------
tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo
echo "Done: $OUT.tar.gz"
echo "Copy it next to discover.sh in the duet3-linux folder (or attach it) and send it back."
