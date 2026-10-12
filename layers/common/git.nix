# Git: バージョン管理と認証ヘルパー（macOS は Git Credential Manager）。
# 名前とメールアドレスは layers/user/.env.d/git.sops、pull の方式などの好みは user レイヤーに置く。
{
  home =
    { lib, pkgs, ... }:
    {
      programs.git = {
        enable = true;
        settings.credential = {
          # システム側の認証ヘルパーを引き継がないよう空文字でリセットし、macOS では Git Credential Manager を足す。
          # Linux の Git Credential Manager は保存先の設定が要るため、ここでは使わない。
          helper = [
            ""
          ]
          ++ lib.optional pkgs.stdenv.hostPlatform.isDarwin "${pkgs.git-credential-manager}/bin/git-credential-manager";
          "https://dev.azure.com".useHttpPath = true;
        };
      };
    };
}
