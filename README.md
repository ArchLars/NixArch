# NixArch: Hybrid Arch Linux + Nix Flakes Desktop

---

## Overview

This guide describes a reproducible hybrid setup in which **Arch Linux** manages the base system (kernel, drivers, boot‑loader, low‑level services) and **Nix (with flakes) + Home Manager** manages the user‑level graphical environment, applications, and dotfiles. The system hostname is `NixArch`.

**Key characteristics**

- **Base system:** Arch Linux (minimal installation)
- **Desktop/user layer:** Nix flakes (multi‑user) with Home Manager
- **Package source for userland:** `nixpkgs‑unstable`
- **GPU integration:** nixGL (Nvidia wrapper)
- **Username assumed:** `lars`

> After the first reboot, running `home-manager switch` builds and activates KDE Plasma, Konsole, Dolphin, SDDM, and other desktop components from Nix; the underlying kernel, drivers, and core services remain Arch‑managed.

---

## 1  Prepare Arch Linux (live ISO)

1. Create a GPT partition table with three partitions AFTER checking your drive name with `lsblk -l` :

```bash
sgdisk --zap-all \
    -n1:0:+1G  -t1:EF00 -c1:"EFI system" \
    -n2:0:+40G -t2:8304 -c2:"Linux root (x86-64)" \
    -n3:0:0    -t3:8302 -c3:"Linux home" \
    /dev/nvme0n1
```

**Partition Layout:**

* `/dev/nvme0n1p1` — 1GB EFI System Partition
* `/dev/nvme0n1p2` — 40GB Root partition
* `/dev/nvme0n1p3` — Remaining space for Home partition



2. Create filesystems and mount them in the correct order:

```bash
# Format partitions
d=/dev/nvme0n1
mkfs.fat -F32 -n EFI ${d}p1 && \
mkfs.ext4 -L root ${d}p2 && \
mkfs.ext4 -L home ${d}p3

# Mount root partition first
mount /dev/disk/by-label/root /mnt

# Create and mount EFI directory
mkdir -p /mnt/boot
mount /dev/disk/by-label/EFI /mnt/boot

# Create and mount home directory
mkdir /mnt/home
mount /dev/disk/by-label/home /mnt/home
```

  
3. Update mirrorlist for optimal download speeds and install the base system, obv replace Norway and Germany:

```bash
# Update mirrorlist with fastest mirrors
reflector --country Norway --country Germany --age 12 --protocol https --sort age --save /etc/pacman.d/mirrorlist

# Install minimal base system
pacstrap /mnt base linux-zen linux-firmware amd-ucode nano sudo zsh
```



arch-chroot /mnt


4. Set Timezone

```bash
# Set timezone to Oslo (Norway)
ln -sf /usr/share/zoneinfo/Europe/Oslo /etc/localtime
# Set hardware clock
hwclock --systohc
```

5. Configure Locale

```bash
# Edit locale generation file
nano /etc/locale.gen
Uncomment: en_US.UTF-8 UTF-8
Uncomment: nb_NO.UTF-8 UTF-8 # Optional if you need second language

# Generate locales
locale-gen

# Set system locale
cat << EOF > /etc/locale.conf
LANG=en_US.UTF-8
LC_TIME=nb_NO.UTF-8 # Optional if you want to set the date & time to a specific LANG default
EOF

# Set console keymap. This even U.S keyboards has to set!
echo "KEYMAP=no-latin1" > /etc/vconsole.conf 

# Persist configure X11 keymap for non U.S keyboards
cat << EOF > /etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "no"
    Option "XkbModel" "pc105"
EndSection
EOF
```

6. Set Hostname and Hosts

```bash
# Set hostname
echo "NixArch" > /etc/hostname

# Configure hosts file
cat << EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   NixArch.localdomain NixArch
EOF
```

7. Create User Account

```bash
# Set root password
passwd

# Create user with necessary groups
useradd -m -G wheel,audio,video,input lars
passwd lars

# Set zsh as default shell for user and root
chsh -s /usr/bin/zsh lars
chsh -s /usr/bin/zsh

# Enable sudo for wheel group
EDITOR=nano visudo
# Uncomment: %wheel ALL=(ALL:ALL) ALL
```

8. Install System Packages & Drivers

```bash
# Update package database
pacman -Syu
```

# Install essential packages

1. Install the remaining Arch‑managed prerequisites (networking, audio stack, drivers, development tooling):
   ```bash
   pacman -S --needed \
     networkmanager \
     pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
     linux-zen-headers \
     nvidia-open-dkms nvidia-utils \
     zram-generator pacman-contrib \
     git wget \
     base-devel
   ```


Configure NVIDIA in Initramfs

