#!/usr/bin/env python3
"""固定依存でレイヤー集約と macOS/Linux の Home Manager 実行時設定を評価する。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class Layers(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nix-layers-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)/'config'
        self.home = Path(self.temp.name)/'home'
        for layer in ('common', 'user/.env.d', 'organizations/acme', 'local/.env.d'):
            (self.root/'layers'/layer).mkdir(parents=True)
        self.write('common/tool.nix', '{ backupTargets = [ "~/.common" "~/.shared" ]; }')
        self.write('user/tool.nix', '{ backupTargets = [ "~/.user" "~/.shared" ]; }')
        self.write('organizations/acme/tool.nix', '{ backupTargets = [ "~/.organization" ]; }')
        self.env = dict(os.environ, NIX_CONFIG_HOME=str(self.home), NIX_CONFIG_USER='test', NIX_CONFIG_SYSTEM='aarch64-darwin')
    def write(self, relative, content):
        (self.root/'layers'/relative).write_text(content)
    def evaluate(self, output=None):
        expression = '''let
          inputs = (builtins.getFlake "path:%s").inputs;
          lib = inputs.nixpkgs.lib;
          layers = import %s/bootstrap/layers.nix { inherit lib; root = builtins.toPath "%s"; };
        in %s''' % (REPO, REPO, self.root, output or '{ inherit (layers) backupTargets secrets envSecrets localValues priorities; }')
        return subprocess.run(['nix','--extra-experimental-features','nix-command flakes','eval','--impure','--json','--expr',expression],env=self.env,capture_output=True)
    def value(self, result):
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout)
    def test_defaults_and_backup_collection(self):
        result = self.value(self.evaluate())
        self.assertEqual(result['secrets']['keyType'], 'yubikey')
        self.assertEqual(result['secrets']['identityFile'], str(self.home/'.config/sops/age/nix-config-yubikeys.txt'))
        self.assertEqual(result['backupTargets'], ['~/.common','~/.shared','~/.organization','~/.user'])
        self.write('local/.env.d/override-layer-priorities.nix', '[ "local" "common" ]')
        self.assertEqual(self.value(self.evaluate())['backupTargets'], ['~/.common','~/.shared'])
    def test_explicit_key_and_public_values(self):
        self.write('local/.env.d/secrets.nix', '{ keyType = "age"; identityFile = "~/.keys/test.txt"; }')
        self.write('local/.env.d/values.nix', '{ userName = "public-name"; }')
        result = self.value(self.evaluate())
        self.assertEqual(result['secrets'], {'keyType':'age','identityFile':str(self.home/'.keys/test.txt')})
        self.assertEqual(result['localValues']['userName'], 'public-name')
    def test_rejects_bad_settings(self):
        for config in ('{ keyType = "age"; }', '{ keyType = "auto"; }', '{ identityFile = "relative"; }', '{ unknown = true; }', '[ ]'):
            self.write('local/.env.d/secrets.nix', config)
            self.assertNotEqual(self.evaluate().returncode, 0, config)
        (self.root/'layers/local/.env.d/secrets.nix').unlink()
        self.write('common/tool.nix', '{ backupTargets = [ "~/one\\n~/two" ]; }')
        self.assertNotEqual(self.evaluate().returncode, 0)
    def test_rejects_plaintext_and_links(self):
        self.write('user/.env.d/plain.txt', 'not-allowed')
        self.assertNotEqual(self.evaluate().returncode, 0)
        (self.root/'layers/user/.env.d/plain.txt').unlink()
        (self.root/'layers/user/.env.d/api.sops').symlink_to(self.root/'layers/common/tool.nix')
        self.assertNotEqual(self.evaluate().returncode, 0)
    def test_home_runtime_on_darwin_and_linux(self):
        self.write('common/repos.nix', (REPO/'layers/common/repos.nix').read_text())
        self.write('local/.env.d/values.nix', '{ userName = "public-name"; }')
        self.write('user/.env.d/api.sops', 'dummy-encrypted-file-not-read')
        self.write('local/tool.nix', '''{ layer, ... }: {
          home = { config, localValues, ... }: {
            programs.zsh.enable = true;
            nixConfig.reposRootDir = layer.override "/workspace";
            nixConfig.secretEnvFiles = [ "api" ];
            nixConfig.secretTemplates.tool = {
              target = ".config/tool/config.json";
              content = ''{"token": @TOKEN@}'';
              values.TOKEN = { secret = "api"; key = "token"; };
            };
            home.sessionVariables = {
              TOOL_ROOT = "${config.nixConfig.reposRootDir}/tool";
              TOOL_USER = localValues.userName;
            };
          };
        }''')
        source = self.home/'.local/state/nix-config/secrets/api'
        source.parent.mkdir(parents=True)
        source.write_text('private-marker-never-evaluated')
        for system in ('aarch64-darwin', 'x86_64-linux'):
            result = self.evaluate('''let hm = inputs.home-manager.lib.homeManagerConfiguration {
              pkgs = inputs.nixpkgs.legacyPackages.%s;
              modules = [ (import %s/bootstrap/shared.nix).home ] ++ layers.home;
              extraSpecialArgs = {
                userName = "test"; homeDirectory = "%s";
                inherit (layers) envSecrets localValues;
              };
            }; in {
              variables = hm.config.home.sessionVariables;
              zsh = hm.config.programs.zsh.initContent;
              activation = hm.config.home.activation.nixConfigSecretTemplates;
            }''' % (system, REPO, self.home))
            value = self.value(result)
            self.assertEqual(value['variables']['REPOS_ROOT_DIR'], '/workspace')
            self.assertEqual(value['variables']['TOOL_ROOT'], '/workspace/tool')
            self.assertEqual(value['variables']['TOOL_USER'], 'public-name')
            self.assertIn(str(source), value['zsh'])
            self.assertIn('setopt localoptions allexport', value['zsh'])
            self.assertIn('writeBoundary', value['activation']['after'])
            self.assertIn('run /nix/store/', value['activation']['data'])
            self.assertNotIn('private-marker-never-evaluated', result.stdout.decode())
            # 実際の zsh で export とオプション復元を確認する（値は HOME 外から読む）。
            source.write_text('API_TOKEN="shell-test"\n')
            shell = subprocess.run(['/bin/zsh','-f','-c', value['zsh']+'\n[[ $options[allexport] == off ]] && /usr/bin/env'],capture_output=True)
            self.assertEqual(shell.returncode, 0, shell.stderr.decode())
            self.assertIn(b'API_TOKEN=shell-test', shell.stdout)
            source.write_text('private-marker-never-evaluated')


if __name__ == '__main__':
    unittest.main()
