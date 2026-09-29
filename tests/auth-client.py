"""Exercise embedded HTTPS bindings, TLS validation and real signed key rotation."""
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import base64
import json
import ssl
import subprocess
import tempfile
import threading
import time
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / '.build/jpm/sqlite-viewer-auth-tests'

def b64(value):
    return base64.urlsafe_b64encode(value).decode().rstrip('=')

def jwk(key, kid):
    public = key.public_key().public_numbers()
    return {'kty':'RSA', 'kid':kid, 'alg':'RS256',
            'n':b64(public.n.to_bytes(256, 'big')), 'e':b64(public.e.to_bytes(3, 'big'))}

def token(key, kid):
    claims = {'iss':'https://test.cloudflareaccess.com', 'aud':'sqlite-viewer',
              'sub':'test', 'type':'app', 'exp':int(time.time())+600,
              'custom':{'roles':['sqlite-viewer.viewer','sqlite-viewer.db.Studio.read']}}
    unsigned = b64(json.dumps({'alg':'RS256','kid':kid}).encode())+'.'+b64(json.dumps(claims).encode())
    return unsigned+'.'+b64(key.sign(unsigned.encode(), padding.PKCS1v15(), hashes.SHA256()))

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        try:
            if self.path == '/slow':
                time.sleep(6)
            if self.path == '/redirect':
                self.send_response(302)
                self.send_header('Location', '/ok')
                self.end_headers()
                return
            self.send_response(503 if self.path == '/error' else 200)
            body = b'x' * (1048576+1) if self.path in ['/large', '/unknown-size'] else b'trusted keys'
            if self.path != '/unknown-size':
                self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp)
    old = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    new = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    (directory/'old.json').write_text(json.dumps({'keys':[jwk(old,'old')]}))
    (directory/'rotated.json').write_text(json.dumps({'keys':[jwk(old,'old'),jwk(new,'new')]}))
    (directory/'invalid.json').write_text('{invalid}')
    (directory/'old.jwt').write_text(token(old,'old'))
    (directory/'new.jwt').write_text(token(new,'new'))
    subprocess.run([BINARY, 'cache', directory], check=True, timeout=15)

    # A private, temporary root and server certificate exercise both trust and
    # hostname verification without depending on an external network service.
    now = datetime.now(timezone.utc)
    root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Test root')])
    ca = (x509.CertificateBuilder().subject_name(root_name).issuer_name(root_name)
          .public_key(old.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now-timedelta(minutes=1)).not_valid_after(now+timedelta(days=1))
          .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
          .sign(old, hashes.SHA256()))
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'localhost')]))
            .issuer_name(root_name).public_key(new.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now-timedelta(minutes=1)).not_valid_after(now+timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), critical=False)
            .sign(old, hashes.SHA256()))
    (directory/'ca.pem').write_bytes(ca.public_bytes(serialization.Encoding.PEM))
    (directory/'cert.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (directory/'key.pem').write_bytes(new.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(directory/'cert.pem', directory/'key.pem')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    url = f'https://localhost:{server.server_port}'
    try:
        for path, expected in [('/ok','ok'),('/redirect','fail'),('/error','fail'),
                               ('/large','fail'),('/unknown-size','fail'),('/slow','fail')]:
            subprocess.run([BINARY,'https',url+path,directory/'ca.pem',expected],check=True,timeout=10)
        subprocess.run([BINARY,'https',url+'/ok','/etc/ssl/certs/ca-certificates.crt','fail'],
                       check=True,timeout=10)
        subprocess.run([BINARY,'https',url.replace('localhost','127.0.0.1')+'/ok',
                        directory/'ca.pem','fail'],check=True,timeout=10)
        subprocess.run([BINARY,'https',url.replace('https:','http:')+'/ok',
                        directory/'ca.pem','fail'],check=True,timeout=10)
    finally:
        server.shutdown()
        server.server_close()
    print('Passed key rotation/cache and HTTPS trust, hostname, protocol, redirect, status, size and timeout checks')
