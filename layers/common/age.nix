# age: ファイルを暗号化する（age-keygen で鍵を作る）。sops の鍵にも使う。
{
  home =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.age ];
    };
}
