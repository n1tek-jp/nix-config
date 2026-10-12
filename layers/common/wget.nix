# wget: HTTP でファイルを取得する。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.wget ];
    };
}
