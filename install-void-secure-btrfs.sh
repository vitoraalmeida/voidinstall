#!/usr/bin/env bash
set -Eeuo pipefail

# Secure Void Linux base installer
# Target: Lenovo ThinkPad P15 Gen 1 / x86_64 glibc / UEFI
#
# REQUIREMENTS IMPLEMENTED
# ------------------------
# - Void Linux x86_64 glibc, no desktop
# - UEFI
# - Custom Secure Boot with locally generated PK/KEK/db keys
# - Kernels signed with the db key via Void's sbsigntool kernel hook (no-op
#   while Secure Boot is disabled; required for GRUB 2.12 UEFI LoadImage
#   verification)
# - Only the EFI System Partition is plaintext
# - LUKS1 for the whole Linux system
# - /boot inside LUKS1
# - Btrfs explicit subvolumes:
#       @               -> /
#       @home           -> /home
#       @var            -> /var
#       @snapshots      -> /.snapshots
#       @var_snapshots  -> /var/.snapshots
#       @swap           -> /swap
# - Snapper
# - Paired / + /var snapshots (XBPS state lives under /var/db/xbps)
# - Automatic hourly paired snapshots with retention
# - Encrypted Btrfs swapfile for hibernation
# - resume + resume_offset configured
# - NetworkManager for Ethernet and Wi-Fi
# - PT-BR ThinkPad keyboard, including / and ? physical key
# - vim, git, rsync
#
# SECURITY MODEL
# --------------
# GPT
# ├── ESP (FAT32, plaintext)
# │   ├── signed standalone GRUB EFI
# │   └── PUBLIC Secure Boot enrollment files
# └── LUKS1
#     └── Btrfs
#         ├── encrypted /boot, kernel, initramfs and grub.cfg
#         ├── separate root/home/var/snapshot subvolumes
#         └── encrypted hibernation swapfile
#
# The firmware verifies the signed standalone GRUB EFI image.
# GRUB contains the modules and early config needed to unlock LUKS1.
# Kernel, initramfs and grub.cfg stay inside encrypted /boot.
#
# IMPORTANT:
# - First boot with Secure Boot DISABLED.
# - After validating the installation, back up /root/secureboot-keys to
#   encrypted offline media.
# - Then enroll PK/KEK/db in ThinkPad UEFI Custom Secure Boot mode.
# - Set a UEFI Supervisor Password and disable external boot when not needed.
#
# WARNING: THIS SCRIPT ERASES THE ENTIRE TARGET DISK.
#
# Usage from official Void x86_64 glibc live ISO booted in UEFI mode:
#
#   DISK=/dev/nvme0n1 \
#   USERNAME=<your-user> \
#   HOSTNAME=<your-host> \
#   TIMEZONE=America/Bahia \
#   SWAP_GB=32 \
#   ./install-void-secure-btrfs.sh
#
# SWAP_GB defaults to installed RAM rounded up to the next GiB.
#
# Fully non-interactive run (DANGEROUS: erases the disk without asking).
# All four variables are required together:
#
#   ASSUME_ERASE=yes \
#   LUKS_PASSPHRASE='...' \
#   ROOT_PASSWORD='...' \
#   USER_PASSWORD='...' \
#   DISK=/dev/nvme0n1 \
#   ./install-void-secure-btrfs.sh
#
# In this mode the LUKS passphrase is staged in a root-only tmpfs file and
# shredded on exit; passwords are applied through chpasswd stdin and unset.
# Prefer invoking from a wrapper so the values stay out of shell history.

DISK="${DISK:-/dev/nvme0n1}"
USERNAME="${USERNAME:-}"
HOSTNAME="${HOSTNAME:-void}"
TIMEZONE="${TIMEZONE:-America/Bahia}"
REPO="${REPO:-https://repo-fastly.voidlinux.org/current}"
MNT="${MNT:-/mnt}"
SWAP_GB="${SWAP_GB:-}"
ASSUME_ERASE="${ASSUME_ERASE:-}"
LUKS_PASSPHRASE="${LUKS_PASSPHRASE:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
USER_PASSWORD="${USER_PASSWORD:-}"
LUKS_PASS_FILE="/run/pneuma-luks-pass"
NONINTERACTIVE=no

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"
}

