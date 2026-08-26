#!/usr/bin/env bash
set -Eeuo pipefail

# install-niri-noctalia.sh
#
# Desktop layer for the secure Void base installation built previously.
#
# Target:
#   Void Linux x86_64 glibc + runit
#   Lenovo ThinkPad P15 Gen 1
#   Intel iGPU + NVIDIA Quadro T1000 4 GB
#
# Installs/configures:
#   - Niri + Noctalia v5
#   - Intel as the normal Niri renderer
#   - NVIDIA proprietary driver + PRIME offload (`prime-run`)
#   - Steam/Proton and 32-bit NVIDIA/Vulkan libraries
#   - PipeWire + WirePlumber + Bluetooth audio
#   - NetworkManager, BlueZ, UPower
#   - elogind lid/suspend/hibernate handling
#   - Noctalia lock screen + idle policy
#   - TLP + tlp-pd (no competing power-profiles-daemon)
#   - portals, gnome-keyring, polkit, automount
#   - Kitty, Firefox, Nautilus, MPV
#   - PT-BR ThinkPad XKB: br(thinkpad)
#   - DKMS signing with the custom Secure Boot db key from the base installer
#
# Deliberately does NOT:
#   - install a display manager
#   - bind the T1000 to vfio-pci
#   - install swaylock/swayidle/mako/waybar/rofi/blueman/nm-applet
#     because Noctalia covers those desktop-facing functions
#
# Usage:
#   sudo USERNAME=vitor ./install-niri-noctalia.sh
#
# Optional:
#   INSTALL_STEAM=1             # default
#   INSTALL_VIRTUALIZATION=0    # set 1 for qemu/libvirt/virt-manager
#   FORCE_INTEL_RENDERER=1      # default
#
# Noctalia v5 on Void is supplied by the community repository documented by
# Noctalia. Third-party repositories should be reviewed according to your
# trust requirements.

INSTALL_STEAM="${INSTALL_STEAM:-1}"
INSTALL_VIRTUALIZATION="${INSTALL_VIRTUALIZATION:-0}"
FORCE_INTEL_RENDERER="${FORCE_INTEL_RENDERER:-1}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (normally via sudo)."
[[ "$(uname -m)" == "x86_64" ]] || die "This script targets x86_64."

TARGET_USER="${USERNAME:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
    TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)"
fi
[[ -n "$TARGET_USER" ]] || die "Could not determine the desktop user."
id "$TARGET_USER" >/dev/null 2>&1 || die "No such user: $TARGET_USER"

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$USER_HOME" ]] || die "Home directory not found: $USER_HOME"

if ! ldd --version 2>&1 | head -n1 | grep -Eqi 'glibc|GNU libc'; then
    die "This script expects Void x86_64 glibc, not musl."
fi

enable_service() {
    local svc="$1"
    if [[ -d "/etc/sv/$svc" ]]; then
        mkdir -p /var/service
        ln -sfn "/etc/sv/$svc" "/var/service/$svc"
        printf '  enabled %s\n' "$svc"
    else
        warn "runit service not found: $svc"
    fi
}

disable_service() {
    rm -f "/var/service/$1"
}

install_required() {
    log "Installing packages: $*"
    xbps-install -Sy "$@"
}

install_optional() {
    local pkg="$1"
    if xbps-query -Rs "^${pkg}-[0-9]" 2>/dev/null | grep -q .; then
        xbps-install -Sy "$pkg"
    else
        warn "Optional package unavailable: $pkg"
    fi
}

# Snapshot the base before changing it.
if command -v system-snapshot >/dev/null 2>&1; then
    log "Creating paired / + /var snapshot before desktop installation"
    system-snapshot "before-niri-noctalia-desktop"
fi

# ---------------------------------------------------------------------------
# Void repositories
# ---------------------------------------------------------------------------

log "Enabling official nonfree and multilib repositories"
xbps-install -Sy \
    void-repo-nonfree \
    void-repo-multilib \
    void-repo-multilib-nonfree
xbps-install -S

log "Adding the Noctalia-documented Void community repository"
cat > /etc/xbps.d/10-voiders-community.conf <<'EOF'
repository=https://repo.voiders.dev
EOF
xbps-install -S

# ---------------------------------------------------------------------------
# Niri / session / portals / storage integration
# ---------------------------------------------------------------------------

