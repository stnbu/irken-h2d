;; -*- Mode: Irken -*-

;; x402 (version 2) over HTTP: the messages, and the headers that
;;  carry them.  see the specs at
;;  https://github.com/x402-foundation/x402/tree/main/specs:
;;  x402-specification-v2.md, transports-v2/http.md, and
;;  schemes/exact/scheme_exact_evm.md.
;;
;; an unpaid request for a priced resource gets a 402, with a
;;  PAYMENT-REQUIRED header: a PaymentRequired object listing the
;;  PaymentRequirements we accept.  the client signs a payment and
;;  retries with a PAYMENT-SIGNATURE header (a PaymentPayload).  we
;;  have the payment verified and settled (see settler.scm), and serve
;;  the resource with a PAYMENT-RESPONSE header (a SettlementResponse).
;;  each header is base64 (with padding) of compact JSON.
;;
;; we offer one kind of payment: the "exact" scheme on one EVM network,
;;  in one token, to one address, all from the configuration (terms).

(require "lib/basis.scm")
(require "lib/parse/lexer.scm")
(require "lib/dfa/charset.scm")
(require "lib/dfa/rx.scm")
(require "lib/dfa/deriv.scm")
(require "lib/dfa/dfa.scm")
(require "lib/dfa/emit.scm")
(require "lib/dfa/lexicon.scm")
(require "lib/parse/earley.scm")
(require "lib/parse/parser.scm")
(require "lib/codecs/hex.scm")
(require "lib/json.scm")   ;; needs an Irken whose json parses {}: see README.md
(require "lib/codecs/base64.scm")

(define X402-VERSION 2)

;; header names, lowercase as HTTP/2 sends them.
(define X402-PAYMENT-REQUIRED "payment-required")
(define X402-PAYMENT-SIGNATURE "payment-signature")
(define X402-PAYMENT-RESPONSE "payment-response")

;; the largest PAYMENT-SIGNATURE we'll decode.  a real one is ~1kB.
(define X402-MAX-HEADER 8192)

;; terms: what a host's priced resources accept.
;;   network        CAIP-2, e.g. "eip155:84532" (Base Sepolia)
;;   asset          the token's contract address
;;   asset-name     its EIP-712 domain name, e.g. "USDC"
;;   asset-version  and version, e.g. "2"
;;   pay-to         the address that receives payments
;;   max-timeout    seconds a payment may take
;;
;; price: one priced part of a site (only amount and description are used here).
;;   host           its host, or "" for every host
;;   prefix         a path prefix, e.g. "/premium/"
;;   amount         atomic units, as a string: USDC has 6 decimals,
;;                  so "10000" is 0.01 USDC.
;;   description    for the PaymentRequired resource.

;; PaymentRequirements for <price>.
(define (x402/requirements terms price)
  (json:obj
   (list (:tuple "scheme" (json:string "exact"))
         (:tuple "network" (json:string terms.network))
         (:tuple "amount" (json:string price.amount))
         (:tuple "asset" (json:string terms.asset))
         (:tuple "payTo" (json:string terms.pay-to))
         (:tuple "maxTimeoutSeconds" (json:number terms.max-timeout))
         (:tuple "extra" (json:obj (list (:tuple "name" (json:string terms.asset-name))
                                         (:tuple "version" (json:string terms.asset-version))))))))

;; the PaymentRequired object for <url>, explaining <error>.
(define (x402/payment-required terms price url error)
  (json:obj
   (list (:tuple "x402Version" (json:number X402-VERSION))
         (:tuple "error" (json:string error))
         (:tuple "resource" (json:obj (list (:tuple "url" (json:string url))
                                            (:tuple "description" (json:string price.description)))))
         (:tuple "accepts" (json:array (list (x402/requirements terms price)))))))

(define (x402/header-encode j)
  (b64-encode (json->string j)))

(define x402-json-parse
  (let ((parse (make-json-parser)))
    (lambda (s) (parse (string-generator s)))))

;; is <s> base64 with padding: [A-Za-z0-9+/]*, then up to two '=',
;;  length a multiple of 4?  (b64-decode doesn't check.)
(define (x402/base64? s)
  (let ((n (string-length s))
        (pad 0))
    (define (b64-char? ch)
      (let ((c (char->int ch)))
        (or (and (>= c 65) (<= c 90))     ;; A-Z
            (and (>= c 97) (<= c 122))    ;; a-z
            (and (>= c 48) (<= c 57))     ;; 0-9
            (char=? ch #\+)
            (char=? ch #\/))))
    (let/cc return
      (when (or (= n 0) (not (= 0 (remainder n 4))))
        (return #f))
      (for-range i n
        (let ((ch (string-ref s i)))
          (cond ((char=? ch #\=)
                 (inc! pad))
                ((or (> pad 0) (not (b64-char? ch)))
                 (return #f)))))
      (<= pad 2))))

;; decode a header carrying a JSON object: (maybe json).
(define (x402/header-decode s)
  (if (or (> (string-length s) X402-MAX-HEADER) (not (x402/base64? s)))
      (maybe:no)
      (try
       (match (x402-json-parse (b64-decode s)) with
         (json:obj pairs) -> (maybe:yes (json:obj pairs))
         _ -> (maybe:no))
       except
       (:NoParse _) -> (maybe:no))))

;; member <key> of <j> as an int, or -1.
(define (x402/get-int j key)
  (match (json/get j key) with
    (maybe:yes (json:number n)) -> n
    _ -> -1))

;; member <key> of <j> as a bool, or #f.
(define (x402/get-bool j key)
  (match (json/get j key) with
    (maybe:yes (json:bool b)) -> b
    _ -> #f))

;; does the client's PaymentPayload say it pays these PaymentRequirements?
;;  (the facilitator checks the signature and the authorization; this
;;  only makes sure the client chose what we offered.)  addresses are
;;  compared without case: EIP-55 checksums are mixed-case.
(define (x402/payment-matches? payload requirements)
  (match (json/get payload "accepted") with
    (maybe:yes accepted)
    -> (let ((same? (lambda (key) (string=? (json/get-string accepted key) (json/get-string requirements key))))
             (same-address? (lambda (key) (string=? (downcase (json/get-string accepted key))
                                                    (downcase (json/get-string requirements key))))))
         (and (= X402-VERSION (x402/get-int payload "x402Version"))
              (same? "scheme")
              (same? "network")
              (same? "amount")
              (same-address? "asset")
              (same-address? "payTo")))
    (maybe:no) -> #f))