cleanup() {
    if [[ -f "$LUKS_PASS_FILE" ]]; then
        shred -u "$LUKS_PASS_FILE" 2>/dev/null || rm -f "$LUKS_PASS_FILE"
    fi
    sync || true
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run this installer as root."
[[ "$(uname -m)" == "x86_64" ]] || die "This installer targets x86_64."
[[ -d /sys/firmware/efi ]] || die "Boot the live ISO in UEFI mode."
[[ -b "$DISK" ]] || die "Target disk does not exist: $DISK"

# xbps-install must already exist in the official Void live environment.
require_cmd xbps-install

install_live_dependencies() {
    declare -A command_packages=(
        [parted]="parted"
        [partprobe]="parted"

        [cryptsetup]="cryptsetup"

        [mkfs.vfat]="dosfstools"

        [mkfs.btrfs]="btrfs-progs"
        [btrfs]="btrfs-progs"

        [wipefs]="util-linux"
        [blkid]="util-linux"
        [mount]="util-linux"
        [umount]="util-linux"
        [lsblk]="util-linux"
        [swapoff]="util-linux"

        [udevadm]="eudev"

        [openssl]="openssl"

        [cert-to-efi-sig-list]="efitools"
        [sign-efi-sig-list]="efitools"

        [sbsign]="sbsigntool"
        [sbverify]="sbsigntool"
    )

    declare -A missing_packages=()

    for cmd in "${!command_packages[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_packages["${command_packages[$cmd]}"]=1
        fi
    done

    if ((${#missing_packages[@]} > 0)); then
        log "Refreshing live repository metadata"
        xbps-install -S

        log "Installing missing live-environment packages"
        xbps-install -y "${!missing_packages[@]}"
    fi
}

install_live_dependencies

# Verify everything required by the installer is now available.
for cmd in \
    xbps-install \
    cryptsetup \
    parted \
    wipefs \
    mkfs.vfat \
    mkfs.btrfs \
    btrfs \
    blkid \
    mount \
    umount \
    chroot \
    udevadm \
    partprobe \
    lsblk \
    swapoff \
    openssl \
    cert-to-efi-sig-list \
    sign-efi-sig-list \
    sbsign \
    sbverify
do
    require_cmd "$cmd"
done

[[ -n "$USERNAME" ]] ||
    die "USERNAME is required (e.g. USERNAME=myuser)."

case "$USERNAME" in
    ''|*[!a-z0-9_-]*|[0-9]*) die "Invalid USERNAME: $USERNAME" ;;
esac

case "$HOSTNAME" in
    ''|*[!a-zA-Z0-9.-]*) die "Invalid HOSTNAME: $HOSTNAME" ;;
esac

if [[ -z "$SWAP_GB" ]]; then
    MEM_KIB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    SWAP_GB="$(( (MEM_KIB + 1048575) / 1048576 ))"
fi

[[ "$SWAP_GB" =~ ^[0-9]+$ ]] || die "SWAP_GB must be an integer."
(( SWAP_GB >= 2 )) || die "SWAP_GB must be at least 2 GiB."

if [[ -n "$ASSUME_ERASE" ]]; then
    [[ "$ASSUME_ERASE" == "yes" ]] || die "ASSUME_ERASE must be 'yes' when set."
    [[ -n "$LUKS_PASSPHRASE" ]] || die "ASSUME_ERASE=yes requires LUKS_PASSPHRASE."
    [[ -n "$ROOT_PASSWORD" ]] || die "ASSUME_ERASE=yes requires ROOT_PASSWORD."
    [[ -n "$USER_PASSWORD" ]] || die "ASSUME_ERASE=yes requires USER_PASSWORD."
    NONINTERACTIVE=yes
else
    [[ -z "$LUKS_PASSPHRASE" && -z "$ROOT_PASSWORD" && -z "$USER_PASSWORD" ]] ||
        die "LUKS_PASSPHRASE/ROOT_PASSWORD/USER_PASSWORD require ASSUME_ERASE=yes."
fi

# Stage the LUKS passphrase in a root-only tmpfs file and drop the env copy
# immediately. No trailing newline: cryptsetup --key-file uses the whole file
# content as the key, and it must match later interactive typing.
if [[ "$NONINTERACTIVE" == "yes" ]]; then
    ( umask 077; printf '%s' "$LUKS_PASSPHRASE" > "$LUKS_PASS_FILE" )
    unset LUKS_PASSPHRASE
fi

if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
    ESP="${DISK}p1"
    CRYPT="${DISK}p2"
else
    ESP="${DISK}1"
    CRYPT="${DISK}2"
fi

printf '\n'
printf '============================================================\n'
printf ' SECURE VOID LINUX INSTALLER\n'
printf '============================================================\n\n'
printf 'Target disk: %s\n' "$DISK"
printf 'User:        %s\n' "$USERNAME"
printf 'Hostname:    %s\n' "$HOSTNAME"
printf 'Swap:        %s GiB\n' "$SWAP_GB"
printf 'Timezone:    %s\n\n' "$TIMEZONE"
printf 'Layout:\n'
printf '  ESP      1 GiB      FAT32, plaintext\n'
printf '  LUKS1    remaining  Btrfs\n'
printf '    @               -> /\n'
printf '    @home           -> /home\n'
printf '    @var            -> /var\n'
printf '    @snapshots      -> /.snapshots\n'
printf '    @var_snapshots  -> /var/.snapshots\n'
printf '    @swap           -> /swap\n\n'

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DISK" || true

printf '\nTHIS WILL ERASE ALL DATA ON %s.\n' "$DISK"
if [[ "$NONINTERACTIVE" == "yes" ]]; then
    printf 'ASSUME_ERASE=yes: skipping interactive confirmation.\n'
else
    printf 'Type exactly: ERASE %s\n> ' "$DISK"
    read -r confirmation ||
        die "Could not read confirmation. No destructive action was performed."
    [[ "$confirmation" == "ERASE $DISK" ]] ||
        die "Confirmation did not match. No destructive action was performed."
fi

log "Cleaning previous mounts/mappings"
swapoff -a 2>/dev/null || true
umount -R "$MNT" 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

log "Creating GPT: ESP + one encrypted system partition"
wipefs -af "$DISK"
parted -s "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 1025MiB \
    set 1 esp on \
    mkpart cryptroot 1025MiB 100%

partprobe "$DISK"
udevadm settle

[[ -b "$ESP" && -b "$CRYPT" ]] ||
    die "Expected partitions were not created."

log "Formatting EFI System Partition"
mkfs.vfat -F32 -n EFI "$ESP"

log "Creating LUKS1 container"
if [[ "$NONINTERACTIVE" == "yes" ]]; then
    cryptsetup luksFormat --type luks1 --batch-mode \
        --key-file "$LUKS_PASS_FILE" "$CRYPT"
    cryptsetup open --key-file "$LUKS_PASS_FILE" "$CRYPT" cryptroot
else
    printf '\nChoose a strong disk-encryption passphrase.\n'
    cryptsetup luksFormat --type luks1 "$CRYPT"
    cryptsetup open "$CRYPT" cryptroot
fi

log "Creating Btrfs filesystem"
mkfs.btrfs -f -L voidroot /dev/mapper/cryptroot

log "Creating explicit Btrfs subvolumes"
mount /dev/mapper/cryptroot "$MNT"

for subvol in \
    @ \
    @home \
    @var \
    @snapshots \
    @var_snapshots \
    @swap
do
    btrfs subvolume create "$MNT/$subvol"
done

umount "$MNT"

# Keep mount options conservative and portable.
BTRFS_OPTS="noatime,compress=zstd:3"

log "Mounting target filesystem"
mount -o "${BTRFS_OPTS},subvol=@" \
    /dev/mapper/cryptroot "$MNT"

mkdir -p \
    "$MNT/home" \
    "$MNT/var" \
    "$MNT/.snapshots" \
    "$MNT/swap" \
    "$MNT/boot/efi"

mount -o "${BTRFS_OPTS},subvol=@home" \
    /dev/mapper/cryptroot "$MNT/home"

mount -o "${BTRFS_OPTS},subvol=@var" \
    /dev/mapper/cryptroot "$MNT/var"

# @var hides the pre-existing /var directory, so create the nested mountpoint
# only after @var is mounted.
mkdir -p "$MNT/var/.snapshots"

mount -o "${BTRFS_OPTS},subvol=@snapshots" \
    /dev/mapper/cryptroot "$MNT/.snapshots"

mount -o "${BTRFS_OPTS},subvol=@var_snapshots" \
    /dev/mapper/cryptroot "$MNT/var/.snapshots"

# Swap is deliberately a separate subvolume and is not compressed/snapshotted.
mount -o "noatime,subvol=@swap" \
    /dev/mapper/cryptroot "$MNT/swap"

mount "$ESP" "$MNT/boot/efi"

log "Creating encrypted Btrfs swapfile for hibernation"
btrfs filesystem mkswapfile -s "${SWAP_GB}g" "$MNT/swap/swapfile"
chmod 600 "$MNT/swap/swapfile"

RESUME_OFFSET="$(
    btrfs inspect-internal map-swapfile -r "$MNT/swap/swapfile"
)"
[[ "$RESUME_OFFSET" =~ ^[0-9]+$ ]] ||
    die "Unable to calculate Btrfs resume_offset."

log "Bootstrapping Void Linux"
mkdir -p "$MNT/var/db/xbps/keys"
cp /var/db/xbps/keys/* "$MNT/var/db/xbps/keys/"

XBPS_ARCH=x86_64 xbps-install -Sy -y \
    -r "$MNT" \
    -R "$REPO" \
    base-system \
    cryptsetup \
    grub-x86_64-efi \
    efibootmgr \
    efitools \
    sbsigntool \
    openssl \
    NetworkManager \
    dbus \
    snapper \
    cronie \
    xkeyboard-config \
    linux-firmware \
    vim \
    git \
    rsync

log "Pinning repository mirror for the installed system"
# Same basename as Void's stock /usr/share/xbps.d/00-repository-main.conf so
# /etc/xbps.d overrides the default repository instead of adding a second one.
mkdir -p "$MNT/etc/xbps.d"
printf 'repository=%s\n' "$REPO" > "$MNT/etc/xbps.d/00-repository-main.conf"

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

[[ -n "$BTRFS_UUID" && -n "$ESP_UUID" && -n "$LUKS_UUID" ]] ||
    die "Unable to determine filesystem UUIDs."

log "Writing crypttab"
# The initramfs crypttab is what makes dracut feed /boot/volume.key (embedded
# in the initramfs via install_items) to cryptsetup, unlocking the root
# mapping without asking for the passphrase a second time.
cat > "$MNT/etc/crypttab" <<EOF
cryptroot UUID=$LUKS_UUID /boot/volume.key luks
EOF

log "Writing fstab"
cat > "$MNT/etc/fstab" <<EOF
# filesystem          mountpoint       type   options                              dump pass
UUID=$BTRFS_UUID      /                btrfs  ${BTRFS_OPTS},subvol=@               0 0
UUID=$BTRFS_UUID      /home            btrfs  ${BTRFS_OPTS},subvol=@home           0 0
UUID=$BTRFS_UUID      /var             btrfs  ${BTRFS_OPTS},subvol=@var            0 0
UUID=$BTRFS_UUID      /.snapshots      btrfs  ${BTRFS_OPTS},subvol=@snapshots      0 0
UUID=$BTRFS_UUID      /var/.snapshots  btrfs  ${BTRFS_OPTS},subvol=@var_snapshots  0 0
UUID=$BTRFS_UUID      /swap            btrfs  noatime,subvol=@swap                 0 0
UUID=$ESP_UUID        /boot/efi        vfat   umask=0077                           0 2
/swap/swapfile        none             swap   defaults                             0 0
EOF

log "Creating second LUKS key for one-passphrase boot"
# GRUB asks for the human passphrase. The initramfs, which is itself stored
# inside encrypted /boot, contains this random key and reopens the root mapping
# without asking for the passphrase a second time.
install -d -m 0700 "$MNT/boot"
dd if=/dev/urandom \
    of="$MNT/boot/volume.key" \
    bs=64 count=1 status=none
chmod 000 "$MNT/boot/volume.key"

if [[ "$NONINTERACTIVE" == "yes" ]]; then
    cryptsetup luksAddKey --key-file "$LUKS_PASS_FILE" \
        "$CRYPT" "$MNT/boot/volume.key"
else
    cryptsetup luksAddKey "$CRYPT" "$MNT/boot/volume.key"
fi

log "Configuring hostname, locale and timezone"
printf '%s\n' "$HOSTNAME" > "$MNT/etc/hostname"

cat > "$MNT/etc/locale.conf" <<'EOF'
LANG=en_US.UTF-8
LC_COLLATE=C
EOF

if ! grep -q '^en_US.UTF-8 UTF-8' "$MNT/etc/default/libc-locales"; then
    printf '\nen_US.UTF-8 UTF-8\n' >> "$MNT/etc/default/libc-locales"
fi

[[ -f "$MNT/usr/share/zoneinfo/$TIMEZONE" ]] ||
    die "Unknown TIMEZONE: $TIMEZONE"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
chroot "$MNT" xbps-reconfigure -f glibc-locales

log "Configuring Brazilian ThinkPad keyboard"
if grep -q '^KEYMAP=' "$MNT/etc/rc.conf"; then
    sed -i 's/^KEYMAP=.*/KEYMAP=br-abnt2/' "$MNT/etc/rc.conf"
else
    printf '\nKEYMAP=br-abnt2\n' >> "$MNT/etc/rc.conf"
fi

# Brazilian IBM/Lenovo ThinkPads expose the physical /? key as RCtrl/keycode 97.
cat > "$MNT/etc/thinkpad-br.map" <<'EOF'
keycode 97 = slash question
EOF

touch "$MNT/etc/rc.local"
if ! grep -q '/etc/thinkpad-br.map' "$MNT/etc/rc.local"; then
    cat >> "$MNT/etc/rc.local" <<'EOF'

# Brazilian ThinkPad /? physical key.
if [ -r /etc/thinkpad-br.map ]; then
    loadkeys /etc/thinkpad-br.map
fi
EOF
fi
chmod 755 "$MNT/etc/rc.local"

mkdir -p "$MNT/etc/profile.d"
cat > "$MNT/etc/profile.d/thinkpad-xkb.sh" <<'EOF'
export XKB_DEFAULT_LAYOUT=br
export XKB_DEFAULT_VARIANT=thinkpad
EOF
chmod 644 "$MNT/etc/profile.d/thinkpad-xkb.sh"

log "Configuring Ethernet and Wi-Fi through NetworkManager"
# NetworkManager is the sole network-management service.
#
# /var/service is a symlink to /run/runit/runsvdir/current, which only exists
# on a booted system (and, through the /run bind mount, would resolve into the
# live ISO, not the target). Enable services directly in the target's default
# runsvdir, which is what /var/service points at after boot.
RUNSVDIR="$MNT/etc/runit/runsvdir/default"
mkdir -p "$RUNSVDIR"

rm -f \
    "$RUNSVDIR/dhcpcd" \
    "$RUNSVDIR/wpa_supplicant"

ln -sfn /etc/sv/udevd \
    "$RUNSVDIR/udevd"

ln -sfn /etc/sv/dbus \
    "$RUNSVDIR/dbus"

ln -sfn /etc/sv/NetworkManager \
    "$RUNSVDIR/NetworkManager"

ln -sfn /etc/sv/cronie \
    "$RUNSVDIR/cronie"


log "Creating administrative user: $USERNAME"
if ! chroot "$MNT" id "$USERNAME" >/dev/null 2>&1; then
    chroot "$MNT" useradd \
        -m \
        -s /bin/bash \
        -G wheel,network,audio,video,input \
        "$USERNAME"
fi

mkdir -p "$MNT/etc/sudoers.d"
cat > "$MNT/etc/sudoers.d/10-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 "$MNT/etc/sudoers.d/10-wheel"

if [[ "$NONINTERACTIVE" == "yes" ]]; then
    log "Setting root and user passwords"

    printf 'root:%s\n' "$ROOT_PASSWORD" |
        chroot "$MNT" chpasswd -c SHA512

    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" |
        chroot "$MNT" chpasswd -c SHA512

    ROOT_HASH="$(
        awk -F: '$1 == "root" { print $2 }' "$MNT/etc/shadow"
    )"

    USER_HASH="$(
        awk -F: -v user="$USERNAME" \
            '$1 == user { print $2 }' \
            "$MNT/etc/shadow"
    )"

    [[ "$ROOT_HASH" == \$6\$* ]] ||
        die "Root password was not written correctly to /etc/shadow."

    [[ "$USER_HASH" == \$6\$* ]] ||
        die "Password for $USERNAME was not written correctly to /etc/shadow."

    unset ROOT_HASH USER_HASH
    unset ROOT_PASSWORD USER_PASSWORD
