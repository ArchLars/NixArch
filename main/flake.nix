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

    # Theming
    stylix.url = "github:danth/stylix";
  };

  outputs = inputs@{ self,
                     nixpkgs,
                     nixpkgs-unstable,
                     home-manager,
                     nixGL,
                     stylix,
                     ... }:
    let
      system = "x86_64-linux";

      # Stable channel
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # Unstable channel exposed via `unstable`
      unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      homeManagerConfigurations = {
        lars = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          # Pass extra inputs to the Home‑Manager modules
          extraSpecialArgs = {
            inherit unstable;
            stylixLib = stylix.lib;
          };

          modules = [
            ./home.nix
            nixGL.homeManagerModules.default
            stylix.homeManagerModules.stylix
          ];
        };
      };
    };
}
