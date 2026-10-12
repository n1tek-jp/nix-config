# jq: JSON を加工する。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.jq ];
    };
}
