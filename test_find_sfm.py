import json, pathlib, sqlite3, tempfile, unittest
import find_sfm_profiles as f

class ProfileTests(unittest.TestCase):
    def test_finds_port_without_exposing_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp);group=root/'test.io.nekohasekai.sfavt';group.mkdir()
            conf=group/'config.json';conf.write_text(json.dumps({'inbounds':[{'type':'mixed','listen':'127.0.0.1','listen_port':2345}], 'outbounds':[{'uuid':'private-secret'}]}))
            db=sqlite3.connect(group/'settings.db');db.execute('create table profiles(name text,path text)');db.execute('insert into profiles values (?,?)',('profile A',str(conf)));db.commit();db.close()
            rows=list(f.find_profiles(root))
            self.assertEqual(len(rows),1);self.assertEqual(rows[0][0],'profile A');self.assertEqual(rows[0][2],[2345]);self.assertNotIn('private-secret',str(rows))
    def test_profile_without_proxy_is_shown(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp);group=root/'group.io.nekohasekai.sfavt';group.mkdir()
            conf=group/'config.json';conf.write_text('{"inbounds": []}')
            db=sqlite3.connect(group/'settings.db');db.execute('create table profiles(name text,path text)');db.execute('insert into profiles values (?,?)',('empty',str(conf)));db.commit();db.close()
            self.assertEqual(list(f.find_profiles(root))[0][2],[])

if __name__=='__main__':unittest.main()
