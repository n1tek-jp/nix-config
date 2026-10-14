#!/usr/bin/env python3
"""公開 manifest とストア外の秘密から、利用者のホームに通常ファイルを生成する。"""
import json
import os
from pathlib import Path
import re
import sys
import tempfile


class TemplateError(Exception):
    pass


def render(manifest):
    home = Path(manifest['homeDirectory']).resolve()
    targets = set()
    for name, template in manifest['templates'].items():
        # エラー詳細に平文・テンプレートの内容を含めない。
        relative = Path(template['target'])
        if (relative.is_absolute() or not relative.parts or
                '..' in relative.parts or '\n' in str(relative)):
            raise TemplateError('生成先はホーム内の相対パスにしてください')
        target = home / relative
        if target.is_symlink() or not target.parent.resolve().is_relative_to(home):
            raise TemplateError('生成先がリンクか、ホーム外を指しています')
        canonical = target.resolve()
        if canonical in targets:
            raise TemplateError('生成先が重複しています')
        targets.add(canonical)
        values = {}
        missing = False
        for placeholder, spec in template['values'].items():
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', placeholder):
                raise TemplateError('プレースホルダー名は英数字と _ にしてください')
            source = Path(manifest['secrets'][spec['secret']])
            if source.is_symlink():
                raise TemplateError('秘密の参照先がリンクです')
            if not source.is_file():
                missing = True
                break
            value = source.read_text()
            if spec.get('key') is not None:
                value = json.loads(value)[spec['key']]
            if template['format'] == 'json':
                value = json.dumps(value, ensure_ascii=False)
            elif not isinstance(value, str):
                raise TemplateError('text テンプレートの値は文字列にしてください')
            values[placeholder] = value
        if missing:
            print('warning: 秘密が未復号のためテンプレートを保持します: ' + name, file=sys.stderr)
            continue
        # 1回だけ置換し、秘密値の中の @名前@ を再解釈しない。
        def substitute(match):
            if match[1] not in values:
                raise TemplateError('未定義のプレースホルダーがあります')
            return values[match[1]]
        output = re.sub(r'@([A-Za-z_][A-Za-z0-9_]*)@', substitute, template['content'])
        if template['format'] == 'json':
            json.loads(output)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temp = None
        try:
            fd, temp = tempfile.mkstemp(prefix='.nix-config-', dir=target.parent)
            with os.fdopen(fd, 'w') as stream:
                stream.write(output)
            os.replace(temp, target)
        finally:
            if temp is not None:
                Path(temp).unlink(missing_ok=True)


def main():
    os.umask(0o077)
    try:
        render(json.loads(Path(sys.argv[1]).read_text()))
    except (OSError, ValueError, KeyError, TypeError, TemplateError):
        print('error: 秘密テンプレートを生成できません。生成先・設定名・JSON キー・構文を確認してください。', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