```bash
# Edit mkinitcpio configuration
nano /etc/mkinitcpio.conf
# MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
# Remove 'kms' from HOOKS=()
# Remove 'base' and 'udev' from HOOKS=() and add 'systemd'
(!IMPORTANT! - Otherwise your system won't boot!)

# Regenerate initramfs
mkinitcpio -P
```

Install and Configure Bootloader

```bash
# Install systemd-boot
bootctl install

# Configure bootloader
cat << EOF > /boot/loader/loader.conf
default arch
timeout 10
console-mode max
editor no
EOF

# Create boot entry
cat << EOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options rw quiet loglevel=3
EOF
```

Configure Zram (Compressed Swap)

```bash
# Configure zram
cat << EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
```

```bash
# Optimizing swap on zram
cat << EOF > /etc/sysctl.d/99-vm-zram-parameters.conf
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
```

 Enable Essential Services

```bash
# Enable network and timesyncd
systemctl enable NetworkManager systemd-timesyncd systemd-boot-update.service
```

---

Exit the chroot, unmount, and reboot:

```bash
exit
umount -R /mnt
reboot
```

---

## 3  Install Nix (multi‑user, flakes enabled)

Install Nix with the daemon (recommended for multi‑user):

```bash
curl -L https://nixos.org/nix/install | sh -s -- --daemon
```

> The Determinate Systems installer is an alternative that enables flakes and other modern defaults automatically. See its documentation for CI‑friendly installation behaviour.

Enable flakes and the new Nix command explicitly:

```bash
sudo mkdir -p /etc/nix
echo 'experimental-features = nix-command flakes' | sudo tee -a /etc/nix/nix.conf
sudo systemctl enable --now nix-daemon.service
```

Reload your shell environment so `nix` is on `PATH` (e.g. `exec $SHELL -l` or re‑login on the TTY).

---

## 4  Bootstrap Home Manager via flake

```bash
nix run home-manager/master -- init --switch
```

This generates `~/.config/home-manager/flake.nix` and `home.nix` and bootstraps an initial config.

### 4.1  `flake.nix`

The example below includes all auxiliary inputs referenced later in this guide (nixGL, Stylix, Agenix, treefmt‑nix, etc.):

```nix
{
  description = "Home configuration for lars on Arch";

  inputs = {
    nixpkgs.url          = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # GPU wrapper
    nixGL.url = "github:nix-community/nixGL";

    # Secret management
    agenix.url = "github:ryantm/agenix";

    # Theming
    stylix.url = "github:danth/stylix";

    # Tree‑wide formatter orchestration
    treefmt-nix.url = "github:numtide/treefmt-nix";

    # Optional: flake‑parts for modularisation
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager
            , nixGL, agenix, stylix, treefmt-nix, ... }@inputs:
    let
      system   = "x86_64-linux";
      pkgs     = import nixpkgs { inherit system; config.allowUnfree = true; };
      unstable = import nixpkgs-unstable { inherit system; config.allowUnfree = true; };
    in {
      homeManagerConfigurations.lars =
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = { inherit unstable; };

          modules = [
            ./home.nix
            nixGL.homeModules.default       # GPU wrappers
            stylix.homeManagerModules.stylix # Theming
            agenix.homeManagerModules.default # Secret management
          ];
        };

      ## Optional formatter preset (run: `nix fmt`)
      formatter = pkgs.alejandra;

      ## treefmt orchestrates multi‑language formatters
      checks.treefmt = treefmt-nix.lib.mkCheck { inherit pkgs; };
    };
}
```

### 4.2  `home.nix`

Below is an updated `home.nix` that enables KDE **Wayland** by default, removes the X11‑only Picom compositor, and sets session variables so Firefox, Electron/Chromium apps, and Qt automatically run natively on Wayland.

