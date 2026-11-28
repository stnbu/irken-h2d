# x402 payments

`serve-x402`, irken-h2d's `serve` with x402 built in, charges for parts of a site with [x402](https://www.x402.org)
(version 2): HTTP 402 Payment Required, paid in a stablecoin such as USDC on
an EVM chain.  A client asks for a priced page, gets a 402 saying what to
pay, signs a payment, and asks again with it; the server has the payment
verified and settled, then serves the page.

Payments go straight from the payer to your `pay-to` address.  The server
holds no key and no money: verifying and settling are done by a
*facilitator*, a service the server calls.  (Settling on-chain without one is
planned; see "Settlers" below.)

## Building

`serve.scm` and `serve-x402.scm` are the same server, `serve-main.scm`; the
second also requires `x402/hooks.scm`, which adds `-x402` through the hooks in
`serve-main.scm`.  So `serve` has none of the x402 code, and there's one `main`.
From the top of the tree:

    $ irken serve-x402.scm

which makes `serve-x402` (or `make serve-x402`: see `README.md`).  It needs an irken-compiler from after November
2026 (master has the fixes it needs: `{}` in `lib/json.scm`, and one type for
`:H2/BadFrame` so a program can be both an HTTP/2 server and an HTTPS
client).

## Running

    $ serve-x402 0.0.0.0:443 -root /var/www/data -cert ... -key ... -x402 /usr/local/etc/x402.conf

It takes all of `serve`'s options.  Without `-x402` it is plain `serve`, and
charges for nothing.

Logged-in users don't pay.  With `-users` or `-passkeys` (see `README.md`), a
request with a login session or a good password is served free (and logged
as `x402: free for <user>: <host><path>`); everyone else pays.  The file is read
again on SIGHUP, where the server reloads on SIGHUP; a bad one is logged, and
the old one kept.

See `x402.conf.example`.  The configuration is checked at startup, and the
server won't start if anything is missing or malformed.  It names:

* `facilitator`: its URL (https only).  `facilitator-root` optionally names a
  PEM file of certificates to trust for it instead of the system's roots.
* `network`, `asset`, `asset-name`, `asset-version`: the chain (as CAIP-2,
  e.g. `eip155:84532` for Base Sepolia) and the token: its contract address
  and its EIP-712 domain name and version (`USDC`, `2` for Circle's USDC).
* `max-timeout`: seconds a client has to pay (default 60).
* `pay-to <address>`: where payments go, for hosts without their own.
* `pay-to <host> <address>`: where payments for `<host>` go.  Each virtual host
  (each directory under `-root`) can have its own.
* `price <where> <amount> <description>`: any number of these.  `<where>` is
  a path prefix for every host (`/premium/`), or for one host
  (`https://example.com/premium/`).  Amounts are in the token's smallest units
  (USDC has 6 decimals, so `10000` is 0.01 USDC).

For a request, the host's own prices are tried first, then the ones for
every host, longest prefix first; it pays the host's own `pay-to`, or the
default.  A host with no prices is free.  A host with a price but no address
to pay, an unknown or repeated setting, or a malformed line stops the server.

Each payment is logged: `x402: paid <amount> to <address> for <host><path>
by <payer>, transaction <hash>`.

## What happens to a request

For a path with a price:

| the request | the answer |
|---|---|
| no `PAYMENT-SIGNATURE` | 402, with `PAYMENT-REQUIRED` (and the same JSON as the body) |
| a malformed one | 400 |
| a payment for something other than what we offer, or one the facilitator refuses | 402, with the reason as the `error` in `PAYMENT-REQUIRED` |
| a good payment | whatever the site answers; see below |
| the facilitator can't be reached | 500, and logged |

The payment is settled only when the site is about to send a 200: then the
200 goes out with `PAYMENT-RESPONSE` (the transaction).  If settling fails,
a 402 with `PAYMENT-RESPONSE` saying why goes out instead, and no content.
Anything else (a 404, a 304) goes out unchanged, and nothing is charged.

Prices are matched against the host and path as they will be served: the host
from `:authority` without its port, as `serve` picks the site's directory, and
the path after `%`-decoding and removing `.` and `..`, so `/%70remium/x` and
`/free/../premium/x` cost the same as `/premium/x`.  Both match without regard
to case: on a case-insensitive filesystem (macOS's, by default),
`/Premium/x` is the same file as `/premium/x`, so it has to cost the same.

## Files

* `x402.scm`: the protocol's messages and headers.
* `settler.scm`: settlers, and the facilitator client (over Irken's
  `doom/http/client.scm`).
* `config.scm`: reading the configuration.
* `handler.scm`: the handler that charges for priced paths.
* `hooks.scm`: x402 in `serve`: `-x402`, and the handler around the sites.
* `t-x402.scm`: tests of `x402.scm` against the spec's examples.
* `mock-facilitator.py`, `test-e2e.py`: an end-to-end test (below).
* `pay.py`: a small client that pays (below).
* `MANUAL-TESTING.md`: paying for real (testnet), step by step.

## Settlers

A settler is a record of two functions, `verify` and `settle`.  The
facilitator is one; settling on-chain ourselves would be another, needing
secp256k1 and keccak-256 (in irken-compiler), EIP-712 hashing, transaction
signing, and a JSON-RPC client for an Ethereum node.

## Testing

    $ make test

runs, among others (see `README.md`):

    $ x402/t-x402                              # compared with its ";; =>" lines
    $ python3 t-serve.py ./serve               # plain serve: no x402 in it
    $ python3 x402/test-e2e.py ./serve-x402

`test-e2e.py` runs `serve-x402` with a price on `/premium/`, against
`mock-facilitator.py` (which checks everything but the signature, and has no
blockchain), and uses curl to check: the 402, payments that work, are
replayed, are for the wrong amount or address, are malformed, or fail at
verify or at settle; paths that try to get around the price; that a 404 isn't
charged; that logged-in users don't pay; that the server copes without the
facilitator; SIGHUP (where the server reloads on it); and that without
`-x402`, nothing is charged.  It needs
python3, openssl, and a curl with HTTP/2.

## Paying for real (testnet)

`pay.py` is a small x402 client: it asks for a page, reads the 402, signs
exactly the payment asked for (a USDC `transferWithAuthorization`, EIP-712
signed), and asks again with it, over HTTP/2.  It also makes throwaway wallets
and shows their USDC balances.  `MANUAL-TESTING.md` says how to use it to pay
irken-h2d with real testnet money, step by step.

## Not done yet

* **HTTP/1.1 clients can't connect.**  irken-h2d speaks only HTTP/2, and some
  x402 clients (Node's `fetch`, Python's `requests`) speak only HTTP/1.1.
  Python's `httpx` with `http2=True`, and browsers, are fine.
* **Responses are deflated whether or not the client asks** (an irken-h2d
  bug, not x402's), so a client must accept `deflate`.  Most do.
* **No CORS headers**, which browser clients on other origins need (see the
  spec's `transports-v2/http.md`).
* **Facilitators that need an API key aren't supported.**
* **No timeout** on facilitator requests: a facilitator that hangs holds
  that request.
* **One network and token**, and prices apply to every host the server
  serves.
* **v1 clients** (the `X-PAYMENT` header) aren't supported.
