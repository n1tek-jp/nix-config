# AWS: CLI と Session Manager プラグイン。
# プロファイル（リージョン・SSO）と SSO ログインの確認は、layers/user/.env.d/aws.sops を重ねて user レイヤーの aws/ が設定する。
{
  home =
    { pkgs, ... }:
    {
      programs.awscli.enable = true;
      home.packages = [ pkgs.ssm-session-manager-plugin ];
    };
}
