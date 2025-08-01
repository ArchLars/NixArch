{ pkgs, unstable, stylixLib, config, lib, ... }:

{
  home.username      = "lars";
  home.homeDirectory = "/home/lars";
  home.stateVersion  = "24.05";
  programs.home-manager.enable = true;

  ## Core desktop packages (Plasma 6 Wayland)
  home.packages = with unstable; [
    kdePackages.plasma-desktop
    kdePackages.konsole
    kdePackages.dolphin
    kdePackages.sddm
    kdePackages.kwayland-integration
    kdePackages.xdg-desktop-portal-kde
    qt6.qtwayland
    qt5.qtwayland
    firefox
    thunderbird
  ];

  # ---- Wayland‑specific session variables -----------------------------
  home.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";   # Firefox native Wayland
    NIXOS_OZONE_WL     = "1";   # Electron/Chromium Wayland
    QT_QPA_PLATFORM    = "wayland;xcb"; # Fallback to X11 if needed
  };

  # ---- GPU integration -------------------------------------------------
  programs.konsole.package = config.lib.nixGL.wrap pkgs.konsole;
  programs.firefox.package = config.lib.nixGL.wrap pkgs.firefox;
  nixGL.defaultWrapper = "nvidia";   # choose "nvidia" or "mesa"
    "store --file ${config.age.secrets.githubToken.path}";

  # ---- Theming ---------------------------------------------------------
  stylix = {
    autoEnable  = true;
    colorScheme = stylixLib.colorSchemes.catppuccin-latte;
    fonts = {
      monospace = {
        package = pkgs.fira-code-nerd-font;
        name    = "FiraCode Nerd Font";
      };
      sansSerif = {
        package = pkgs.inter;
        name    = "Inter";
      };
    };
  };

  # ---- Shell & prompt --------------------------------------------------
  programs.zsh = {
    enable               = true;
    enableCompletion     = true;
    syntaxHighlighting.enable = true;
    autocd               = true;

    zplug.enable = true;
    zplug.plugins = [
      { name = "zsh-users/zsh-autosuggestions"; }
      { name = "zsh-users/zsh-completions";    }
    ];
  };

  # ---- Utilities -------------------------------------------------------
  programs.nix-index.enable = true;
  services.kdeconnect.enable = true;  # Picom removed; only KDE Connect

  # ---- nix‑ld for proprietary binaries --------------------------------
  programs.nix-ld.enable    = true;
  programs.nix-ld.libraries = with pkgs; [ glibc openssl ffmpeg ];
}
