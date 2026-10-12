# macOS と NixOS の両方で使う土台。形はコンテキストと同じ（system / home）。
{
  # unfree のパッケージは、使うコンテキストが system.nixpkgs.config.allowUnfreePackages に名前を足して許可する。
  system = {
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      # dotfiles などが置いた既存ファイルは、上書きせずにこの拡張子を付けて退避する。
      backupFileExtension = "before-nix-config";
    };
  };

  home =
    { userName, homeDirectory, ... }:
    {
      home = {
        username = userName;
        inherit homeDirectory;
        stateVersion = "26.05";
      };

      programs.home-manager.enable = true;
    };
}
