# NixOS: 端末の /etc/nixos/configuration.nix（ハードウェア・起動・ユーザー定義）に、
# Home Manager と各レイヤーのコンテキストを重ねる。NixOS 以外の Linux は対象外。
{
  inputs,
  layers,
  userName,
  homeDirectory,
  hostSystem,
}:
let
  shared = import ./shared.nix;
  machineConfiguration = /etc/nixos/configuration.nix;
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
if !builtins.pathExists machineConfiguration then
  throw "/etc/nixos/configuration.nix が見つかりません。Linux は NixOS のみ対応しています"
else
  inputs.nixpkgs.lib.nixosSystem {
    inherit specialArgs;
    modules = [
      machineConfiguration
      inputs.home-manager.nixosModules.home-manager
      shared.system
      {
        nixpkgs.hostPlatform = hostSystem;

        users.users.${userName}.home = homeDirectory;

        home-manager = {
          extraSpecialArgs = specialArgs;
          users.${userName}.imports = [ shared.home ] ++ layers.home;
        };
      }
    ]
    ++ layers.system
    ++ layers.nixos;
  }