install_required \
    dbus \
    NetworkManager \
    python3 \
    niri \
    xwayland-satellite \
    elogind \
    polkit \
    upower \
    brightnessctl \
    xdg-user-dirs \
    xdg-utils \
    xdg-desktop-portal \
    xdg-desktop-portal-gtk \
    xdg-desktop-portal-gnome \
    gnome-keyring \
    udisks2 \
    gvfs \
    gvfs-mtp \
    wl-clipboard \
    grim \
    slurp \
    playerctl \
    wev

install_required noctalia sdbus-c++

# ---------------------------------------------------------------------------
# Audio + Bluetooth
# ---------------------------------------------------------------------------

install_required \
    pipewire \
    wireplumber \
    alsa-pipewire \
    libspa-bluetooth \
    pavucontrol \
    bluez

log "Configuring PipeWire/WirePlumber"
mkdir -p /etc/pipewire/pipewire.conf.d /etc/alsa/conf.d

[[ -e /usr/share/examples/wireplumber/10-wireplumber.conf ]] && \
    ln -sfn /usr/share/examples/wireplumber/10-wireplumber.conf \
        /etc/pipewire/pipewire.conf.d/10-wireplumber.conf

[[ -e /usr/share/examples/pipewire/20-pipewire-pulse.conf ]] && \
    ln -sfn /usr/share/examples/pipewire/20-pipewire-pulse.conf \
        /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf

[[ -e /usr/share/alsa/alsa.conf.d/50-pipewire.conf ]] && \
    ln -sfn /usr/share/alsa/alsa.conf.d/50-pipewire.conf \
        /etc/alsa/conf.d/50-pipewire.conf

[[ -e /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf ]] && \
    ln -sfn /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf \
        /etc/alsa/conf.d/99-pipewire-default.conf

# ---------------------------------------------------------------------------
# Laptop power management
# ---------------------------------------------------------------------------

install_required tlp tlp-pd

# One policy engine only. tlp-pd exposes the power-profile API while TLP owns
# the actual laptop tuning.
if xbps-query power-profiles-daemon >/dev/null 2>&1; then
    warn "Removing power-profiles-daemon to avoid competing with TLP/tlp-pd."
    xbps-remove -Ry power-profiles-daemon || true
fi
disable_service power-profiles-daemon

mkdir -p /etc/tlp.d
cat > /etc/tlp.d/10-thinkpad.conf <<'EOF'
TLP_ENABLE=1

CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power

WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

# Let unused PCIe devices enter runtime power management.
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto
EOF

# elogind, rather than acpid, owns lid/power/suspend events.
disable_service acpid
mkdir -p /etc/elogind/logind.conf.d
cat > /etc/elogind/logind.conf.d/10-thinkpad.conf <<'EOF'
[Login]
HandlePowerKey=poweroff
HandleSuspendKey=suspend
HandleHibernateKey=hibernate

HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
EOF

# ---------------------------------------------------------------------------
# Intel graphics
# ---------------------------------------------------------------------------

install_required \
    mesa-dri \
    mesa-vulkan-intel \
    vulkan-loader \
    intel-video-accel \
    glxinfo

# ---------------------------------------------------------------------------
# Secure-Boot-aware NVIDIA DKMS + PRIME
# ---------------------------------------------------------------------------

install_required dkms linux-headers openssl

SB_KEY="/root/secureboot-keys/db.key"
SB_CERT="/root/secureboot-keys/db.crt"
SB_DER="/root/secureboot-keys/db-module.der"

if [[ -r "$SB_KEY" && -r "$SB_CERT" ]]; then
    log "Configuring DKMS signing using the Secure Boot db key"
    openssl x509 -in "$SB_CERT" -outform DER -out "$SB_DER"
    chmod 600 "$SB_KEY"
    chmod 644 "$SB_DER"

    mkdir -p /etc/dkms/framework.conf.d
    cat > /etc/dkms/framework.conf.d/10-secureboot.conf <<EOF
mok_signing_key="$SB_KEY"
mok_certificate="$SB_DER"
sign_file="/lib/modules/\$kernelver/build/scripts/sign-file"
EOF
else
    warn "Secure Boot signing keys from the base installer were not found."
    warn "If Secure Boot is enabled, unsigned NVIDIA DKMS modules may be rejected."
