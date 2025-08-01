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

1. Partition and format disks (following your existing “archtutorial”). Mount the target root under `/mnt`.
2. Install the minimal base system:
   ```bash
   pacstrap /mnt base linux linux-firmware amd-ucode nano sudo zsh
   ```
3. Install the remaining Arch‑managed prerequisites (networking, audio stack, drivers, development tooling):
   ```bash
   pacman -S --needed \
     networkmanager \
     pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
     linux-headers \
     nvidia-open nvidia-utils \
     zram-generator pacman-contrib \
     git wget \
     base-devel
   ```
   *Everything else (display manager, desktop environment, graphical applications) is supplied by Nix.*
4. Generate `fstab`:
   ```bash
   genfstab -U /mnt >> /mnt/etc/fstab
   ```

---

## 2  Chroot and core configuration

```bash
arch-chroot /mnt

# Time and locale
ln -sf /usr/share/zoneinfo/Europe/Oslo /etc/localtime
hwclock --systohc
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname and hosts
echo "NixArch" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   NixArch.localdomain NixArch
EOF

# User setup
passwd                      # set root password
useradd -m -G wheel,audio,video,input lars
passwd lars
chsh -s /usr/bin/zsh lars
EDITOR=nano visudo          # uncomment: %wheel ALL=(ALL) ALL
```

Enable essential services:

```bash
systemctl enable NetworkManager systemd-timesyncd
```

Optional: configure zram swap for performance:

```bash
cat <<EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
systemctl enable systemd-zram-setup@zram0.service
```

Install and configure the bootloader (example: systemd‑boot):

```bash
bootctl install
cat <<EOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options rw quiet
EOF
```

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
    image       = ./wallpapers/nixarch-latte.png;
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
| Create per‑project dev shell (direnv) | `echo "use nix" > .envrc && direnv allow`            |
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

## 7  Debugging and auditing changes

### 7.1  nix‑diff

```bash
nix build .#homeConfigurations.lars.activationPackage --profile old
# make a change…
nix build .#homeConfigurations.lars.activationPackage --profile new
nix run nixpkgs#nix-diff -- ./old ./newhybrid Arch Linux + Nix flake
```

### 7.2  nvd

```bash
nvd diff result-1 result-2
```

---

## 8  Continuous Integration (GitHub Actions)

```yaml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - uses: DeterminateSystems/nix-installer-action@v9
      - run: nix flake check
      - run: nix fmt -- --check
```

Add extra jobs, such as building the activation package, to guarantee the flake stays buildable.

---

## 9  Running non‑Nix binaries

With `programs.nix-ld.enable = true;` proprietary applications unpacked under `$HOME/.local/opt` can often be executed directly:

```bash
./some-game.AppImage  # links resolved via nix-ld wrapper
```

Prefer packaged software when available.

---

## 10  Future directions

- **flake‑parts:** split the Home Manager config into reusable modules.
- **Machine variants:** add laptop/desktop or workstation profiles.
- **treefmt:** run `nix develop` → `treefmt` to auto‑format the whole repository.
- **Agenix:** migrate all API keys and private files out of Git to encrypted `.age` files.
- **Virtualised reviews:** use `nix build .#vm` to test contributions in ephemeral VMs before merging.

---


hybrid Arch Linux + Nix flake
