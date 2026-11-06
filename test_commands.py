"""Exercise installation commands against fake PF/launchd, with no system changes."""
import json, os, pathlib, plistlib, shutil, subprocess, tempfile, unittest

ROOT=pathlib.Path(__file__).resolve().parent

class CommandsTest(unittest.TestCase):
    def run_install(self, interactive):
        with tempfile.TemporaryDirectory() as td:
            root=pathlib.Path(td);state=root/'state';state.mkdir();bindir=root/'bin';bindir.mkdir();source=root/'source';source.mkdir()
            install=root/'sbin'/'claude-lockdown.sh';helper=root/'libexec'/'known_addresses.py';plist=root/'daemon.plist';kernel=root/'kernel'
            (state/'cidrs').write_text('160.79.104.0/21\n');(state/'boot').write_text('boot123\n');(state/'pf-token').write_text('12345\n')
            old='block drop out quick on en0 inet from any to 160.79.104.0/21\n';(state/'rules').write_text(old);kernel.write_text(old)
            profile=root/'SFM directory'/'profile.json';profile.parent.mkdir();profile.write_text(json.dumps({'inbounds':[{'type':'mixed','listen':'127.0.0.1','listen_port':2345}],'outbounds':[{'type':'vless','server':'8.8.8.8'}]}))
            shutil.copy2(ROOT/'known_addresses.py',source/'known_addresses.py')
            def exe(name,content):
                p=bindir/name;p.write_text(content);p.chmod(0o755)
            exe('ifconfig','#!/bin/sh\necho en0\n');exe('sysctl','#!/bin/sh\necho boot123\n')
            exe('uuidgen','#!/bin/sh\necho test-id\n');exe('chown','#!/bin/sh\nexit 0\n');exe('plutil','#!/bin/sh\nexit 0\n')
            exe('launchctl','#!/bin/sh\n[ "$1" = print ] && exit 1\nexit 0\n')
            exe('pfctl', '''#!/usr/bin/python3
import os,pathlib,sys
a=sys.argv[1:]; k=pathlib.Path(os.environ['MOCK_KERNEL'])
if a[:2]==['-o','none']: a=a[2:]
if a==['-sr']:print('anchor "com.apple/*" all')
elif a==['-si']:print('Status: Enabled')
elif a[:1] in (['-n'],['-k']):pass
elif len(a)>=3 and a[0]=='-a' and a[2]=='-sr':print(k.read_text(),end='')
elif len(a)>=4 and a[0]=='-a' and a[2]=='-f':k.write_text(pathlib.Path(a[3]).read_text())
else:print('unexpected pfctl',a,file=sys.stderr);sys.exit(1)
''')
            code=(ROOT/'claude-lockdown.sh').read_text()
            code=code.replace('PATH=/usr/bin:/bin:/usr/sbin:/sbin',f'PATH={bindir}:/usr/bin:/bin:/usr/sbin:/sbin')
            code=code.replace('STATE_DIR="/var/db/claude-lockdown"',f'STATE_DIR="{state}"')
            code=code.replace('INSTALL_PATH="/usr/local/sbin/claude-lockdown.sh"',f'INSTALL_PATH="{install}"')
            code=code.replace('HELPER="/usr/local/libexec/claude-lockdown/known_addresses.py"',f'HELPER="{helper}"')
            code=code.replace('DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"',f'DAEMON_PLIST="{plist}"')
            code=code.replace('mkdir -p /usr/local/libexec/claude-lockdown',f'mkdir -p "{helper.parent}"')
            code=code.replace('mkdir -p /usr/local/sbin',f'mkdir -p "{install.parent}"')
            code=code.replace("need_root() { [ \"$(uname -s)\" = Darwin ] || fail '仅支持 macOS'; [ \"$(id -u)\" -eq 0 ] || fail '请用 sudo 运行'; }",'need_root() { :; }')
            source_script=source/'claude-lockdown.sh';source_script.write_text(code)
            env=os.environ.copy();env['MOCK_KERNEL']=str(kernel)
            args=['/bin/bash',str(source_script),'install']
            stdin=str(profile)+'\n2345\n' if interactive else None
            if not interactive: args += ['--sfm-profile',str(profile),'--proxy-port','2345']
            done=subprocess.run(args,input=stdin,capture_output=True,text=True,env=env)
            self.assertEqual(done.returncode,0,done.stdout+'\n'+done.stderr)
            self.assertTrue(install.exists());self.assertTrue(helper.exists())
            self.assertEqual(plistlib.loads(plist.read_bytes())['StartInterval'],3600)
            self.assertEqual((state/'proxy-port').read_text().strip(),'2345')
            self.assertEqual(json.loads((state/'sfm-server-ips.json').read_text()),{'servers':['8.8.8.8']})
            if not interactive:
                again=subprocess.run(['/bin/bash',str(install),'install','--sfm-profile',str(profile),'--proxy-port','2345'],capture_output=True,text=True,env=env)
                self.assertEqual(again.returncode,0,again.stdout+'\n'+again.stderr)
    def test_install_interactive(self): self.run_install(True)
    def test_install_flags(self): self.run_install(False)

if __name__=='__main__':unittest.main()