fi

install_required nvidia

# These services can intentionally keep the dGPU alive. PRIME does not require
# them for this laptop use case.
disable_service nvidia-persistenced
disable_service nvidia-powerd

cat > /etc/modprobe.d/90-nvidia-thinkpad.conf <<'EOF'
# Modern Wayland/Niri.
options nvidia_drm modeset=1 fbdev=1

# Request Turing dynamic runtime D3 power management.  Some P15 Gen 1 firmware
# configurations report RTD3 as unsupported; PRIME offload still works normally.
options nvidia NVreg_DynamicPowerManagement=0x02
EOF

mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/80-nvidia-runtime-pm.rules <<'EOF'
ACTION=="add",  SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", TEST=="power/control", ATTR{power/control}="auto"
EOF

# ---------------------------------------------------------------------------
# Steam / Proton
# ---------------------------------------------------------------------------

if [[ "$INSTALL_STEAM" == 1 ]]; then
    install_required \
        libgcc-32bit \
        libstdc++-32bit \
        libdrm-32bit \
        libglvnd-32bit \
        mesa-dri-32bit \
        mesa-vulkan-intel-32bit \
        vulkan-loader-32bit \
        nvidia-libs-32bit \
        steam

    install_optional gamescope
    install_optional MangoHud
fi

# ---------------------------------------------------------------------------
# Applications + fonts
# ---------------------------------------------------------------------------

install_required \
    kitty \
    firefox \
    nautilus \
    mpv \
    imv \
    fontconfig \
    dejavu-fonts-ttf \
    noto-fonts-ttf \
    noto-fonts-emoji \
    font-firacode

# ---------------------------------------------------------------------------
# Optional future VFIO tooling (no vfio-pci binding here)
# ---------------------------------------------------------------------------

if [[ "$INSTALL_VIRTUALIZATION" == 1 ]]; then
    install_required qemu libvirt virt-manager
    enable_service libvirtd
    getent group libvirt >/dev/null 2>&1 && usermod -aG libvirt "$TARGET_USER"
fi

# ---------------------------------------------------------------------------
# runit services
# ---------------------------------------------------------------------------

log "Enabling system services"
enable_service dbus
enable_service NetworkManager
enable_service elogind
enable_service bluetoothd
enable_service tlp
enable_service tlp-pd

# NetworkManager is the sole network manager.
disable_service dhcpcd
disable_service wpa_supplicant

for grp in audio video input network; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" "$TARGET_USER"
done

# ---------------------------------------------------------------------------
# User setup
# ---------------------------------------------------------------------------

runuser -u "$TARGET_USER" -- env HOME="$USER_HOME" xdg-user-dirs-update || true

mkdir -p \
    "$USER_HOME/.config/niri" \
    "$USER_HOME/.config/noctalia" \
    "$USER_HOME/.local/bin"

# Noctalia handles lock + idle itself, so no swaylock/swayidle are needed.
NOCTALIA_CFG="$USER_HOME/.config/noctalia/config.toml"
if [[ -e "$NOCTALIA_CFG" ]]; then
    cp -a "$NOCTALIA_CFG" "${NOCTALIA_CFG}.backup.$(date +%Y%m%d-%H%M%S)"
fi

cat > "$NOCTALIA_CFG" <<'EOF'
[lockscreen]
enabled = true
lock_before_suspend = true
fingerprint = false

[idle]
behavior_order = ["lock", "screen-off", "suspend"]
pre_action_fade_seconds = 2.0

[idle.behavior.lock]
timeout = 300
action = "lock"
enabled = true

[idle.behavior.screen-off]
timeout = 600
action = "screen_off"
enabled = true

[idle.behavior.suspend]
timeout = 1800
action = "lock_and_suspend"
enabled = true

[shell]
niri_overview_type_to_launch_enabled = true
EOF

# Session helper launched by Niri. It starts the user audio stack and shell.
SESSION_HELPER="$USER_HOME/.local/bin/niri-session-services"
cat > "$SESSION_HELPER" <<'EOF'
#!/bin/sh

dbus-update-activation-environment \
    DISPLAY \
    WAYLAND_DISPLAY \
    XDG_CURRENT_DESKTOP \
    XDG_SESSION_DESKTOP \
    XDG_SESSION_TYPE \
    XDG_RUNTIME_DIR 2>/dev/null || true

