# Rosetta 2: Apple Silicon で Intel 向けのアプリやコンテナを動かす。未導入なら switch のときに入れる。
# 入れるときは Apple のライセンスに自動で同意する（softwareupdate --agree-to-license）。
{
  darwin =
    { lib, hostSystem, ... }:
    lib.mkIf (hostSystem == "aarch64-darwin") {
      system.activationScripts.postActivation.text = ''
        if [ ! -f /Library/Apple/usr/libexec/oah/libRosettaRuntime ]; then
          echo "installing Rosetta 2..." >&2
          /usr/sbin/softwareupdate --install-rosetta --agree-to-license
        fi
      '';
    };
}
