# Docker: コンテナを操作する docker CLI（compose と buildx のプラグインを含む）。実行環境（Colima など）は user レイヤーで選ぶ。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.docker-client ];
    };
}