if ! pgrep -x pipewire >/dev/null 2>&1; then
    pipewire >/tmp/pipewire-"$UID".log 2>&1 &
fi

i=0
while [ "$i" -lt 50 ] && \
      [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$UID}/pipewire-0" ]; do
    sleep 0.1
    i=$((i + 1))
done

if ! pgrep -u "$UID" -x gnome-keyring-daemon >/dev/null 2>&1; then
    gnome-keyring-daemon --start --components=secrets >/dev/null 2>&1 || true
fi

exec noctalia --daemon
EOF
chmod 755 "$SESSION_HELPER"

# ---------------------------------------------------------------------------
# Niri configuration
# ---------------------------------------------------------------------------

log "Building Niri config from this installed Niri version's default"

NIRI_DEFAULT=""
for f in \
    /usr/share/examples/niri/default-config.kdl \
    /usr/share/examples/niri/config.kdl \
    /etc/niri/config.kdl
do
    if [[ -f "$f" ]]; then
        NIRI_DEFAULT="$f"
        break
    fi
done

if [[ -z "$NIRI_DEFAULT" ]]; then
    NIRI_DEFAULT="$(
        xbps-query -f niri 2>/dev/null |
        awk '{print $NF}' |
        grep -E '/(default-)?config\.kdl$' |
        while read -r f; do
            [[ -f "$f" ]] && { echo "$f"; break; }
        done
    )"
fi

[[ -n "$NIRI_DEFAULT" && -f "$NIRI_DEFAULT" ]] ||
    die "Could not locate the Niri default config."

NIRI_CFG="$USER_HOME/.config/niri/config.kdl"
if [[ -e "$NIRI_CFG" ]]; then
    cp -a "$NIRI_CFG" "${NIRI_CFG}.backup.$(date +%Y%m%d-%H%M%S)"
fi
cp "$NIRI_DEFAULT" "$NIRI_CFG"