```nix
{ pkgs, unstable, config, lib, ... }:

{
  home.username      = "lars";
  home.homeDirectory = "/home/lars";
  home.stateVersion  = "24.05";
  programs.home-manager.enable = true;

  ## Core desktop packages (Plasma 6 Wayland)
  home.packages =
    (with unstable; [
      kdePackages.plasma-desktop       # pulls kwin‑wayland
      kdePackages.konsole
      kdePackages.dolphin
      kdePackages.sddm
      kdePackages.kwayland-integration # extra Wayland libs
      kdePackages.xdg-desktop-portal-kde
      qt6.qtwayland qt5.qtwayland      # Qt Wayland platform plugins
      firefox thunderbird
    ]) ++ (with pkgs; [
      statix nix-diff nvd nixfmt-rfc-style
    ]);

  # ---- Wayland‑specific session variables -----------------------------
  home.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";  # Firefox native Wayland
    NIXOS_OZONE_WL     = "1";  # Electron/Chromium Wayland
    QT_QPA_PLATFORM    = "wayland;xcb"; # fallback to X11 if needed
  };

  # ---- GPU integration -------------------------------------------------
  programs.konsole.package = config.lib.nixGL.wrap pkgs.konsole;
  programs.firefox.package = config.lib.nixGL.wrap pkgs.firefox;
  nixGL.defaultWrapper = "nvidia";   # choose "nvidia" or "mesa"

  # ---- Secrets ---------------------------------------------------------
  age.secrets.githubToken.file = "secrets/github_token.age";
  programs.git.extraConfig.credential.helper =
    "store --file ${config.age.secrets.githubToken.path}";

  # ---- Theming ---------------------------------------------------------
  stylix = {
    autoEnable  = true;
    colorScheme = stylix.colorSchemes.catppuccin-latte;
    fonts = {
      monospace = { package = pkgs.fira-code-nerd-font; name = "FiraCode Nerd Font"; };
      sansSerif = { package = pkgs.inter;               name = "Inter"; };
    };
  };

  # ---- Development conveniences ---------------------------------------
  programs.direnv.enable            = true;
  programs.direnv.nix-direnv.enable = true;
  programs.nix-index.enable         = true;  # `command-not-found` hook

  # ---- Shell & prompt --------------------------------------------------
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    syntaxHighlighting.enable = true;
    autocd = true;
    zplug.enable = true;
    zplug.plugins = [
      { name = "zsh-users/zsh-autosuggestions"; }
      { name = "zsh-users/zsh-completions";    }
    ];
  };
  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_state$git_status$nodejs$rust$golang$cmd_duration$line_break$character";
    };
  };

  # ---- Utilities -------------------------------------------------------
  services.kdeconnect.enable = true;  # was combined with Picom section; Picom removed

  # ---- nix‑ld for proprietary binaries --------------------------------
  programs.nix-ld.enable    = true;
  programs.nix-ld.libraries = with pkgs; [ glibc openssl ffmpeg ];
}
```

> **Choose the Wayland session:** At the SDDM login screen, select **“Plasma (Wayland)”**. Once you confirm it works, you can set it as the default session under *Startup ‑› Login Screen (SDDM) ‑› Behaviour*.

### 4.3  Pulling existing configs from GitHub

If you already have initial `flake.nix` and `home.nix` generated locally and want to replace or keep them in sync with the remote repository `ArchLars/NixArch`, fetch them directly:

```bash
# Clone the repo once (or pull to update)
git clone git@github.com:ArchLars/NixArch.git ~/NixArch || (cd ~/NixArch && git pull)

# Overwrite the generated configs with the ones from GitHub
curl -L -o ~/.config/home-manager/flake.nix https://raw.githubusercontent.com/ArchLars/NixArch/main/flake.nix
curl -L -o ~/.config/home-manager/home.nix https://raw.githubusercontent.com/ArchLars/NixArch/main/home.nix

# Apply the updated configuration
home-manager switch
```

To automate future replacements, you can script it, for example:

```bash
#!/usr/bin/env bash
set -e
cd ~
curl -L -o ~/.config/home-manager/flake.nix https://raw.githubusercontent.com/ArchLars/NixArch/main/flake.nix
curl -L -o ~/.config/home-manager/home.nix https://raw.githubusercontent.com/ArchLars/NixArch/main/home.nix
home-manager switch
```

If you intend to push local changes back to the repository, set up the remote and commit:

```bash
cd ~/NixArch
git remote add origin git@github.com:ArchLars/NixArch.git  # or use HTTPS: https://github.com/ArchLars/NixArch.git
git fetch
git add flake.nix home.nix
git commit -m "Sync generated Home Manager configs"
git push origin main
```

For authenticated pushes over HTTPS, store a GitHub personal access token securely; if you use age-encrypted secrets, decrypt it in a script and export it for git credential helper use.

Activate the configuration:

```bash
home-manager switch
```

Enable SDDM (its unit file lives in the Nix store and must be explicitly enabled):

```bash
sudo systemctl enable sddm.service
```

---

## 5  Daily workflow

| Task                                  | Command                                              |
| ------------------------------------- | ---------------------------------------------------- |
| Update user environment               | `nix flake update && home-manager switch`            |
| Add/remove a package                  | edit `home.nix` → `home-manager switch`              |
| Fast package search                   | `nix-locate -w bin/hledger`                          |
| Rollback to previous generation       | `home-manager generations` → `home-manager rollback` |

---

## 6  Binary caches

Pre‑built binaries save substantial build time. Add additional caches to `/etc/nix/nix.conf` *before* large updates:

```ini
substituters        = https://cache.nixos.org https://nix-community.cachix.org
trusted-public-keys = cache.nixos.org-1:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
                      nix-community.cachix.org-1:yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
```

Other recommended caches include *FlakeHub* and *Determinate Systems*.

---

