"""Real HTTP/JWT/SSE integration tests. Ephemeral keys use cryptography, never application crypto."""
import base64
import http.client
import json
import os
import shutil
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest
import urllib.parse
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'dist/bin/sqlite-viewer'
def b64(value):
    return base64.urlsafe_b64encode(value).decode().rstrip('=')

class Viewer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.path = Path(cls.temp.name)
        # Run only a copied executable, from an unrelated directory. No source,
        # asset directory, installed Janet, or native module tree is available.
        cls.binary = cls.path / 'sqlite-viewer'
        shutil.copy2(BINARY, cls.binary)
        cls.database = cls.path / 'demo.sqlite'
        subprocess.run([cls.binary, '--seed', cls.database], cwd=cls.path,
                       check=True, capture_output=True)
        cls.key = Ed25519PrivateKey.generate()
        jwks = {'keys': [{'kty':'OKP', 'crv':'Ed25519', 'kid':'test', 'alg':'EdDSA',
                         'x':b64(cls.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))}]}
        (cls.path/'jwks.json').write_text(json.dumps(jwks))
        (cls.path/'databases.json').write_text(json.dumps({'Studio':str(cls.database)}))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); cls.port = sock.getsockname()[1]
        cls.origin = f'http://127.0.0.1:{cls.port}'
        env = dict(os.environ, JANET_PATH=str(cls.path/'no-modules'), SV_PORT=str(cls.port), SV_HOST='127.0.0.1', SV_ALLOW_HTTP='1',
                   SV_ORIGIN=cls.origin, SV_ISSUER='https://issuer.test', SV_AUDIENCE='sqlite-viewer',
                   SV_JWKS=str(cls.path/'jwks.json'), SV_DATABASES=str(cls.path/'databases.json'))
        cls.log = (cls.path/'server.log').open('w+')
        cls.server = subprocess.Popen([cls.binary], cwd=cls.path, env=env, stdout=cls.log, stderr=cls.log)
        for _ in range(100):
            try:
                if cls.request('/healthz', authenticated=False)[0] == 200: break
            except OSError: time.sleep(.05)
        else:
            cls.log.seek(0); raise RuntimeError(cls.log.read())

    @classmethod
    def tearDownClass(cls):
        if cls.server.poll() is not None:
            cls.log.seek(0)
            print(f'Server exited unexpectedly ({cls.server.returncode}):\n{cls.log.read()}')
        cls.server.terminate(); cls.server.wait(timeout=5); cls.log.close(); cls.temp.cleanup()

    @classmethod
    def token(cls, **changes):
        claims = dict(iss='https://issuer.test', aud='sqlite-viewer', sub='test-user',
                      exp=int(time.time())+300, roles=['viewer'], databases=['Studio'])
        claims.update(changes)
        unsigned = b64(json.dumps({'alg':'EdDSA','kid':'test'}).encode())+'.'+b64(json.dumps(claims).encode())
        return unsigned+'.'+b64(cls.key.sign(unsigned.encode()))

    @classmethod
    def request(cls, path, method='GET', payload=None, authenticated=True, headers=None):
        hdr = {'Authorization':'Bearer '+cls.token()} if authenticated else {}
        hdr.update(headers or {})
        conn = http.client.HTTPConnection('127.0.0.1', cls.port, timeout=5)
        conn.request(method,path,body=payload,headers=hdr)
        response = conn.getresponse()
        result = response.status, dict(response.getheaders()), response.read().decode()
        conn.close(); return result

    def test_auth_boundary(self):
        self.assertEqual(401,self.request('/?table=customers',authenticated=False)[0])
        for token in [self.token(exp=1),self.token(aud='wrong'),self.token(iss='wrong'),
                      self.token(roles=[]), self.token(sub=''),self.token()[:-8]+'tampered']:
            self.assertEqual(401,self.request('/',headers={'Authorization':'Bearer '+token})[0])
        self.assertEqual(403,self.request('/',headers={'Authorization':'Bearer '+self.token(databases=['Other'])})[0])
        self.assertEqual(403,self.request('/?db=secret')[0])
        self.assertEqual(403,self.request('/',headers={'Host':'evil.test'})[0])

    def test_embedded_assets(self):
        for name in ['app.css', 'app.js', 'datastar.js', 'icon.svg']:
            status, _, body = self.request('/assets/'+name, authenticated=False)
            self.assertEqual(200, status)
            self.assertEqual((ROOT/'assets'/name).read_text(), body)

    def test_session_and_csrf(self):
        payload=urllib.parse.urlencode({'token':self.token()})
        status,headers,_=self.request('/session','POST',payload,False,{'Origin':self.origin,'Content-Type':'application/x-www-form-urlencoded'})
        self.assertEqual(303,status)
        cookie=headers['Set-Cookie']
        self.assertIn('HttpOnly',cookie); self.assertIn('SameSite=Strict',cookie)
        self.assertEqual(200,self.request('/?table=customers',authenticated=False,headers={'Cookie':cookie.split(';')[0]})[0])
        self.assertEqual(403,self.request('/session','POST',payload,False,{'Origin':'https://evil.test'})[0])
        self.assertEqual(403,self.request('/query','POST','{"sql":"SELECT 1"}',headers={'Origin':'https://evil.test'})[0])

    def test_views_search_sort_and_columns(self):
        for tab in ['Data','Schema','Indexes','SQL']:
            status,_,html=self.request('/?table=customers&tab='+tab)
            self.assertEqual(200,status,html)
            self.assertNotIn('Couldn’t load',html)
        _,_,html=self.request('/?table=customers&search=Olivia&size=10&sort=id&direction=desc&hidden=email')
        self.assertIn('Olivia Martin',html)
        self.assertNotIn('<th scope="col">email</th>',html)
        self.assertIn('Page 1 of 2',html)
        _,_,html=self.request('/?table=customers&filter=country&value=Japan&op=equals')
        self.assertIn('40 rows',html)
        self.assertEqual(400,self.request('/?table=missing')[0])

    def test_sql_and_export(self):
        for query,valid in [('SELECT 42 AS answer',True),('DELETE FROM customers',False),
                            ("ATTACH '/tmp/private.db' AS secret",False),('SELECT 1; SELECT 2',False)]:
            status,_,data=self.request('/query?db=Studio','POST',json.dumps({'sql':query}),headers={'Origin':self.origin,'Content-Type':'application/json'})
            self.assertEqual(200,status)
            self.assertIn('datastar-patch-elements',data)
            self.assertEqual(not valid,'Couldn’t load' in data)
        status,headers,csv=self.request('/export?table=customers&size=10')
        self.assertEqual(200,status); self.assertIn('text/csv',headers['Content-Type'])
        self.assertEqual(11,len(csv.splitlines()))

    def test_external_writer_reactive_update(self):
        conn=http.client.HTTPConnection('127.0.0.1',self.port,timeout=5)
        conn.request('GET','/events?table=customers&search=ReactiveProbe',headers={'Authorization':'Bearer '+self.token()})
        response=conn.getresponse(); self.assertEqual(200,response.status)
        while b'No rows to show' not in response.readline(): pass
        writer=sqlite3.connect(self.database)
        writer.execute("INSERT INTO customers(name) VALUES('ReactiveProbe')"); writer.commit(); writer.close()
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            line=response.readline()
            if b'<td><span title="ReactiveProbe">' in line: break
        else: self.fail('External commit did not reach SSE subscriber')
        conn.close()
        self.assertEqual(200,self.request('/healthz',authenticated=False)[0])

    def test_live_sql_subscription(self):
        conn=http.client.HTTPConnection('127.0.0.1',self.port,timeout=5)
        payload=json.dumps({'sql':"SELECT name FROM customers WHERE name='LiveSqlProbe'"})
        conn.request('POST','/query?db=Studio',body=payload,headers={
            'Authorization':'Bearer '+self.token(), 'Origin':self.origin,
            'Content-Type':'application/json', 'Datastar-Request':'true'})
        response=conn.getresponse(); self.assertEqual(200,response.status)
        while b'No rows to show' not in response.readline(): pass
        with sqlite3.connect(self.database) as writer:
            writer.execute("INSERT INTO customers(name) VALUES('LiveSqlProbe')")
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if b'<td><span title="LiveSqlProbe">' in response.readline(): break
        else: self.fail('SQL subscription did not refresh')
        conn.close()

    def test_schema_subscription(self):
        conn=http.client.HTTPConnection('127.0.0.1',self.port,timeout=5)
        conn.request('GET','/events?table=products&tab=Schema',headers={'Authorization':'Bearer '+self.token()})
        response=conn.getresponse(); self.assertEqual(200,response.status)
        while b'primary_key' not in response.readline(): pass
        with sqlite3.connect(self.database) as writer:
            writer.execute('ALTER TABLE products ADD COLUMN reactive_column TEXT')
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if b'reactive_column' in response.readline(): break
        else: self.fail('Schema subscription did not refresh')
        conn.close()

if __name__=='__main__': unittest.main(verbosity=2)