else
    printf '\nSet ROOT password:\n'
    chroot "$MNT" passwd root

    printf '\nSet password for %s:\n' "$USERNAME"
    chroot "$MNT" passwd "$USERNAME"
fi


log "Configuring Snapper for explicit root and /var snapshot stores"
mkdir -p "$MNT/etc/snapper/configs"

cat > "$MNT/etc/snapper/configs/root" <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"

NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="20"
NUMBER_LIMIT_IMPORTANT="10"

TIMELINE_CREATE="no"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_QUARTERLY="0"
TIMELINE_LIMIT_YEARLY="0"

EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF

cat > "$MNT/etc/snapper/configs/var" <<'EOF'
SUBVOLUME="/var"
FSTYPE="btrfs"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"

NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="20"
NUMBER_LIMIT_IMPORTANT="10"

TIMELINE_CREATE="no"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_QUARTERLY="0"
TIMELINE_LIMIT_YEARLY="0"

EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF

# Void's snapper package is built with configuration in /etc/conf.d.
if grep -q '^SNAPPER_CONFIGS=' "$MNT/etc/conf.d/snapper"; then
    sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root var"/' \
        "$MNT/etc/conf.d/snapper"
else
    printf '\nSNAPPER_CONFIGS="root var"\n' >> "$MNT/etc/conf.d/snapper"
