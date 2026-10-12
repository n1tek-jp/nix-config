# GNU getopt: 長いオプションを解釈できる getopt（macOS 標準は BSD 版）。
{
  home =
    { lib, pkgs, ... }:
    {
      home.packages = lib.optional pkgs.stdenv.hostPlatform.isDarwin pkgs.getopt;
    };
}
