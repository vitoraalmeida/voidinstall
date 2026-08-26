#!/usr/bin/env bash
set -Eeuo pipefail

# Void Linux secure base installer for Lenovo ThinkPad P1 Gen 2.
#
# DESIGN
# ──────
# GPT
# ├── EFI System Partition (FAT32, unencrypted)
# │   ├── signed standalone GRUB EFI
# │   └── PUBLIC Secure Boot enrollment material
# └── LUKS1
#     └── Btrfs
#         ├── @      -> /
#         │            /boot lives HERE, encrypted
#         ├── @home  -> /home
#         └── @var   -> /var
#
# Security properties:
#   * Only the ESP is plaintext.
#   * /boot, kernel, initramfs and grub.cfg live inside LUKS1.
#   * GRUB EFI is a standalone image containing the modules/config required
#     to unlock LUKS and is signed with a locally generated Secure Boot db key.
#   * PK, KEK and db key pairs are generated; private keys stay inside LUKS.
#   * Public enrollment files are copied to the ESP for UEFI Custom Mode.
#   * A random LUKS key is embedded in the encrypted initramfs so the passphrase
#     is entered once at GRUB, not a second time in the initramfs.
#
# IMPORTANT:
#   Secure Boot key enrollment, UEFI Supervisor Password, and disabling external
#   boot must be completed manually in ThinkPad Setup after installation.
#
# WARNING: THIS SCRIPT DESTROYS ALL DATA ON DISK.
#
# Run from the official Void x86_64 glibc live ISO, booted in UEFI mode:
#
#   DISK=/dev/nvme0n1 \
#   USERNAME=vitor \
#   HOSTNAME=p1 \
#   ./install-void-secure-btrfs.sh
#
# Optional:
#   TIMEZONE=America/Bahia
#
# The live environment must already have Internet access.

DISK="${DISK:-/dev/nvme0n1}"
USERNAME="${USERNAME:-user}"neovim void linuxneovim void linux
HOSTNAME="${HOSTNAME:-host}"
TIMEZONE="${TIMEZONE:-America/Bahia}"
REPO="${REPO:-https://repo-fastly.voidlinux.org/current}"
MNT="${MNT:-/mnt}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '\n==> %s\n' "$*"
}

cleanup() {
    set +e
    sync
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ -b "$DISK" ]] || die "Disk does not exist: $DISK"
[[ -d /sys/firmware/efi ]] || die "Boot the live ISO in UEFI mode."
[[ "$(uname -m)" == "x86_64" ]] || die "This script targets x86_64."
command -v xbps-install >/dev/null || die "xbps-install unavailable."
command -v cryptsetup >/dev/null || die "cryptsetup unavailable."
command -v parted >/dev/null || die "parted unavailable."

case "$USERNAME" in
    ''|*[!a-z0-9_-]*|[0-9]*) die "Invalid USERNAME: $USERNAME" ;;
esac

case "$HOSTNAME" in
    ''|*[!a-zA-Z0-9.-]*) die "Invalid HOSTNAME: $HOSTNAME" ;;
esac

if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
    ESP="${DISK}p1"
    CRYPT="${DISK}p2"
else
    ESP="${DISK}1"
    CRYPT="${DISK}2"
fi

# Refresh live repository metadata before touching the disk.
log "Refreshing repository metadata"
xbps-install -S

printf '\n'
printf 'SECURE VOID INSTALLATION\n'
printf '========================\n'
printf 'THIS WILL ERASE: %s\n\n' "$DISK"
printf 'Layout:\n'
printf '  EFI    1 GiB      FAT32, plaintext, signed bootloader only\n'
printf '  LUKS1  remaining  Btrfs\n'
printf '                    @      -> / (includes encrypted /boot)\n'
printf '                    @home  -> /home\n'
printf '                    @var   -> /var\n\n'
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DISK" || true
printf '\nType exactly: ERASE %s\n> ' "$DISK"
read -r confirmation
[[ "$confirmation" == "ERASE $DISK" ]] || die "Confirmation did not match. Nothing changed."

