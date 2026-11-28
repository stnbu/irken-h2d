# -*- Mode: Python -*-

# x402 end to end: a real irken-h2d (serve-x402) charging for a directory,
#   settled by x402/mock-facilitator.py, exercised with curl over
#   HTTP/2.  needs python3, openssl, and a curl with HTTP/2.
#
#   python3 x402/test-e2e.py ./serve-x402
#
# everything (certificates, site, config, logs) goes in a scratch
#   directory, removed afterwards unless -k.

import os
import sys
import json
import time
import base64
import shutil
import signal
import socket
import argparse
import tempfile
import subprocess

PJ = os.path.join
HERE = os.path.dirname (os.path.abspath (__file__))

PAY_TO = '0x209693Bc6afc0C5328bA36FaF03C514EF312287C'
ASSET = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
NETWORK = 'eip155:84532'
PRICE = '10000'
PAYER = '0x857b06519E91e3A54538791bDbb0E22373e36b66'
# a second site, with its own address and a price of its own.
OTHER = 'other.test'
OTHER_PAY_TO = '0x' + 'ab' * 20
MEMBERS_PRICE = '50000'

def free_port():
    s = socket.socket()
    s.bind (('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port

def make_cert (dir, name):
    cert, key = PJ (dir, name + '.pem'), PJ (dir, name + '-key.pem')
    subprocess.run (['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
                     '-nodes', '-keyout', key, '-out', cert, '-days', '2', '-subj', '/CN=localhost',
                     '-addext', 'subjectAltName=DNS:localhost,DNS:%s' % (OTHER,)],
                    check=True, capture_output=True)
    return cert, key

def wait_for (port, proc, what):
    for i in range (100):
        if proc.poll() is not None:
            sys.exit ('%s exited early (%d)' % (what, proc.returncode))
        try:
            socket.create_connection (('127.0.0.1', port), 0.1).close()
            return
        except OSError:
            time.sleep (0.1)
    sys.exit ('%s never listened on %d' % (what, port))

def b64 (ob):
    return base64.b64encode (json.dumps (ob, separators=(',', ':')).encode()).decode()

def unb64 (s):
    return json.loads (base64.b64decode (s))

def requirements (amount=PRICE, pay_to=PAY_TO, network=NETWORK):
    return {'scheme': 'exact', 'network': network, 'amount': amount, 'asset': ASSET, 'payTo': pay_to,
            'maxTimeoutSeconds': 60, 'extra': {'name': 'USDC', 'version': '2'}}

nonce_counter = [0]

def payment (payer=PAYER, amount=PRICE, accepted=None, nonce=None, pay_to=PAY_TO):
    """a PaymentPayload; the mock facilitator doesn't check the signature."""
    nonce_counter[0] += 1
    now = int (time.time())
    return {'x402Version': 2,
            'accepted': accepted or requirements (amount),
            'payload': {'signature': '0x' + '11' * 65,
                        'authorization': {'from': payer, 'to': pay_to, 'value': amount,
                                          'validAfter': str (now - 600), 'validBefore': str (now + 60),
                                          'nonce': nonce or ('0x%064x' % (nonce_counter[0] + int (now) * 1000))}},
            'extensions': {}}

class Result:
    def __init__ (self, status, headers, body):
        self.status, self.headers, self.body = status, headers, body

def get (port, path, headers={}, path_as_is=False, user=None, host='localhost'):
    # --compressed: irken-h2d deflates whether or not the client asks
    #   (a known bug), so ask, as most clients do.
    # --noproxy: this is all on 127.0.0.1, whatever *_PROXY says.
    cmd = ['curl', '-sS', '-k', '--http2', '--compressed', '--noproxy', '*', '--max-time', '20', '-D', '-', '-o', '-']
    if path_as_is:
        cmd.append ('--path-as-is')
    if user:
        cmd += ['-u', user]
    if host != 'localhost':
        cmd += ['--resolve', '%s:%d:127.0.0.1' % (host, port)]
    for k, v in headers.items():
        cmd += ['-H', '%s: %s' % (k, v)]
    cmd.append ('https://%s:%d%s' % (host, port, path))
    out = subprocess.run (cmd, capture_output=True).stdout.decode ('utf-8', 'replace')
    head, _, body = out.partition ('\r\n\r\n')
    lines = head.split ('\r\n')
    status = int (lines[0].split()[1]) if lines and lines[0].startswith ('HTTP') else 0
    hs = {}
    for l in lines[1:]:
        k, _, v = l.partition (':')
        hs[k.strip().lower()] = v.strip()
    return Result (status, hs, body)

failures = []

def check (name, ok, detail=''):
    print ('%s  %s%s' % ('PASS' if ok else 'FAIL', name, '' if ok else ': ' + detail), flush=True)
    if not ok:
        failures.append (name)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument ('serve', help='the serve-x402 binary')
    ap.add_argument ('-k', action='store_true', help='keep the scratch directory')
    args = ap.parse_args()
    serve = os.path.abspath (args.serve)
    tmp = tempfile.mkdtemp (prefix='x402-e2e-')
    procs = []
    try:
        site_cert, site_key = make_cert (tmp, 'site')
        fac_cert, fac_key = make_cert (tmp, 'facilitator')
        www = PJ (tmp, 'www', 'localhost')
        os.makedirs (PJ (www, 'premium'))
        open (PJ (www, 'index.html'), 'w').write ('free page\n')
        open (PJ (www, 'premium', 'article.html'), 'w').write ('paid article\n')
        os.makedirs (PJ (www, 'members'))
        open (PJ (www, 'members', 'list.html'), 'w').write ('localhost members\n')
        other = PJ (tmp, 'www', OTHER)
        for d in ['premium', 'members']:
            os.makedirs (PJ (other, d))
            open (PJ (other, d, 'page.html'), 'w').write ('%s %s\n' % (OTHER, d))
        fac_port, site_port = free_port(), free_port()
        users = PJ (tmp, 'users')
        open (users, 'w').write ('member:sesame\n')
        os.chmod (users, 0o600)
        conf = PJ (tmp, 'x402.conf')
        open (conf, 'w').write ('\n'.join ([
            '# test configuration',
            'facilitator       https://localhost:%d' % (fac_port,),
            'facilitator-root  %s' % (fac_cert,),
            'network           %s' % (NETWORK,),
            'asset             %s' % (ASSET,),
            'asset-name        USDC',
            'asset-version     2',
            'pay-to            %s' % (PAY_TO,),
            'pay-to %s  %s' % (OTHER, OTHER_PAY_TO),
            'max-timeout       60',
            'price /premium/   %s  premium articles' % (PRICE,),
            'price https://%s/members/  %s  members only' % (OTHER, MEMBERS_PRICE),
            '']))
        fac_log = open (PJ (tmp, 'facilitator.out'), 'w')
        fac = subprocess.Popen ([sys.executable, PJ (HERE, 'mock-facilitator.py'), '-port', str (fac_port),
                                 '-cert', fac_cert, '-key', fac_key], stdout=fac_log, stderr=subprocess.STDOUT)
        procs.append (fac)
        wait_for (fac_port, fac, 'mock facilitator')
        serve_log = open (PJ (tmp, 'serve.out'), 'w')
        srv = subprocess.Popen ([serve, '127.0.0.1:%d' % (site_port,), '-root', PJ (tmp, 'www'),
                                 '-cert', site_cert, '-key', site_key, '-log', PJ (tmp, 'access.log'),
                                 '-r', '-users', users, '-x402', conf], stdout=serve_log, stderr=subprocess.STDOUT)
        procs.append (srv)
        wait_for (site_port, srv, 'serve')

        def settlements():
            return sum (1 for l in open (PJ (tmp, 'facilitator.out'))
                        if l.startswith ('mock-facilitator: /settle') and ' -> ok' in l)

        r = get (site_port, '/')
        check ('a free page is free', r.status == 200 and r.body == 'free page\n' and 'payment-required' not in r.headers,
               '%d %r' % (r.status, r.body))

        r = get (site_port, '/premium/article.html')
        req = unb64 (r.headers['payment-required']) if 'payment-required' in r.headers else {}
        check ('an unpaid request gets 402 and PAYMENT-REQUIRED', r.status == 402 and req.get ('accepts') == [requirements()]
               and req.get ('x402Version') == 2 and req['resource']['url'] == 'https://localhost:%d/premium/article.html' % (site_port,),
               '%d %r' % (r.status, req))
        check ('the 402 body is the same PaymentRequired', r.status == 402 and json.loads (r.body or 'null') == req)

        for path in ['/%70remium/article.html', '/free/../premium/article.html', '//premium/article.html', '/premium/./article.html',
                     '/PREMIUM/article.html', '/Premium/article.html']:
            r = get (site_port, path, path_as_is=True)
            check ('no way around the price: %s' % (path,), r.status == 402, str (r.status))

        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (payment())})
        resp = unb64 (r.headers['payment-response']) if 'payment-response' in r.headers else {}
        check ('a good payment gets the article and PAYMENT-RESPONSE',
               r.status == 200 and r.body == 'paid article\n' and resp.get ('success') is True
               and resp.get ('transaction', '').startswith ('0x') and resp.get ('payer') == PAYER,
               '%d %r %r' % (r.status, r.body, resp))
        check ('a paid response is not cached', 'no-store' in r.headers.get ('cache-control', ''))

        p = payment()
        get (site_port, '/premium/article.html', {'payment-signature': b64 (p)})
        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (p)})
        req = unb64 (r.headers['payment-required']) if 'payment-required' in r.headers else {}
        check ('a payment can\'t be used twice', r.status == 402 and req.get ('error') == 'invalid_transaction_state',
               '%d %r' % (r.status, req.get ('error')))

        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (payment (amount='1', accepted=requirements ('1')))})
        req = unb64 (r.headers['payment-required']) if 'payment-required' in r.headers else {}
        check ('paying less than the price: 402', r.status == 402 and req.get ('error') == 'invalid_payment_requirements',
               '%d %r' % (r.status, req.get ('error')))

        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (payment (accepted=requirements (pay_to='0x' + '12' * 20)))})
        check ('paying someone else: 402', r.status == 402, str (r.status))

        p = payment(); p['payload']['authorization']['value'] = '1'
        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (p)})
        req = unb64 (r.headers['payment-required']) if 'payment-required' in r.headers else {}
        check ('an authorization for less than it claims: 402 from verify',
               r.status == 402 and req.get ('error') == 'invalid_exact_evm_payload_authorization_value_mismatch',
               '%d %r' % (r.status, req.get ('error')))

        for bad in ['not base64!', base64.b64encode (b'not json').decode(), base64.b64encode (b'[1,2,3]').decode()]:
            r = get (site_port, '/premium/article.html', {'payment-signature': bad})
            check ('a malformed PAYMENT-SIGNATURE is a 400: %r' % (bad[:12],), r.status == 400, str (r.status))

        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (payment (payer='0x000000000000000000000000000000000000dead'))})
        req = unb64 (r.headers['payment-required']) if 'payment-required' in r.headers else {}
        check ('no money: 402 insufficient_funds', r.status == 402 and req.get ('error') == 'insufficient_funds',
               '%d %r' % (r.status, req.get ('error')))

        before = settlements()
        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (payment (payer='0x000000000000000000000000000000000000beef'))})
        resp = unb64 (r.headers['payment-response']) if 'payment-response' in r.headers else {}
        check ('settling fails: 402 with PAYMENT-RESPONSE, and no article',
               r.status == 402 and resp.get ('success') is False and resp.get ('errorReason') == 'insufficient_funds'
               and 'paid article' not in r.body and 'payment-required' in r.headers,
               '%d %r %r' % (r.status, resp, r.body[:40]))

        before = settlements()
        r = get (site_port, '/premium/missing.html', {'payment-signature': b64 (payment())})
        check ('a missing page is a 404, and isn\'t charged', r.status == 404 and settlements() == before,
               '%d, settlements %d -> %d' % (r.status, before, settlements()))

        # another host: its own address, for the every-host price and its own.
        def offer (r):
            return (unb64 (r.headers['payment-required']).get ('accepts') or [{}])[0] if 'payment-required' in r.headers else {}
        r = get (site_port, '/premium/page.html', host=OTHER)
        check ('another host pays its own address, for a price for every host',
               r.status == 402 and offer (r) == requirements (pay_to=OTHER_PAY_TO), '%d %r' % (r.status, offer (r)))
        r = get (site_port, '/members/page.html', host=OTHER)
        check ('a host\'s own price', r.status == 402 and offer (r) == requirements (MEMBERS_PRICE, pay_to=OTHER_PAY_TO),
               '%d %r' % (r.status, offer (r)))
        r = get (site_port, '/members/list.html')
        check ('a host\'s price is only for that host', r.status == 200 and r.body == 'localhost members\n', str (r.status))
        r = get (site_port, '/members/page.html', {'payment-signature': b64 (payment())}, host=OTHER)
        check ('paying one host\'s address on another: 402', r.status == 402, str (r.status))
        r = get (site_port, '/members/page.html', host=OTHER,
                 headers={'payment-signature': b64 (payment (amount=MEMBERS_PRICE, pay_to=OTHER_PAY_TO,
                                                             accepted=requirements (MEMBERS_PRICE, pay_to=OTHER_PAY_TO)))})
        check ('paying the other host', r.status == 200 and r.body == '%s members\n' % (OTHER,), '%d %r' % (r.status, r.body[:40]))
        for host in ['OTHER.TEST', 'Other.Test']:
            r = get (site_port, '/members/page.html', host=host)
            check ('no way around a host\'s price: %s' % (host,), r.status in (402, 404), str (r.status))

        before = settlements()
        r = get (site_port, '/premium/article.html', user='member:sesame')
        check ('a logged-in user gets the article free',
               r.status == 200 and r.body == 'paid article\n' and 'payment-response' not in r.headers and settlements() == before,
               '%d %r' % (r.status, r.body[:40]))
        r = get (site_port, '/premium/article.html', user='member:wrong')
        check ('a wrong password pays like anyone else: 402', r.status == 402 and 'payment-required' in r.headers, str (r.status))
        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (payment())})
        check ('the server still works after all that', r.status == 200 and r.body == 'paid article\n', str (r.status))

        answers = [l for l in open (PJ (tmp, 'facilitator.out')) if l.startswith ('mock-facilitator: /')]
        check ('the facilitator\'s answers were compressed, and read', answers and all (l.rstrip().endswith ('(gzipped)') for l in answers),
               ''.join (answers[:3]))

        fac.terminate(); fac.wait()
        r = get (site_port, '/premium/article.html', {'payment-signature': b64 (payment())})
        check ('no facilitator: 500', r.status == 500, str (r.status))
        r = get (site_port, '/')
        check ('free pages still work without the facilitator', r.status == 200, str (r.status))
        r = get (site_port, '/premium/article.html', user='member:sesame')
        check ('logged-in users don\'t need the facilitator', r.status == 200 and r.body == 'paid article\n', str (r.status))

        log = open (PJ (tmp, 'serve.out')).read()
        check ('payments are logged', log.count ('x402: paid 10000 to %s for localhost/premium/article.html by %s' % (PAY_TO, PAYER)) == 3
               and log.count ('x402: paid %s to %s for %s/members/page.html' % (MEMBERS_PRICE, OTHER_PAY_TO, OTHER)) == 1, log)
        check ('free access is logged', log.count ('x402: free for member: localhost/premium/article.html') == 2, log)

        # SIGHUP re-reads the file, and keeps the old one if the new one's bad.
        #   (only where the server reloads on SIGHUP: not on Linux, yet.)
        if 'no SIGHUP reloading' in log:
            print ('SKIP  SIGHUP: this server doesn\'t reload on SIGHUP here')
        else:
            open (conf, 'a').write ('price /premium/dear/ 99000 dearer\n')
            os.makedirs (PJ (www, 'premium', 'dear'))
            open (PJ (www, 'premium', 'dear', 'x.html'), 'w').write ('dear\n')
            srv.send_signal (signal.SIGHUP); time.sleep (1)
            r = get (site_port, '/premium/dear/x.html')
            req = unb64 (r.headers['payment-required']) if 'payment-required' in r.headers else {}
            check ('SIGHUP: a new price', r.status == 402 and req.get ('accepts', [{}])[0].get ('amount') == '99000', '%d %r' % (r.status, req))
            open (conf, 'a').write ('price /x/ lots of money\n')
            srv.send_signal (signal.SIGHUP); time.sleep (1)
            r = get (site_port, '/premium/dear/x.html')
            req = unb64 (r.headers['payment-required']) if 'payment-required' in r.headers else {}
            check ('SIGHUP: a bad file is logged, and the old one kept', r.status == 402
                   and req.get ('accepts', [{}])[0].get ('amount') == '99000'
                   and 'keeping the old one' in open (PJ (tmp, 'serve.out')).read(), '%d %r' % (r.status, req))

        # a bad configuration stops the server, saying why.
        good = open (conf).read().replace ('price /x/ lots of money\n', '')
        for change, why in [
                (('max-timeout       60', 'max-timout 60'), 'unknown setting: max-timout'),
                (('asset-name        USDC', 'asset-name USDC\nasset-name USDC'), 'asset-name: twice'),
                (('pay-to %s' % (OTHER,), 'pay-to %s:443' % (OTHER,)), 'no port'),
                (('price /premium/', 'price premium/'), 'must be a path'),
                (('pay-to            %s\n' % (PAY_TO,), ''), 'no pay-to for every host'),
                (('pay-to %s  %s\n' % (OTHER, OTHER_PAY_TO), 'pay-to %s  0x12\n' % (OTHER,)), 'not an address')]:
            bad = PJ (tmp, 'bad.conf')
            assert change[0] in good, change
            open (bad, 'w').write (good.replace (*change))
            out = subprocess.run ([serve, '127.0.0.1:%d' % (free_port(),), '-root', PJ (tmp, 'www'), '-cert', site_cert,
                                   '-key', site_key, '-log', PJ (tmp, 'access.log'), '-r', '-x402', bad],
                                  capture_output=True, timeout=20)
            text = (out.stdout + out.stderr).decode ('utf-8', 'replace')
            check ('a bad configuration stops the server: %s' % (why,), out.returncode != 0 and why in text,
                   '%d %r' % (out.returncode, text[-200:]))

        # without -x402, serve-x402 is plain serve: nothing is charged.
        srv.terminate(); srv.wait()
        plain_port = free_port()
        plain = subprocess.Popen ([serve, '127.0.0.1:%d' % (plain_port,), '-root', PJ (tmp, 'www'),
                                   '-cert', site_cert, '-key', site_key, '-log', PJ (tmp, 'access.log'), '-r'],
                                  stdout=serve_log, stderr=subprocess.STDOUT)
        procs.append (plain)
        wait_for (plain_port, plain, 'serve-x402 without -x402')
        r = get (plain_port, '/premium/article.html')
        check ('without -x402, nothing is charged', r.status == 200 and r.body == 'paid article\n', str (r.status))
    finally:
        for p in procs:
            if p.poll() is None:
                p.terminate()
                p.wait()
        if args.k or failures:
            print ('scratch directory:', tmp)
        else:
            shutil.rmtree (tmp, ignore_errors=True)
    print ('%d failed' % (len (failures),))
    sys.exit (1 if failures else 0)

if __name__ == '__main__':
    main()
