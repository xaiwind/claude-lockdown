"""Run the real shell entry point against isolated fake PF and DNS processes."""
import os, pathlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).parent

class Integration(unittest.TestCase):
    def run_case(self, mode):
        with tempfile.TemporaryDirectory() as td:
            root=pathlib.Path(td); state=root/'state'; state.mkdir(); binpath=root/'bin';binpath.mkdir()
            old='160.79.104.0/21\n';new='160.79.104.0/21\n34.120.108.227/32\n'
            (state/'cidrs').write_text(old);(state/'boot').write_text('boot123\n');(state/'pf-token').write_text('12345\n')
            old_rules='block drop out quick on en0 inet from any to 160.79.104.0/21\n'
            (state/'rules').write_text(old_rules);(root/'kernel').write_text(old_rules)
            (state/'sfm-server-ips.json').write_text('{\"servers\":[\"8.8.8.8\"]}\n');(state/'proxy-port').write_text('2345\n')
            helper=root/'known.py';helper.write_text("import os,pathlib,sys\nassert '--server-list' in sys.argv and '--sfm-profile' not in sys.argv\np=pathlib.Path(sys.argv[sys.argv.index('--output')+1]);p.write_text("+repr(old)+" if os.environ.get('MOCK_UNCHANGED')=='1' else "+repr(new)+")\npathlib.Path(sys.argv[sys.argv.index('--history-output')+1]).write_text('{\"version\":1,\"last_seen\":{}}')\n")
            def executable(name,content):
                p=binpath/name;p.write_text(content);p.chmod(0o755)
            executable('ifconfig','#!/bin/sh\necho en0\n')
            executable('sysctl','#!/bin/sh\necho boot123\n')
            executable('pfctl', '''#!/usr/bin/python3
import os,pathlib,sys
args=sys.argv[1:]; k=pathlib.Path(os.environ['MOCK_KERNEL'])
no_optimization=args[:2]==['-o','none']
if no_optimization: args=args[2:]
if args==['-sr']: print('anchor "com.apple/*" all')
elif args==['-si']: print('Status: Enabled')
elif args[:1] in (['-n'],['-k']): pass
elif len(args)>=3 and args[0]=='-a' and args[2]=='-sr': print(k.read_text(),end='')
elif len(args)>=4 and args[0]=='-a' and args[2]=='-f':
  with open(os.environ['MOCK_TRACE'],'a') as t: t.write('load\\n')
  proposed=pathlib.Path(args[3]).read_text()
  if not (os.environ.get('MOCK_STALE')=='1' and '34.120.108.227' in proposed):
   if not no_optimization and '34.120.108.227' in proposed: k.write_text('block drop out quick on en0 inet from any to <__automatic_0>\\n')
   else: k.write_text(proposed)
elif len(args)>=4 and args[0]=='-a' and args[2]=='-F': k.write_text('')
else: print('unexpected fake pfctl command',args,file=sys.stderr);sys.exit(1)
''')
            source=(ROOT/'claude-lockdown.sh').read_text()
            source=source.replace('PATH=/usr/bin:/bin:/usr/sbin:/sbin',f'PATH={binpath}:/usr/bin:/bin:/usr/sbin:/sbin')
            source=source.replace('STATE_DIR="/var/db/claude-lockdown"',f'STATE_DIR="{state}"')
            source=source.replace('HELPER="/usr/local/libexec/claude-lockdown/known_addresses.py"',f'HELPER="{helper}"')
            source=source.replace("need_root() { [ \"$(uname -s)\" = Darwin ] || fail '仅支持 macOS'; [ \"$(id -u)\" -eq 0 ] || fail '请用 sudo 运行'; }",'need_root() { :; }')
            path=root/'run.sh';path.write_text(source)
            env=os.environ.copy();env['MOCK_KERNEL']=str(root/'kernel');env['MOCK_STALE']='1' if mode=='stale' else '0';env['MOCK_UNCHANGED']='1' if mode=='unchanged' else '0';env['MOCK_TRACE']=str(root/'trace')
            result=subprocess.run(['/bin/bash',str(path),'reconcile'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            if mode=='unchanged':
                self.assertEqual((state/'cidrs').read_text(),old)
                self.assertFalse((root/'trace').exists(), 'unchanged rules must not be reloaded')
            elif mode=='stale':
                self.assertEqual((state/'cidrs').read_text(),old)
                self.assertNotIn('34.120.108.227',(root/'kernel').read_text())
                self.assertIn('本次未更新',result.stderr)
            else:
                self.assertEqual((state/'cidrs').read_text(),new)
                self.assertIn('34.120.108.227',(root/'kernel').read_text())
    def test_unchanged_rules_are_not_reloaded(self):self.run_case('unchanged')
    def test_successful_refresh(self):self.run_case('ok')
    def test_stale_kernel_fails_and_rolls_back(self):self.run_case('stale')

if __name__=='__main__':unittest.main()