log "Unmounting old target state"
swapoff -a 2>/dev/null || true
umount -R "$MNT" 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

log "Creating GPT: ESP + encrypted system"
wipefs -af "$DISK"
parted -s "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 1025MiB \
    set 1 esp on \
    mkpart cryptroot 1025MiB 100%

partprobe "$DISK"
udevadm settle

[[ -b "$ESP" && -b "$CRYPT" ]] || die "Partitions were not created correctly."

log "Formatting EFI System Partition"
mkfs.vfat -F32 -n EFI "$ESP"

log "Creating LUKS1 container"
printf '\nChoose a strong disk-encryption passphrase.\n'
cryptsetup luksFormat --type luks1 "$CRYPT"
cryptsetup open "$CRYPT" cryptroot

log "Creating Btrfs filesystem and subvolumes"
mkfs.btrfs -f -L voidroot /dev/mapper/cryptroot
mount /dev/mapper/cryptroot "$MNT"
btrfs subvolume create "$MNT/@"
btrfs subvolume create "$MNT/@home"
btrfs subvolume create "$MNT/@var"
umount "$MNT"

BTRFS_OPTS="noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

mount -o "${BTRFS_OPTS},subvol=@" /dev/mapper/cryptroot "$MNT"
mkdir -p "$MNT"/{home,var,boot/efi}
mount -o "${BTRFS_OPTS},subvol=@home" /dev/mapper/cryptroot "$MNT/home"
mount -o "${BTRFS_OPTS},subvol=@var" /dev/mapper/cryptroot "$MNT/var"
mount "$ESP" "$MNT/boot/efi"

log "Bootstrapping Void Linux"
mkdir -p "$MNT/var/db/xbps/keys"
cp /var/db/xbps/keys/* "$MNT/var/db/xbps/keys/"

# efitools creates PK/KEK/db enrollment objects.
# sbsigntool signs the standalone GRUB EFI image.
XBPS_ARCH=x86_64 xbps-install -Sy -r "$MNT" -R "$REPO" \
    base-system \
    cryptsetup \
    grub-x86_64-efi \
    efibootmgr \
    efitools \
    sbsigntool \
    openssl \
    NetworkManager \
    dbus \
    vim \
    git \
    snapper \
    xtools \
    xkeyboard-config

log "Binding pseudo-filesystems for chroot"
for fs in dev proc sys; do
    mount --rbind "/$fs" "$MNT/$fs"
    mount --make-rslave "$MNT/$fs"
done
mount --bind /run "$MNT/run"
mount --make-rslave "$MNT/run"

BTRFS_UUID="$(blkid -s UUID -o value /dev/mapper/cryptroot)"
ESP_UUID="$(blkid -s UUID -o value "$ESP")"
LUKS_UUID="$(cryptsetup luksUUID "$CRYPT")"

log "Writing fstab and crypttab"
cat > "$MNT/etc/fstab" <<EOF
# <file system>  <mount point>  <type>  <options>  <dump> <pass>
UUID=$BTRFS_UUID  /          btrfs  ${BTRFS_OPTS},subvol=@      0 0
UUID=$BTRFS_UUID  /home      btrfs  ${BTRFS_OPTS},subvol=@home  0 0
UUID=$BTRFS_UUID  /var       btrfs  ${BTRFS_OPTS},subvol=@var   0 0
UUID=$ESP_UUID    /boot/efi  vfat   umask=0077                  0 2
EOF

log "Creating encrypted initramfs LUKS key"
# The key is stored under /boot, which itself is inside LUKS.
# It is also embedded in initramfs. Therefore an offline attacker cannot read it.
install -d -m 0700 "$MNT/boot"
dd if=/dev/urandom of="$MNT/boot/volume.key" bs=64 count=1 status=none
chmod 000 "$MNT/boot/volume.key"
cryptsetup luksAddKey "$CRYPT" "$MNT/boot/volume.key"

cat > "$MNT/etc/crypttab" <<EOF
cryptroot UUID=$LUKS_UUID /boot/volume.key luks
EOF

log "Configuring hostname, locale and timezone"
printf '%s\n' "$HOSTNAME" > "$MNT/etc/hostname"

cat > "$MNT/etc/locale.conf" <<'EOF'
LANG=pt_BR.UTF-8
LC_COLLATE=C
EOF

grep -q '^pt_BR.UTF-8 UTF-8' "$MNT/etc/default/libc-locales" 2>/dev/null ||
    printf '\npt_BR.UTF-8 UTF-8\n' >> "$MNT/etc/default/libc-locales"

ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
chroot "$MNT" xbps-reconfigure -f glibc-locales

log "Configuring Brazilian ThinkPad keyboard"
if grep -q '^KEYMAP=' "$MNT/etc/rc.conf"; then
    sed -i 's/^KEYMAP=.*/KEYMAP=br-abnt2/' "$MNT/etc/rc.conf"
