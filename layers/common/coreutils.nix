# GNU coreutils: g 接頭辞付き（gtail、gdate など）で入れる。macOS 標準の BSD 版のコマンドは隠さない。
# ただし tail は GNU 版（--pid などが使える）を使う。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.coreutils-prefixed ];
      programs.zsh.shellAliases.tail = "gtail";
    };
}
