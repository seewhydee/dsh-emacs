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

(ert-deftest dsh-bridge-target-label ()
  (let ((dsh-bridge-target-session nil))
    (should (equal (dsh-bridge--target-label) "last-active")))
  (let ((dsh-bridge-target-session "s1"))
    (should (equal (dsh-bridge--target-label) "s1"))))

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
    (should (equal choices-seen '(("a" . "live-1") ("(last-active)" . nil))))))

(defconst dsh-bridge-test--outbox-response
  (cons 200
        (list (cons 'entries
                    (list (list (cons 'id "e1")
                                (cons 'sessionId "s1")
                                (cons 'source "message-action")
                                (cons 'text "hello")
                                (cons 'ts 1000))))
              (cons 'overflowed nil))))

(ert-deftest dsh-bridge-inbox-inserts-and-acks ()
  "Pull inserts each entry and acks the collected ids after a successful insert."
  (let (acked-payload)
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (cond
                  ((equal method "GET") dsh-bridge-test--outbox-response)
                  ((equal method "POST") (setq acked-payload payload)
                   (cons 200 (list (cons 'ok t))))
                  (t (cons 404 (list (cons 'error "unexpected"))))))))
      (dsh-bridge-inbox)
      (should (string-match-p "hello"
                              (with-current-buffer "*dsh-bridge-inbox*"
                                (buffer-string))))
      (should (equal acked-payload '((ids . ("e1")))))
      (should (with-current-buffer "*dsh-bridge-inbox*"
                (eq major-mode 'dsh-bridge-view-mode))))))

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

(ert-deftest dsh-bridge-send-draft-override-wins-over-pin ()
  "An explicit session override beats the pin in the /draft payload."
  (let ((captured nil)
        (dsh-bridge-target-session "pin"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (method path payload _callback)
                 (setq captured (list method path payload)))))
      (dsh-bridge-send-draft "hello" "override"))
    (should (equal (cadr captured) "/draft"))
    (should (equal (cdr (assoc 'sessionId (caddr captured))) "override"))))

(ert-deftest dsh-bridge-send-text-override-wins-over-pin ()
  "An explicit session override beats the pin in the /send payload."
  (let ((captured nil)
        (dsh-bridge-target-session "pin"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload _callback)
                 (setq captured payload))))
      (dsh-bridge-send-text "hi" "override"))
    (should (equal (cdr (assoc 'sessionId captured)) "override"))))

(ert-deftest dsh-bridge-send-text-no-target-omits-session ()
  "With neither a pin nor an override, no sessionId key is sent."
  (let ((captured nil)
        (dsh-bridge-target-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload _callback)
                 (setq captured payload))))
      (dsh-bridge-send-text "hi"))
    (should (equal (cdr (assoc 'text captured)) "hi"))
    (should (null (assoc 'sessionId captured)))))

(ert-deftest dsh-bridge-send-sends-region-when-active ()
  "`dsh-bridge-send' sends the region when one is active, without asking."
  (let ((transient-mark-mode t) captured)
    (with-temp-buffer
      (insert "before region after")
      (goto-char 8)
      (set-mark (point-max))
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload)))
                ;; The guard must not fire for a region send.
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "dsh-bridge: guard asked for a region"))))
        (call-interactively #'dsh-bridge-send)))
    (should (equal (cdr (assoc 'text captured)) "region after"))))

(ert-deftest dsh-bridge-send-whole-buffer-confirms ()
  "A whole-buffer send asks y-or-n-p first and proceeds when confirmed."
  (let ((asked nil) captured)
    (with-temp-buffer
      (insert "whole")
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload)))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) t)))
        (dsh-bridge-send)))
    (should asked)
    (should (equal (cdr (assoc 'text captured)) "whole"))))

(ert-deftest dsh-bridge-send-whole-buffer-aborts-on-no ()
  "Declining the whole-buffer confirmation sends nothing."
  (let (captured)
    (with-temp-buffer
      (insert "whole")
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload)))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (condition-case nil (dsh-bridge-send) (error nil))))
    (should (null captured))))

(ert-deftest dsh-bridge-send-prompt-buffer-exempt-from-guard ()
  "In the prompt buffer, sending the whole buffer is the point: no guard."
  (let ((asked nil) captured)
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (insert "prompt text")
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload)))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) t)))
        (dsh-bridge-send)))
    (should (null asked))
    (should (equal (cdr (assoc 'text captured)) "prompt text"))))

(ert-deftest dsh-bridge-send-prefix-override ()
  "With a prefix argument, send targets the completing-read session for this
call only, leaving the pin untouched."
  (let ((transient-mark-mode t)
        (current-prefix-arg t)
        (captured nil)
        (dsh-bridge-target-session "pin"))
    (with-temp-buffer
      (insert "text")
      (goto-char (point-min))
      (set-mark (point-max))
      (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
                 (lambda () '(((id . "live-1") (live . t)))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt _table &rest _) "live-1"))
                ((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload))))
        (call-interactively #'dsh-bridge-send)))
    (should (equal (cdr (assoc 'sessionId captured)) "live-1"))
    (should (equal (cdr (assoc 'text captured)) "text"))
    (should (equal dsh-bridge-target-session "pin"))))

(ert-deftest dsh-bridge-fetch-uses-pin ()
  "`dsh-bridge-fetch' requests /output with the pinned session id."
  (let ((dsh-bridge-target-session "s1")
        (captured nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method path _payload _callback)
                 (setq captured path))))
      (dsh-bridge-fetch))
    (should (equal captured "/output?sessionId=s1"))))

(ert-deftest dsh-bridge-fetch-populates-output ()
  "Fetch writes the reply into *dsh-bridge-output* in `dsh-bridge-view-mode'."
  (let ((dsh-bridge-target-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          "{\"text\":\"reply text\",\"sessionId\":\"s1\"}" 200))))
      (dsh-bridge-fetch))
    (let ((buf (get-buffer "*dsh-bridge-output*")))
      (should buf)
      (with-current-buffer buf
        (should (equal (buffer-string) "reply text"))
        (should (eq major-mode 'dsh-bridge-view-mode))
        (should buffer-read-only)
        (should (string-match-p "reply from: s1"
                                (format "%s" header-line-format)))))))

(ert-deftest dsh-bridge-fetch-peek-labels-content-session ()
  "A peek/override fetch labels the output buffer with the content's session,
not the pinned target."
  (let ((dsh-bridge-target-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          "{\"text\":\"other reply\",\"sessionId\":\"s2\"}"
                          200))))
      (dsh-bridge-fetch "s2"))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "other reply"))
      (should (string-match-p "reply from: s2"
                              (format "%s" header-line-format)))
      (should-not (string-match-p "target: s1"
                                  (format "%s" header-line-format))))))

(ert-deftest dsh-bridge-view-mode-basics ()
  "The view mode is read-only and binds the dispatcher's letters plus g/q/h."
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (should buffer-read-only)
    (should (eq major-mode 'dsh-bridge-view-mode)))
  (dolist (spec dsh-bridge--verb-suffixes)
    (should (eq (lookup-key dsh-bridge-view-mode-map (kbd (car spec)))
                (cadr spec))))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "g")) #'revert-buffer))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "q")) #'quit-window))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "r")) #'dsh-bridge-reply)))

(ert-deftest dsh-bridge-reply-pins-content-session ()
  "Reply pins the session whose output is shown and opens the prompt below."
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (setq-local dsh-bridge--view-content-session "sess-a")
    (let ((selected nil) (popped nil))
      (cl-letf (((symbol-function 'dsh-bridge--session-live-p) (lambda (_) t))
                ((symbol-function 'dsh-bridge-select-session)
                 (lambda (id) (setq selected id)))
                ((symbol-function 'dsh-bridge--prompt-buffer)
                 (lambda () (get-buffer-create "*dsh-bridge-prompt*")))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buf action) (setq popped (list buf action)))))
        (dsh-bridge-reply))
      (should (equal selected "sess-a"))
      (should (equal (car popped) (get-buffer-create "*dsh-bridge-prompt*")))
      (should (equal (cadr popped) dsh-bridge-prompt-display-action)))))

(ert-deftest dsh-bridge-view-mode-gfm ()
  "When markdown-mode/gfm is loaded, the view mode inherits gfm-view-mode.
No-op child of the markdown-less test environment; asserts the GitHub-Flavored
Markdown wiring in a session where markdown-mode is available."
  (when (featurep 'markdown-mode)
    (with-temp-buffer
      (insert "# Heading\n")
      (dsh-bridge-view-mode)
      (should (derived-mode-p 'gfm-view-mode))
      (should font-lock-defaults)
      (should markdown-fontify-code-blocks-natively)
      (should buffer-read-only))))

(ert-deftest dsh-bridge-prompt-mode-basics ()
  "The prompt mode derives from text-mode in a markdown-less environment and
binds C-c C-c / C-c C-d / C-c C-k."
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (should (eq major-mode 'dsh-bridge-prompt-mode))
    (should (provided-mode-derived-p major-mode 'text-mode))
    (should (string-match-p "target" (format "%s" header-line-format))))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-c"))
              #'dsh-bridge-send))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-d"))
              #'dsh-bridge-draft))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-k"))
              #'dsh-bridge-erase-prompt)))

(ert-deftest dsh-bridge-obsolete-aliases ()
  "The pre-interface command names are aliases of the new verbs."
  (should (eq (symbol-function 'dsh-bridge-send-region) 'dsh-bridge-send))
  (should (eq (symbol-function 'dsh-bridge-send-buffer) 'dsh-bridge-send))
  (should (eq (symbol-function 'dsh-bridge-get-output) 'dsh-bridge-fetch))
  (should (eq (symbol-function 'dsh-bridge-pull-inbox) 'dsh-bridge-inbox))
  (should (eq (symbol-function 'dsh-bridge-send-draft-region) 'dsh-bridge-draft))
  (should (eq (symbol-function 'dsh-bridge-send-draft-buffer) 'dsh-bridge-draft)))

(ert-deftest dsh-bridge-list-sessions-columns-and-marker ()
  "The session list shows marker/R/Session/Age/Workspace columns."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-target-session "live-1")
        (dsh-bridge-sessions-show-saved t))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 '(((id . "live-1") (live . t) (running . t) (title . "First live")
                    (cwd . "/a") (lastActive . 1700000000000))
                   ((id . "saved-1") (live . nil) (title . "A saved one") (cwd . "/b")
                    (createdAt . 1690000000000)))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (let ((buf (get-buffer "*dsh-bridge-sessions*")))
      (should buf)
      (should (= (length (buffer-local-value 'tabulated-list-format buf)) 5))
      (should (equal (buffer-local-value 'tabulated-list-sort-key buf)
                     '("Age" . t)))
      (let* ((entries (buffer-local-value 'tabulated-list-entries buf))
             (live (assoc "live-1" entries))
             (saved (assoc "saved-1" entries))
             (live-cells (cadr live))
             (saved-cells (cadr saved)))
        (should live)
        (should saved)
        ;; Pin marker (index 0): "*" + face for the target, a space otherwise.
        (should (equal (aref live-cells 0) "*"))
        (should (eq (get-text-property 0 'face (aref live-cells 0))
                    'dsh-bridge-current-target-face))
        (should (equal (aref saved-cells 0) " "))
        ;; Running marker (index 1): "…" when running, a space otherwise.
        (should (equal (aref live-cells 1) "…"))
        (should (equal (aref saved-cells 1) " "))
        ;; Session name (index 2): unaltered name, saved face for saved rows.
        (should (equal (aref live-cells 2) "First live"))
        (should (equal (aref saved-cells 2) "A saved one"))
        (should (eq (get-text-property 0 'face (aref saved-cells 2))
                    'dsh-bridge-saved-session-face))
        ;; Age (index 3) carries the raw activity timestamp.
        (should (equal (get-text-property 0 'dsh-bridge-age-ts
                                          (aref live-cells 3))
                       1700000000000))
        (should (equal (get-text-property 0 'dsh-bridge-age-ts
                                          (aref saved-cells 3))
                       1690000000000))
        ;; Workspace (index 4) is the cwd basename without a workspace title.
        (should (equal (aref live-cells 4) "a"))
        (should (equal (aref saved-cells 4) "b"))))))

(ert-deftest dsh-bridge-list-sessions-shows-ids-when-enabled ()
  "With `dsh-bridge-show-session-ids' non-nil, an Id column appears."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-target-session nil)
        (dsh-bridge-show-session-ids t))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () '(((id . "live-1") (live . t) (cwd . "/a")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (let ((buf (get-buffer "*dsh-bridge-sessions*")))
      (should (= (length (buffer-local-value 'tabulated-list-format buf)) 6))
      (let* ((entries (buffer-local-value 'tabulated-list-entries buf))
             (cells (cadr (assoc "live-1" entries))))
        (should (equal (aref cells 5) "live-1"))))))

(ert-deftest dsh-bridge-list-sessions-hides-saved-by-default ()
  "Saved sessions are hidden by default and revealed by the toggle."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-target-session nil)
        (dsh-bridge-sessions-show-saved nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 '(((id . "live-1") (live . t) (cwd . "/a"))
                   ((id . "saved-1") (live . nil) (cwd . "/b")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions)
      (let ((buf (get-buffer "*dsh-bridge-sessions*")))
        (should (assoc "live-1" (buffer-local-value 'tabulated-list-entries buf)))
        (should-not (assoc "saved-1" (buffer-local-value 'tabulated-list-entries buf)))
        (with-current-buffer buf
          (dsh-bridge-toggle-saved-sessions))
        (should (assoc "saved-1" (buffer-local-value 'tabulated-list-entries buf)))))))

(ert-deftest dsh-bridge-session-label-precedence ()
  "The label is the title, else the cwd basename, else the raw id."
  (should (equal (dsh-bridge--session-label '((title . "T") (cwd . "/x") (id . "i")))
                 "T"))
  (should (equal (dsh-bridge--session-label '((cwd . "/x/y") (id . "i"))) "y"))
  (should (equal (dsh-bridge--session-label '((cwd . "/x/") (id . "i"))) "x"))
  (should (equal (dsh-bridge--session-label '((id . "i"))) "i"))
  (should (equal (dsh-bridge--session-label '((title . "") (cwd . "/x") (id . "i")))
                 "x")))

(ert-deftest dsh-bridge-workspace-label ()
  "The workspace label is the title, else the cwd basename, else the cwd."
  (should (equal (dsh-bridge--workspace-label '((workspace . "proj") (cwd . "/x/y")))
                 "proj"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/x/y"))) "y"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/x/"))) "x"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/"))) "/"))
  (should (equal (dsh-bridge--workspace-label '((id . "i"))) "")))

(ert-deftest dsh-bridge-running-marker ()
  "The running marker is \"…\" when running, a space otherwise."
  (should (equal (dsh-bridge--running-marker '((running . t))) "…"))
  (should (equal (dsh-bridge--running-marker '((running . nil))) " "))
  (should (equal (dsh-bridge--running-marker '((id . "s"))) " ")))

(ert-deftest dsh-bridge-relative-age ()
  "Ages match DSH's buckets (now/min/h/d/mo/y)."
  (let ((now 1700000000))
    (should (equal (dsh-bridge--relative-age (* now 1000) now) "now"))
    (should (equal (dsh-bridge--relative-age (* (- now 90) 1000) now) "1min"))
    (should (equal (dsh-bridge--relative-age (* (- now 7200) 1000) now) "2h"))
    (should (equal (dsh-bridge--relative-age (* (- now 86400) 1000) now) "1d"))
    (should (equal (dsh-bridge--relative-age (* (- now (* 45 86400)) 1000) now) "1mo"))
    (should (equal (dsh-bridge--relative-age (* (- now (* 400 86400)) 1000) now) "1y"))))

(ert-deftest dsh-bridge-sessions-revert-refetches ()
  "`g' in the sessions buffer re-fetches the list from the host."
  (let ((dsh-bridge-target-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () '(((id . "live-1") (live . t) (cwd . "/a")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () '(((id . "live-2") (live . t) (cwd . "/b")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (with-current-buffer (get-buffer "*dsh-bridge-sessions*")
        (revert-buffer t t)))
    (let ((entries (buffer-local-value 'tabulated-list-entries
                                       (get-buffer "*dsh-bridge-sessions*"))))
      (should (assoc "live-2" entries))
      (should-not (assoc "live-1" entries)))))

(ert-deftest dsh-bridge-unpin-session ()
  "`dsh-bridge-unpin-session' POSTs a null sessionId and clears the pin."
  (let ((captured nil)
        (dsh-bridge-target-session "pinned"))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (setq captured (list method path payload))
                 (cons 200 (list (cons 'ok t)))))
              ((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () nil)))
      (dsh-bridge-unpin-session))
    (should (equal (car captured) "POST"))
    (should (equal (cadr captured) "/select"))
    (should (equal (caddr captured) '((sessionId . nil))))
    (should (null dsh-bridge-target-session))))

(ert-deftest dsh-bridge-unpin-encodes-null ()
  "The unpin payload encodes sessionId as JSON null, not the string \"json-null\"."
  (should (equal (json-encode '((sessionId . nil))) "{\"sessionId\":null}")))

(ert-deftest dsh-bridge-dispatcher-shares-view-letters ()
  "Every dispatcher verb is bound to the same command in the view buffers,
and the dispatcher layout contains the same keys."
  (dolist (spec dsh-bridge--verb-suffixes)
    (should (eq (lookup-key dsh-bridge-view-mode-map (kbd (car spec)))
                (cadr spec)))
    ;; Use transient's public API to check the dispatcher layout.
    (should (transient-get-suffix 'dsh-bridge (car spec)))))

(ert-deftest dsh-bridge-mode-menus ()
  "Each dsh-bridge mode installs a menu-bar menu."
  (let ((key (vector 'menu-bar (intern "dsh bridge"))))
    (dolist (map (list dsh-bridge-sessions-mode-map
                       dsh-bridge-view-mode-map
                       dsh-bridge-prompt-mode-map))
      (should (lookup-key map key)))))

(ert-deftest dsh-bridge-chunked-decode ()
  "HTTP/1.1 chunked transfer encoding is decoded byte-for-byte."
  (let ((decoded (dsh-bridge--chunked-decode
                  (string-to-unibyte "5\r\nhello\r\n0\r\n\r\n"))))
    (should (equal (car decoded) (string-to-unibyte "hello")))
    (should (equal (cdr decoded) "")))
  ;; An incomplete chunk is held back whole for the next call.
  (let ((decoded (dsh-bridge--chunked-decode (string-to-unibyte "5\r\nhel"))))
    (should (equal (car decoded) ""))
    (should (equal (cdr decoded) (string-to-unibyte "5\r\nhel"))))
  ;; Multibyte UTF-8 payloads are framed by their byte length.
  (let ((decoded (dsh-bridge--chunked-decode
                  (encode-coding-string "3\r\n…\r\n0\r\n\r\n" 'utf-8))))
    (should (equal (decode-coding-string (car decoded) 'utf-8) "…"))
    (should (equal (cdr decoded) ""))))

(ert-deftest dsh-bridge-sse-parse ()
  "SSE `data:' frames are decoded; non-data lines and partial frames are handled."
  (let ((result (dsh-bridge--sse-parse "")))
    (should (null (car result)))
    (should (equal (cdr result) "")))
  (let ((result (dsh-bridge--sse-parse "retry: 5000\n\n")))
    (should (null (car result)))
    (should (equal (cdr result) "")))
  (let ((result (dsh-bridge--sse-parse "data: {\"kind\":\"outbox\"}\n\n")))
    (should (equal (car result) '(((kind . "outbox")))))
    (should (equal (cdr result) "")))
  ;; No trailing blank line yet: held back.
  (let ((result (dsh-bridge--sse-parse "data: {\"kind\":\"outbox\"}")))
    (should (null (car result)))
    (should (equal (cdr result) "data: {\"kind\":\"outbox\"}")))
  ;; Several events in one buffer.
  (let ((result (dsh-bridge--sse-parse
                 "data: {\"kind\":\"draft\"}\n\ndata: {\"kind\":\"outbox\"}\n\n")))
    (should (equal (car result) '(((kind . "draft")) ((kind . "outbox")))))
    (should (equal (cdr result) ""))))

(ert-deftest dsh-bridge-outbox-notice-p ()
  "Only outbox-kind events are treated as inbox notices."
  (should (dsh-bridge--outbox-notice-p '(((kind . "outbox")))))
  (should-not (dsh-bridge--outbox-notice-p '(((kind . "draft")))))
  (should-not (dsh-bridge--outbox-notice-p nil)))

(ert-deftest dsh-bridge-sse-decode-roundtrip ()
  "A full chunked SSE body decodes to an outbox notice."
  (let* ((payload "data: {\"kind\":\"outbox\"}\n\n")
         (size (length (encode-coding-string payload 'utf-8)))
         (raw (encode-coding-string
               (concat (format "%x\r\n" size) payload "\r\n0\r\n\r\n")
               'utf-8)))
    (let* ((decoded (dsh-bridge--chunked-decode raw))
           (parsed (dsh-bridge--sse-parse
                    (decode-coding-string (car decoded) 'utf-8))))
      (should (dsh-bridge--outbox-notice-p (car parsed))))))

(provide 'dsh-bridge-tests)
;;; dsh-bridge-tests.el ends here
