;; -*- Mode: Irken -*-

;; x402 in serve: requiring this (as serve-x402.scm does, before
;;  calling main) adds -x402 <file>, which charges for the priced paths
;;  of the sites under -root.  see x402/README.md, and serve-main.scm
;;  for the hooks.
;;
;; without -x402, nothing is charged, and the server is plain serve.
;;  the file is read at startup (a bad one stops the server) and again
;;  on SIGHUP (a bad one is logged, and the old one kept).

(require "x402/handler.scm")

(define (x402/log-config path config)
  (logf "x402: " (int (length config.prices)) " prices from " path
        ", paid to " config.terms.pay-to " on " config.terms.network
        ", settled by " config.settler.name))

(define (x402/serve-wrapper path login site)
  (let ((state {config=(try
                        (x402/load-config path)
                        except
                        (:X402/BadConfig why) -> (startup-failed (format path ": " why)))}))
    (x402/log-config path state.config)
    (when (eq? login (maybe:no))
      (logf "x402: no -users or -passkeys: everyone pays"))
    (push! *sighup-hooks*
           (lambda ()
             (try
              (let ((config (x402/load-config path)))
                (set! state.config config)
                (x402/log-config path config))
              except
              (:X402/BadConfig why) -> (logf "x402: SIGHUP: " path ": " why ": keeping the old one"))))
    (multi-handler (list (x402-wrapper state login site) site))))

(set! *serve-options* (append *serve-options* (makeopt (arg 'x402 (string "")))))
(push! *serve-usage*
       (format "  [-x402 <file>] charge for priced paths with x402 payments; logged-in\n"
               "     users (-users, -passkeys) don't pay.  see x402/README.md.\n"))
(push! *site-wrappers*
       (lambda (opts login site)
         (match (get-string-opt opts 'x402) with
           (maybe:yes path) -> (if (> (string-length path) 0) (x402/serve-wrapper path login site) site)
           (maybe:no) -> site)))
