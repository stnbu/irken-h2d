;; -*- Mode: Irken -*-

;; irken-h2d with x402 payments: serve, plus -x402 <file>.  see
;;  serve-main.scm and x402/README.md.
;;
;;  $ make serve-x402      (or: irken serve-x402.scm)

(include "serve-main.scm")
(require "x402/hooks.scm")
(main)
