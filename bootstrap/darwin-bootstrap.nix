# macOS: nix-darwin に Home Manager を組み込み、各レイヤーのコンテキストを読み込む。
{
  inputs,
  layers,
  userName,
  homeDirectory,
  hostSystem,
}:
let
  shared = import ./shared.nix;
  specialArgs = {
    inherit
      inputs
      userName
      homeDirectory
      hostSystem
      ;
    inherit (layers) envSecrets localValues;
  };
in
inputs.nix-darwin.lib.darwinSystem {
  inherit specialArgs;
  modules = [
    inputs.home-manager.darwinModules.home-manager
    shared.system
    {
      nixpkgs.hostPlatform = hostSystem;

      system = {
        primaryUser = userName;
        stateVersion = 7;
      };

      users.users.${userName}.home = homeDirectory;

      home-manager = {
        extraSpecialArgs = specialArgs;
        users.${userName}.imports = [ shared.home ] ++ layers.home;
      };
    }
  ]
  ++ layers.system
  ++ layers.darwin;
}
