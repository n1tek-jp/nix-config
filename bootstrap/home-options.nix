# 秘密は実行時にファイルから読み込む。Nix が評価するのは名前、パス、公開テンプレートだけ。
{
  config,
  lib,
  pkgs,
  envSecrets,
  homeDirectory,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.nixConfig;
  valueType = types.submodule {
    options = {
      secret = mkOption {
        type = types.str;
        description = "envSecrets の設定名。key がなければファイル全体を使う。";
      };
      key = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "復号した JSON オブジェクトから読むトップレベルのキー。";
      };
    };
  };
  templateType = types.submodule {
    options = {
      target = mkOption {
        type = types.str;
        description = "ホームからの相対パス。実行時に通常ファイルとして生成する。";
      };
      format = mkOption {
        type = types.enum [
          "json"
          "text"
        ];
        default = "json";
        description = "json は値を JSON エスケープし、完成後の構文も確認する。";
      };
      content = mkOption {
        type = types.lines;
        description = "公開テンプレート。@名前@ を values の値で置換する。秘密値を書かない。";
      };
      values = mkOption {
        type = types.attrsOf valueType;
        default = { };
        description = "プレースホルダー名と、秘密ファイル・JSON キーの対応。";
      };
    };
  };
  secretNames =
    cfg.secretEnvFiles
    ++ lib.concatMap (template: map (value: value.secret) (builtins.attrValues template.values)) (
      builtins.attrValues cfg.secretTemplates
    );
  manifest = pkgs.writeText "nix-config-secret-templates.json" (
    builtins.toJSON {
      inherit homeDirectory;
      secrets = envSecrets;
      templates = cfg.secretTemplates;
    }
  );
in
{
  options.nixConfig = {
    reposRootDir = mkOption {
      type = types.strMatching "/.*";
      description = "リポジトリを置く絶対パス。他の home context と REPOS_ROOT_DIR が共有する。";
    };
    secretEnvFiles = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "zsh の対話シェルで source して export する envSecrets の設定名（信頼できるシェル代入形式）。";
    };
    secretTemplates = mkOption {
      type = types.attrsOf templateType;
      default = { };
      description = "Home Manager の activation でストア外へ生成する秘密入りテンプレート。";
    };
  };

  config = {
    assertions = map (name: {
      assertion = builtins.hasAttr name envSecrets;
      message = "nixConfig: layers/user/.env.d/${name}.sops がありません";
    }) (lib.unique secretNames);

    programs.zsh.initContent = lib.mkIf (cfg.secretEnvFiles != [ ]) (
      lib.mkOrder 550 (
        lib.concatMapStringsSep "\n" (
          name:
          let
            path = lib.escapeShellArg envSecrets.${name};
          in
          ''
            if [[ -f ${path} && ! -L ${path} && -r ${path} ]]; then
              () {
                setopt localoptions allexport
                source ${path}
              }
            fi
          ''
        ) cfg.secretEnvFiles
      )
    );

    home.activation.nixConfigSecretTemplates = lib.mkIf (cfg.secretTemplates != { }) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${pkgs.python3}/bin/python3 ${../scripts/render-secret-templates.py} ${manifest}
      ''
    );
  };
}
