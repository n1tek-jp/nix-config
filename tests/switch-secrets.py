#!/usr/bin/env python3
# 本物の sops と、使い捨ての鍵を扱う偽YubiKeyプラグインで復号経路を検証する。
# HOME、XDG、SOPSの環境を隔離し、実機やsudoには接続しない。
import json
import os
from pathlib import Path
import pty
import select
import time
import signal
import termios
import shutil
import subprocess
import sys
import tempfile
import unittest

SOPS = shutil.which('sops')
HELPER = Path(__file__).resolve().parents[1] / 'scripts/sync-secrets.sh'
PYTHON = sys.executable

def encode(hrp, data):
    chars = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
    values = []
    acc = bits = 0
    for byte in data:
        acc = (acc << 8) | byte
        bits += 8
        while bits >= 5:
            bits -= 5
            values.append((acc >> bits) & 31)
    if bits:
        values.append((acc << (5 - bits)) & 31)
    expand = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
    chk = 1
    for v in expand + values + [0] * 6:
        top = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i, g in enumerate([0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]):
            if top >> i & 1:
                chk ^= g
    chk ^= 1
    return hrp + '1' + ''.join(chars[x] for x in values + [(chk >> (5 * (5-i))) & 31 for i in range(6)])

PLUGIN = r'''
import os, sys, base64, json
from pathlib import Path
cfg=json.loads(Path(os.environ['TEST_CONFIG']).read_text())
if sys.argv[1]=='--list':
    for r in cfg['connected']: print(r)
    sys.exit(0)
def read():
    header=sys.stdin.readline().strip().split()
    if not header: sys.exit(1)
    body=[]
    while True:
        line=sys.stdin.readline().strip()
        body.append(line)
        if len(line)<64: break
    return header[1],header[2:],''.join(body)
def send(kind,args,body=''):
    print('-> '+kind+' '+args+'\n'+body,flush=True)
    read()
items=[]
while True:
    kind,args,body=read()
    if kind=='done': break
    items.append((kind,args,body))
if sys.argv[1]=='--age-plugin=recipient-v1':
    key=next(x[2] for x in items if x[0]=='wrap-file-key')
    send('recipient-stanza','0 disposable-test',key)
else:
    with open(os.environ['TEST_CALLS'],'a') as f: f.write('decrypt\n')
    if cfg.get('hang'):
        os.system('stty -echo </dev/tty')
        import time; time.sleep(1)
    if cfg.get('fail'):
        send('error','identity 0',base64.b64encode(b'test: wrong PIN').decode().rstrip('='))
    else:
        key=next(x[2] for x in items if x[0]=='recipient-stanza')
        send('file-key','0',key)
print('-> done\n',flush=True)
'''