else
    printf '\nKEYMAP=br-abnt2\n' >> "$MNT/etc/rc.conf"
fi

# Lenovo Brazilian ThinkPads expose the physical /? key as Linux keycode 97
# (Right Ctrl). This makes it slash and Shift+slash question mark in the TTY.
cat > "$MNT/etc/thinkpad-br.map" <<'EOF'
keycode 97 = slash question
EOF

touch "$MNT/etc/rc.local"
if ! grep -q 'thinkpad-br.map' "$MNT/etc/rc.local"; then
    cat >> "$MNT/etc/rc.local" <<'EOF'

# Brazilian ThinkPad physical /? key.
if [ -r /etc/thinkpad-br.map ]; then
    loadkeys /etc/thinkpad-br.map
fi
EOF
fi
chmod +x "$MNT/etc/rc.local"

# Future Wayland/XKB sessions (including Niri) can inherit this.
mkdir -p "$MNT/etc/profile.d"
cat > "$MNT/etc/profile.d/thinkpad-xkb.sh" <<'EOF'
export XKB_DEFAULT_LAYOUT=br
export XKB_DEFAULT_VARIANT=thinkpad
EOF
chmod 644 "$MNT/etc/profile.d/thinkpad-xkb.sh"

log "Configuring wired and Wi-Fi networking"
rm -f "$MNT/var/service/dhcpcd" "$MNT/var/service/wpa_supplicant"
mkdir -p "$MNT/var/service"
ln -sfn /etc/sv/dbus "$MNT/var/service/dbus"
ln -sfn /etc/sv/NetworkManager "$MNT/var/service/NetworkManager"

log "Creating administrative user: $USERNAME"
if ! chroot "$MNT" id "$USERNAME" >/dev/null 2>&1; then
    chroot "$MNT" useradd -m -s /bin/bash -G wheel,network,audio,video,input "$USERNAME"
fi

mkdir -p "$MNT/etc/sudoers.d"
cat > "$MNT/etc/sudoers.d/10-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 "$MNT/etc/sudoers.d/10-wheel"

printf '\nSet the ROOT password:\n'
chroot "$MNT" passwd root

printf '\nSet the password for %s:\n' "$USERNAME"
chroot "$MNT" passwd "$USERNAME"

log "Configuring dracut for encrypted root"
mkdir -p "$MNT/etc/dracut.conf.d"
cat > "$MNT/etc/dracut.conf.d/10-cryptroot.conf" <<'EOF'
add_dracutmodules+=" crypt btrfs "
install_items+=" /boot/volume.key /etc/crypttab "
hostonly="yes"
EOF

log "Configuring GRUB files inside encrypted /boot"
cat >> "$MNT/etc/default/grub" <<EOF

