# voidinstall — Secure Void Linux installation pipeline

Fully scripted, reproducible Void Linux installation for one specific machine
(Lenovo ThinkPad P15 Gen 1, x86_64 glibc, UEFI). Three layers, run in order:

| # | Script | Layer | Where it runs |
|---|--------|-------|---------------|
| 1 | `install-void-secure-btrfs.sh` | Disk, LUKS, Btrfs, Secure Boot, base system, user | Void **live ISO** |
| 2 | `install-niri-noctalia-secure.sh` | Desktop: Niri + Noctalia v5, audio, power, **dotfiles** | Installed system (TTY, via `sudo`) |
| 3 | `install-nvidia-secure.sh` | NVIDIA dGPU driver (DKMS + Secure Boot signing) | Installed system (TTY, via `sudo`) |

The end state is the session defined by the
[dotfiles](https://github.com/vitoraalmeida/dotfiles) repository: niri +
Noctalia with the personal Stow-managed configs applied on top.

## Execution order

```
Void live ISO (UEFI mode)
  └── 1. install-void-secure-btrfs.sh      erases the target disk
         └── reboot → TTY login (br-abnt2)
                └── (Wi-Fi? run `nmtui` first)
                └── 2. install-niri-noctalia-secure.sh
                       └── reboot → TTY login → `start-niri`
                             └── 3. install-nvidia-secure.sh   (optional, dGPU)
```

### 1. Base system — `install-void-secure-btrfs.sh`

Run from the official Void x86_64 glibc live ISO booted in UEFI mode:

```sh
DISK=/dev/nvme0n1 USERNAME=user HOSTNAME=host \
TIMEZONE=America/Bahia ./install-void-secure-btrfs.sh
```

What it does:

- GPT with 1 GiB plaintext ESP + LUKS1 covering the rest of the disk
- Btrfs subvolumes: `@` `/`, `@home`, `@var`, `@snapshots`, `@var_snapshots`, `@swap`
- Encrypted `/boot`, signed standalone GRUB EFI, custom Secure Boot
  PK/KEK/db keys (first boot with Secure Boot **disabled**)
- Encrypted swapfile sized to RAM + hibernation (`resume`/`resume_offset`)
- Snapper with paired `/` + `/var` snapshots and hourly timeline
- NetworkManager, cronie, br-abnt2 keyboard (incl. ThinkPad `/` key fix)
- Admin user with wheel/sudo (`USERNAME` defaults to `user`)

A fully non-interactive variant exists (`ASSUME_ERASE=yes` + the three
password variables) — see the header of the script.

After the first boot validates, follow the printed checklist: back up
`/root/secureboot-keys` to encrypted offline media, then enroll PK/KEK/db in
ThinkPad UEFI Custom Secure Boot mode.

### 2. Desktop layer — `install-niri-noctalia-secure.sh`

```sh
sudo ./install-niri-noctalia-secure.sh
```

What it does, in order:

1. Pre-install paired snapper snapshot
2. Adds the `repo.voiders.dev` community repository (Noctalia)
3. Installs Niri, Noctalia v5, PipeWire/WirePlumber, portals, elogind, TLP,
   Intel/Mesa graphics, GNOME keyring PAM integration
4. Installs **Iosevka Nerd Font** (matches the dotfiles configs) and writes a
   matching `fontconfig/fonts.conf`
5. **Dotfiles integration** (if `~/dotfiles` is absent it is cloned from
   `DOTFILES_REPO`, default `https://github.com/vitoraalmeida/dotfiles.git`):
   - installs `stow` + every package from `packages/xbps-manual.txt`
   - installs every Flatpak app from `packages/flatpak-apps.txt`
   - copies the wallpapers into `~/Pictures/Wallpapers`
6. Writes the Noctalia config, the `niri-session-services` helper, generates
   `~/.config/niri/config.kdl` from the installed niri default (Intel render
   node auto-detected, br(thinkpad) layout, Noctalia bindings) and validates it
7. Installs `/usr/local/bin/start-niri` (TTY launcher, `dbus-run-session`)
8. **Runs `~/dotfiles/install.sh` as the user** — the personal Stow configs
   are applied last, so they win over everything generated above
9. Final paired snapper snapshot

Optional environment variables: `INSTALL_BRAVE`, `INSTALL_IOSEVKA_NERD_FONT`,
`INSTALL_ADW_GTK3`, `INSTALL_NWG_LOOK`, `FORCE_INTEL_RENDERER`, `DOTFILES_DIR`,
`DOTFILES_REPO`, `APPLY_DOTFILES=0` (skip the clone + Stow step).

After it finishes: reboot, log in on the TTY, run `start-niri`.

### 3. NVIDIA layer — `install-nvidia-secure.sh`

```sh
sudo ./install-nvidia-secure.sh
```

Installs the NVIDIA driver via DKMS from the nonfree repo, signs the modules
with the Secure Boot db key, blacklists nouveau, enables `nvidia-drm
modeset` and RTD3 runtime power management, and coordinates with TLP.
The compositor stays on the Intel GPU (battery life); dGPU apps use
`prime-run <command>`. Reboot required.

Notes for this machine:

- Keep the default `NVIDIA_COMPOSITOR=0`. The dotfiles pin niri to the Intel
  render node in `niri/.config/niri/gpu-mode.kdl` (with `hdmi`/`vfio`
  alternatives in `gpu-modes/`, switchable via the `gpu-mode` script).
- With `NVIDIA_COMPOSITOR=1` the script rewrites `~/.config/niri/config.kdl`,
  which after the dotfiles step is a Stow symlink **into the dotfiles repo** —
  the edit would land in the repository. If you ever want it, run the dotfiles
  `update.sh` + commit afterwards, or edit `gpu-mode.kdl` instead.
- Inside a QEMU/KVM VM (GPU passthrough) RTD3 is auto-disabled; see the script
  header for the required VM configuration (both GPU functions as VFIO
  hostdevs, USB by vendor/product, UEFI firmware).

## System snapshots and rollback

Installed by the base script:

```sh
sudo snapper --no-dbus -c root list      # list snapshots
sudo system-snapshot "before change"     # manual paired / + /var snapshot
sudo xbps-snapshot-update                # snapshot → update → re-sign GRUB → snapshot
```

`/` and `/var` are always snapshotted together (XBPS database lives in
`/var/db/xbps`). `/home` is intentionally independent — the dotfiles are its
backup strategy (git).

## Dotfiles maintenance loop

Once the machine is up, day-to-day changes happen in `~/dotfiles`:

```sh
# edit configs live (~/.config/... are Stow symlinks into the repo), then:
~/dotfiles/update.sh                     # live state → repo (packages, dconf, noctalia state)
git -C ~/dotfiles add -A && git -C ~/dotfiles commit -m "..." && git -C ~/dotfiles push
```

To roll the machine back to a previous state: `git reset --hard <hash>` in
`~/dotfiles` (or `git checkout <hash> -- <path>`), then re-run
`~/dotfiles/install.sh` to reapply, then `sudo xbps-install` as needed for
package-list changes.
