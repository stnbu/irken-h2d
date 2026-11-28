# Manual testing: a real x402 payment (testnet)

These steps pay irken-h2d with real testnet money: USDC on Base Sepolia,
verified and settled by the public x402.org facilitator.  Everything runs on
your own machine; only the server talks to the facilitator, and nothing needs
to be reachable from the internet.  First done on 2026-11-25 (macOS, Apple
silicon): transaction
[`0x7282a94a5d0031e1697fe3e99b73d4e945f1b952dedabf0365ef2ef5f73ed81c`](https://sepolia.basescan.org/tx/0x7282a94a5d0031e1697fe3e99b73d4e945f1b952dedabf0365ef2ef5f73ed81c).

Use throwaway wallets only.  `pay.py` keeps keys unencrypted.

## 0. What you need

* irken-compiler built (`make bootstrap`) and irken-h2d's `serve-x402` built
  against it, with the automated tests passing (`make test`: see
  "Building" and "Testing" in `README.md`); run them first.
* Python 3.10 to 3.13 (tested with 3.10 and 3.13), in a venv.  macOS's own
  `/usr/bin/python3` (3.9) is too old, and very new Pythons may have to
  compile some dependencies.  With Homebrew:

      brew install python@3.13
      /opt/homebrew/bin/python3.13 -m venv ~/git/irken/.venv
      source ~/git/irken/.venv/bin/activate
      python -m pip install --upgrade pip
      python -m pip install eth-account "httpx[http2]"

  Activate the venv (`source ~/git/irken/.venv/bin/activate`) in each
  terminal you use below.
* Homebrew's openssl, for the test certificate (`brew install openssl`).

## 1. Check that Irken can reach the facilitator

The server talks to the facilitator with Irken's own TLS client, which offers
fewer options than most clients and doesn't follow redirects.  Irken's
`demo/h2/fetch` uses the same client:

    cd ~/git/irken/irken-compiler
    self/compile -C demo/h2/fetch.scm -q
    demo/h2/fetch -i https://x402.org/facilitator/supported

Expect a 200 and JSON whose `kinds` include
`{"x402Version":2,"scheme":"exact","network":"eip155:84532"}`.

## 2. Wallets

    cd ~/git/irken/irken-h2d
    python3 x402/pay.py new-wallet payee
    python3 x402/pay.py new-wallet payer

Each prints its address; keys go in `~/.x402-test/<name>.key`.
`python3 x402/pay.py address <name>` shows an address again.

## 3. Test USDC for the payer

Only the payer needs USDC.  The payee only receives, and neither needs ETH:
the payer just signs an authorization, and the facilitator submits the
transfer and pays the gas.

At https://faucet.circle.com choose USDC (not EURC) and Base Sepolia (it's
further down the network list: scroll, or type "Base"), and paste the
**payer's** address.  Then:

    python3 x402/pay.py balance payer
    python3 x402/pay.py balance payee

## 4. A test site

    mkdir -p ~/tmp/x402-real/www/localhost/premium && cd ~/tmp/x402-real
    echo '<p>you paid for this</p>' > www/localhost/premium/hello.html
    "$(brew --prefix openssl)/bin/openssl" req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout key.pem -out cert.pem \
        -days 7 -subj /CN=localhost -addext subjectAltName=DNS:localhost
    cp ~/git/irken/irken-h2d/x402/x402.conf.example x402.conf

Edit `x402.conf`:

* `pay-to`: the payee's address (`python3 ~/git/irken/irken-h2d/x402/pay.py address payee`).
* the `/premium/` price: something small, e.g. `1000` (0.001 USDC).

The facilitator is already `https://x402.org/facilitator`: free, no API key,
testnets only.

## 5. Run the server

In one terminal (`-d` shows what it's doing):

    cd ~/tmp/x402-real
    ~/git/irken/irken-h2d/serve-x402 127.0.0.1:4433 -root www -cert cert.pem -key key.pem \
        -r -log x402.log -x402 x402.conf -d

`-root` holds a directory per host name, hence `www/localhost/`.  `-r` and
`-log` keep the server off port 80 and out of /var/log.  At startup it logs
`x402: 2 prices from x402.conf, paid to <payee> on eip155:84532, settled by
facilitator https://x402.org/facilitator`.

## 6. Pay

In another terminal:

    cd ~/git/irken/irken-h2d
    python3 x402/pay.py get https://localhost:4433/premium/hello.html -key payer -k

`-k` skips checking the server's (self-signed) certificate.  To see the
signed payment without sending it, add `-dry-run`.

Expect:

1. `HTTP/2 402` with a `payment-required` saying what to pay;
2. `--- paying 1000 units of 0x036C... to <payee> on eip155:84532`;
3. after a second or two, `HTTP/2 200`, a `payment-response` with
   `"success": true` and a `transaction`, the page, and a
   sepolia.basescan.org link to the transaction.

## 7. Check it

* The transaction link shows a USDC transfer of the price from the payer to
  the payee.
* `python3 x402/pay.py balance payer` and `... balance payee` have moved by
  the price.
* The server logged `x402: paid 1000 for /premium/hello.html by <payer>,
  transaction <hash>`.

## Things that can go wrong

* **402 `invalid_exact_evm_insufficient_balance`:** the payer has no (or too
  little) USDC on Base Sepolia.  Check `balance payer`, and that the faucet
  sent USDC to the payer's address, not the payee's.  This 402 also shows
  the failure path working: the facilitator's reason comes back as the
  PaymentRequired `error`.
* **500 from the server:** it couldn't reach the facilitator, or its answer
  made no sense; the server's terminal says why (`x402: verifying ...` or
  `x402: settling ...`).
* **`pay.py` can't connect:** is `serve-x402` running, on 4433?  The server
  speaks only HTTP/2, which `pay.py` uses; most other clients (curl without
  `--http2`, Python `requests`) can't connect.
* **`balance` fails:** it asks Base Sepolia's public RPC,
  https://sepolia.base.org.

## Cleaning up

Stop the server (Ctrl-C).  `~/tmp/x402-real` and `~/.x402-test` can be
deleted; the wallets were for this test only.