# Entire /boot is inside LUKS1.
GRUB_ENABLE_CRYPTODISK=y
EOF

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$MNT/etc/default/grub"; then
    sed -i \
        "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 rd.luks.uuid=luks-$LUKS_UUID root=UUID=$BTRFS_UUID rootflags=subvol=@ rw\"|" \
        "$MNT/etc/default/grub"
else
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rd.luks.uuid=luks-%s root=UUID=%s rootflags=subvol=@ rw"\n' \
        "$LUKS_UUID" "$BTRFS_UUID" >> "$MNT/etc/default/grub"
fi

chroot "$MNT" dracut --regenerate-all --force
mkdir -p "$MNT/boot/grub"
chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg

log "Generating local Secure Boot PK, KEK and db keys"
KEYDIR="$MNT/root/secureboot-keys"
PUBDIR="$MNT/boot/efi/EFI/keys"
mkdir -p "$KEYDIR" "$PUBDIR"
chmod 700 "$KEYDIR"

generate_key() {
    local name="$1"
    local cn="$2"

    openssl req \
        -new -x509 -newkey rsa:4096 \
        -subj "/CN=$cn/" \
        -keyout "$KEYDIR/$name.key" \
        -out "$KEYDIR/$name.crt" \
        -days 3650 \
        -nodes \
        -sha256

    openssl x509 \
        -outform DER \
        -in "$KEYDIR/$name.crt" \
        -out "$PUBDIR/$name.cer"

    chmod 600 "$KEYDIR/$name.key"
    chmod 644 "$KEYDIR/$name.crt" "$PUBDIR/$name.cer"
}

generate_key PK  "$HOSTNAME Secure Boot Platform Key"
generate_key KEK "$HOSTNAME Secure Boot KEK"
generate_key db  "$HOSTNAME Secure Boot db"

# Produce EFI Signature Lists and authenticated update files.
UUIDGEN="$(cat /proc/sys/kernel/random/uuid)"
cert-to-efi-sig-list -g "$UUIDGEN" "$KEYDIR/PK.crt"  "$PUBDIR/PK.esl"
cert-to-efi-sig-list -g "$UUIDGEN" "$KEYDIR/KEK.crt" "$PUBDIR/KEK.esl"
cert-to-efi-sig-list -g "$UUIDGEN" "$KEYDIR/db.crt"  "$PUBDIR/db.esl"

sign-efi-sig-list \
    -k "$KEYDIR/PK.key" -c "$KEYDIR/PK.crt" \
    PK "$PUBDIR/PK.esl" "$PUBDIR/PK.auth"

sign-efi-sig-list \
    -k "$KEYDIR/PK.key" -c "$KEYDIR/PK.crt" \
    KEK "$PUBDIR/KEK.esl" "$PUBDIR/KEK.auth"

sign-efi-sig-list \
    -k "$KEYDIR/KEK.key" -c "$KEYDIR/KEK.crt" \
    db "$PUBDIR/db.esl" "$PUBDIR/db.auth"

cat > "$PUBDIR/README.txt" <<'EOF'
These are PUBLIC Secure Boot enrollment files.

Private signing keys are NOT stored on the EFI System Partition.
They are under /root/secureboot-keys, which is inside LUKS.

ThinkPad Setup:
  Security -> Secure Boot
  1. Set a Supervisor Password first.
  2. Enter Custom/Setup Mode ("Reset to Setup Mode" / clear current keys).
  3. Enroll your own PK, KEK and db using the files in this directory.
  4. Enable Secure Boot.
  5. Disable external/USB boot unless you intentionally need it.

Keep an offline backup of the private keys before relying on this setup.
EOF

log "Building a standalone GRUB EFI that can unlock LUKS without external modules"
mkdir -p "$MNT/root/grub-build"

