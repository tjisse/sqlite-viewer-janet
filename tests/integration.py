"""Real HTTP/JWT/SSE integration tests. Ephemeral keys use cryptography, never application crypto."""
import base64
import http.client
from html.parser import HTMLParser
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
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes

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
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        public = cls.key.public_key().public_numbers()
        jwks = {'keys': [{'kty':'RSA', 'kid':'test', 'alg':'RS256',
                         'n':b64(public.n.to_bytes(256, 'big')), 'e':b64(public.e.to_bytes(3, 'big'))}]}
        (cls.path/'jwks.json').write_text(json.dumps(jwks))
        (cls.path/'databases.json').write_text(json.dumps({'Studio':str(cls.database)}))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); cls.port = sock.getsockname()[1]
        cls.origin = f'http://127.0.0.1:{cls.port}'
        env = dict(os.environ, JANET_PATH=str(cls.path/'no-modules'), SV_PORT=str(cls.port), SV_HOST='127.0.0.1', SV_ALLOW_HTTP='1',
                   SV_ORIGIN=cls.origin, SV_ISSUER='https://test.cloudflareaccess.com', SV_AUDIENCE='sqlite-viewer',
                   SV_JWKS=str(cls.path/'jwks.json'), SV_DATABASES=str(cls.path/'databases.json'))
        cls.env = env
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
        claims = dict(iss='https://test.cloudflareaccess.com', aud='sqlite-viewer', sub='test-user',
                      exp=int(time.time())+300, type='app',
                      custom={'roles':['sqlite-viewer.viewer','sqlite-viewer.db.Studio.read']})
        claims.update(changes)
        unsigned = b64(json.dumps({'alg':'RS256','kid':'test'}).encode())+'.'+b64(json.dumps(claims).encode())
        return unsigned+'.'+b64(cls.key.sign(unsigned.encode(), padding.PKCS1v15(), hashes.SHA256()))

    @classmethod
    def request(cls, path, method='GET', payload=None, authenticated=True, headers=None):
        hdr = {'Cf-Access-Jwt-Assertion':cls.token()} if authenticated else {}
        hdr.update(headers or {})
        conn = http.client.HTTPConnection('127.0.0.1', cls.port, timeout=5)
        conn.request(method,path,body=payload,headers=hdr)
        response = conn.getresponse()
        result = response.status, dict(response.getheaders()), response.read().decode()
        conn.close(); return result

    def test_auth_boundary(self):
        self.assertEqual(401,self.request('/?table=customers',authenticated=False)[0])
        for token in [self.token(exp=1),self.token(aud='wrong'),self.token(iss='wrong'),
                      self.token(custom={'roles':[]}), self.token(sub=''),self.token()[:-8]+'tampered']:
            self.assertEqual(401,self.request('/',headers={'Cf-Access-Jwt-Assertion':token})[0])
        self.assertEqual(403,self.request('/',headers={'Cf-Access-Jwt-Assertion':self.token(custom={'roles':['sqlite-viewer.viewer','sqlite-viewer.db.Other.read']})})[0])
        self.assertEqual(403,self.request('/?db=secret')[0])
        self.assertEqual(403,self.request('/',headers={'Host':'evil.test'})[0])

    def test_startup_rejects_invalid_access_config(self):
        for changes in [{'SV_ISSUER':'https://evil.test'}, {'SV_AUDIENCE':''},
                        {'SV_ISSUER':'https://test.cloudflareaccess.com/path'}]:
            result = subprocess.run([self.binary], cwd=self.path,
                                    env=dict(self.env, **changes), capture_output=True, timeout=5)
            self.assertNotEqual(0, result.returncode)
        aliases = self.path/'reserved.json'
        aliases.write_text(json.dumps({'All':str(self.database)}))
        result = subprocess.run([self.binary], cwd=self.path,
                                env=dict(self.env, SV_DATABASES=str(aliases)), capture_output=True, timeout=5)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b'reserved', result.stderr)

    def test_streams_stop_at_expiry(self):
        token = self.token(exp=int(time.time())+2)
        status, _, body = self.request('/events?table=customers',
                                      headers={'Cf-Access-Jwt-Assertion':token})
        self.assertEqual(200, status)
        self.assertIn('Session expired', body)
        token = self.token(exp=int(time.time())+2)
        status, _, body = self.request('/query', 'POST', '{"sql":"SELECT 1"}', headers={
            'Origin':self.origin, 'Datastar-Request':'true', 'Cf-Access-Jwt-Assertion':token})
        self.assertEqual(200, status)
        self.assertIn('Session expired', body)

    def test_embedded_assets(self):
        for name in ['app.css', 'app.js', 'datastar.js', 'icon.svg']:
            status, _, body = self.request('/assets/'+name, authenticated=False)
            self.assertEqual(200, status)
            self.assertEqual((ROOT/'assets'/name).read_text(), body)

    def test_access_login_logout_and_csrf(self):
        status, headers, body = self.request('/', authenticated=False)
        self.assertEqual(401, status)
        self.assertIn('Cloudflare Access', body)
        self.assertNotIn('name="token"', body)
        status, page_headers, signed_in = self.request('/')
        self.assertEqual(200, status)
        self.assertEqual('same-origin', page_headers['Referrer-Policy'])
        class SignOutParser(HTMLParser):
            def __init__(self):
                super().__init__()
                self.links = []
                self.forms = []

            def handle_starttag(self, tag, attrs):
                attrs = dict(attrs)
                if tag == 'a' and attrs.get('class') == 'sign-out':
                    self.links.append(attrs.get('href'))
                if tag == 'form':
                    self.forms.append((attrs.get('action'), attrs.get('method')))

        parsed = SignOutParser()
        parsed.feed(signed_in)
        self.assertEqual([], parsed.links)
        self.assertIn(('/logout', 'post'), parsed.forms)
        payload = urllib.parse.urlencode({'token':self.token()})
        self.assertEqual(404, self.request('/session', 'POST', payload, False,
                                          {'Origin':self.origin})[0])
        for headers in [{'Authorization':'Bearer '+self.token()},
                        {'Cookie':'sv_session='+self.token()},
                        {'Cookie':'CF_Authorization='+self.token()},
                        {'Cf-Access-Authenticated-User-Email':'alice@example.com'}]:
            self.assertEqual(401, self.request('/', authenticated=False, headers=headers)[0])
        status, headers, _ = self.request('/logout', 'POST', '', headers={'Origin':self.origin})
        self.assertEqual(303, status)
        self.assertEqual('/cdn-cgi/access/logout', headers['Location'])
        self.assertNotIn('Set-Cookie', headers)
        for origin in [None, 'null', 'https://evil.test']:
            headers = {} if origin is None else {'Origin':origin}
            self.assertEqual(403, self.request('/logout', 'POST', '', headers=headers)[0])
        self.assertEqual(403, self.request('/logout', headers={'Origin':self.origin})[0])
        self.assertEqual(403,self.request('/query','POST','{"sql":"SELECT 1"}',headers={'Origin':'https://evil.test'})[0])

    def test_entra_role_grants(self):
        for custom in [None, {}, {'roles':'sqlite-viewer.viewer'},
                       {'roles':['sqlite-viewer.viewer', 42]},
                       {'roles':['viewer','sqlite-viewer.db.Studio.read']}]:
            self.assertEqual(401, self.request('/', headers={
                'Cf-Access-Jwt-Assertion':self.token(custom=custom)})[0])
        self.assertEqual(401, self.request('/', headers={
            'Cf-Access-Jwt-Assertion':self.token(type='service')})[0])
        for roles in [['sqlite-viewer.viewer'],
                      ['sqlite-viewer.viewer', 'sqlite-viewer.db.studio.read'],
                      ['sqlite-viewer.viewer', 'other.db.Studio.read']]:
            token = self.token(custom={'roles':roles}, databases=['*'])
            headers = {'Cf-Access-Jwt-Assertion':token, 'Origin':self.origin}
            for path, method, payload in [('/', 'GET', None), ('/export?table=customers','GET',None),
                                          ('/events?table=customers','GET',None),
                                          ('/query','POST','{"sql":"SELECT 1"}')]:
                self.assertEqual(403, self.request(path, method, payload, headers=headers)[0])
        for roles in [['sqlite-viewer.viewer', 'sqlite-viewer.db.All.read'],
                      ['unrelated.role','sqlite-viewer.viewer','sqlite-viewer.db.Studio.read']]:
            self.assertEqual(200, self.request('/', headers={
                'Cf-Access-Jwt-Assertion':self.token(custom={'roles':roles})})[0])

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

    def test_html_attributes_and_datastar(self):
        class Elements(HTMLParser):
            def __init__(self, source):
                super().__init__()
                self.elements = []
                self.feed(source)

            def handle_starttag(self, tag, attrs):
                self.elements.append((tag, dict(attrs)))

        value = '"<probe>&\'/100%'
        params = {'table': 'customers', 'search': value, 'hidden': 'email'}
        status, _, body = self.request('/?' + urllib.parse.urlencode(params))
        self.assertEqual(200, status)
        elements = Elements(body).elements
        search = next(attrs for tag, attrs in elements if attrs.get('name') == 'search')
        self.assertEqual(value, search['value'])
        self.assertFalse(any(tag == 'probe' for tag, _ in elements))
        columns = [attrs for tag, attrs in elements if 'data-column' in attrs]
        self.assertTrue(columns)
        for attrs in columns:
            self.assertEqual(attrs['data-column'] != 'email', 'checked' in attrs)
        subscription = next(attrs for _, attrs in elements if attrs.get('id') == 'subscription')
        expression = subscription['data-init']
        self.assertTrue(expression.startswith("@get('/events?"))
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(expression[6:-2]).query)
        self.assertEqual([value], query['search'])
        _, _, body = self.request('/?table=customers&tab=SQL')
        elements = Elements(body).elements
        editor = next(attrs for _, attrs in elements if attrs.get('class') == 'sql-editor')
        self.assertEqual({'sql': 'SELECT * FROM "customers" LIMIT 100'}, json.loads(editor['data-signals']))
        self.assertEqual("@post('/query?db=Studio')", editor['data-on:submit__prevent'])
        self.assertTrue(any('data-bind:sql' in attrs for _, attrs in elements))

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
        conn.request('GET','/events?table=customers&search=ReactiveProbe',headers={'Cf-Access-Jwt-Assertion':self.token()})
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
            'Cf-Access-Jwt-Assertion':self.token(), 'Origin':self.origin,
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
        conn.request('GET','/events?table=products&tab=Schema',headers={'Cf-Access-Jwt-Assertion':self.token()})
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
