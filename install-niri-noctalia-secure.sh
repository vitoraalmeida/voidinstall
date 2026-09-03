#!/usr/bin/env bash
set -Eeuo pipefail

# install-niri-noctalia-secure.sh
#
# Desktop layer for the secure Void base installation.
#
# Target:
#   Void Linux x86_64 glibc + runit
#   Niri + Noctalia v5
#
# Installs/configures:
#   - Niri + Noctalia v5
#   - Intel/Mesa graphics stack
#   - PipeWire + WirePlumber + Bluetooth audio
#   - NetworkManager, BlueZ, UPower
#   - elogind lid/suspend/hibernate handling
#   - Noctalia lock screen + idle policy
#   - TLP + tlp-pd + tlp-rdw
#   - XDG portals, gnome-keyring, polkit, automount
#   - Alacritty, Brave (Flatpak), Nautilus, MPV
#   - adw-gtk3 from the latest upstream release
#   - nwg-look built from the official upstream repository
#   - GTK integration helpers and Noctalia GTK/Alacritty templates
#   - Iosevka Nerd Font
#   - PT-BR ThinkPad XKB: br(thinkpad)
#
# Machine-specific integration (this setup targets one ThinkPad P15 Gen 1):
#   With APPLY_DOTFILES=1 (default), the dotfiles repository is cloned to
#   ~/dotfiles (override with DOTFILES_DIR / DOTFILES_REPO) if missing, and
#   its install.sh is executed at the end — after the generated configs, so
#   the personal Stow configs always win. The dotfiles integration also:
#   - installs the root packages from dotfiles packages/xbps-roots.txt
#     (XBPS resolves the rest of the dependency tree)
#   - installs every Flatpak app from dotfiles packages/flatpak-apps.txt
#   - copies the dotfiles wallpapers into ~/Pictures/Wallpapers
#
# Deliberately does NOT install:
#   - NVIDIA drivers / PRIME tooling
#   - Steam / gaming libraries
#   - qemu / libvirt / virt-manager / VFIO tooling
#   - a display manager
#   - swaylock / swayidle / mako / waybar / rofi / blueman / nm-applet
#     because Noctalia covers those desktop-facing functions
#
# Usage:
#   sudo USERNAME=vitor ./install-niri-noctalia-secure.sh
#
# Optional environment variables:
#   INSTALL_BRAVE=1
#   INSTALL_IOSEVKA_NERD_FONT=1
#   INSTALL_ADW_GTK3=1
#   INSTALL_NWG_LOOK=1
#   FORCE_INTEL_RENDERER=1
#   DOTFILES_DIR=~/dotfiles
#   DOTFILES_REPO=https://github.com/vitoraalmeida/dotfiles.git
#   APPLY_DOTFILES=1   (clone if missing and run dotfiles install.sh at the end)

INSTALL_BRAVE="${INSTALL_BRAVE:-1}"
INSTALL_IOSEVKA_NERD_FONT="${INSTALL_IOSEVKA_NERD_FONT:-1}"
INSTALL_ADW_GTK3="${INSTALL_ADW_GTK3:-1}"
INSTALL_NWG_LOOK="${INSTALL_NWG_LOOK:-1}"
FORCE_INTEL_RENDERER="${FORCE_INTEL_RENDERER:-1}"
DOTFILES_DIR="${DOTFILES_DIR:-}"
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/vitoraalmeida/dotfiles.git}"
APPLY_DOTFILES="${APPLY_DOTFILES:-1}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (normally via sudo)."
[[ "$(uname -m)" == "x86_64" ]] || die "This script targets x86_64."

command -v xbps-install >/dev/null 2>&1 ||
    die "xbps not found: this script must run inside the installed Void system, not on the host or live ISO."

TARGET_USER="${USERNAME:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
    TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)"
fi

[[ -n "$TARGET_USER" ]] || die "Could not determine the desktop user."
id "$TARGET_USER" >/dev/null 2>&1 || die "No such user: $TARGET_USER"

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$USER_HOME" ]] || die "Home directory not found: $USER_HOME"

DOTFILES_DIR="${DOTFILES_DIR:-$USER_HOME/dotfiles}"

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
    local svc="$1"
    if [[ -e "/var/service/$svc" || -L "/var/service/$svc" ]]; then
        # Stop the service if runit is live; the || true covers running this
        # in environments where runsvdir is not supervising (e.g. chroot).
        sv down "/var/service/$svc" 2>/dev/null || true
        rm -f "/var/service/$svc"
    fi
}

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
# Snapshot before changes
# ---------------------------------------------------------------------------