fi

log "Installing paired system-snapshot helper"
cat > "$MNT/usr/local/sbin/system-snapshot" <<'EOF'
#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || {
    echo "Run as root." >&2
    exit 1
}

case "${1:-}" in
    --timeline)
        ID="$(date -u +%Y%m%dT%H%M%SZ)"
        DESC="paired-timeline:$ID"

        snapper --no-dbus -c root create \
            --description "$DESC" \
            --cleanup-algorithm timeline

        snapper --no-dbus -c var create \
            --description "$DESC" \
            --cleanup-algorithm timeline

        snapper --no-dbus -c root cleanup all
        snapper --no-dbus -c var cleanup all
        ;;

    "")
        echo "Usage: system-snapshot 'description' | --timeline" >&2
        exit 2
        ;;

    *)
        ID="$(date -u +%Y%m%dT%H%M%SZ)"
        DESC="paired:$ID:$*"

        snapper --no-dbus -c root create \
            --description "$DESC" \
            --cleanup-algorithm number

        snapper --no-dbus -c var create \
            --description "$DESC" \
            --cleanup-algorithm number
        ;;
esac
EOF
chmod 755 "$MNT/usr/local/sbin/system-snapshot"

mkdir -p "$MNT/etc/cron.hourly"
cat > "$MNT/etc/cron.hourly/10-system-snapshot" <<'EOF'
#!/bin/sh
exec /usr/local/sbin/system-snapshot --timeline
EOF
chmod 755 "$MNT/etc/cron.hourly/10-system-snapshot"

