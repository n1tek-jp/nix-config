#!/usr/bin/env python3
"""ストア外の生成、JSON エスケープ、失敗時の保持、パス制限を検証する。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'scripts/render-secret-templates.py'


class Templates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='secret-templates-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.secret = self.root / 'secret'
        self.token = 'quotes"\n日本語 @TOKEN@'
        self.secret.write_text(json.dumps({'token': self.token}))
        self.manifest = {
            'homeDirectory': str(self.home),
            'secrets': {'api': str(self.secret)},
            'templates': {'tool': {
                'target': '.config/tool/config.json',
                'format': 'json',
                'content': '{"token": @TOKEN@, "user": "public"}',
                'values': {'TOKEN': {'secret': 'api', 'key': 'token'}},
            }},
        }
        self.target = self.home / '.config/tool/config.json'
    def run_helper(self):
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps(self.manifest))
        return subprocess.run([sys.executable, str(HELPER), str(manifest)], capture_output=True)
    def test_json_escape_permissions_and_repeat(self):
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(json.loads(self.target.read_text())['token'], self.token)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.target.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(list(self.target.parent.glob('.nix-config-*')), [])
    def test_raw_file_in_text_template(self):
        self.secret.write_text('raw-value\n')
        template = self.manifest['templates']['tool']
        template.update(format='text', content='token=@TOKEN@')
        template['values']['TOKEN']['key'] = None
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.target.read_text(), 'token=raw-value\n')
    def test_missing_secret_keeps_previous_file(self):
        self.run_helper()
        previous = self.target.read_bytes()
        self.secret.unlink()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0)
        self.assertIn(b'warning:', result.stderr)
        self.assertEqual(self.target.read_bytes(), previous)
    def test_invalid_json_and_key_never_leak_secret(self):
        self.run_helper()
        previous = self.target.read_bytes()
        for content in ('invalid @TOKEN@', '{"token": @UNKNOWN@}'):
            self.manifest['templates']['tool']['content'] = content
            result = self.run_helper()
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(self.token.encode(), result.stderr + result.stdout)
            self.assertEqual(self.target.read_bytes(), previous)
        self.manifest['templates']['tool']['content'] = '{"token": @TOKEN@}'
        self.manifest['templates']['tool']['values']['TOKEN']['key'] = 'missing'
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.target.read_bytes(), previous)
    def test_rejects_paths_outside_home_and_links(self):
        for target in ('../outside', str(self.root/'outside'), '.'):
            self.manifest['templates']['tool']['target'] = target
            self.assertNotEqual(self.run_helper().returncode, 0)
        self.manifest['templates']['tool']['target'] = '.config/tool/config.json'
        (self.home/'.config').symlink_to(self.root)
        self.assertNotEqual(self.run_helper().returncode, 0)
        (self.home/'.config').unlink()
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(self.secret)
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(json.loads(self.secret.read_text())['token'], self.token)
    def test_rejects_secret_symlink(self):
        link = self.root/'secret-link'; link.symlink_to(self.secret)
        self.manifest['secrets']['api'] = str(link)
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertFalse(self.target.exists())


if __name__ == '__main__':
    unittest.main()
