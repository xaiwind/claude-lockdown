"""Check the real macOS PF parser without loading any system rules."""
import pathlib, subprocess, sys, tempfile, unittest

@unittest.skipUnless(sys.platform == 'darwin' and pathlib.Path('/sbin/pfctl').exists(), 'macOS pfctl required')
class ParserTests(unittest.TestCase):
    def test_nonoptimized_rules_remain_individually_verifiable(self):
        targets = ['34.36.57.103/32','34.54.194.141/32','34.120.108.227/32',
                   '35.190.46.17/32','153.61.0.0/16','160.79.104.0/21',
                   '216.73.216.0/22','2607:6bc0::/32']
        interfaces = ['en0','en1','en2','en3','en4','en5','en6','bridge0']
        rules=''.join('block drop out quick on %s %s from any to %s\n' %
                      (interface, 'inet6' if ':' in target else 'inet', target)
                      for interface in interfaces for target in targets)
        with tempfile.TemporaryDirectory() as d:
            candidate=pathlib.Path(d)/'rules'; candidate.write_text(rules)
            result=subprocess.run(['/sbin/pfctl','-o','none','-n','-v','-f',str(candidate)],
                                  text=True,capture_output=True,check=True)
            output=result.stdout
            self.assertNotIn('<__automatic_', output)
            self.assertEqual(len([x for x in output.splitlines() if x.startswith('block ')]),len(interfaces)*len(targets))
            # Run the real shell verifier over PF's own normalized output.
            parsed=pathlib.Path(d)/'parsed';parsed.write_text(output)
            source=pathlib.Path(__file__).with_name('claude-lockdown.sh').read_text().split('case "${1:-status}"')[0]
            lib=pathlib.Path(d)/'lib.sh';lib.write_text(source)
            subprocess.run(['/bin/bash','-c','source "$1"; verify_rules "$2" "$3"','test',str(lib),str(candidate),str(parsed)],check=True)

if __name__=='__main__': unittest.main()