# This configuration is embedded in grubx64.efi.
# Because the disk contains a single LUKS volume, cryptomount -a is intentional.
cat > "$MNT/root/grub-build/early.cfg" <<EOF
set pager=1
insmod part_gpt
insmod cryptodisk
insmod luks
insmod gcry_rijndael
insmod gcry_sha256
insmod btrfs
cryptomount -a
search --fs-uuid --set=root $BTRFS_UUID
set prefix=(\$root)/@/boot/grub
configfile (\$root)/@/boot/grub/grub.cfg
EOF

mkdir -p "$MNT/boot/efi/EFI/Void" "$MNT/boot/efi/EFI/BOOT"

chroot "$MNT" grub-mkstandalone \
    -O x86_64-efi \
    -o /root/grub-build/grubx64-unsigned.efi \
    --modules="part_gpt cryptodisk luks gcry_rijndael gcry_sha256 btrfs normal configfile search search_fs_uuid linux all_video gfxterm echo reboot halt" \
    "boot/grub/grub.cfg=/root/grub-build/early.cfg"

sbsign \
    --key "$KEYDIR/db.key" \
    --cert "$KEYDIR/db.crt" \
    --output "$MNT/boot/efi/EFI/Void/grubx64.efi" \
    "$MNT/root/grub-build/grubx64-unsigned.efi"

cp "$MNT/boot/efi/EFI/Void/grubx64.efi" \
   "$MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"

sbverify --cert "$KEYDIR/db.crt" "$MNT/boot/efi/EFI/Void/grubx64.efi" >/dev/null

log "Creating UEFI boot entry"
if ! chroot "$MNT" efibootmgr \
    --create \
    --disk "$DISK" \
    --part 1 \
    --label "Void Linux" \
    --loader '\EFI\Void\grubx64.efi'; then
    printf 'WARNING: efibootmgr could not create an NVRAM entry.\n'
    printf 'The signed fallback loader exists at EFI/BOOT/BOOTX64.EFI.\n'
fi

log "Installing Secure Boot GRUB refresh helper"
cat > "$MNT/usr/local/sbin/secureboot-refresh-grub" <<'EOF'
#!/bin/sh
set -eu

KEYDIR=/root/secureboot-keys
ESP=/boot/efi
BUILD=/root/grub-build

[ -r "$KEYDIR/db.key" ] || {
    echo "Missing $KEYDIR/db.key" >&2
    exit 1
}

BTRFS_UUID="$(findmnt -no UUID /)"
mkdir -p "$BUILD" "$ESP/EFI/Void" "$ESP/EFI/BOOT"

grub-mkconfig -o /boot/grub/grub.cfg

cat > "$BUILD/early.cfg" <<EOC
set pager=1
insmod part_gpt
insmod cryptodisk
insmod luks
insmod gcry_rijndael
insmod gcry_sha256
insmod btrfs
cryptomount -a
search --fs-uuid --set=root $BTRFS_UUID
set prefix=(\$root)/@/boot/grub
configfile (\$root)/@/boot/grub/grub.cfg
EOC

grub-mkstandalone \
    -O x86_64-efi \
    -o "$BUILD/grubx64-unsigned.efi" \
    --modules="part_gpt cryptodisk luks gcry_rijndael gcry_sha256 btrfs normal configfile search search_fs_uuid linux all_video gfxterm echo reboot halt" \
    "boot/grub/grub.cfg=$BUILD/early.cfg"

sbsign \
    --key "$KEYDIR/db.key" \
    --cert "$KEYDIR/db.crt" \
    --output "$ESP/EFI/Void/grubx64.efi" \
    "$BUILD/grubx64-unsigned.efi"

cp "$ESP/EFI/Void/grubx64.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"
sbverify --cert "$KEYDIR/db.crt" "$ESP/EFI/Void/grubx64.efi"
echo "Signed GRUB EFI refreshed."
EOF
chmod 700 "$MNT/usr/local/sbin/secureboot-refresh-grub"

