;; -*- Mode: Irken -*-

;; irken-h2d: an HTTP/2 file server.

(require "server.scm")

(define program-options
  (makeopt
   (arg 'root (string "/var/local/www/data"))
   (arg 'cert (string "cert.pem"))
   (arg 'key  (string "key.pem"))
   (arg 'log  (string "/var/log/irken-httpd.log"))
   (arg 'acme (string ""))
   (arg 'users (string ""))
   (arg 'passkeys (string ""))
   (arg 'user (string ""))
   (flag 'd)
   (arg 'http (int 80))
   (flag 'r)
   (pos 'addr (string "127.0.0.1:4433"))
   (flag 'h)
   ))

(define (get-options)
  (if (< sys.argc 2)
      (usage)
      (try
       (process-options program-options (rest (vector->list sys.argv)))
       except
       (:Getopt/MissingArg _ _) -> (usage)
       (:Getopt/UnknownArg _ _) -> (usage)
       )))

(define (usage)
  (printf "HTTP/2 TLS-1.3 file server.\n\n")
  (printf "Usage: " sys.argv[0] " <addr>\n"
          "  [-root = /var/local/www/data\n"
          "  [-cert = cert.pem]\n"
          "  [-key = key.pem]\n"
          "  [-log = /var/log/irken-httpd.log]\n"
          "  [-r] disable redirect (301 Moved Permanently) on port 80\n"
          "  [-acme <dir>] on port 80, answer ACME http-01 challenges\n"
          "     (/.well-known/acme-challenge/<token>) from <dir>/<token>\n"
          "  [-http <port>] use <port> instead of 80 for redirects & challenges\n"
          "  [-users <file>] users for /status (basic auth): name:password lines.\n"
          "  [-passkeys <file>] passkeys for /status: see README.md.\n"
          "     without -users or -passkeys, /status is disabled.\n"
          "  [-user <name>] after binding the ports, run as this user\n"
          "     (start as root to bind ports 80 and 443)\n"
          "  [-d] print debugging output\n"
          "  [-h] print this usage.\n"
          "\n"
          " note: the root filesystem is expected to be of the form:\n"
          "      /var/www/root/hostname0/index.html\n"
          "      /var/www/root/hostname1/index.html\n"
          "   where each <hostname> is the FQDN/authority for that site.\n"
          "\n"
          "example: $ " sys.argv[0] " 127.0.0.1:4433 -root /var/www/root/\n"
          "\n"
          )
  (%exit #f -1))

(define (split-addr addr)
  (match (string-split addr #\:) with
    (ip port) -> (:tuple ip (string->int port))
    (ip)      -> (:tuple ip 443)
    _         -> (usage)
    ))

(define (main)
  (let ((opts (get-options))
        (addr "127.0.0.1:4433")
        (root "/var/local/www/data")
        (cert "cert.pem")
        (key  "key.pem")
        (redirect? #t)
        (acme-dir (maybe:no))
        (http-port 80)
        (log  "/var/log/irken-httpd.log")
        (users (maybe:no))
        (passkeys (maybe:no))
        (user (maybe:no)))
    (when-maybe v (get-bool-opt opts 'h) (usage))
    (when-maybe v (get-bool-opt opts 'r) (set! redirect? #f))
    (when-maybe v (get-string-opt opts 'root) (set! root v))
    (when-maybe v (get-string-opt opts 'cert) (set! cert v))
    (when-maybe v (get-string-opt opts 'key)  (set! key v))
    (when-maybe v (get-string-opt opts 'log)  (set! log v))
    (when-maybe v (get-string-opt opts 'addr) (set! addr v))
    (when-maybe v (get-string-opt opts 'acme) (when (> (string-length v) 0) (set! acme-dir (maybe:yes v))))
    (when-maybe v (get-int-opt opts 'http) (set! http-port v))
    (when-maybe v (get-string-opt opts 'users) (when (> (string-length v) 0) (set! users (maybe:yes v))))
    (when-maybe v (get-string-opt opts 'passkeys) (when (> (string-length v) 0) (set! passkeys (maybe:yes v))))
    (when-maybe v (get-string-opt opts 'user) (when (> (string-length v) 0) (set! user (maybe:yes v))))
    (set! *debugf* #f)
    (when-maybe v (get-bool-opt opts 'd) (set! *debugf* v))
    ;; the runtime's GC messages (on stderr, so also in syslog) too.
    (set-verbose-gc *debugf*)
    (set! *dnscache* (dnscache/make "127.0.0.1" 1000))

    (let ((creds (try
                  (load-creds cert key)
                  except
                  (:Serve/BadCreds why) -> (startup-failed why)))
          ((ip port) (split-addr addr))
          (status (match users passkeys with
                    (maybe:no) (maybe:no)
                    -> (begin (logf "no -users or -passkeys: /status is disabled") (list:nil))
                    _ _
                    -> (let ((login (login/make users passkeys)))
                         (push! *sighup-hooks* (lambda () (login/reload! login #t)))
                         (list (login-wrapper login "/status" (status-handler addr opts))))))
          (handler (h2-handler
                    (multi-handler
                     (append status
                             (list favicon-handler
                                   (host-handler root))))))
          ;;(handler (h2-handler (host-handler root)))
          )
      (set! *logfile* (maybe:yes (open-log log)))
      (logf "read " (int (length creds.x509s)) " certs from " cert)
      (debugf "redirect? " (bool redirect?) "\n")
      (let ((main-sock (listen-on ip port))
            (http-sock (if (or redirect? (not (eq? acme-dir (maybe:no))))
                           (maybe:yes (listen-on ip http-port))
                           (maybe:no))))
        (logf "listening on " addr
              (match http-sock with
                (maybe:yes _) -> (format " and port " (int http-port))
                (maybe:no) -> ""))
        ;; the ports are bound, and the log file and certificates
        ;;  read: give up root.
        (when-maybe name user
          (try
           (begin
             (drop-privileges name)
             (logf "running as " name))
           except
           (:OSError e) -> (begin (logf "can't run as " name ": " (strerror e)) (%exit #f 1))
           (:Posix/NoSuchUser _) -> (begin (logf "no such user: " name) (%exit #f 1))
           (:Posix/StillRoot _) -> (begin (logf "still root after becoming " name) (%exit #f 1))))
        (when-maybe sock http-sock
          (poller/fork (lambda () (serve-redirect sock acme-dir))))
        (reload-on-sighup creds cert key log)
        (serve main-sock (h2-channel handler creds '("h2"))))
      (poller/wait-and-schedule))))

;; don't let SIGPIPE take down the server.
(signal/ignore SIGPIPE)
(main)
(printf "after main.\n")
