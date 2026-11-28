;; -*- Mode: Irken -*-

;; the x402 configuration file (serve-x402 -x402 <file>): what we charge
;;  for, in what, to whom, and who settles.  see x402/x402.conf.example.
;;
;;   facilitator       https://x402.org/facilitator
;;   facilitator-root  <pem>   (optional: trust only these certificates
;;                              for the facilitator, e.g. a test one's own)
;;   network           eip155:84532
;;   asset             0x036CbD53842c5426634e7929541eC2318f3dCF7e
;;   asset-name        USDC
;;   asset-version     2
;;   max-timeout       60
;;   pay-to            0x...            (for hosts without their own)
;;   pay-to <host>     0x...            (for <host>)
;;   price  <where>  <amount>  <description...>
;;
;; <where> is a path prefix for every host (/premium/), or for one host
;;  (https://example.com/premium/).  for a request, the host's own
;;  prices are tried first, then the ones for every host; in each, the
;;  longest matching prefix wins.  hosts and paths match without regard
;;  to case, so that a case-insensitive filesystem (macOS's, by
;;  default) can't serve /Premium/ free.  the host is the one
;;  host-handler serves the request from: :authority, without :port.
;;
;; '#' starts a comment.  an unknown or repeated setting is an error,
;;  as is a priced host with no address to pay.

(require "x402/settler.scm")

(define (x402-config-error what)
  (raise (:X402/BadConfig what)))

;; 0x and 40 hex digits.
(define (x402/address? s)
  (and (= 42 (string-length s))
       (string=? "0x" (substring s 0 2))
       (all? hex-digit? (string->list (substring s 2 42)))))

(define (x402/amount? s)
  (and (> (string-length s) 0)
       (all? digit? (string->list s))
       (not (all? (lambda (ch) (char=? ch #\0)) (string->list s)))))

(define (x402/config-host host what)
  (let ((host (downcase host)))
    (when (>= (string-find ":" host) 0)
      (x402-config-error (format what ": no port, please (prices are per host, on any port): " host)))
    (when (not (hostname-legal? host))
      (x402-config-error (format what ": not a host name: " host)))
    host))

;; a price's <where> -> (:tuple host prefix), with host "" for every host.
(define (x402/parse-where where)
  (cond ((starts-with where "/")
         (:tuple "" (downcase where)))
        ((starts-with where "https://")
         (let ((rest (substring where 8 (string-length where)))
               (slash (string-find "/" rest)))
           (when (< slash 1)
             (x402-config-error (format "price: no host, or no path after it: " where)))
           (:tuple (x402/config-host (substring rest 0 slash) "price")
                   (downcase (substring rest slash (string-length rest))))))
        (else
         (x402-config-error (format "price: must be a path (/premium/) or https://<host>/<path>: " where)))))

;; the settings that take one value.
(define x402-settings '("facilitator" "facilitator-root" "network" "asset" "asset-name" "asset-version" "max-timeout" "pay-to"))

;; -> {terms sites prices settler}
;;   terms   for hosts without a pay-to of their own (pay-to "" if there's
;;            no default: then no such host has a price)
;;   sites   host => its terms
;;   prices  {host prefix amount description}, the hosts' own first, and
;;            longest prefix first.
(define (x402/load-config path)
  (when (not (isfile? path))
    (x402-config-error (format "no such file: " path)))
  (let ((settings (tree/empty))
        (pay-tos (tree/empty))   ;; host => address
        (prices (list:nil)))
    (define (price-exists? host prefix)
      (any? (lambda (p) (and (string=? p.host host) (string=? p.prefix prefix))) prices))
    (for-list line (config-lines path)
      (match line with
        () -> #u
        ("price" where amount . description)
        -> (let (((host prefix) (x402/parse-where where)))
             (when (not (x402/amount? amount))
               (x402-config-error (format "price: the amount must be a positive number of the token's atomic units: " amount)))
             (when (price-exists? host prefix)
               (x402-config-error (format "price: twice: " where)))
             (push! prices {host=host prefix=prefix amount=amount description=(string-join description " ")}))
        ("pay-to" host address)
        -> (let ((host (x402/config-host host "pay-to")))
             (when (not (x402/address? address))
               (x402-config-error (format "pay-to " host ": not an address: " address)))
             (when (not (eq? (tree/member pay-tos string-compare host) (maybe:no)))
               (x402-config-error (format "pay-to " host ": twice")))
             (tree/insert! pay-tos string-compare host address))
        (key value)
        -> (begin
             (when (not (member? key x402-settings string=?))
               (x402-config-error (format "unknown setting: " key)))
             (when (not (eq? (tree/member settings string-compare key) (maybe:no)))
               (x402-config-error (format key ": twice")))
             (tree/insert! settings string-compare key value))
        _ -> (x402-config-error (format "can't read this line: " (string-join line " ")))))
    (define (get key)
      (match (tree/member settings string-compare key) with
        (maybe:yes v) -> v
        (maybe:no) -> (x402-config-error (format "missing: " key))))
    (define (get-or key default)
      (match (tree/member settings string-compare key) with
        (maybe:yes v) -> v
        (maybe:no) -> default))
    (when (null? prices)
      (x402-config-error "no price lines: nothing would be charged for"))
    (let ((facilitator (get "facilitator"))
          (root (get-or "facilitator-root" ""))
          (network (get "network"))
          (asset (get "asset"))
          (asset-name (get "asset-name"))
          (asset-version (get "asset-version"))
          (default-pay-to (get-or "pay-to" ""))
          (timeout (string->int (get-or "max-timeout" "60"))))
      (define (terms pay-to)
        {network=network asset=asset asset-name=asset-name asset-version=asset-version
         pay-to=pay-to max-timeout=timeout})
      (when (not (string=? "https://" (substring facilitator 0 (min 8 (string-length facilitator)))))
        (x402-config-error (format "facilitator: must be an https:// URL: " facilitator)))
      (when (not (string=? "eip155:" (substring network 0 (min 7 (string-length network)))))
        (x402-config-error (format "network: only EVM networks (eip155:<chain id>) are supported: " network)))
      (when (not (x402/address? asset))
        (x402-config-error (format "asset: not an address: " asset)))
      (when (and (> (string-length default-pay-to) 0) (not (x402/address? default-pay-to)))
        (x402-config-error (format "pay-to: not an address: " default-pay-to)))
      ;; every priced host has someone to pay.
      (when (= 0 (string-length default-pay-to))
        (for-list p prices
          (cond ((string=? p.host "")
                 (x402-config-error (format "price " p.prefix ": for every host, but there's no pay-to for every host")))
                ((eq? (tree/member pay-tos string-compare p.host) (maybe:no))
                 (x402-config-error (format "price https://" p.host p.prefix ": no pay-to for " p.host)))
                (else #u))))
      (when (and (> (string-length root) 0) (not (isfile? root)))
        (x402-config-error (format "facilitator-root: no such file: " root)))
      (let ((anchors (try
                      (load-trust-anchors root)
                      except
                      (:HTTPS/Failed why) -> (x402-config-error (format "facilitator certificates: " why))))
            (sites (tree/empty)))
        (when (null? anchors)
          (x402-config-error (format "no trusted certificates for the facilitator in "
                                     (if (> (string-length root) 0) root "the system's bundle"))))
        (for-map host address pay-tos
          (tree/insert! sites string-compare host (terms address)))
        {terms=(terms default-pay-to)
         sites=sites
         prices=(sort (lambda (a b)
                        (let ((a-own? (> (string-length a.host) 0))
                              (b-own? (> (string-length b.host) 0)))
                          (if (eq? a-own? b-own?)
                              (> (string-length a.prefix) (string-length b.prefix))
                              a-own?)))
                      prices)
         settler=(x402/facilitator facilitator anchors)}))))

;; the terms for a request to <host>.
(define (x402/terms-for config host)
  (match (tree/member config.sites string-compare host) with
    (maybe:yes terms) -> terms
    (maybe:no) -> config.terms))
