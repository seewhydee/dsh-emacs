;;; dsh-bridge-tests.el --- ERT tests for dsh-bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run with:
;;   emacs --batch -L emacs -l emacs/dsh-bridge-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dsh-bridge)

(ert-deftest dsh-bridge-path-no-session ()
  (should (equal (dsh-bridge--path "/output" nil) "/output")))

(ert-deftest dsh-bridge-path-with-session ()
  (should (equal (dsh-bridge--path "/output" "session-1")
                 "/output?sessionId=session-1")))

(ert-deftest dsh-bridge-extra-headers-with-token ()
  (let ((dsh-bridge-token "secret"))
    (should (equal (dsh-bridge--extra-headers nil)
                   '(("Authorization" . "Bearer secret"))))))

(ert-deftest dsh-bridge-extra-headers-with-payload-and-token ()
  (let ((dsh-bridge-token "secret"))
    (should (equal (dsh-bridge--extra-headers '((text . "x")))
                   '(("Content-Type" . "application/json")
                     ("Authorization" . "Bearer secret"))))))

(ert-deftest dsh-bridge-extra-headers-no-token ()
  (let ((dsh-bridge-token nil)
        (dsh-bridge-token-file "/nonexistent/dsh-bridge-token"))
    (should (equal (dsh-bridge--extra-headers nil) nil))))

(ert-deftest dsh-bridge-extra-headers-token-is-unibyte ()
  ;; A multibyte (even pure-ASCII) token header value poisons url-http's
  ;; request concatenation: a body containing non-ASCII bytes then fails
  ;; with "Multibyte text in HTTP request" (bug#23750).
  (let ((dsh-bridge-token (string-to-multibyte "secret")))
    (dolist (pair (dsh-bridge--extra-headers '((text . "x"))))
      (should-not (multibyte-string-p (car pair)))
      (should-not (multibyte-string-p (cdr pair))))))

(ert-deftest dsh-bridge-error-message-http-status ()
  (should (equal (dsh-bridge--error-message nil 401 '((error . "unauthorized")))
                 "HTTP 401: unauthorized")))

(ert-deftest dsh-bridge-error-message-transport ()
  (should (equal (dsh-bridge--error-message '(:error "connection refused") nil nil)
                 "request failed: connection refused")))

(ert-deftest dsh-bridge-error-message-body-error ()
  (should (equal (dsh-bridge--error-message nil 200 '((error . "boom"))) "boom")))

(ert-deftest dsh-bridge-error-message-success ()
  (should (equal (dsh-bridge--error-message nil 200 '((ok . t))) nil)))

;; The remaining tests point the bridge at port 9 (discard), which refuses
;; connections immediately, so a transport failure stands in for an
;; unreachable `dsh web'.

(ert-deftest dsh-bridge-select-session-transport-failure ()
  "A failed /select request must not look like a successful selection."
  (let ((dsh-bridge-url "http://127.0.0.1:9/dsh-bridge")
        (dsh-bridge-timeout 2)
        (dsh-bridge-target-session nil))
    (dsh-bridge-select-session "some-session")
    (should (null dsh-bridge-target-session))))

(ert-deftest dsh-bridge-current-session-transport-failure ()
  "A failed /current request must not clear the pinned session."
  (let ((dsh-bridge-url "http://127.0.0.1:9/dsh-bridge")
        (dsh-bridge-timeout 2)
        (dsh-bridge-target-session "pinned-session"))
    (dsh-bridge-current-session)
    (should (equal dsh-bridge-target-session "pinned-session"))))

(ert-deftest dsh-bridge-select-session-offers-live-sessions-only ()
  "Completion offers live sessions (plus the unpin choice) only."
  (let ((dsh-bridge-url "http://127.0.0.1:9/dsh-bridge")
        (dsh-bridge-timeout 2)
        (choices-seen nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 '(((id . "live-1") (live . t) (cwd . "/a"))
                   ((id . "saved-1") (live . nil) (cwd . "/b")))))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _rest)
                 (setq choices-seen table)
                 "(last-active)")))
      (call-interactively #'dsh-bridge-select-session))
    (should (equal choices-seen '("live-1" "(last-active)")))))

(defconst dsh-bridge-test--outbox-response
  (cons 200
        (list (cons 'entries
                    (list (list (cons 'id "e1")
                                (cons 'sessionId "s1")
                                (cons 'source "message-action")
                                (cons 'text "hello")
                                (cons 'ts 1000))))
              (cons 'overflowed nil))))

(ert-deftest dsh-bridge-pull-inbox-inserts-and-acks ()
  "Pull inserts each entry and acks the collected ids after a successful insert."
  (let (acked-payload)
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (cond
                  ((equal method "GET") dsh-bridge-test--outbox-response)
                  ((equal method "POST") (setq acked-payload payload)
                   (cons 200 (list (cons 'ok t))))
                  (t (cons 404 (list (cons 'error "unexpected"))))))))
      (dsh-bridge-pull-inbox)
      (should (string-match-p "hello"
                              (with-current-buffer "*dsh-bridge-inbox*"
                                (buffer-string))))
      (should (equal acked-payload '((ids . ("e1"))))))))

(ert-deftest dsh-bridge-send-draft-posts-to-draft ()
  "send-draft POSTs the text (and the pinned session) to /draft."
  (let ((captured nil)
        (dsh-bridge-target-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (method path payload _callback)
                 (setq captured (list method path payload)))))
      (dsh-bridge-send-draft "hello"))
    (should (equal (car captured) "POST"))
    (should (equal (cadr captured) "/draft"))
    (should (equal (cdr (assoc 'text (caddr captured))) "hello"))
    (should (equal (cdr (assoc 'sessionId (caddr captured))) "s1"))))

(provide 'dsh-bridge-tests)
;;; dsh-bridge-tests.el ends here
