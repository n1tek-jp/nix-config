# sops: 設定ファイルの値を暗号化したまま編集する。鍵の置き場所は user/sops.nix。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.sops ];
    };
}