if command -v system-snapshot >/dev/null 2>&1; then
    log "Creating paired / + /var snapshot before desktop installation"
    system-snapshot "before-niri-noctalia-desktop"
fi

# ---------------------------------------------------------------------------
# Noctalia repository
# ---------------------------------------------------------------------------

log "Adding the Noctalia-documented Void community repository"
cat > /etc/xbps.d/10-voiders-community.conf <<'EOF'
repository=https://repo.voiders.dev
EOF

warn "The first repository sync asks to trust the repo.voiders.dev RSA key; verify the fingerprint before accepting."
xbps-install -S ||
    die "Syncing the voiders community repository failed; check /etc/xbps.d/10-voiders-community.conf."

# ---------------------------------------------------------------------------
# Core utilities + Niri / session / portals / storage integration
# ---------------------------------------------------------------------------

install_required \
    dbus \
    NetworkManager \
    python3 \
    git \
    curl \
    wget \
    jq \
    unzip \
    xz \
    niri \
    noctalia \
    sdbus-c++ \
    xwayland-satellite \
    xkeyboard-config \
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

# ---------------------------------------------------------------------------
# Audio + Bluetooth
# ---------------------------------------------------------------------------

install_required \
    pipewire \
    wireplumber \
    wireplumber-elogind \
    alsa-pipewire \
    alsa-utils \
    libspa-bluetooth \
    rtkit \
    pulseaudio-utils \
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

install_required \
    tlp \
    tlp-pd \
    tlp-rdw

# TLP owns the actual laptop tuning. tlp-pd provides the power-profile API
# consumed by desktop shells such as Noctalia.
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
# Intel / Mesa graphics
# ---------------------------------------------------------------------------

install_required \
    mesa-dri \
    mesa-vulkan-intel \
    vulkan-loader \
    intel-video-accel \
    glxinfo

# ---------------------------------------------------------------------------
# Applications, Flatpak, GTK helpers and fonts
# ---------------------------------------------------------------------------

install_required \
    alacritty \
    nautilus \
    mpv \
    imv \
    flatpak \
    dconf \
    gsettings-desktop-schemas \
    fontconfig \
    dejavu-fonts-ttf \
    noto-fonts-ttf \
    noto-fonts-emoji \
    font-firacode

# ---------------------------------------------------------------------------
# Source-install dependencies for nwg-look
# ---------------------------------------------------------------------------

if [[ "$INSTALL_NWG_LOOK" == 1 ]]; then
    install_required \
        go \
        gcc \
        make \
        pkg-config \
        gtk+3-devel \
        cairo-devel \
        libglib-devel \
        pango-devel \
        xcur2png
fi

# ---------------------------------------------------------------------------
# adw-gtk3 (upstream release, not XBPS)
# ---------------------------------------------------------------------------

if [[ "$INSTALL_ADW_GTK3" == 1 ]]; then
    log "Installing adw-gtk3 from the latest upstream release"

    THEMES_DIR="$USER_HOME/.local/share/themes"
    TMP_ADW_DIR="$(mktemp -d)"
    ADW_ARCHIVE="$TMP_ADW_DIR/adw-gtk3.tar.xz"

    mkdir -p "$THEMES_DIR"

    ADW_URL="$(
        curl -fsSL https://api.github.com/repos/lassekongo83/adw-gtk3/releases/latest |
        jq -r '[.assets[] | select(.name | startswith("adw-gtk3") and endswith(".tar.xz"))][0].browser_download_url // empty'
    )"

    [[ -n "$ADW_URL" && "$ADW_URL" != "null" ]] ||
        die "Could not determine the latest adw-gtk3 tar.xz release asset."

    curl -fL "$ADW_URL" -o "$ADW_ARCHIVE"

    rm -rf \
        "$THEMES_DIR/adw-gtk3" \
        "$THEMES_DIR/adw-gtk3-dark"

    tar -xJf "$ADW_ARCHIVE" -C "$THEMES_DIR"
    rm -rf "$TMP_ADW_DIR"

    chown -R "$TARGET_USER:$TARGET_USER" \
        "$THEMES_DIR/adw-gtk3" \
        "$THEMES_DIR/adw-gtk3-dark"

    # Upstream recommends these theme extensions for GTK3 Flatpak apps.
    flatpak remote-add --if-not-exists \
        flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo

    flatpak install -y --noninteractive \
        flathub \
        org.gtk.Gtk3theme.adw-gtk3 \
        org.gtk.Gtk3theme.adw-gtk3-dark ||
        warn "Could not install adw-gtk3 Flatpak theme extensions."