log "Configuring dracut for LUKS1, Btrfs and hibernation"
mkdir -p "$MNT/etc/dracut.conf.d"
cat > "$MNT/etc/dracut.conf.d/10-cryptroot.conf" <<'EOF'
add_dracutmodules+=" crypt btrfs resume "
install_items+=" /boot/volume.key /etc/crypttab "
hostonly="yes"
EOF

# In hostonly mode dracut looks for a resume device on the kernel command line
# visible at build time; the live ISO's /proc/cmdline has no resume=. Feeding
# the parameters through kernel_cmdline (stored in the initramfs'
# /etc/cmdline.d) makes the resume module include hibernation support.
cat > "$MNT/etc/dracut.conf.d/20-resume.conf" <<EOF
kernel_cmdline+=" resume=UUID=$BTRFS_UUID resume_offset=$RESUME_OFFSET "
EOF

log "Configuring encrypted /boot and resume parameters"
if grep -q '^GRUB_ENABLE_CRYPTODISK=' "$MNT/etc/default/grub"; then
    sed -i 's/^GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' \
        "$MNT/etc/default/grub"
else
    printf '\nGRUB_ENABLE_CRYPTODISK=y\n' >> "$MNT/etc/default/grub"
fi

KERNEL_CMDLINE="loglevel=4 rd.luks.uuid=luks-$LUKS_UUID root=UUID=$BTRFS_UUID rootflags=subvol=@ resume=UUID=$BTRFS_UUID resume_offset=$RESUME_OFFSET rw"

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$MNT/etc/default/grub"; then
    sed -i \
        "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$KERNEL_CMDLINE\"|" \
        "$MNT/etc/default/grub"
else
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$KERNEL_CMDLINE" \
        >> "$MNT/etc/default/grub"
fi

chroot "$MNT" dracut --regenerate-all --force
mkdir -p "$MNT/boot/grub"

# Install the normal GRUB module tree under encrypted /boot/grub first.  The
# signed standalone EFI below is the bootstrap, while external modules remain
# available after LUKS has been unlocked.
chroot "$MNT" grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --boot-directory=/boot \
    --bootloader-id=Void \
    --no-nvram

chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg

log "Generating custom Secure Boot PK, KEK and db keys"
KEYDIR="$MNT/root/secureboot-keys"
PUBDIR="$MNT/boot/efi/EFI/keys"

