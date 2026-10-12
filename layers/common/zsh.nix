# zsh: ログインシェルと補完。キーバインドやエイリアスなどの好みは user レイヤーに置く。
{
  home =
    { pkgs, ... }:
    {
      programs.zsh = {
        enable = true;
        enableCompletion = true;

        # 履歴はシェルごとに分ける（macOS 標準の zsh と同じ）。
        history.share = false;
      };

      home.packages = [ pkgs.zsh-completions ];
    };

  # 補完の初期化は Home Manager 側の .zshrc で行うため、/etc/zshrc では行わない。
  system.programs.zsh.enableGlobalCompInit = false;

  # nix-darwin は macOS 標準の /etc/zprofile と /etc/zshrc を置き換えるため、標準の挙動のうち必要なものを残す。
  darwin.programs.zsh = {
    loginShellInit = ''
      if [ -z "$LANG" ]; then
        export LANG=C.UTF-8
      fi
    '';
    interactiveShellInit = ''
      if [[ ! -x /usr/bin/locale ]] || [[ "$(locale LC_CTYPE)" == "UTF-8" ]]; then
        setopt COMBINING_CHARS
      fi
      disable log
      [ -r "/etc/zshrc_$TERM_PROGRAM" ] && . "/etc/zshrc_$TERM_PROGRAM"
    '';
  };

  nixos =
    { pkgs, userName, ... }:
    {
      programs.zsh.enable = true;
      users.users.${userName}.shell = pkgs.zsh;
    };
}
