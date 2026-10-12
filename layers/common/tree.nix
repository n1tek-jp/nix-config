# tree: ディレクトリ構造を表示する。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.tree ];
    };
}