mkdir -p "$KEYDIR" "$PUBDIR"
chmod 700 "$KEYDIR"

generate_key() {
    local name="$1"
    local cn="$2"

    openssl req \
        -new \
        -x509 \
        -newkey rsa:4096 \
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

# Void's sbsigntool kernel hook signs with db.key/db.crt and refuses to run
# unless both are root-owned and not readable by group or others. The public
# copies on the ESP stay 644.
chmod 600 "$KEYDIR/db.crt"

PK_GUID="$(cat /proc/sys/kernel/random/uuid)"
KEK_GUID="$(cat /proc/sys/kernel/random/uuid)"
DB_GUID="$(cat /proc/sys/kernel/random/uuid)"

cert-to-efi-sig-list \
    -g "$PK_GUID" \
    "$KEYDIR/PK.crt" \
    "$PUBDIR/PK.esl"

cert-to-efi-sig-list \
    -g "$KEK_GUID" \
    "$KEYDIR/KEK.crt" \
    "$PUBDIR/KEK.esl"

cert-to-efi-sig-list \
    -g "$DB_GUID" \
    "$KEYDIR/db.crt" \
    "$PUBDIR/db.esl"

sign-efi-sig-list \
    -k "$KEYDIR/PK.key" \
    -c "$KEYDIR/PK.crt" \
    PK "$PUBDIR/PK.esl" "$PUBDIR/PK.auth"

sign-efi-sig-list \
    -k "$KEYDIR/PK.key" \
    -c "$KEYDIR/PK.crt" \
    KEK "$PUBDIR/KEK.esl" "$PUBDIR/KEK.auth"

sign-efi-sig-list \
    -k "$KEYDIR/KEK.key" \
    -c "$KEYDIR/KEK.crt" \
    db "$PUBDIR/db.esl" "$PUBDIR/db.auth"

log "Building signed standalone GRUB EFI"
mkdir -p "$MNT/root/grub-build"

cat > "$MNT/root/grub-build/early.cfg" <<EOF
set pager=1
insmod part_gpt
insmod cryptodisk
insmod luks
insmod gcry_rijndael
insmod gcry_sha1
insmod gcry_sha256
insmod gcry_sha512
insmod btrfs

cryptomount -a

# Resolve the root by filesystem UUID so boot does not depend on the
# GRUB-assigned crypto device number.
search --no-floppy --fs-uuid --set=root $BTRFS_UUID
set prefix=(\$root)/@/boot/grub
insmod normal
normal
EOF

mkdir -p \
    "$MNT/boot/efi/EFI/Void" \
    "$MNT/boot/efi/EFI/BOOT"

chroot "$MNT" grub-mkstandalone \
    -O x86_64-efi \
    -o /root/grub-build/grubx64-unsigned.efi \
    --modules="part_gpt cryptodisk luks gcry_rijndael gcry_sha1 gcry_sha256 gcry_sha512 btrfs normal configfile search search_fs_uuid linux ls cat all_video gfxterm echo reboot halt" \
    "boot/grub/grub.cfg=/root/grub-build/early.cfg"

sbsign \
    --key "$KEYDIR/db.key" \
    --cert "$KEYDIR/db.crt" \
    --output "$MNT/boot/efi/EFI/Void/grubx64.efi" \
    "$MNT/root/grub-build/grubx64-unsigned.efi"

cp "$MNT/boot/efi/EFI/Void/grubx64.efi" \
   "$MNT/boot/efi/EFI/BOOT/BOOTX64.EFI"

sbverify \
    --cert "$KEYDIR/db.crt" \
    "$MNT/boot/efi/EFI/Void/grubx64.efi" >/dev/null

log "Creating UEFI boot entry"
if ! chroot "$MNT" efibootmgr \
    --create \
    --disk "$DISK" \
    --part 1 \
    --label "Void Linux" \
    --loader '\EFI\Void\grubx64.efi'
then
    warn "Could not create NVRAM entry; the signed fallback EFI/BOOT/BOOTX64.EFI exists."
fi

log "Installing GRUB rebuild + re-sign helper"
cat > "$MNT/usr/local/sbin/secureboot-refresh-grub" <<'EOF'
#!/bin/sh
set -eu

KEYDIR=/root/secureboot-keys
ESP=/boot/efi
BUILD=/root/grub-build

[ "$(id -u)" -eq 0 ] || {
    echo "Run as root." >&2
    exit 1
}

[ -r "$KEYDIR/db.key" ] || {
    echo "Missing Secure Boot db private key." >&2
    exit 1
}

mkdir -p \
    "$BUILD" \
    "$ESP/EFI/Void" \
    "$ESP/EFI/BOOT"

# Refresh /boot/grub/x86_64-efi as well as grub.cfg.  grub-install may write an
# unsigned EFI loader temporarily; the signed standalone image generated below
# overwrites it before this helper returns.
grub-install \
    --target=x86_64-efi \
    --efi-directory="$ESP" \
    --boot-directory=/boot \
    --bootloader-id=Void \
    --no-nvram

# Re-derive the btrfs resume_offset so hibernation keeps working if the
# swapfile's physical location ever changes (balance/defrag).
RESUME_OFFSET="$(btrfs inspect-internal map-swapfile -r /swap/swapfile 2>/dev/null || true)"
if [ -n "$RESUME_OFFSET" ]; then
    sed -i "s|resume_offset=[0-9][0-9]*|resume_offset=$RESUME_OFFSET|" /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg

BTRFS_UUID="$(blkid -s UUID -o value /dev/mapper/cryptroot)"

cat > "$BUILD/early.cfg" <<EOC
set pager=1
insmod part_gpt
insmod cryptodisk
insmod luks
insmod gcry_rijndael
insmod gcry_sha1
insmod gcry_sha256
insmod gcry_sha512
insmod btrfs

cryptomount -a

search --no-floppy --fs-uuid --set=root $BTRFS_UUID
set prefix=(\$root)/@/boot/grub
insmod normal
normal
EOC

grub-mkstandalone \
    -O x86_64-efi \
    -o "$BUILD/grubx64-unsigned.efi" \
    --modules="part_gpt cryptodisk luks gcry_rijndael gcry_sha1 gcry_sha256 gcry_sha512 btrfs normal configfile search search_fs_uuid linux ls cat all_video gfxterm echo reboot halt" \
    "boot/grub/grub.cfg=$BUILD/early.cfg"

sbsign \
    --key "$KEYDIR/db.key" \
    --cert "$KEYDIR/db.crt" \
    --output "$ESP/EFI/Void/grubx64.efi" \
    "$BUILD/grubx64-unsigned.efi"

cp "$ESP/EFI/Void/grubx64.efi" \
   "$ESP/EFI/BOOT/BOOTX64.EFI"

sbverify \
    --cert "$KEYDIR/db.crt" \
    "$ESP/EFI/Void/grubx64.efi"

echo "GRUB regenerated and signed."
EOF
chmod 700 "$MNT/usr/local/sbin/secureboot-refresh-grub"

log "Configuring kernel signing for Secure Boot"
# Void's sbsigntool package ships a kernel hook (/etc/kernel.d/post-install/
# 40-sbsigntool) that signs /boot/vmlinuz-$VERSION with sbsign on every
# kernel install/upgrade/reconfigure when this config file exists. It is
# idempotent (skips already-signed kernels) and verifies the signature after
# signing. GRUB 2.12 loads PE kernels through UEFI LoadImage, so the
# firmware verifies the kernel against the enrolled db key; with Secure Boot
# disabled the signatures are simply ignored.
cat > "$MNT/etc/default/sbsigntool-kernel-hook" <<'EOF'
SBSIGN_EFI_KERNEL=1
EFI_KEY_FILE=/root/secureboot-keys/db.key
EFI_CERT_FILE=/root/secureboot-keys/db.crt
EOF
chmod 644 "$MNT/etc/default/sbsigntool-kernel-hook"

log "Installing snapshot-aware XBPS update wrapper"
cat > "$MNT/usr/local/sbin/xbps-snapshot-update" <<'EOF'
#!/bin/sh
set -eu

ID="$(date -u +%Y%m%dT%H%M%SZ)"
PRE="xbps-pre:$ID"

snapper --no-dbus -c root create \
    --description "$PRE" \
    --cleanup-algorithm number

snapper --no-dbus -c var create \
    --description "$PRE" \
    --cleanup-algorithm number

if ! xbps-install -Su -y; then
    echo "XBPS update failed; pre-update snapshots were retained." >&2
    exit 1
fi

/usr/local/sbin/secureboot-refresh-grub

POST="xbps-post:$ID"

snapper --no-dbus -c root create \
    --description "$POST" \
    --cleanup-algorithm number

snapper --no-dbus -c var create \
    --description "$POST" \
    --cleanup-algorithm number

echo "Update complete with paired / and /var pre/post snapshots."
EOF
chmod 700 "$MNT/usr/local/sbin/xbps-snapshot-update"

cat > "$MNT/root/SNAPSHOTS-AND-ROLLBACK.txt" <<'EOF'
VOID BTRFS SNAPSHOT MODEL
=========================

Subvolumes:
  @               /
  @home           /home
  @var            /var
  @snapshots      /.snapshots
  @var_snapshots  /var/.snapshots
  @swap           /swap

Why / and /var are snapshotted together:
  Void stores the XBPS package database under /var/db/xbps.
  A system/package rollback must therefore restore the matching root AND /var
  snapshots from the same pair.

Commands:
  sudo snapper --no-dbus -c root list
  sudo snapper --no-dbus -c var list
  sudo system-snapshot "before change"
  sudo xbps-snapshot-update

Home is intentionally independent and should be backed up separately.
@swap must never be snapshotted.
EOF
chmod 600 "$MNT/root/SNAPSHOTS-AND-ROLLBACK.txt"

cat > "$PUBDIR/README.txt" <<'EOF'
CUSTOM SECURE BOOT
==================

These files are PUBLIC enrollment material.
Private keys remain inside LUKS at /root/secureboot-keys.

Recommended order:
  1. First boot with Secure Boot disabled.
  2. Verify LUKS boot, network, keyboard, snapshots and swap.
  3. Back up /root/secureboot-keys to encrypted offline media.
  4. Enter ThinkPad Setup (F1).
  5. Set a Supervisor Password.
  6. Enter Secure Boot Custom/Setup Mode and clear current keys as appropriate.
  7. Enroll your PK, KEK and db.
  8. Enable Secure Boot.
  9. Disable USB/external boot when not needed.
 10. Protect boot-order changes with the Supervisor Password.
EOF

log "Creating initial paired installation snapshots"
chroot "$MNT" /usr/bin/env LANG=C LC_ALL=C /usr/local/sbin/system-snapshot "fresh-secure-void-install"

log "Final package configuration"
chroot "$MNT" xbps-reconfigure -fa

# xbps-reconfigure can regenerate kernel/initramfs/grub.cfg.
chroot "$MNT" /usr/local/sbin/secureboot-refresh-grub

log "Verifying required installation invariants"
test -f "$MNT/boot/efi/EFI/Void/grubx64.efi" ||
    die "Signed GRUB EFI missing."

test -f "$MNT/etc/snapper/configs/root" ||
    die "Root Snapper config missing."

test -f "$MNT/etc/snapper/configs/var" ||
    die "/var Snapper config missing."

test -f "$MNT/swap/swapfile" ||
    die "Swapfile missing."

test -f "$MNT/etc/default/sbsigntool-kernel-hook" ||
    die "Kernel signing configuration missing."

grep -q '^SBSIGN_EFI_KERNEL=1' "$MNT/etc/default/sbsigntool-kernel-hook" ||
    die "sbsigntool kernel signing is not enabled."

# Network invariants: NetworkManager is the sole DHCP/DNS manager, so a
# missing package or activation symlink must abort the install instead of
# producing a system that boots without any working network manager.
test -d "$MNT/etc/sv/NetworkManager" ||
    die "NetworkManager package service missing from /etc/sv."

test -x "$MNT/etc/sv/NetworkManager/run" ||
    die "NetworkManager service run script missing."

chroot "$MNT" sh -c 'test -e /var/service/NetworkManager' ||
    die "NetworkManager service not activated in /var/service."

test -x "$MNT/etc/sv/dbus/run" ||
    die "dbus package service missing from /etc/sv."

chroot "$MNT" sh -c 'test -e /var/service/dbus' ||
    die "dbus service not activated in /var/service."

test -e "$MNT/etc/runit/runsvdir/default/dhcpcd" &&
    die "dhcpcd service is activated; it would conflict with NetworkManager."

test -e "$MNT/etc/runit/runsvdir/default/wpa_supplicant" &&
    die "wpa_supplicant service is activated; NetworkManager manages it via dbus."

grep -q 'subvol=@snapshots' "$MNT/etc/fstab" ||
    die "@snapshots missing from fstab."

grep -q 'subvol=@var_snapshots' "$MNT/etc/fstab" ||
    die "@var_snapshots missing from fstab."

grep -q 'subvol=@home' "$MNT/etc/fstab" ||
    die "@home missing from fstab."

grep -q 'subvol=@var' "$MNT/etc/fstab" ||
    die "@var missing from fstab."

grep -q 'subvol=@swap' "$MNT/etc/fstab" ||
    die "@swap missing from fstab."

grep -q 'resume_offset=' "$MNT/etc/default/grub" ||
    die "resume_offset missing from GRUB kernel command line."

grep -q "^repository=" "$MNT/etc/xbps.d/00-repository-main.conf" ||
    die "Pinned repository mirror missing from /etc/xbps.d."

sbverify \
    --cert "$KEYDIR/db.crt" \
    "$MNT/boot/efi/EFI/Void/grubx64.efi" >/dev/null ||
    die "Secure Boot signature verification failed."

printf '\n'
printf '====================================================================\n'
printf ' INSTALLATION COMPLETE\n'
printf '====================================================================\n\n'
printf 'Disk:            %s\n' "$DISK"
printf 'Hostname:        %s\n' "$HOSTNAME"
printf 'User:            %s\n' "$USERNAME"
printf 'LUKS:            LUKS1\n'
printf '/boot:           encrypted inside @\n'
printf 'Filesystem:      Btrfs\n'
printf 'Root snapshots:  @snapshots\n'
printf 'Var snapshots:   @var_snapshots\n'
printf 'Home:            @home\n'
printf 'Var:             @var\n'
printf 'Swap:            @swap, %s GiB\n' "$SWAP_GB"
printf 'resume_offset:   %s\n' "$RESUME_OFFSET"
printf 'Network:         NetworkManager\n'
printf 'Keyboard TTY:    br-abnt2 + ThinkPad /? override\n'
printf 'Future XKB:      br(thinkpad)\n'
printf 'Editor/VCS:      vim + git\n\n'

printf 'FIRST BOOT:\n'
printf '  Keep Secure Boot DISABLED.\n'
printf '  Services:           sv status dbus NetworkManager\n'
printf '  Wi-Fi:              nmtui\n'
printf '  Network:            nmcli device\n'
printf '  Root snapshots:     sudo snapper --no-dbus -c root list\n'
printf '  Var snapshots:      sudo snapper --no-dbus -c var list\n'
printf '  Manual pair:        sudo system-snapshot "description"\n'
printf '  Safe update:        sudo xbps-snapshot-update\n'
printf '  Swap:               swapon --show\n\n'

printf 'AFTER VALIDATION:\n'
printf '  Back up /root/secureboot-keys to encrypted offline media,\n'
printf '  then configure UEFI Supervisor Password and enroll PK/KEK/db.\n\n'

printf 'Before rebooting from the live ISO:\n'
printf '  sync\n'
printf '  umount -R %s\n' "$MNT"
printf '  cryptsetup close cryptroot\n'
printf '  reboot\n'