class Secrets(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='nix-secrets-test-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.home=self.root/'home'; self.home.mkdir()
        self.envdir=self.root/'env'; self.envdir.mkdir()
        self.state=self.home/'state'
        self.tools=self.root/'tools'; (self.tools/'bin').mkdir(parents=True)
        (self.tools/'bin/sops').symlink_to(SOPS)
        p=self.tools/'bin/age-plugin-yubikey'; p.write_text('#!'+PYTHON+'\n'+PLUGIN); p.chmod(0o700)
        self.r1=encode('age1yubikey',[1,2,3]); self.r2=encode('age1yubikey',[4,5,6])
        self.i1=encode('age-plugin-yubikey-',[1,2,3]).upper()
        self.i2=encode('age-plugin-yubikey-',[4,5,6]).upper()
        self.ids=self.root/'identities'
        self.ids.write_text('# Recipient: '+self.r1+'\n'+self.i1+'\n# Recipient: '+self.r2+'\n'+self.i2+'\n')
        self.config=self.root/'config'; self.config.write_text(json.dumps({'connected':[self.r1]}))
        self.calls=self.root/'calls'
        self.env={k:v for k,v in os.environ.items() if not k.startswith('SOPS_') and not k.startswith('AWS_') and not k.startswith('SSH_')}
        self.env.update(HOME=str(self.home),XDG_CONFIG_HOME=str(self.home/'config'),PATH=str(self.tools/'bin')+':/usr/bin:/bin',TEST_CONFIG=str(self.config),TEST_CALLS=str(self.calls))
    def encrypt(self,name,content,recipient=None):
        r=subprocess.run([SOPS,'--config','/dev/null','encrypt','--input-type','binary','--output-type','binary','--age',recipient or self.r1,'/dev/stdin'],input=content,env=self.env,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr.decode())
        (self.envdir/(name+'.sops')).write_bytes(r.stdout)
    def sync(self,tty=True,action='sync',key_type='yubikey',identities=None):
        cmd=['/bin/sh',str(HELPER),action,str(self.envdir),str(self.state),str(self.tools),str(identities or self.ids),key_type]
        if not tty:
            return subprocess.run(cmd,env=self.env,capture_output=True,start_new_session=True)
        pid,fd=pty.fork()
        if pid==0:
            os.chdir(self.root); os.execve(cmd[0],cmd,self.env)
        output=b''
        deadline=time.monotonic()+15
        while True:
            if time.monotonic()>deadline:
                os.killpg(pid,signal.SIGKILL); os.waitpid(pid,0); os.close(fd)
                self.fail('試験がタイムアウト: '+output.decode(errors='replace'))
            if not select.select([fd],[],[],0.1)[0]: continue
            try:
                chunk=os.read(fd,65536)
                if not chunk: break
                output+=chunk
            except OSError: break
        os.close(fd); _,status=os.waitpid(pid,0)
        result=subprocess.CompletedProcess(cmd,os.waitstatus_to_exitcode(status),output,b'')
        if result.returncode: print(output.decode(errors='replace'),file=sys.stderr)
        return result
    def assertClean(self):
        self.assertFalse((self.state/'.lock').exists())
        self.assertEqual(list(self.state.glob('.work.*')),[])
    def test_roundtrip_cache_and_update(self):
        self.encrypt('git',b'[user]\nname = Example\n')
        self.assertEqual(self.sync().returncode,0)
        self.assertEqual((self.state/'git').read_bytes(),b'[user]\nname = Example\n')
        self.assertEqual((self.state/'git').stat().st_mode & 0o777,0o400)
        self.assertEqual(self.state.stat().st_mode & 0o777,0o700)
        self.assertEqual(self.sync(tty=False).returncode,0)
        self.assertEqual(len(self.calls.read_text().splitlines()),1)
        self.encrypt('git',b'[user]\nname = New\n')
        self.sync(); self.assertEqual((self.state/'git').read_bytes(),b'[user]\nname = New\n')
        self.assertEqual(len(self.calls.read_text().splitlines()),2)
        self.assertClean()
    def test_invalid_cipher_does_not_block_next(self):
        (self.envdir/'aws.sops').write_text('invalid')
        self.encrypt('git',b'ok')
        self.sync(); self.assertEqual((self.state/'git').read_bytes(),b'ok'); self.assertClean()
    def test_absent_recipient_does_not_block_next(self):
        self.encrypt('aws',b'wrong-recipient',self.r2); self.encrypt('git',b'ok')
        self.sync(); self.assertFalse((self.state/'aws').exists()); self.assertEqual((self.state/'git').read_bytes(),b'ok')
        self.assertEqual(len(self.calls.read_text().splitlines()),1)
    def test_failure_stops_pin_retries_and_preserves_old(self):
        self.encrypt('aws',b'old'); self.sync()
        self.encrypt('aws',b'new'); self.encrypt('git',b'later')
        self.config.write_text(json.dumps({'connected':[self.r1], 'fail':True}))
        self.sync(); self.assertEqual((self.state/'aws').read_bytes(),b'old')
        self.assertFalse((self.state/'git').exists()); self.assertEqual(len(self.calls.read_text().splitlines()),2)
        self.assertClean()
    def test_two_keys_choose_registration_order(self):
        self.config.write_text(json.dumps({'connected':[self.r2,self.r1]}))
        self.encrypt('aws',b'other',self.r2); self.encrypt('git',b'main')
        self.sync(); self.assertFalse((self.state/'aws').exists()); self.assertEqual((self.state/'git').read_bytes(),b'main')
    def test_no_tty_or_no_key_does_not_decrypt(self):
        self.encrypt('git',b'ok'); self.sync(tty=False); self.assertFalse(self.calls.exists())
        self.config.write_text(json.dumps({'connected':[]})); self.sync(); self.assertFalse(self.calls.exists()); self.assertClean()
    def test_prune_only_after_apply(self):
        self.encrypt('aws',b'old'); self.sync(); (self.envdir/'aws.sops').unlink()
        self.sync(); self.assertTrue((self.state/'aws').exists())
        self.sync(action='prune'); self.assertFalse((self.state/'aws').exists()); self.assertClean()
    def test_cancel_restores_terminal_and_cleans_partial(self):
        self.encrypt('git',b'ok')
        self.config.write_text(json.dumps({'connected':[self.r1], 'hang':True}))
        cmd=['/bin/sh',str(HELPER),'sync',str(self.envdir),str(self.state),str(self.tools),str(self.ids)]
        pid,fd=pty.fork()
        if pid==0:
            os.chdir(self.root); os.execve(cmd[0],cmd,self.env)
        deadline=time.monotonic()+10
        while not self.calls.exists():
            if time.monotonic()>deadline:
                os.killpg(pid,signal.SIGKILL); self.fail('偽プラグインが開始しませんでした')
            time.sleep(0.05)
        time.sleep(0.1)
        os.killpg(pid,signal.SIGINT)
        deadline=time.monotonic()+10
        while True:
            if select.select([fd],[],[],0.05)[0]:
                try: os.read(fd,65536)
                except OSError: pass
            waited,status=os.waitpid(pid,os.WNOHANG)
            if waited: break
            if time.monotonic()>deadline:
                os.killpg(pid,signal.SIGKILL); os.waitpid(pid,0); os.close(fd)
                self.fail('中断時の試験がタイムアウトしました')
            time.sleep(0.05)
        attrs=termios.tcgetattr(fd); os.close(fd)
        self.assertEqual(os.waitstatus_to_exitcode(status),130)
        self.assertTrue(attrs[3] & termios.ECHO)
        self.assertFalse((self.state/'git').exists())
        self.assertClean()
    def test_missing_identity_and_lock(self):
        self.encrypt('git',b'ok'); self.ids.unlink(); self.sync(); self.assertFalse(self.calls.exists())
        (self.state/'.lock').mkdir(); self.assertNotEqual(self.sync().returncode,0)
    def test_only_hardware_identity_is_selected(self):
        self.ids.write_text('AGE-SECRET-KEY-DISPOSABLE-INVALID\n'+self.ids.read_text())
        self.encrypt('git',b'ok'); self.sync(); self.assertEqual((self.state/'git').read_bytes(),b'ok')
        self.assertClean()

    def software_key(self, name='software'):
        path = self.root/name
        result = subprocess.run([shutil.which('age-keygen'), '-o', str(path)], capture_output=True)
        self.assertEqual(result.returncode, 0)
        recipient = subprocess.check_output([shutil.which('age-keygen'), '-y', str(path)]).decode().strip()
        return path, recipient
    def test_software_key_without_terminal(self):
        key, recipient = self.software_key()
        self.encrypt('api', b'software-secret', recipient)
        self.assertEqual(self.sync(tty=False,key_type='age',identities=key).returncode,0)
        self.assertEqual((self.state/'api').read_bytes(),b'software-secret')
        self.assertEqual((self.state/'api').stat().st_mode & 0o777,0o400)
        self.assertFalse(self.calls.exists())
        self.assertClean()
    def test_software_key_is_not_implicitly_selected(self):
        key, recipient = self.software_key()
        self.encrypt('api',b'implicit',recipient)
        self.env['SOPS_AGE_KEY_FILE']=str(key)
        self.env['SOPS_AGE_KEY']=key.read_text()
        default=self.home/'config/sops/age/keys.txt'
        default.parent.mkdir(parents=True); default.write_text(key.read_text())
        self.sync()
        self.assertFalse((self.state/'api').exists())
        self.assertFalse(self.calls.exists())
    def test_software_selection_ignores_other_age_keys(self):
        key, recipient = self.software_key()
        wrong, _ = self.software_key('wrong')
        self.encrypt('api',b'implicit',recipient)
        self.env['SOPS_AGE_KEY']=key.read_text()
        self.env['SOPS_AGE_KEY_FILE']=str(key)
        command=self.root/'key-command'
        command.write_text('#!/bin/sh\ntouch '+str(self.root/'unexpected-command')+'\ncat '+str(key)+'\n')
        command.chmod(0o700)
        self.env['SOPS_AGE_KEY_CMD']=str(command)
        default=self.home/'config/sops/age/keys.txt'
        default.parent.mkdir(parents=True); default.write_text(key.read_text())
        self.sync(tty=False,key_type='age',identities=wrong)
        self.assertFalse((self.state/'api').exists())
        self.assertClean()
        self.assertFalse((self.root/'unexpected-command').exists())
    def test_software_selection_ignores_home_ssh_key(self):
        ssh=self.home/'.ssh/id_ed25519'; ssh.parent.mkdir()
        subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(ssh)],check=True)
        key, _ = self.software_key()
        self.encrypt('api',b'ssh-secret',Path(str(ssh)+'.pub').read_text().strip())
        self.env['SOPS_AGE_SSH_PRIVATE_KEY_FILE']=str(ssh)
        self.sync(tty=False,key_type='age',identities=key)
        self.assertFalse((self.state/'api').exists())
    def test_software_failure_preserves_cache_but_allows_other_files(self):
        key, recipient = self.software_key()
        _, wrong_recipient = self.software_key('wrong')
        self.encrypt('api',b'old',recipient)
        self.sync(tty=False,key_type='age',identities=key)
        self.encrypt('api',b'new',wrong_recipient)
        self.encrypt('later',b'valid',recipient)
        self.sync(tty=False,key_type='age',identities=key)
        self.assertEqual((self.state/'api').read_bytes(),b'old')
        self.assertEqual((self.state/'later').read_bytes(),b'valid')
        self.assertClean()
    def test_software_selection_rejects_plugin_identity(self):
        self.encrypt('api',b'ok')
        self.sync(tty=False,key_type='age')
        self.assertFalse((self.state/'api').exists())
        self.assertFalse(self.calls.exists())

if __name__=='__main__':
    if SOPS is None: sys.exit('sopsが必要です')
    unittest.main()
