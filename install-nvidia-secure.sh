#!/usr/bin/env bash
set -Eeuo pipefail

# install-nvidia-secure.sh
#
# NVIDIA driver layer for the secure Void base installation.
#
# Target:
#   Void Linux x86_64 glibc + runit
#   Hybrid graphics: Intel iGPU (compositor) + NVIDIA Turing dGPU
#
# Installs/configures:
#   - NVIDIA driver from the nonfree repository (nvidia + nvidia-dkms +
#     nvidia-libs + nvidia-firmware via the metapackage)
#   - DKMS module build against the running kernel (linux-headers)
#   - Secure Boot: DKMS modules signed with the custom db key, kept signed
#     across kernel and driver updates through a kernel hook
#   - nouveau/nova_core/nova_drm blacklisting (package-provided + dracut)
#   - nvidia-drm modeset + fbdev for Wayland (niri)
#   - Runtime power management (RTD3) for the dGPU, coordinated with TLP
#   - PRIME render offload through Void's prime-run wrapper
#   - Optional: run the niri compositor itself on the NVIDIA GPU
#
# Usage:
#   sudo ./install-nvidia-secure.sh
#
# Optional environment variables:
#   NVIDIA_COMPOSITOR=1     render the niri session on the NVIDIA GPU
#                           (default 0: compositor on Intel, dGPU via prime-run)
#   INSTALL_NVIDIA_VAAPI=1  install nvidia-vaapi-driver (NVDEC VA-API backend)

NVIDIA_COMPOSITOR="${NVIDIA_COMPOSITOR:-0}"
INSTALL_NVIDIA_VAAPI="${INSTALL_NVIDIA_VAAPI:-0}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (normally via sudo)."
[[ "$(uname -m)" == "x86_64" ]] || die "This script targets x86_64."

command -v xbps-install >/dev/null 2>&1 ||
    die "xbps not found: this script must run inside the installed Void system."

install_required() {
    log "Installing packages: $*"
    xbps-install -Sy "$@"
}

append_once() {
    local file="$1"
    local marker="$2"
    local content="$3"

    touch "$file"
    if ! grep -Fq "$marker" "$file"; then
        printf '\n%s\n' "$content" >> "$file"
    fi
}

# ---------------------------------------------------------------------------
# Hardware and prerequisites
# ---------------------------------------------------------------------------

KVER="$(uname -r)"

log "Checking for NVIDIA hardware"
# PCI vendor 10de is exclusively NVIDIA; the class code sits before the
# vendor ID in lspci output, so matching on the vendor alone is correct.
if ! lspci -nn 2>/dev/null | grep -qi '10de:'; then
    die "No NVIDIA GPU (PCI vendor 10de) found; nothing to install."
fi

log "Checking kernel headers for the running kernel ($KVER)"
if [[ ! -e "/lib/modules/$KVER/build" ]]; then
    install_required linux-headers
    [[ -e "/lib/modules/$KVER/build" ]] ||
        die "Headers for the running kernel $KVER are still missing; reboot into the freshly installed kernel and re-run."
fi

SB_KEYS_DIR=/root/secureboot-keys
SB_SIGNING=no
if [[ -r "$SB_KEYS_DIR/db.key" && -r "$SB_KEYS_DIR/db.crt" ]]; then
    SB_SIGNING=yes
    log "Secure Boot keys found; DKMS modules will be signed with the db key"
else
    warn "Secure Boot keys not found in $SB_KEYS_DIR."
    warn "NVIDIA modules will be UNSIGNED. Restore the /root/secureboot-keys backup and re-run this script to enable signing."
fi

# ---------------------------------------------------------------------------
# Snapshot before changes
# ---------------------------------------------------------------------------

if command -v system-snapshot >/dev/null 2>&1; then
    log "Creating paired / + /var snapshot before NVIDIA installation"
    system-snapshot "before-nvidia-driver"
fi

# ---------------------------------------------------------------------------
# Nonfree repository
# ---------------------------------------------------------------------------

