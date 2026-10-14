# VS Code: 本体と、統合ターミナルのシェル統合。設定と拡張機能の選択は好みなので user レイヤーに置く。
# 本体の更新は Nix で行うため、VS Code 自身の更新確認は止める。
{
  backupTargets = [
    "~/.vscode/argv.json"
    "~/Library/Application Support/Code/User/settings.json"
    "~/.config/Code/User/settings.json"
  ];

  system.nixpkgs.config.allowUnfreePackages = [ "vscode" ];

  home = {
    programs.vscode = {
      enable = true;
      profiles.default.enableUpdateCheck = false;
    };

    programs.zsh.initContent = ''
      if [[ "$TERM_PROGRAM" == "vscode" ]]; then
          . "$(code --locate-shell-integration-path zsh)" 2>/dev/null
      fi
    '';
  };
}
