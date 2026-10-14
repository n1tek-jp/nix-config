# macOS と NixOS の両方で使う土台。形はコンテキストと同じ（system / home）。
{
  # nix-darwin の土台が置き換えるファイル（macOS のみ switch が集約する）。
  backupTargets = [
    "/etc/bashrc"
    "/etc/nix/nix.conf"
    "/etc/pam.d/sudo_local"
  ];

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
      imports = [ ./home-options.nix ];

      home = {
        username = userName;
        inherit homeDirectory;
        stateVersion = "26.05";
      };

      programs.home-manager.enable = true;
    };
}
