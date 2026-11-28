;; -*- Mode: Irken -*-

;; charging for parts of a site.  (x402-wrapper state login other-handler)
;;  is a handler that takes the requests for priced paths, and lets
;;  <other-handler> answer them once they're paid for.  <state> holds
;;  the configuration ({config}, so that SIGHUP can replace it).
;;
;; logins come first: a request from a logged-in user (a session, or a
;;  password: see login.scm; <login> is (maybe:yes login) with -users
;;  or -passkeys) isn't charged at all, only logged.
;;
;; the order of things, for everyone else:
;;
;;   no PAYMENT-SIGNATURE: 402, with PAYMENT-REQUIRED saying what to pay.
;;   a malformed one: 400.
;;   one that doesn't pay what we asked, or the settler says is no
;;     good: 402, with the reason as PaymentRequired's error.
;;   otherwise <other-handler> answers.  if it answers 200, the payment
;;     is settled first; the 200 goes out with PAYMENT-RESPONSE, or if
;;     settling fails, a 402 (with PAYMENT-RESPONSE saying why) goes
;;     out instead, and the body is dropped.  any other answer (404,
;;     304, ...) goes out as it is, and nothing is charged.
;;   if the settler can't be reached: 500.
;;
;; prices match the host as host-handler sees it (authority->host), and
;;  the path as file-handler sees it: %-decoded and with dot segments
;;  removed, so "/free/../premium/x" and "/%70remium/x" are both
;;  "/premium/x".  both without regard to case: see config.scm.  the
;;  host's own terms (its pay-to) are the ones asked for, and checked.

(require "x402/config.scm")

;; the path as file-handler will serve it.
(define (x402/request-path request)
  (match (lookup-header ":path" request.headers) with
    (maybe:yes uri)
    -> (match (decode-uri uri) with
         (maybe:yes (:tuple parts _ _)) -> (maybe:yes (string-join (remove-dot-segments parts) "/"))
         (maybe:no) -> (maybe:no))
    (maybe:no) -> (maybe:no)))

;; the host as host-handler will serve it from, lowercase.
(define (x402/request-host request)
  (match (lookup-header ":authority" request.headers) with
    (maybe:yes authority) -> (downcase (authority->host authority))
    (maybe:no) -> ""))

;; the price for <path> on <host>: prices are the hosts' own first, and
;;  longest-prefix first (see x402/load-config).
(define (x402/find-price prices host path)
  (let ((path (downcase path)))
    (let loop ((prices prices))
      (match prices with
        () -> (maybe:no)
        (price . rest) -> (if (and (or (string=? price.host host) (string=? price.host ""))
                                   (starts-with path price.prefix))
                              (maybe:yes price)
                              (loop rest))))))

;; <request>, except that a 200 is first passed to <charge>, which
;;  answers (maybe:yes extra-headers) to let it go out, or (maybe:no)
;;  if it has sent something else instead: the body is then dropped.
(define (x402/charging-request request charge)
  (let ((dropping? #f))
    (define (send-headers status headers has-data?)
      (if (string=? status "200")
          (match (charge) with
            (maybe:yes extra) -> (request.send-headers status (append extra headers) has-data?)
            (maybe:no) -> (set! dropping? #t))
          (request.send-headers status headers has-data?)))
    (define (send-data data last?)
      (when (not dropping?)
        (request.send-data data last?)))
    (define (send-with-generator gen)
      (if dropping?
          (for chunk gen #u) ;; run it out, so that it closes its file.
          (request.send-with-generator gen)))
    {send-headers        = send-headers
     send-data           = send-data
     send-with-generator = send-with-generator
     recv-body           = request.recv-body
     stream-id           = request.stream-id
     headers             = request.headers
     get-info            = request.get-info
     get-conn            = request.get-conn
     }))

(define (x402/handle config terms price fun request where path)
  (let ((authority (if-maybe a (lookup-header ":authority" request.headers) a ""))
        (url (format "https://" authority path))
        (requirements (x402/requirements terms price)))

    (define (send-402 error extra-headers)
      (let ((required (json->string (x402/payment-required terms price url error))))
        (debugf "=> 402 " path ": " error "\n")
        (request.send-headers "402"
                              (append (list (:tuple X402-PAYMENT-REQUIRED (b64-encode required))
                                            (:tuple "content-type" "application/json")
                                            (:tuple "cache-control" "no-store"))
                                      extra-headers)
                              #t)
        ;; the header is what counts; the body is for people with curl.
        (request.send-data required #t)))

    (define (fail what why)
      (logf "x402: " what " " where ": " why)
      (send-status request "500"))

    (define (pay payload payer)
      (lambda ()
        (match (config.settler.settle payload requirements) with
          (x402-settled:ok response)
          -> (begin
               (logf "x402: paid " price.amount " to " terms.pay-to " for " where " by " payer ", transaction "
                     (json/get-string response "transaction"))
               (maybe:yes (list (:tuple X402-PAYMENT-RESPONSE (x402/header-encode response))
                                (:tuple "cache-control" "private, no-store"))))
          (x402-settled:refused response)
          -> (begin
               (send-402 (json/get-string response "errorReason")
                         (list (:tuple X402-PAYMENT-RESPONSE (x402/header-encode response))))
               (maybe:no))
          (x402-settled:failed why)
          -> (begin (fail "settling" why) (maybe:no)))))

    (match (lookup-header X402-PAYMENT-SIGNATURE request.headers) with
      (maybe:no)
      -> (send-402 "PAYMENT-SIGNATURE header is required" (list:nil))
      (maybe:yes header)
      -> (match (x402/header-decode header) with
           (maybe:no)
           -> (send-status request "400")
           (maybe:yes payload)
           -> (if (not (x402/payment-matches? payload requirements))
                  (send-402 "invalid_payment_requirements" (list:nil))
                  (match (config.settler.verify payload requirements) with
                    (x402-verified:ok payer) -> (fun (x402/charging-request request (pay payload payer)))
                    (x402-verified:invalid reason) -> (send-402 reason (list:nil))
                    (x402-verified:failed why) -> (fail "verifying" why)))))))

(define (x402/logged-in login request)
  (match login with
    (maybe:yes login) -> (login-user login request)
    (maybe:no) -> (maybe:no)))

(define (x402-wrapper state login other-handler)
  (lambda (request)
    (let ((config state.config)
          (host (x402/request-host request)))
      (match (x402/request-path request) with
        (maybe:yes path)
        -> (match (x402/find-price config.prices host path) (other-handler request) with
             (maybe:yes price) (maybe:yes fun)
             -> (let ((where (format host path)))
                  (match (x402/logged-in login request) with
                    (maybe:yes name)
                    -> (begin (logf "x402: free for " name ": " where) (maybe:yes fun))
                    (maybe:no)
                    -> (maybe:yes (lambda (request)
                                    (x402/handle config (x402/terms-for config host) price fun request where path)))))
             _ _ -> (maybe:no))
        (maybe:no) -> (maybe:no)))))
