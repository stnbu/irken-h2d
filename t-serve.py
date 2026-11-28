# -*- Mode: Python -*-

# plain serve, end to end: it serves files, /status needs a login, and
#   it has nothing of x402 in it.  needs python3, openssl, and a curl
#   with HTTP/2.
#
#   python3 t-serve.py ./serve
#
# (x402/test-e2e.py does serve-x402.)

import os
import sys
import time
import shutil
import socket
import argparse
import tempfile
import subprocess

PJ = os.path.join

def free_port():
    s = socket.socket()
    s.bind (('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port

def openssl():
    # macOS's own openssl is LibreSSL, which can't make these
    #   certificates: use Homebrew's if it's there.
    try:
        prefix = subprocess.run (['brew', '--prefix', 'openssl'], capture_output=True, text=True).stdout.strip()
        if prefix and os.path.exists (PJ (prefix, 'bin', 'openssl')):
            return PJ (prefix, 'bin', 'openssl')
    except OSError:
        pass
    return 'openssl'

def make_cert (dir):
    cert, key = PJ (dir, 'site.pem'), PJ (dir, 'site-key.pem')
    subprocess.run ([openssl(), 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
                     '-nodes', '-keyout', key, '-out', cert, '-days', '2', '-subj', '/CN=localhost',
                     '-addext', 'subjectAltName=DNS:localhost'],
                    check=True, capture_output=True)
    return cert, key

def get (port, path, user=None):
    # --compressed: irken-h2d deflates whether or not the client asks.
    #   --noproxy: this is all on 127.0.0.1, whatever *_PROXY says.
    cmd = ['curl', '-sS', '-k', '--http2', '--compressed', '--noproxy', '*', '--max-time', '20',
           '-o', '-', '-w', '\n%{http_code}']
    if user:
        cmd += ['-u', user]
    cmd.append ('https://localhost:%d%s' % (port, path))
    out = subprocess.run (cmd, capture_output=True).stdout.decode ('utf-8', 'replace')
    body, _, status = out.rpartition ('\n')
    return int (status or 0), body

failures = []

def check (name, ok, detail=''):
    print ('%s  %s%s' % ('PASS' if ok else 'FAIL', name, '' if ok else ': ' + detail), flush=True)
    if not ok:
        failures.append (name)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument ('serve', help='the serve binary')
    ap.add_argument ('-k', action='store_true', help='keep the scratch directory')
    args = ap.parse_args()
    serve = os.path.abspath (args.serve)
    tmp = tempfile.mkdtemp (prefix='t-serve-')
    srv = None
    try:
        check ('no x402 in serve', b'x402' not in open (serve, 'rb').read().lower())
        out = subprocess.run ([serve, '-h'], capture_output=True, timeout=20)
        check ('no -x402 in the usage', b'x402' not in out.stdout + out.stderr, (out.stdout + out.stderr).decode()[-300:])
        out = subprocess.run ([serve, '127.0.0.1:%d' % (free_port(),), '-x402', 'x.conf'], capture_output=True, timeout=20)
        check ('-x402 is refused', out.returncode != 0 and b'Unwanted argument: -x402' in out.stdout + out.stderr,
               (out.stdout + out.stderr).decode()[-300:])

        cert, key = make_cert (tmp)
        www = PJ (tmp, 'www', 'localhost')
        os.makedirs (PJ (www, 'premium'))
        open (PJ (www, 'index.html'), 'w').write ('home\n')
        open (PJ (www, 'premium', 'article.html'), 'w').write ('article\n')
        users = PJ (tmp, 'users')
        open (users, 'w').write ('admin:sesame\n')
        os.chmod (users, 0o600)
        port = free_port()
        log = open (PJ (tmp, 'serve.out'), 'w')
        srv = subprocess.Popen ([serve, '127.0.0.1:%d' % (port,), '-root', PJ (tmp, 'www'), '-cert', cert, '-key', key,
                                 '-log', PJ (tmp, 'access.log'), '-r', '-users', users],
                                stdout=log, stderr=subprocess.STDOUT)
        for i in range (100):
            if srv.poll() is not None:
                sys.exit ('serve exited early (%d)' % (srv.returncode,))
            try:
                socket.create_connection (('127.0.0.1', port), 0.1).close()
                break
            except OSError:
                time.sleep (0.1)

        status, body = get (port, '/')
        check ('a page', status == 200 and body == 'home\n', '%d %r' % (status, body))
        status, body = get (port, '/premium/article.html')
        check ('/premium/ is just files', status == 200 and body == 'article\n', '%d %r' % (status, body))
        status, body = get (port, '/missing.html')
        check ('a missing page: 404', status == 404, str (status))
        status, body = get (port, '/status/')
        check ('/status/ needs a login', status == 401, str (status))
        status, body = get (port, '/status/', user='admin:wrong')
        check ('a wrong password: 401', status == 401, str (status))
        status, body = get (port, '/status/', user='admin:sesame')
        check ('/status/ with a password', status == 200 and 'html' in body.lower(), str (status))
        status, body = get (port, '/premium/article.html', user='admin:sesame')
        check ('logged in, pages are the same', status == 200 and body == 'article\n', '%d %r' % (status, body))
        check ('serve says nothing of x402', 'x402' not in open (PJ (tmp, 'serve.out')).read())
    finally:
        if srv and srv.poll() is None:
            srv.terminate()
            srv.wait()
        if args.k or failures:
            print ('scratch directory:', tmp)
        else:
            shutil.rmtree (tmp, ignore_errors=True)
    print ('%d failed' % (len (failures),))
    sys.exit (1 if failures else 0)

if __name__ == '__main__':
    main()