log "Configuring Snapper"
# Root snapshots include encrypted /boot because /boot is part of @.
# /home and /var are separate subvolumes and are intentionally excluded.
if [[ ! -f "$MNT/etc/snapper/configs/root" ]]; then
    chroot "$MNT" snapper -c root create-config /
fi

SNAPPER_CFG="$MNT/etc/snapper/configs/root"
sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/' "$SNAPPER_CFG" || true
sed -i 's/^NUMBER_CLEANUP=.*/NUMBER_CLEANUP="yes"/' "$SNAPPER_CFG" || true
sed -i 's/^NUMBER_MIN_AGE=.*/NUMBER_MIN_AGE="1800"/' "$SNAPPER_CFG" || true
sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="20"/' "$SNAPPER_CFG" || true
sed -i 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="10"/' "$SNAPPER_CFG" || true

cat > "$MNT/usr/local/sbin/xbps-snapshot-update" <<'EOF'
#!/bin/sh
set -eu

snapper -c root create \
    --description "XBPS pre-update" \
    --cleanup-algorithm number

xbps-install -Su

# Kernel/initramfs/grub.cfg are inside the encrypted root.
# Refresh the signed standalone EFI image as well in case GRUB changed.
/usr/local/sbin/secureboot-refresh-grub

snapper -c root create \
    --description "XBPS post-update" \
    --cleanup-algorithm number
EOF
chmod 700 "$MNT/usr/local/sbin/xbps-snapshot-update"

chroot "$MNT" snapper -c root create \
    --description "Fresh secure Void base installation" \
    --cleanup-algorithm number

log "Final package configuration"
chroot "$MNT" xbps-reconfigure -fa

# xbps-reconfigure may regenerate kernel/initramfs; refresh grub.cfg and signed EFI.
chroot "$MNT" /usr/local/sbin/secureboot-refresh-grub

printf '\n'
printf '====================================================================\n'
printf 'Secure Void installation complete\n'
printf '====================================================================\n\n'
printf 'Disk:       %s\n' "$DISK"
printf 'Hostname:   %s\n' "$HOSTNAME"
printf 'User:       %s\n' "$USERNAME"
printf 'Encryption: LUKS1\n'
printf 'Filesystem: Btrfs (@, @home, @var)\n'
printf '/boot:      INSIDE LUKS1\n'
printf 'ESP:        only signed bootloader + public enrollment files\n'
printf 'Network:    NetworkManager (Ethernet + Wi-Fi)\n'
printf 'Keyboard:   PT-BR ThinkPad /? mapping\n\n'

printf 'DO NOT ENABLE SECURE BOOT YET.\n\n'
printf 'First boot once with Secure Boot disabled and verify the system works.\n'
printf 'Then back up /root/secureboot-keys to encrypted offline media.\n\n'

printf 'ThinkPad UEFI hardening steps (manual):\n'
printf '  1. F1 -> Security -> Password -> set Supervisor Password.\n'
printf '  2. Security -> Secure Boot -> Reset to Setup Mode / clear existing keys.\n'
printf '  3. Enroll YOUR PK, KEK and db from EFI/keys on the ESP.\n'
printf '  4. Enable Secure Boot in Custom Mode.\n'
printf '  5. Disable USB/external boot when not needed.\n'
printf '  6. Keep the Supervisor Password and Secure Boot private keys safe.\n\n'

printf 'Useful commands after boot:\n'
printf '  nmcli device\n'
printf '  nmtui\n'
printf '  sudo snapper list\n'
printf '  sudo snapper create --description "before change"\n'
printf '  sudo xbps-snapshot-update\n'
printf '  sudo secureboot-refresh-grub\n\n'

printf 'Before rebooting:\n'
printf '  umount -R %s\n' "$MNT"
printf '  cryptsetup close cryptroot\n'
printf '  reboot\n'
