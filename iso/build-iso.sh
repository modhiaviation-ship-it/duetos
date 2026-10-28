#!/usr/bin/env bash
# build-iso.sh: builds the DuetOS live/installer ISO with archiso.
#
# Run as root inside an Arch Linux environment (WSL "archlinux", a VM, or real Arch):
#     bash /path/to/duet3-linux/iso/build-iso.sh
#
# Starts from the official archiso "releng" profile (so boot plumbing always matches the
# installed archiso version), then overlays our files, packages and services.
# Idempotent: every run starts from a clean work directory.
# Output: duet3-linux/out/duetos-YYYY.MM.DD-x86_64.iso

set -euo pipefail

HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
OUTDIR="$HERE/../out"
BUILD=/var/tmp/duetos-build
PROFILE="$BUILD/profile"
LOCALREPO="$BUILD/localrepo"
# Packages we allow to be built from the AUR if they are not in the official repos.
AUR_ALLOWED=(lisgd wvkbd wlopm nwg-drawer)
# Kernel parameters added to every live boot entry (one-line reasons in README.md).
KPARAMS="quiet loglevel=3 rd.udev.log_level=3 nowatchdog zswap.enabled=0 copytoram=n"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

echo "==> Installing build tools"
pacman -Syu --needed --noconfirm archiso git base-devel sudo

echo "==> Fresh work tree in $BUILD"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$LOCALREPO" "$OUTDIR"
cp -r /usr/share/archiso/configs/releng "$PROFILE"

echo "==> Overlaying DuetOS airootfs"
cp -rT "$HERE/airootfs" "$PROFILE/airootfs"
# Dotfiles are stored as dot-NAME (GitHub's web upload skips names starting with '.').
find "$PROFILE/airootfs" -depth -name 'dot-*' | while read -r p; do
    mv "$p" "$(dirname "$p")/.${p##*/dot-}"
done
# Files edited on Windows may carry CRLF line endings; strip them from text files.
{ grep -rIl $'\r' "$PROFILE/airootfs" || true; } | xargs -r sed -i 's/\r$//'
# Normalise permissions (files copied from /mnt/c come in as 0777).
find "$PROFILE/airootfs" -type d -exec chmod 755 {} +
find "$PROFILE/airootfs" -type f -exec chmod 644 {} +
chmod 755 "$PROFILE"/airootfs/usr/local/bin/*
# Ship the discovery script as a command too.
install -m 755 "$HERE/../discover.sh" "$PROFILE/airootfs/usr/local/bin/duet-discover"
# A plain Arch pacman.conf for the image: releng's, copied before we add our temporary
# local repo. (The build host's own may be a Docker one that strips docs and locales.)
install -m 644 "$PROFILE/pacman.conf" "$PROFILE/airootfs/etc/pacman.conf"

echo "==> Removing releng pieces we replace"
# Releng blocks suspend in the live system; we want to test suspend.
rm -f "$PROFILE/airootfs/etc/systemd/logind.conf.d/do-not-suspend.conf"
# Releng's networking (iwd + systemd-networkd) and reflector are replaced by NetworkManager.
W="$PROFILE/airootfs/etc/systemd/system"
rm -f "$W"/multi-user.target.wants/{iwd.service,systemd-networkd.service,ModemManager.service,reflector.service,sshd.service,livecd-talk.service,livecd-alsa-unmuter.service} \
      "$W"/network-online.target.wants/systemd-networkd-wait-online.service \
      "$W"/sockets.target.wants/systemd-networkd*.socket \
      "$W"/systemd-networkd-wait-online.service.wants/* \
      "$W"/dbus-org.freedesktop.network1.service
rm -rf "$PROFILE/airootfs/etc/systemd/network"

echo "==> Enabling DuetOS services"
mkdir -p "$W"/multi-user.target.wants "$W"/timers.target.wants
ln -sf /usr/lib/systemd/system/NetworkManager.service            "$W/multi-user.target.wants/NetworkManager.service"
ln -sf /usr/lib/systemd/system/NetworkManager-dispatcher.service "$W/dbus-org.freedesktop.nm-dispatcher.service"
ln -sf /usr/lib/systemd/system/bluetooth.service                 "$W/multi-user.target.wants/bluetooth.service"
ln -sf /usr/lib/systemd/system/bluetooth.service                 "$W/dbus-org.bluez.service"
ln -sf /etc/systemd/system/duet-live-setup.service               "$W/multi-user.target.wants/duet-live-setup.service"
ln -sf /etc/systemd/system/duet-power-auto.timer                 "$W/timers.target.wants/duet-power-auto.timer"

echo "==> Package list"
cat "$HERE/packages.duet" | sed 's/#.*//' | awk 'NF' >"$BUILD/wanted.txt"
missing=()
while read -r p; do
    pacman -Si "$p" >/dev/null 2>&1 || missing+=("$p")