if ! grep -qs '/nonfree' /etc/xbps.d/*.conf /usr/share/xbps.d/*.conf 2>/dev/null; then
    log "Enabling the Void nonfree repository"
    install_required void-repo-nonfree
fi

log "Syncing repository metadata"
xbps-install -S ||
    die "Syncing repositories failed; check /etc/xbps.d."

# ---------------------------------------------------------------------------
# Secure Boot module signing infrastructure
# ---------------------------------------------------------------------------

if [[ "$SB_SIGNING" == yes ]]; then
    log "Installing DKMS module signing helper and kernel hook"

    # Stage a copy of the kernel's sign-file: it is kernel-version
    # independent, so this fallback keeps future kernel updates signable even
    # if a headers package stops shipping the binary.
    if [[ -x "/lib/modules/$KVER/build/scripts/sign-file" ]] &&
       [[ ! -e /usr/local/sbin/sign-file ]]; then
        install -m 755 "/lib/modules/$KVER/build/scripts/sign-file" \
            /usr/local/sbin/sign-file
    fi

    cat > /usr/local/sbin/sb-sign-modules <<'EOF'
#!/bin/sh
set -eu

VERSION="${1:-$(uname -r)}"
KEYDIR=/root/secureboot-keys
KEY="$KEYDIR/db.key"
CERT="$KEYDIR/db.crt"
KDIR="/lib/modules/$VERSION"

[ -f "$KEY" ] && [ -f "$CERT" ] || exit 0

SIGN_FILE=""
if [ -x "$KDIR/build/scripts/sign-file" ]; then
    SIGN_FILE="$KDIR/build/scripts/sign-file"
elif [ -x /usr/local/sbin/sign-file ]; then
    SIGN_FILE=/usr/local/sbin/sign-file
else
    echo "sign-file not found for kernel $VERSION; modules left unsigned." >&2
    exit 1
fi

mkdir -p "$KDIR/updates"

# DKMS modules may be installed compressed; decompress before signing,
# depmod accepts mixed compression.
find "$KDIR/updates" -name '*.ko.zst' -exec zstd -q -d {} \; 2>/dev/null || true
find "$KDIR/updates" -name '*.ko.xz' -exec xz -q -d {} \; 2>/dev/null || true

SIGNED=0
while IFS= read -r ko; do
    [ -n "$ko" ] || continue
    if [ -z "$(modinfo -F signer "$ko" 2>/dev/null)" ]; then
        "$SIGN_FILE" sha512 "$KEY" "$CERT" "$ko"
        SIGNED=$((SIGNED + 1))
    fi
done <<MODS
$(find "$KDIR/updates" -name '*.ko' 2>/dev/null)
MODS

depmod -a "$VERSION"

if [ "$SIGNED" -gt 0 ]; then
    echo "Secure Boot: signed $SIGNED module(s) for kernel $VERSION"
fi
EOF
    chmod 755 /usr/local/sbin/sb-sign-modules

    # 15 > 10-dkms (builds modules) and 15 < 20-initramfs (embeds them).
    mkdir -p /etc/kernel.d/post-install
    cat > /etc/kernel.d/post-install/15-sb-sign-modules <<'EOF'
#!/bin/sh
exec /usr/local/sbin/sb-sign-modules "${1:-$(uname -r)}"
EOF
    chmod 755 /etc/kernel.d/post-install/15-sb-sign-modules
fi

# ---------------------------------------------------------------------------
# Driver options, KMS and initramfs configuration
# ---------------------------------------------------------------------------

log "Configuring NVIDIA module options (modeset, fbdev, runtime PM)"
cat > /etc/modprobe.d/nvidia-secure.conf <<'EOF'
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_DynamicPowerManagement=0x02
EOF

log "Configuring dracut for NVIDIA early KMS"
cat > /etc/dracut.conf.d/30-nvidia.conf <<'EOF'
add_drivers+=" nvidia nvidia_modeset nvidia_drm nvidia_uvm "
omit_drivers+=" nouveau nova_core nova_drm "
EOF

# ---------------------------------------------------------------------------
# Laptop power management coordination (TLP)
# ---------------------------------------------------------------------------

if xbps-query tlp >/dev/null 2>&1; then
    log "Excluding NVIDIA from TLP runtime PM (driver RTD3 owns it)"
    mkdir -p /etc/tlp.d
    cat > /etc/tlp.d/20-nvidia.conf <<'EOF'
# NVIDIA implements its own runtime D3 power management; TLP must not
# touch NVIDIA PCI devices or the GPU will fail to resume.
RUNTIME_PM_DRIVER_BLACKLIST="nvidia nouveau mei_hdcp"
EOF
fi

# ---------------------------------------------------------------------------
# Driver installation
# ---------------------------------------------------------------------------

log "Installing NVIDIA driver and DKMS module"
install_required nvidia

if [[ "$INSTALL_NVIDIA_VAAPI" == 1 ]]; then
    install_required nvidia-vaapi-driver
fi

log "Verifying the kernel module was built"
MODINFO_OUT="$(modinfo nvidia 2>/dev/null || true)"
[[ -n "$MODINFO_OUT" ]] ||
    die "nvidia kernel module not found; check 'dkms status' for build failures."

if [[ "$SB_SIGNING" == yes ]]; then
    log "Signing freshly built NVIDIA modules"
    /usr/local/sbin/sb-sign-modules "$KVER"
    SIGNER="$(modinfo -F signer nvidia 2>/dev/null || true)"
    if [[ -n "$SIGNER" ]]; then
        log "Module signer: $SIGNER"
    else
        warn "nvidia module appears unsigned after signing; inspect /usr/local/sbin/sb-sign-modules output."
    fi
fi

# ---------------------------------------------------------------------------
# Runtime power management udev rules (RTD3)
# ---------------------------------------------------------------------------

log "Installing NVIDIA runtime PM udev rules"
cat > /etc/udev/rules.d/80-nvidia-pm.rules <<'EOF'
# Enable runtime PM for NVIDIA VGA/3D controller devices on bind
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"

# Disable runtime PM for NVIDIA VGA/3D controller devices on unbind
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
EOF

udevadm control --reload

# ---------------------------------------------------------------------------
# PRIME offload wrapper check
# ---------------------------------------------------------------------------

command -v prime-run >/dev/null 2>&1 ||
    die "prime-run not found; the nvidia package should have installed it."

# ---------------------------------------------------------------------------
# Rebuild initramfs with NVIDIA drivers
# ---------------------------------------------------------------------------

log "Regenerating initramfs (early KMS + nouveau omission)"
dracut --regenerate-all --force

# ---------------------------------------------------------------------------
# Optional: render the compositor on the NVIDIA GPU
# ---------------------------------------------------------------------------

if [[ -z "${SUDO_USER:-}" ]]; then
    TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)"
    USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
else
    TARGET_USER="$SUDO_USER"
    USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi
NIRI_CFG="$USER_HOME/.config/niri/config.kdl"

if [[ "$NVIDIA_COMPOSITOR" == 1 ]]; then
    log "Switching the niri compositor to the NVIDIA render node"

    command -v python3 >/dev/null 2>&1 ||
        die "python3 is required for the compositor patch."

    NVIDIA_RENDER_NODE=""
    for sysnode in /sys/class/drm/renderD*; do
        [[ -e "$sysnode/device/vendor" ]] || continue
        [[ "$(cat "$sysnode/device/vendor")" == 0x10de ]] || continue

        devnode="/dev/dri/${sysnode##*/}"
        NVIDIA_RENDER_NODE="$devnode"

        for bypath in /dev/dri/by-path/*-render; do
            [[ -e "$bypath" ]] || continue
            if [[ "$(readlink -f "$bypath")" == "$(readlink -f "$devnode")" ]]; then
                NVIDIA_RENDER_NODE="$bypath"
                break
            fi
        done

        break
    done

    [[ -n "$NVIDIA_RENDER_NODE" ]] ||
        die "NVIDIA render node not detected; cannot configure the compositor."

    if [[ ! -f "$NIRI_CFG" ]]; then
        warn "No niri config at $NIRI_CFG; run install-niri-noctalia-secure.sh first, then re-run this script."
    else
        PATCH_NIRI_CFG="$NIRI_CFG"
        PATCH_NVIDIA_RENDER="$NVIDIA_RENDER_NODE"
        python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["PATCH_NIRI_CFG"])
node = os.environ["PATCH_NVIDIA_RENDER"]

text = path.read_text()

if "render-drm-device" in text:
    text = re.sub(
        r'render-drm-device "[^"]*"',
        f'render-drm-device "{node}"',
        text,
        count=1,
    )
else:
    m = re.search(r'(^debug \{[ \t]*\n)', text, re.M)
    if m:
        text = text[:m.end()] + f'    render-drm-device "{node}"\n' + text[m.end():]
    else:
        text += f'\ndebug {{\n    render-drm-device "{node}"\n}}\n'

path.write_text(text)
PY
        chown "$TARGET_USER:$TARGET_USER" "$NIRI_CFG"
        log "niri will render on $NVIDIA_RENDER_NODE"
    fi
else
    log "Compositor stays on Intel; run apps on the dGPU with: prime-run <command>"
fi

# ---------------------------------------------------------------------------
# Snapshot after changes
# ---------------------------------------------------------------------------

if command -v system-snapshot >/dev/null 2>&1; then
    log "Creating paired / + /var snapshot after NVIDIA installation"
    system-snapshot "nvidia-driver-installed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '====================================================================\n'
printf ' NVIDIA INSTALLATION COMPLETE\n'
printf '====================================================================\n\n'

printf 'Driver:        %s\n' "$(modinfo -F version nvidia 2>/dev/null || echo 'unknown')"
printf 'Module:        DKMS (%s)\n' "$(dkms status 2>/dev/null | head -n1 || echo 'see dkms status')"
printf 'Signed:        %s\n' "$([[ "$SB_SIGNING" == yes ]] && { modinfo -F signer nvidia 2>/dev/null || echo 'yes'; } || echo 'no (keys missing)')"
printf 'Modeset:       nvidia-drm modeset=1 fbdev=1\n'
printf 'Offload:       prime-run <command>\n'
printf 'Compositor:    %s\n' "$([[ "$NVIDIA_COMPOSITOR" == 1 ]] && echo 'NVIDIA GPU' || echo 'Intel GPU (default)')"
printf 'Power:         RTD3 runtime PM + TLP blacklist\n\n'

printf 'REBOOT REQUIRED before the driver is active.\n\n'

printf 'After reboot:\n'
printf '  Verify driver:      nvidia-smi\n'
printf '  Verify modeset:     cat /sys/module/nvidia_drm/parameters/modeset\n'
printf '  Run app on dGPU:    prime-run glxinfo | grep "OpenGL renderer"\n'
printf '  Module signature:   modinfo -F signer nvidia\n'
printf '  RTD3 status:        cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status\n\n'

printf 'Notes:\n'
printf '  - The compositor intentionally stays on the Intel GPU unless\n'
printf '    NVIDIA_COMPOSITOR=1 was set; this maximizes battery life.\n'
printf '  - Driver and kernel updates keep working automatically:\n'
printf '    10-dkms rebuilds the module, 15-sb-sign-modules re-signs it,\n'
printf '    20-initramfs regenerates, 40-sbsigntool re-signs the kernel.\n'
printf '  - Suspend/resume hooks for the driver ship in the nvidia package.\n'
if [[ "$INSTALL_NVIDIA_VAAPI" == 1 ]]; then
    printf '  - nvidia-vaapi-driver: export LIBVA_DRIVER_NAME=nvidia and\n'
    printf '    NVD_BACKEND=direct for applications that use VA-API.\n'
fi
