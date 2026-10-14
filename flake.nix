{
  description = "Layered Nix configuration for macOS and NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ nixpkgs, ... }:
    let
      requireEnv =
        name:
        let
          value = builtins.getEnv name;
        in
        if value == "" then throw "Environment variable ${name} is required; run ./switch" else value;

      userName = requireEnv "NIX_CONFIG_USER";
      homeDirectory = requireEnv "NIX_CONFIG_HOME";
      hostSystem = requireEnv "NIX_CONFIG_SYSTEM";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${hostSystem};
      layers = import ./bootstrap/layers.nix {
        inherit lib;
        root = ./.;
      };
      bootstrapArgs = {
        inherit
          inputs
          layers
          userName
          homeDirectory
          hostSystem
          ;
      };

      platformOutputs =
        if lib.hasSuffix "-darwin" hostSystem then
          { darwinConfigurations.default = import ./bootstrap/darwin-bootstrap.nix bootstrapArgs; }
        else if lib.hasSuffix "-linux" hostSystem then
          { nixosConfigurations.default = import ./bootstrap/linux-bootstrap.nix bootstrapArgs; }
        else
          throw "Unsupported Nix system: ${hostSystem}";
    in
    {
      # switch は公開設定とパスだけを評価する。鍵本体や復号結果は読まない。
      switchConfig = {
        inherit (layers) secrets;
        backupTargets = lib.unique (
          layers.backupTargets
          ++ lib.optionals (lib.hasSuffix "-darwin" hostSystem) (import ./bootstrap/shared.nix).backupTargets
        );
      };
      formatter.${hostSystem} = pkgs.nixfmt;
      packages.${hostSystem}.secret-tools = pkgs.symlinkJoin {
        name = "nix-config-secret-tools";
        paths = [
          pkgs.sops
          pkgs.age
          pkgs.age-plugin-yubikey
        ];
      };
    }
    // platformOutputs;
}