done <"$BUILD/wanted.txt"

aur_built=()
if [ ${#missing[@]} -gt 0 ]; then
    echo "==> Not in official repos: ${missing[*]}"
    id builder >/dev/null 2>&1 || useradd -m builder
    echo "builder ALL=(root) NOPASSWD: /usr/bin/pacman" >/etc/sudoers.d/99-duetos-builder
    for p in "${missing[@]}"; do
        if [[ " ${AUR_ALLOWED[*]} " == *" $p "* ]]; then
            echo "==> Building $p from the AUR"
            rm -rf "/home/builder/$p"
            if sudo -u builder git clone --depth 1 "https://aur.archlinux.org/$p.git" "/home/builder/$p" &&
               (echo "---- PKGBUILD for $p ----"; cat "/home/builder/$p/PKGBUILD") &&
               (cd "/home/builder/$p" && sudo -u builder makepkg -s --noconfirm --needed); then
                cp /home/builder/"$p"/*.pkg.tar.zst "$LOCALREPO/"
                aur_built+=("$p")
            else
                echo "!! AUR build of $p failed; dropping it (the desktop has fallbacks)."
                sed -i "/^$p\$/d" "$BUILD/wanted.txt"
            fi
        else
            echo "!! $p not found anywhere; dropping it."
            sed -i "/^$p\$/d" "$BUILD/wanted.txt"
        fi
    done
    rm -f /etc/sudoers.d/99-duetos-builder
fi

if [ ${#aur_built[@]} -gt 0 ]; then
    repo-add "$LOCALREPO/duetlocal.db.tar.gz" "$LOCALREPO"/*.pkg.tar.zst
    cat >>"$PROFILE/pacman.conf" <<EOF

[duetlocal]
SigLevel = Optional TrustAll
Server = file://$LOCALREPO
EOF
fi

cat "$BUILD/wanted.txt" >>"$PROFILE/packages.x86_64"
sort -u -o "$PROFILE/packages.x86_64" "$PROFILE/packages.x86_64"

echo "==> Profile metadata, permissions, boot parameters"
sed -i -e 's/^iso_name=.*/iso_name="duetos"/' \
       -e 's/^iso_label=.*/iso_label="DUETOS_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"/' \
       -e 's/^iso_publisher=.*/iso_publisher="DuetOS (Arch Linux based)"/' \
       -e 's/^iso_application=.*/iso_application="DuetOS live and installer for Lenovo IdeaPad Duet 3"/' \
       "$PROFILE/profiledef.sh"
{
    echo 'file_permissions+=(["/etc/sudoers.d/10-duet-live"]="0:0:440")'
    echo 'file_permissions+=(["/etc/sudoers.d/20-duet-power"]="0:0:440")'
    for f in "$PROFILE"/airootfs/usr/local/bin/*; do
        echo "file_permissions+=([\"/usr/local/bin/$(basename "$f")\"]=\"0:0:755\")"
    done
} >>"$PROFILE/profiledef.sh"

# Append our kernel parameters to every boot entry that boots the live system.
{ grep -rl 'archisobasedir' "$PROFILE"/efiboot "$PROFILE"/syslinux "$PROFILE"/grub 2>/dev/null || true; } |
    while read -r f; do
        sed -i "/archisobasedir/ s/\$/ $KPARAMS/" "$f"
    done
# Shorter boot menu timeout.
sed -i 's/^timeout .*/timeout 3/' "$PROFILE"/efiboot/loader/loader.conf 2>/dev/null || true

echo "==> Sanity checks against the installed tool versions"
pacman -Sp --print-format '%n %v' labwc wvkbd 2>/dev/null || true
if [ -f /usr/share/doc/labwc/rc.xml.all ]; then
    grep -q calibrationMatrix /usr/share/doc/labwc/rc.xml.all ||
        echo "NOTE: this labwc may not support <calibrationMatrix>; see README (touch after rotation)."
fi

echo "==> Building ISO (this takes 15-40 minutes)"
mkarchiso -v -w "$BUILD/work" -o "$BUILD/out" "$PROFILE"

ISO=$(ls -t "$BUILD"/out/*.iso | head -1)
cp "$ISO" "$OUTDIR/"
(cd "$OUTDIR" && sha256sum "$(basename "$ISO")" >"$(basename "$ISO").sha256")
echo
echo "Done: $OUTDIR/$(basename "$ISO")"
du -h "$OUTDIR/$(basename "$ISO")"
