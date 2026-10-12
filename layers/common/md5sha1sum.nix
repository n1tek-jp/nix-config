# md5sum / sha1sum: macOS に無い GNU 互換のハッシュコマンド。
# Nixpkgs に md5sha1sum が無いため、GNU coreutils の同名コマンドだけを PATH に置く。
{
  home =
    { lib, pkgs, ... }:
    let
      hashCommands = pkgs.runCommand "md5sha1sum" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.coreutils}/bin/md5sum ${pkgs.coreutils}/bin/sha1sum $out/bin/
      '';
    in
    {
      home.packages = lib.optional pkgs.stdenv.hostPlatform.isDarwin hashCommands;
    };
}
