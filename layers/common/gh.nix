# GitHub CLI（gh）。github.com への git の認証（https）も gh が受け持ち、Git Credential Manager とキーチェーンを通らない。
# トークンは gh auth login --insecure-storage で ~/.config/gh/hosts.yml（自分だけが読める）に置く（README）。
{
  backupTargets = [
    "~/.config/gh/config.yml"
  ];

  home = {
    programs.gh = {
      enable = true;
      settings.git_protocol = "https";
    };
  };
}
