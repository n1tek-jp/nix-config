# uv: Python の処理系・パッケージ管理。uv tool install で入れたコマンドは ~/.local/bin に置かれる。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.uv ];
      home.sessionPath = [ "$HOME/.local/bin" ];
    };

  # uv が取得する Python は汎用 Linux 向けのビルド済みバイナリなので、NixOS では nix-ld が無いと起動しない。
  nixos.programs.nix-ld.enable = true;
}