fi

# ---------------------------------------------------------------------------
# nwg-look (official upstream source, not XBPS)
# ---------------------------------------------------------------------------

if [[ "$INSTALL_NWG_LOOK" == 1 ]]; then
    log "Building and installing nwg-look from upstream"

    TMP_NWG_DIR="$(mktemp -d)"

    git clone --depth 1 \
        https://github.com/nwg-piotr/nwg-look.git \
        "$TMP_NWG_DIR/nwg-look"

    (
        cd "$TMP_NWG_DIR/nwg-look"
        make build
        make install
    )

    rm -rf "$TMP_NWG_DIR"

    command -v nwg-look >/dev/null 2>&1 ||
        die "nwg-look installation finished but the executable was not found."
fi

# ---------------------------------------------------------------------------
# System services
# ---------------------------------------------------------------------------

log "Enabling system services"

enable_service udevd
enable_service dbus
enable_service NetworkManager
enable_service elogind
enable_service bluetoothd
enable_service tlp
enable_service tlp-pd
enable_service polkitd

if [[ ! -e /run/udev/control ]] && command -v sv >/dev/null 2>&1; then
    sv up udevd
    [[ -e /run/udev/control ]] ||
        die "udevd is not running; elogind and input hotplug require it. Check 'sv status udevd'."
fi

# NetworkManager is the sole network manager.
disable_service dhcpcd
disable_service wpa_supplicant

for grp in audio video input network; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" "$TARGET_USER"
done

# ---------------------------------------------------------------------------
# User directories
# ---------------------------------------------------------------------------

runuser -u "$TARGET_USER" -- \
    env HOME="$USER_HOME" \
    xdg-user-dirs-update || true

mkdir -p \
    "$USER_HOME/.config/niri" \
    "$USER_HOME/.config/noctalia" \
    "$USER_HOME/.config/fontconfig" \
    "$USER_HOME/.config/alacritty" \
    "$USER_HOME/.local/bin" \
    "$USER_HOME/.local/share/fonts"

# ---------------------------------------------------------------------------
# Iosevka Nerd Font
# ---------------------------------------------------------------------------

if [[ "$INSTALL_IOSEVKA_NERD_FONT" == 1 ]]; then
    log "Installing Iosevka Nerd Font"

    TMP_FONT_ZIP="$(mktemp --suffix=.zip)"
    FONT_DIR="$USER_HOME/.local/share/fonts/IosevkaNerdFont"

    mkdir -p "$FONT_DIR"

    curl -fL \
        https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Iosevka.zip \
        -o "$TMP_FONT_ZIP"

    unzip -q -o "$TMP_FONT_ZIP" '*.ttf' -d "$FONT_DIR"
    rm -f "$TMP_FONT_ZIP"

    chown -R "$TARGET_USER:$TARGET_USER" "$FONT_DIR"

    runuser -u "$TARGET_USER" -- \
        env HOME="$USER_HOME" \
        fc-cache -f
fi

# The dotfiles fontconfig prefers Iosevka everywhere (sans-serif, serif and
# monospace aliases); this file matches it, and the Stow step later overwrites
# it with the canonical version anyway. Only written when the font was
# installed, so fontconfig never points at a missing family.
if [[ "$INSTALL_IOSEVKA_NERD_FONT" == 1 ]]; then
    FONT_CONF="$USER_HOME/.config/fontconfig/fonts.conf"

    if [[ -e "$FONT_CONF" ]]; then
        cp -a "$FONT_CONF" \
            "$FONT_CONF.backup.$(date +%Y%m%d-%H%M%S)"
    fi

    cat > "$FONT_CONF" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Iosevka Nerd Font</family>
    </prefer>
  </alias>

  <alias>
    <family>serif</family>
    <prefer>
      <family>Iosevka Nerd Font</family>
    </prefer>
  </alias>

  <alias>
    <family>monospace</family>
    <prefer>
      <family>Iosevka Nerd Font Mono</family>
    </prefer>
  </alias>
