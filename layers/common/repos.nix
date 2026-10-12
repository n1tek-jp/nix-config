# リポジトリを置くディレクトリ（REPOS_ROOT_DIR）。スクリプトやツールがリポジトリの場所を知るために使う。
# 端末ごとに場所を変えられるよう layer.override で包む。
{ layer, ... }:
{
  home = {
    home.sessionVariables.REPOS_ROOT_DIR = layer.override "$HOME/repos";
  };
}
