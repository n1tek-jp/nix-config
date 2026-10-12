# Homebrew: Nixpkgs で扱えない macOS 専用アプリのために使う。本体は事前に手で入れる。
# PATH では Nix で入れたコマンドを優先し、Homebrew は後ろに置く。
{
  darwin = {
    homebrew = {
      enable = true;
      onActivation = {
        autoUpdate = false;
        cleanup = "none";
        upgrade = false;
      };
    };
  };

  home =
    {
      lib,
      pkgs,
      hostSystem,
      ...
    }:
    let
      prefix = if hostSystem == "aarch64-darwin" then "/opt/homebrew" else "/usr/local";
    in
    lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      # Homebrew に残したコマンドの補完（compinit より前に読み込む）。
      programs.zsh.initContent = lib.mkOrder 550 ''
        fpath+=("${prefix}/share/zsh/site-functions")
      '';

      programs.zsh.profileExtra = ''
        export HOMEBREW_PREFIX="${prefix}"
        export HOMEBREW_CELLAR="${prefix}/Cellar"
        export HOMEBREW_REPOSITORY="${if prefix == "/opt/homebrew" then prefix else "${prefix}/Homebrew"}"
        export PATH="$PATH:${prefix}/bin:${prefix}/sbin"
        export MANPATH="''${MANPATH:-}:${prefix}/share/man"
        export INFOPATH="${prefix}/share/info:''${INFOPATH:-}"
      '';
    };
}
