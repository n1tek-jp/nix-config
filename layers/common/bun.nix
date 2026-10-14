# Bun: JavaScript / TypeScript の実行環境・パッケージ管理。bun install -g で入れたコマンドは ~/.bun/bin に置かれる。
{
  backupTargets = [
    "~/.bun/bin/bun"
    "~/.bun/bin/bunx"
  ];

  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.bun ];
      home.sessionVariables.BUN_INSTALL = "$HOME/.bun";
      home.sessionPath = [ "$HOME/.bun/bin" ];
    };
}