</fontconfig>
EOF

    chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config/fontconfig"
fi

# ---------------------------------------------------------------------------
# Flatpak + Brave
# ---------------------------------------------------------------------------

if [[ "$INSTALL_BRAVE" == 1 ]]; then
    log "Installing Brave from Flathub"

    flatpak remote-add --if-not-exists \
        flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo

    flatpak install -y --noninteractive \
        flathub \
        com.brave.Browser
fi

# ---------------------------------------------------------------------------
# Dotfiles repository + machine-specific integration
# ---------------------------------------------------------------------------

if [[ ! -d "$DOTFILES_DIR" && "$APPLY_DOTFILES" == 1 ]]; then
    log "Cloning the dotfiles repository into $DOTFILES_DIR"

    runuser -u "$TARGET_USER" -- \
        env HOME="$USER_HOME" \
        git clone "$DOTFILES_REPO" "$DOTFILES_DIR" ||
        die "Could not clone $DOTFILES_REPO into $DOTFILES_DIR."
fi

if [[ -d "$DOTFILES_DIR" ]]; then
    log "Dotfiles repository found at $DOTFILES_DIR"

    # Stow is required by the dotfiles' own install.sh.
    install_required stow

    # Root packages only: everything else in the setup is a transitive
    # dependency that XBPS resolves on its own. Falls back to the
    # auto-captured manual list when the curated roots file is absent.
    PKG_LIST="$DOTFILES_DIR/packages/xbps-roots.txt"

    if [[ ! -s "$PKG_LIST" ]]; then
        PKG_LIST="$DOTFILES_DIR/packages/xbps-manual.txt"
    fi

    if [[ -s "$PKG_LIST" ]]; then
        mapfile -t DOTFILES_PKGS < <(
            sed -E 's/-[0-9][0-9A-Za-z.+~]*_[0-9]+$//' "$PKG_LIST" |
            sed '/^[[:space:]]*$/d'
        )

        if ((${#DOTFILES_PKGS[@]} > 0)); then
            log "Installing the dotfiles package set (${#DOTFILES_PKGS[@]} roots from $(basename "$PKG_LIST"))"

            if ! xbps-install -Sy "${DOTFILES_PKGS[@]}"; then
                warn "Bulk install failed; retrying package by package."
                FAILED=()
                for PKG in "${DOTFILES_PKGS[@]}"; do
                    xbps-install -Sy "$PKG" || FAILED+=("$PKG")
                done
                if ((${#FAILED[@]} > 0)); then
                    warn "Packages not installed: ${FAILED[*]}"
                fi
            fi
        fi
    else
        warn "No xbps-roots.txt or xbps-manual.txt in $DOTFILES_DIR; skipping the package set."
    fi

    FLATPAK_LIST="$DOTFILES_DIR/packages/flatpak-apps.txt"

    if [[ -s "$FLATPAK_LIST" ]]; then
        log "Installing Flatpak apps from $FLATPAK_LIST"

        flatpak remote-add --if-not-exists \
            flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo

        while IFS= read -r APP_ID; do
            [[ -n "$APP_ID" ]] || continue
            flatpak install -y --noninteractive flathub "$APP_ID" ||
                warn "Could not install Flatpak app: $APP_ID"
        done < "$FLATPAK_LIST"
    fi

    if compgen -G "$DOTFILES_DIR/*.jpg" > /dev/null; then
        log "Installing dotfiles wallpapers"

        WALLPAPER_DIR="$USER_HOME/Pictures/Wallpapers"
        mkdir -p "$WALLPAPER_DIR"
        cp -a "$DOTFILES_DIR"/*.jpg "$WALLPAPER_DIR"/
        chown -R "$TARGET_USER:$TARGET_USER" "$WALLPAPER_DIR"
    fi
else
    warn "DOTFILES_DIR not found at $DOTFILES_DIR; skipping the machine-specific package set."
fi

# Ensure Flatpak desktop files are visible to Noctalia and other launchers
# even on a minimal runit login environment.
PROFILE_MARKER="# --- Flatpak XDG exports (Niri/Noctalia installer) ---"
PROFILE_CONTENT='
# --- Flatpak XDG exports (Niri/Noctalia installer) ---
export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
# --- end Flatpak XDG exports ---'

append_once "$USER_HOME/.profile" "$PROFILE_MARKER" "$PROFILE_CONTENT"
chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.profile"

# ---------------------------------------------------------------------------
# GTK theme defaults
# ---------------------------------------------------------------------------

if [[ "$INSTALL_ADW_GTK3" == 1 ]]; then
    log "Setting adw-gtk3-dark as the GTK theme"

    runuser -u "$TARGET_USER" -- \
        env HOME="$USER_HOME" \
        dbus-run-session -- \
        gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' || true

    runuser -u "$TARGET_USER" -- \
        env HOME="$USER_HOME" \
        dbus-run-session -- \
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
fi

# ---------------------------------------------------------------------------
# Noctalia configuration
# ---------------------------------------------------------------------------

NOCTALIA_CFG="$USER_HOME/.config/noctalia/config.toml"

if [[ -e "$NOCTALIA_CFG" ]]; then
    cp -a "$NOCTALIA_CFG" \
        "${NOCTALIA_CFG}.backup.$(date +%Y%m%d-%H%M%S)"
fi

cat > "$NOCTALIA_CFG" <<'EOF'
[shell]
font_family = "Iosevka Nerd Font Mono"
niri_overview_type_to_launch_enabled = true

[theme]
mode = "dark"
source = "builtin"
builtin = "Noctalia"

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
EOF

# Builtin GTK3/GTK4 and Alacritty theme templates are enabled by default, so
# no templates override file is written.

# ---------------------------------------------------------------------------
# PAM: unlock gnome-keyring on TTY login
# ---------------------------------------------------------------------------

log "Configuring gnome-keyring PAM unlock for TTY login"

# Without PAM integration the keyring stays locked after a TTY login, so
# Brave, Wi-Fi secrets and the session helper's keyring start all prompt or
# fail. The auth line must run after pam_unix (appending keeps that order);
# the session line starts the daemon with the login.
[[ -e /usr/lib/security/pam_gnome_keyring.so ]] ||
    die "gnome-keyring PAM module missing from /usr/lib/security."

LOGIN_PAM=/etc/pam.d/login
touch "$LOGIN_PAM"

append_once "$LOGIN_PAM" "pam_gnome_keyring.so" \
    "auth       optional    pam_gnome_keyring.so"

append_once "$LOGIN_PAM" "pam_gnome_keyring.so auto_start" \
    "session     optional    pam_gnome_keyring.so auto_start"

# ---------------------------------------------------------------------------
# Session helper
# ---------------------------------------------------------------------------

SESSION_HELPER="$USER_HOME/.local/bin/niri-session-services"

cat > "$SESSION_HELPER" <<'EOF'
#!/bin/sh

dbus-update-activation-environment \
    DISPLAY \
    WAYLAND_DISPLAY \
    XDG_CURRENT_DESKTOP \
    XDG_SESSION_DESKTOP \
    XDG_SESSION_TYPE \
    XDG_RUNTIME_DIR \
    XDG_DATA_DIRS 2>/dev/null || true

# Void's PipeWire example snippets start WirePlumber and the PulseAudio
# compatibility server from the main PipeWire process.
USER_UID="$(id -u)"

if ! pgrep -u "$USER_UID" -x pipewire >/dev/null 2>&1; then
    pipewire >/tmp/pipewire-"$USER_UID".log 2>&1 &
fi

i=0
while [ "$i" -lt 50 ] && \
      [ ! -S "${XDG_RUNTIME_DIR:-/run/user/$USER_UID}/pipewire-0" ]; do
    sleep 0.1
    i=$((i + 1))
done

if ! pgrep -u "$USER_UID" -x gnome-keyring-daemon >/dev/null 2>&1; then
    gnome-keyring-daemon \
        --start \
        --components=secrets \
        >/dev/null 2>&1 || true
fi

# --daemon returns after Noctalia has initialized.
noctalia --daemon

# Apply GTK/Alacritty templates selected in ~/.config/noctalia/config.toml.
# Retry briefly until the daemon's IPC is accepting commands.
i=0
while [ "$i" -lt 20 ]; do
    if noctalia msg templates-apply >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
    i=$((i + 1))
done
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
    cp -a "$NIRI_CFG" \
        "${NIRI_CFG}.backup.$(date +%Y%m%d-%H%M%S)"
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
            raise SystemExit(
                f"Niri default config changed; expected text missing: {old!r}"
            )
        return
    text = text.replace(old, new, 1)

# Modify the existing xkb block. Never append a second input {}.
m = re.search(r'(\n\s*xkb\s*\{\s*\n)', text)
if not m:
    raise SystemExit("Could not find xkb block in Niri default config.")

# Match the existing indentation so the inserted lines sit flush with
# whatever depth the default config uses for the xkb block.
indent = re.match(r'\n(\s*)xkb', m.group(1)).group(1)

new_xkb = (
    m.group(1)
    + f'{indent}    layout "br"\n'
    + f'{indent}    variant "thinkpad"\n'
)

text = text[:m.start()] + new_xkb + text[m.end():]

# No Waybar: Noctalia is the desktop shell.
replace_once(
    'spawn-at-startup "waybar"',
    f'spawn-at-startup "{session_helper}"'
)

# Niri's current default terminal is already Alacritty, so no terminal
# replacement is needed.

replace_once(
    'Mod+D hotkey-overlay-title="Run an Application: fuzzel" { spawn "fuzzel"; }',
    'Mod+D hotkey-overlay-title="Application Launcher: Noctalia" { spawn "noctalia" "msg" "panel-toggle" "launcher"; }'
)

replace_once(
    'Super+Alt+L hotkey-overlay-title="Lock the Screen: swaylock" { spawn "swaylock"; }',
    'Super+Alt+L hotkey-overlay-title="Lock: Noctalia" { spawn "noctalia" "msg" "session" "lock"; }'
)

# Multimedia-line formatting changes between Niri releases. These replacements
# are optional because the stock wpctl/brightnessctl bindings still work.
for old, new in {
    'XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+ -l 1.0"; }':
        'XF86AudioRaiseVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-up"; }',

    'XF86AudioLowerVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-"; }':
        'XF86AudioLowerVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-down"; }',

    'XF86MonBrightnessUp allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "+10%"; }':
        'XF86MonBrightnessUp allow-when-locked=true { spawn "noctalia" "msg" "brightness-up"; }',

    'XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "10%-"; }':
        'XF86MonBrightnessDown allow-when-locked=true { spawn "noctalia" "msg" "brightness-down"; }',
}.items():
    replace_once(old, new, required=False)

# The default config pads XF86AudioMute with extra spaces, so match
# whitespace-tolerantly instead of via the exact-string table above.
text, _ = re.subn(
    r'XF86AudioMute\s+allow-when-locked=true \{ spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; \}',
    'XF86AudioMute allow-when-locked=true { spawn "noctalia" "msg" "volume-mute"; }',
    text,
    count=1,
)

# Add Noctalia bindings inside the one existing binds {} block.
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

# Desktop integration.
text += r"""

// Desktop integration added by install-niri-noctalia-secure.sh.
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
    text += '    // Keep normal compositor rendering on Intel.\n'
    text += f'    render-drm-device "{intel_render}"\n'

text += "}\n"

path.write_text(text)
PY

chown -R "$TARGET_USER:$TARGET_USER" \
    "$USER_HOME/.config/niri" \
    "$USER_HOME/.config/noctalia" \
    "$USER_HOME/.config/alacritty" \
    "$USER_HOME/.local"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

log "Validating generated Niri config"

runuser -u "$TARGET_USER" -- \
    env \
        HOME="$USER_HOME" \
        XDG_CONFIG_HOME="$USER_HOME/.config" \
    niri validate ||
    die "niri validate failed; inspect $NIRI_CFG"

if noctalia config validate --help >/dev/null 2>&1; then
    log "Validating Noctalia config"

    runuser -u "$TARGET_USER" -- \
        env \
            HOME="$USER_HOME" \
            XDG_CONFIG_HOME="$USER_HOME/.config" \
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

export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# On runit there is no systemd user manager. Give the graphical session its
# own D-Bus session bus and let Niri perform its normal --session setup.
exec dbus-run-session -- niri --session
EOF

chmod 755 /usr/local/bin/start-niri

# ---------------------------------------------------------------------------
# Default browser
# ---------------------------------------------------------------------------

if [[ "$INSTALL_BRAVE" == 1 ]]; then
    log "Setting Brave as the default browser"

    runuser -u "$TARGET_USER" -- \
        env \
            HOME="$USER_HOME" \
            XDG_DATA_DIRS="$USER_HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share" \
        xdg-mime default com.brave.Browser.desktop text/html || true

    runuser -u "$TARGET_USER" -- \
        env \
            HOME="$USER_HOME" \
            XDG_DATA_DIRS="$USER_HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share" \
        xdg-mime default com.brave.Browser.desktop x-scheme-handler/http || true

    runuser -u "$TARGET_USER" -- \
        env \
            HOME="$USER_HOME" \
            XDG_DATA_DIRS="$USER_HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share" \
        xdg-mime default com.brave.Browser.desktop x-scheme-handler/https || true
fi

# ---------------------------------------------------------------------------
# Dotfiles personal configs (applied last, so they win over the generated ones)
# ---------------------------------------------------------------------------

if [[ -d "$DOTFILES_DIR" && "$APPLY_DOTFILES" == 1 ]]; then
    if [[ -x "$DOTFILES_DIR/install.sh" ]]; then
        log "Applying the dotfiles personal configs (Stow)"

        runuser -u "$TARGET_USER" -- \
            env HOME="$USER_HOME" \
            sh "$DOTFILES_DIR/install.sh" ||
            die "The dotfiles install.sh failed; inspect the output above."
    else
        warn "No install.sh in $DOTFILES_DIR; personal configs were not applied."
    fi
fi

# ---------------------------------------------------------------------------
# Final snapshot
# ---------------------------------------------------------------------------

if command -v system-snapshot >/dev/null 2>&1; then
    log "Creating paired / + /var snapshot after desktop installation"
    system-snapshot "niri-noctalia-desktop-installed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '====================================================================\n'
printf ' NIRI + NOCTALIA INSTALLATION COMPLETE\n'
printf '====================================================================\n\n'

printf 'User:          %s\n' "$TARGET_USER"
printf 'Desktop:       Niri + Noctalia v5\n'
printf 'Terminal:      Alacritty\n'
printf 'Browser:       %s\n' "$([[ "$INSTALL_BRAVE" == 1 ]] && echo 'Brave (Flatpak)' || echo 'not installed')"
printf 'Files:         Nautilus\n'
printf 'Audio:         PipeWire + WirePlumber\n'
printf 'Bluetooth:     BlueZ + PipeWire Bluetooth audio\n'
printf 'Network:       NetworkManager\n'
printf 'Power:         TLP + tlp-pd + tlp-rdw + UPower\n'
printf 'Session:       elogind\n'
printf 'Lock/idle:     Noctalia\n'
printf 'Keyboard:      br(thinkpad)\n'
printf 'Monospace:     Iosevka Nerd Font Mono\n'
printf 'Niri renderer: %s\n' "${INTEL_RENDER_NODE:-automatic}"
if [[ -d "$DOTFILES_DIR" ]]; then
    printf 'Dotfiles:      %s\n' "$([[ "$APPLY_DOTFILES" == 1 ]] &&
        echo "clonados e aplicados ($DOTFILES_DIR)" || echo "clonados em $DOTFILES_DIR (install.sh não rodou)")"
else
    printf 'Dotfiles:      não instalados (DOTFILES_REPO=%s)\n' "$DOTFILES_REPO"
fi
printf '\n'

printf 'After reboot:\n'
printf '  1. Log in on the TTY as %s\n' "$TARGET_USER"
if [[ -d "$DOTFILES_DIR" && "$APPLY_DOTFILES" == 1 ]]; then
    printf '  2. Run: start-niri\n\n'
else
    printf '  2. Run: %s/install.sh (personal configs)\n' "$DOTFILES_DIR"
    printf '  3. Run: start-niri\n\n'
fi

printf 'Useful checks:\n'
printf '  niri validate\n'
printf '  niri msg outputs\n'
printf '  noctalia msg --help\n'
printf '  noctalia theme --list-templates\n'
printf '  fc-match monospace\n'
printf '  wpctl status\n'
printf '  pactl info\n'
printf '  tlp-stat -s\n'
printf '  loginctl hibernate\n\n'

printf 'Notes:\n'
printf '  - No NVIDIA, Steam or virtualization packages were installed.\n'
printf '  - No display manager was installed.\n'
printf '  - Noctalia handles launcher, notifications, lock screen and idle policy.\n'
printf '  - adw-gtk3 is installed from the latest upstream release.\n'
printf '  - nwg-look is built from its official upstream repository.\n'
printf '  - GTK3/GTK4 and Alacritty Noctalia templates are enabled.\n'