# Detect the Intel render node by PCI vendor ID.
INTEL_RENDER_NODE=""
if [[ "$FORCE_INTEL_RENDERER" == 1 ]]; then
    for sysnode in /sys/class/drm/renderD*; do
        [[ -e "$sysnode/device/vendor" ]] || continue
        [[ "$(cat "$sysnode/device/vendor")" == 0x8086 ]] || continue

        devnode="/dev/dri/${sysnode##*/}"
        INTEL_RENDER_NODE="$devnode"

        for bypath in /dev/dri/by-path/*-render; do
            [[ -e "$bypath" ]] || continue
            if [[ "$(readlink -f "$bypath")" == "$(readlink -f "$devnode")" ]]; then
                INTEL_RENDER_NODE="$bypath"
                break
            fi
        done
        break
    done

    [[ -n "$INTEL_RENDER_NODE" ]] ||
        warn "Intel render node not detected; Niri will auto-select the renderer."
fi

export PATCH_NIRI_CFG="$NIRI_CFG"
export PATCH_SESSION_HELPER="$SESSION_HELPER"
export PATCH_INTEL_RENDER="$INTEL_RENDER_NODE"

python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["PATCH_NIRI_CFG"])
session_helper = os.environ["PATCH_SESSION_HELPER"]
intel_render = os.environ.get("PATCH_INTEL_RENDER", "")
text = path.read_text()

def replace_once(old, new, required=True):
    global text
    if old not in text:
        if required:
            raise SystemExit(f"Niri default config changed; expected text missing: {old!r}")
        return
    text = text.replace(old, new, 1)

# Modify the existing xkb block. Never append a second input {}.
m = re.search(r'(\n\s*xkb\s*\{\s*\n)', text)
if not m:
    raise SystemExit("Could not find xkb block in Niri default config.")

new_xkb = (
    m.group(1)
    + '            layout "br"\n'
    + '            variant "thinkpad"\n'
)
text = text[:m.start()] + new_xkb + text[m.end():]

# No Waybar: Noctalia is the desktop shell.
replace_once(
    'spawn-at-startup "waybar"',
    f'spawn-at-startup "{session_helper}"'
)

replace_once(
    'Mod+T hotkey-overlay-title="Open a Terminal: alacritty" { spawn "alacritty"; }',
    'Mod+T hotkey-overlay-title="Open a Terminal: kitty" { spawn "kitty"; }'
)
replace_once(
    'Mod+D hotkey-overlay-title="Run an Application: fuzzel" { spawn "fuzzel"; }',
    'Mod+D hotkey-overlay-title="Application Launcher: Noctalia" { spawn "noctalia" "msg" "panel-toggle" "launcher"; }'
)
replace_once(
    'Super+Alt+L hotkey-overlay-title="Lock the Screen: swaylock" { spawn "swaylock"; }',
    'Super+Alt+L hotkey-overlay-title="Lock: Noctalia" { spawn "noctalia" "msg" "session" "lock"; }'
)

# Multimedia-line formatting changes between Niri releases.  These replacements
# are cosmetic integrations with Noctalia; the stock wpctl/brightnessctl binds
# are still functional if a future default cannot be matched exactly.
for old, new in {
    'XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+ -l 1.0"; }':
        'XF86AudioRaiseVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-up"; }',
    'XF86AudioLowerVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-"; }':
        'XF86AudioLowerVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-down"; }',
    'XF86AudioMute allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; }':
        'XF86AudioMute allow-when-locked=true { spawn "noctalia" "msg" "volume-mute"; }',
    'XF86MonBrightnessUp allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "+10%"; }':
        'XF86MonBrightnessUp allow-when-locked=true { spawn "noctalia" "msg" "brightness-up"; }',
    'XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "10%-"; }':
        'XF86MonBrightnessDown allow-when-locked=true { spawn "noctalia" "msg" "brightness-down"; }',
}.items():
    replace_once(old, new, required=False)

# Add bindings inside the ONE existing binds {} block.
extra_binds = """binds {
    // Noctalia integration.
    Mod+Space hotkey-overlay-title="Noctalia Launcher" { spawn "noctalia" "msg" "panel-toggle" "launcher"; }
    Mod+S hotkey-overlay-title="Noctalia Control Center" { spawn "noctalia" "msg" "panel-toggle" "control-center"; }
    Mod+Shift+S hotkey-overlay-title="Noctalia Settings" { spawn "noctalia" "msg" "settings-toggle"; }
    Alt+Tab hotkey-overlay-title="Noctalia Window Switcher" { spawn "noctalia" "msg" "window-switcher"; }
    Mod+Shift+Escape hotkey-overlay-title="Session Menu" { spawn "noctalia" "msg" "panel-toggle" "session"; }
    Super+Alt+H hotkey-overlay-title="Lock and Hibernate" { spawn-sh "noctalia msg session lock; sleep 1; loginctl hibernate"; }
"""
replace_once("binds {", extra_binds)

# Current Niri defaults contain only a commented rounded-corners example.
# Add the active rule once.
text += r"""

// Desktop integration added by install-niri-noctalia.sh.
window-rule {
    geometry-corner-radius 12
    clip-to-geometry true
}

window-rule {
    match app-id="dev.noctalia.Noctalia"
    open-floating true
}

debug {
    honor-xdg-activation-with-invalid-serial
"""

if intel_render:
    text += f'    // Keep normal compositor rendering on Intel.\n'
    text += f'    render-drm-device "{intel_render}"\n'

text += "}\n"
path.write_text(text)
PY

chown -R "$TARGET_USER:$TARGET_USER" \
    "$USER_HOME/.config/niri" \
    "$USER_HOME/.config/noctalia" \
    "$USER_HOME/.local"

log "Validating generated Niri config"
runuser -u "$TARGET_USER" -- \
    env HOME="$USER_HOME" XDG_CONFIG_HOME="$USER_HOME/.config" \
    niri validate ||
    die "niri validate failed; inspect $NIRI_CFG"

# Noctalia validator availability can differ across package revisions.
if noctalia config validate --help >/dev/null 2>&1; then
    log "Validating Noctalia config"
    runuser -u "$TARGET_USER" -- \
        env HOME="$USER_HOME" XDG_CONFIG_HOME="$USER_HOME/.config" \
        noctalia config validate ||
        warn "Noctalia reported a config issue; inspect $NOCTALIA_CFG."
fi

# ---------------------------------------------------------------------------
# TTY launcher for runit/Void
# ---------------------------------------------------------------------------

cat > /usr/local/bin/start-niri <<'EOF'
#!/bin/sh
set -eu

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    echo "XDG_RUNTIME_DIR is missing." >&2
    echo "elogind should create it on a normal TTY login; log out and back in." >&2
    exit 1
fi

export XDG_CURRENT_DESKTOP=niri
export XDG_SESSION_DESKTOP=niri
export XDG_SESSION_TYPE=wayland

# On runit there is no systemd/dinit user manager. Give the graphical session
# its own D-Bus session bus and let Niri perform its normal --session setup.
exec dbus-run-session -- niri --session
EOF
chmod 755 /usr/local/bin/start-niri

# Browser default; failure is harmless before the first graphical login.
runuser -u "$TARGET_USER" -- \
    env HOME="$USER_HOME" \
    xdg-settings set default-web-browser firefox.desktop 2>/dev/null || true

# ---------------------------------------------------------------------------
# Rebuild boot artifacts after NVIDIA installation
# ---------------------------------------------------------------------------

log "Regenerating initramfs"
dracut --regenerate-all --force

if [[ -x /usr/local/sbin/secureboot-refresh-grub ]]; then
    log "Refreshing and re-signing the standalone Secure Boot GRUB image"
    /usr/local/sbin/secureboot-refresh-grub
fi

if modinfo nvidia >/dev/null 2>&1; then
    signer="$(modinfo -F signer nvidia 2>/dev/null || true)"
    if [[ -n "$signer" ]]; then
        printf '\nNVIDIA module signer: %s\n' "$signer"
    elif [[ -r "$SB_KEY" ]]; then
        warn "The NVIDIA module is present but modinfo did not report a signer."
        warn "Verify DKMS module signing before enabling/relying on Secure Boot."
    fi
fi

if command -v system-snapshot >/dev/null 2>&1; then
    log "Creating paired / + /var snapshot after desktop installation"
    system-snapshot "niri-noctalia-desktop-installed"
fi

printf '\n'
printf '====================================================================\n'
printf ' NIRI + NOCTALIA INSTALLATION COMPLETE\n'
printf '====================================================================\n\n'
printf 'User:          %s\n' "$TARGET_USER"
printf 'Desktop:       Niri + Noctalia v5\n'
printf 'Terminal:      Kitty\n'
printf 'Browser:       Firefox\n'
printf 'Files:         Nautilus\n'
printf 'Audio:         PipeWire + WirePlumber\n'
printf 'Bluetooth:     BlueZ + PipeWire Bluetooth audio\n'
printf 'Network:       NetworkManager\n'
printf 'Power:         TLP + tlp-pd + UPower\n'
printf 'Session:       elogind\n'
printf 'Lock/idle:     Noctalia\n'
printf 'Keyboard:      br(thinkpad)\n'
printf 'Niri renderer: %s\n' "${INTEL_RENDER_NODE:-automatic}"
printf 'NVIDIA:        PRIME offload; not bound to VFIO\n'
printf 'Steam:         %s\n\n' "$([[ "$INSTALL_STEAM" == 1 ]] && echo installed || echo skipped)"

printf 'After reboot:\n'
printf '  1. Log in on the TTY as %s\n' "$TARGET_USER"
printf '  2. Run: start-niri\n\n'

printf 'PRIME / gaming:\n'
printf '  prime-run program\n'
if [[ "$INSTALL_STEAM" == 1 ]]; then
    printf '  Steam launch option: prime-run %%command%%\n'
fi
printf '  nvidia-smi\n\n'

printf 'Useful checks:\n'
printf '  niri validate\n'
printf '  niri msg outputs\n'
printf '  noctalia msg --help\n'
printf '  tlp-stat -s\n'
printf '  loginctl hibernate\n\n'

printf 'Notes:\n'
printf '  - The internal desktop renderer is Intel when detection succeeded.\n'
printf '  - HDMI on this P15 may keep the T1000 awake because the port is dGPU-wired.\n'
printf '  - If an external high-refresh display has cross-GPU presentation issues,\n'
printf '    remove render-drm-device from ~/.config/niri/config.kdl and let Niri\n'
printf '    select the renderer automatically.\n'
printf '  - No display manager was installed.\n'
printf '  - VFIO can be added later; this script does not reserve the T1000 for a VM.\n'
