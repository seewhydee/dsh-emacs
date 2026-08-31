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

;;; Low-level HTTP plumbing

(ert-deftest dsh-bridge-path-no-session ()
  (should (equal (dsh-bridge--path "/output" nil) "/output")))

(ert-deftest dsh-bridge-path-with-session ()
  (should (equal (dsh-bridge--path "/output" "session-1")
                 "/output?sessionId=session-1")))

(defmacro dsh-bridge-test--with-token-file (content &rest body)
  "Run BODY with `dsh-bridge-token-file' bound to a temp file holding CONTENT."
  (declare (indent 1))
  `(let* ((file (make-temp-file "dsh-bridge-token"))
          (dsh-bridge-token-file file))
     (unwind-protect
         (progn
           (with-temp-file file (insert ,content))
           ,@body)
       (delete-file file))))

(ert-deftest dsh-bridge-extra-headers-with-token ()
  (dsh-bridge-test--with-token-file "secret"
    (should (equal (dsh-bridge--extra-headers nil)
                   '(("Authorization" . "Bearer secret"))))))

(ert-deftest dsh-bridge-extra-headers-with-payload-and-token ()
  (dsh-bridge-test--with-token-file "secret"
    (should (equal (dsh-bridge--extra-headers '((text . "x")))
                   '(("Content-Type" . "application/json")
                     ("Authorization" . "Bearer secret"))))))

(ert-deftest dsh-bridge-extra-headers-no-token ()
  (let ((dsh-bridge-token-file "/nonexistent/dsh-bridge-token"))
    (should (equal (dsh-bridge--extra-headers nil) nil))))

(ert-deftest dsh-bridge-extra-headers-token-is-unibyte ()
  ;; A multibyte (even pure-ASCII) token header value poisons url-http's
  ;; request concatenation: a body containing non-ASCII bytes then fails
  ;; with "Multibyte text in HTTP request" (bug#23750).  The token is read
  ;; from the file as multibyte text, then coerced to unibyte.
  (dsh-bridge-test--with-token-file "secret"
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

;;; Targeting: the effective-session rule and the default target

(ert-deftest dsh-bridge-effective-session-default-only ()
  "With no buffer session, the effective session is the default target."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (should (equal (dsh-bridge--effective-session) "s1")))))

(ert-deftest dsh-bridge-effective-session-nil-without-default ()
  "With no buffer session and no default target, the effective session is nil
(last-active)."
  (let ((dsh-bridge-default-session nil))
    (with-temp-buffer
      (should (null (dsh-bridge--effective-session))))))

(ert-deftest dsh-bridge-effective-session-prompt-binding-wins ()
  "A prompt-buffer binding beats the default target."
  (let ((dsh-bridge-default-session "default"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "bound")
      (should (equal (dsh-bridge--effective-session) "bound")))))

(ert-deftest dsh-bridge-effective-session-output-content-wins ()
  "The output buffer's shown session beats the default target."
  (let ((dsh-bridge-default-session "default"))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "shown")
      (should (equal (dsh-bridge--effective-session) "shown")))))

(ert-deftest dsh-bridge-set-default-target-local ()
  "`dsh-bridge-set-default-target' sets the Emacs-side default directly and
never POSTs /select (the host pin is gone)."
  (let ((dsh-bridge-default-session "old") (posts nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path _payload)
                 (when (equal method "POST") (push path posts))
                 (cons 200 (list (cons 'sessions nil))))))
      (dsh-bridge-set-default-target "new"))
    (should (equal dsh-bridge-default-session "new"))
    (should-not (member "/select" posts))))

(ert-deftest dsh-bridge-clear-default-target-local ()
  "`dsh-bridge-clear-default-target' clears the default target, no host
round-trip."
  (let ((dsh-bridge-default-session "pinned"))
    (dsh-bridge-clear-default-target))
  (should (null dsh-bridge-default-session)))

(ert-deftest dsh-bridge-set-default-target-offers-saved-sessions ()
  "Completion offers live and saved sessions (plus the last-active choice)."
  (let ((table-seen nil)
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 '(((id . "live-1") (live . t) (cwd . "/a"))
                   ((id . "saved-1") (live . nil) (cwd . "/b")))))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _rest)
                 (setq table-seen table)
                 "(last-active)")))
      (call-interactively #'dsh-bridge-set-default-target))
    (should (equal (all-completions "" table-seen)
                   '("live-1" "saved-1" "(last-active)")))))

(ert-deftest dsh-bridge-effective-session-label ()
  "Header labels carry the right qualifier."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    ;; Bound buffer session: plain label.
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (should (equal (dsh-bridge--effective-session-label) "T")))
    ;; Default target: (default) qualifier.
    (with-temp-buffer
      (let ((dsh-bridge-default-session "s1"))
        (should (equal (dsh-bridge--effective-session-label) "T (default)"))))
    ;; Resolved last-active: (last active) qualifier.
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active '("s1" . "T")))
        (should (equal (dsh-bridge--effective-session-label)
                       "T (last active)"))))
    ;; Nothing bound and nothing resolved: no qualifier.
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active nil))
        (should (equal (dsh-bridge--effective-session-label) ""))))))

(ert-deftest dsh-bridge-session-unknown-message ()
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T")))))
    (should (string-match-p "session s1 is not known"
                            (dsh-bridge--session-unknown-message "s1")))))

(ert-deftest dsh-bridge-send-text-records-last-resolved ()
  "A nil-target send records the host-resolved session for display."
  (let ((dsh-bridge-default-session nil)
        (dsh-bridge--last-resolved-active nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload callback)
                 (funcall callback nil
                          "{\"ok\":true,\"sessionId\":\"s1\",\"title\":\"T\"}"
                          200))))
      (dsh-bridge-send-text "hello"))
    (should (equal (car dsh-bridge--last-resolved-active) "s1"))
    (should (equal (cdr dsh-bridge--last-resolved-active) "T"))))

(ert-deftest dsh-bridge-explicit-target-does-not-record-last-resolved ()
  "An explicit target is not the host's last-active resolution; nothing is
recorded."
  (let ((dsh-bridge-default-session "s1")
        (dsh-bridge--last-resolved-active nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload callback)
                 (funcall callback nil
                          "{\"ok\":true,\"sessionId\":\"s1\",\"title\":\"T\"}"
                          200))))
      (dsh-bridge-send-text "hello"))
    (should (null dsh-bridge--last-resolved-active))))

;;; Session labels

(ert-deftest dsh-bridge-session-label-precedence ()
  "The label is the title, else the raw id."
  (let ((dsh-bridge--sessions-cache
         '(((id . "s1") (title . "T") (cwd . "/x"))
           ((id . "s2") (cwd . "/x/y")))))
    (should (equal (dsh-bridge--label-for-id "s1") "T"))
    (should (equal (dsh-bridge--label-for-id "s2") "s2"))
    (should (equal (dsh-bridge--label-for-id "missing") "missing"))))

(ert-deftest dsh-bridge-workspace-label ()
  "The workspace label is the title, else the cwd basename, else the cwd."
  (should (equal (dsh-bridge--workspace-label '((workspace . "proj") (cwd . "/x/y")))
                 "proj"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/x/y"))) "y"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/x/"))) "x"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/"))) "/"))
  (should (equal (dsh-bridge--workspace-label '((id . "i"))) "")))

;;; Text senders

(ert-deftest dsh-bridge-send-draft-posts-to-draft ()
  "send-draft POSTs the text (and the effective session) to /draft."
  (let ((captured nil)
        (dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (method path payload _callback)
                 (setq captured (list method path payload)))))
      (dsh-bridge-send-draft "hello"))
    (should (equal (car captured) "POST"))
    (should (equal (cadr captured) "/draft"))
    (should (equal (cdr (assoc 'text (caddr captured))) "hello"))
    (should (equal (cdr (assoc 'sessionId (caddr captured))) "s1"))))

(ert-deftest dsh-bridge-send-draft-override-wins-over-default ()
  "An explicit session override beats the default target in the /draft payload."
  (let ((captured nil)
        (dsh-bridge-default-session "pin"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (method path payload _callback)
                 (setq captured (list method path payload)))))
      (dsh-bridge-send-draft "hello" "override"))
    (should (equal (cadr captured) "/draft"))
    (should (equal (cdr (assoc 'sessionId (caddr captured))) "override"))))

(ert-deftest dsh-bridge-send-text-override-wins-over-default ()
  "An explicit session override beats the default target in the /send payload."
  (let ((captured nil)
        (dsh-bridge-default-session "pin"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload _callback)
                 (setq captured payload))))
      (dsh-bridge-send-text "hi" "override"))
    (should (equal (cdr (assoc 'sessionId captured)) "override"))))

(ert-deftest dsh-bridge-send-text-no-target-omits-session ()
  "With neither a default target nor an override, no sessionId key is sent."
  (let ((captured nil)
        (dsh-bridge-default-session nil))
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

(ert-deftest dsh-bridge-draft-whole-buffer-confirms ()
  "A whole-buffer draft asks y-or-n-p first (guard symmetry with send)."
  (let ((asked nil) captured)
    (with-temp-buffer
      (insert "whole")
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload)))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) t)))
        (dsh-bridge-draft)))
    (should asked)
    (should (equal (cdr (assoc 'text captured)) "whole"))))

(ert-deftest dsh-bridge-send-read-only-no-region-refuses ()
  "Sending from a read-only buffer without a region refuses."
  (let ((sent nil))
    (with-temp-buffer
      (insert "content")
      (dsh-bridge-view-mode)
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (&rest _) (setq sent t))))
        (condition-case nil (dsh-bridge-send) (error nil)))
      (should (null sent)))))

(ert-deftest dsh-bridge-send-active-region-in-read-only-works ()
  "A region in a read-only buffer is sendable."
  (let ((transient-mark-mode t) captured)
    (with-temp-buffer
      (insert "alpha beta")
      (dsh-bridge-view-mode)
      (goto-char 7)
      (set-mark (point-max))
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload))))
        (dsh-bridge-send)))
    (should (equal (cdr (assoc 'text captured)) "beta"))))

(ert-deftest dsh-bridge-send-prefix-override ()
  "With a prefix argument, send targets the completing-read session for this
call only, leaving the default target untouched."
  (let ((transient-mark-mode t)
        (current-prefix-arg t)
        (captured nil)
        (dsh-bridge-default-session "pin"))
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
    (should (equal dsh-bridge-default-session "pin"))))

;;; Fetch and the output buffer

(ert-deftest dsh-bridge-fetch-uses-default-target ()
  "`dsh-bridge-fetch' requests /output with the default target when the
current buffer has no session of its own."
  (let ((dsh-bridge-default-session "s1")
        (captured nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method path _payload _callback)
                 (setq captured path))))
      (dsh-bridge-fetch))
    (should (equal captured "/output?sessionId=s1"))))

(ert-deftest dsh-bridge-fetch-populates-output ()
  "Fetch writes the reply into *dsh-bridge-output* in `dsh-bridge-view-mode'."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          "{\"text\":\"reply text\",\"sessionId\":\"s1\"}" 200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch))
    (let ((buf (get-buffer "*dsh-bridge-output*")))
      (should buf)
      (with-current-buffer buf
        (should (equal (buffer-string) "reply text"))
        (should (eq major-mode 'dsh-bridge-view-mode))
        (should buffer-read-only)
        (should (string-match-p " s1" (format "%s" header-line-format)))
        (should (string-match-p "· " (format "%s" header-line-format)))))))

(ert-deftest dsh-bridge-fetch-peek-labels-content-session ()
  "A peek/override fetch labels the output buffer with the content's session,
not the default target."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          "{\"text\":\"other reply\",\"sessionId\":\"s2\"}"
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch "s2"))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "other reply"))
      (should (string-match-p " s2" (format "%s" header-line-format)))
      (should-not (string-match-p " s1" (format "%s" header-line-format)))
      (should-not (string-match-p "target:" (format "%s" header-line-format))))))

(ert-deftest dsh-bridge-fetch-seeds-status ()
  "Fetch seeds the tracker from /output's running flag: true -> running,
false -> idle.  `dsh-bridge--call' parses JSON `false' as the non-nil symbol
:false, so the check must compare against t, not truthiness (a regression:
a `running:false' session used to be seeded `running' and show amber)."
  (dolist (case (list (cons "{\"text\":\"r\",\"sessionId\":\"s1\",\"running\":true}"
                            'running)
                      (cons "{\"text\":\"r\",\"sessionId\":\"s1\",\"running\":false}"
                            'idle)))
    (let ((dsh-bridge-default-session "s1")
          (dsh-bridge--session-status nil))
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path _payload callback)
                   (funcall callback nil (car case) 200)))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (&rest _) (cons nil nil))))
        (dsh-bridge-fetch "s1"))
      (should (eq (dsh-bridge--status-state "s1") (cdr case))))))

(ert-deftest dsh-bridge-apply-session-directory ()
  "The helper sets default-directory (trailing slash), with cache fallback."
  (with-temp-buffer
    (dsh-bridge--apply-session-directory "s1" "/home/user/proj")
    (should (equal default-directory "/home/user/proj/")))
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (cwd . "/cache/dir")))))
    (with-temp-buffer
      (dsh-bridge--apply-session-directory "s1" nil)
      (should (equal default-directory "/cache/dir/"))))
  (with-temp-buffer
    (let ((before default-directory))
      (dsh-bridge--apply-session-directory "s1" nil)
      (should (equal default-directory before)))))

(ert-deftest dsh-bridge-fetch-sets-output-directory ()
  "Fetch sets the output buffer's default-directory to the session cwd."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          "{\"text\":\"reply\",\"sessionId\":\"s1\",\"cwd\":\"/w/sess1\"}"
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal default-directory "/w/sess1/")))))

;;; The prompt buffer: session binding, header, history

(ert-deftest dsh-bridge-set-prompt-session-sets-directory ()
  "Binding the prompt buffer sets its default-directory from the cache."
  (when (get-buffer "*dsh-bridge-prompt*")
    (kill-buffer "*dsh-bridge-prompt*"))
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (cwd . "/w/sess1") (live . t)))))
    (dsh-bridge--set-prompt-session "s1")
    (with-current-buffer "*dsh-bridge-prompt*"
      (should (equal default-directory "/w/sess1/"))))
  (kill-buffer "*dsh-bridge-prompt*"))

(ert-deftest dsh-bridge-set-default-target-sets-prompt-directory ()
  "Setting the default target re-points an unbound prompt buffer's directory."
  (when (get-buffer "*dsh-bridge-prompt*")
    (kill-buffer "*dsh-bridge-prompt*"))
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (cwd . "/w/sess1") (live . t))))
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions) (lambda () nil)))
      (get-buffer-create "*dsh-bridge-prompt*")
      (dsh-bridge-set-default-target "s1")
      (with-current-buffer "*dsh-bridge-prompt*"
        (should (equal default-directory "/w/sess1/")))))
  (kill-buffer "*dsh-bridge-prompt*"))

(ert-deftest dsh-bridge-prompt-mode-basics ()
  "The prompt mode derives from text-mode in a markdown-less environment and
binds the compose keys plus fetch/set-session/list."
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (should (eq major-mode 'dsh-bridge-prompt-mode))
    (should (provided-mode-derived-p major-mode 'text-mode))
    (should (eq (car-safe header-line-format) :eval)))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-c"))
              #'dsh-bridge-send-and-exit))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-d"))
              #'dsh-bridge-draft))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-k"))
              #'dsh-bridge-erase-prompt))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-f"))
              #'dsh-bridge-fetch))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-s"))
              #'dsh-bridge-set-buffer-session))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-l"))
              #'dsh-bridge-list-sessions))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "M-p"))
              #'dsh-bridge-prompt-previous-history))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "M-n"))
              #'dsh-bridge-prompt-next-history)))

(ert-deftest dsh-bridge-prompt-header-qualifiers ()
  "The prompt header names the effective session with its qualifier."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    ;; Bound buffer session: plain label (header refreshes after binding).
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (should (string-match-p " T$" (dsh-bridge--prompt-header-line))))
    (with-temp-buffer
      (let ((dsh-bridge-default-session "s1"))
        (dsh-bridge-prompt-mode)
        (should (string-match-p "T (default)"
                                (dsh-bridge--prompt-header-line)))))
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active nil)
            (dsh-bridge-status-indicator 'geometric))
        (dsh-bridge-prompt-mode)
        ;; Nothing bound and nothing resolved: the header shows only the status.
        (should (string-match-p "●" (dsh-bridge--prompt-header-line)))
        (should-not (string-match-p "(last-active)"
                                    (dsh-bridge--prompt-header-line)))))))

(ert-deftest dsh-bridge-set-buffer-session-binds ()
  "`C-c C-s' rebinds the prompt buffer's session."
  (let ((dsh-bridge-default-session "default"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (cl-letf (((symbol-function 'dsh-bridge--read-session-id)
                 (lambda (_prompt _pseudo) "live-1"))
                ((symbol-function 'dsh-bridge--set-prompt-session)
                 (lambda (id) (setq-local dsh-bridge--prompt-session id))))
        (dsh-bridge-set-buffer-session))
      (should (equal dsh-bridge--prompt-session "live-1")))))

(ert-deftest dsh-bridge-prompt-history-navigation ()
  "M-p/M-n cycle the prompt buffer through the cached session history."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-history-session "s1")
      (setq dsh-bridge--prompt-history '(("s1" "third" "second" "first")))
      (insert "my draft")
      ;; M-p: newest prompt, draft saved.
      (dsh-bridge-prompt-previous-history)
      (should (equal (buffer-string) "third"))
      (should (equal dsh-bridge--prompt-draft "my draft"))
      (should (equal dsh-bridge--prompt-history-index 0))
      ;; M-p again: older, then oldest, then stays.
      (dsh-bridge-prompt-previous-history)
      (should (equal (buffer-string) "second"))
      (dsh-bridge-prompt-previous-history)
      (should (equal (buffer-string) "first"))
      (dsh-bridge-prompt-previous-history)
      (should (equal (buffer-string) "first"))
      ;; M-n walks back to the newest, then restores the draft.
      (dsh-bridge-prompt-next-history)
      (should (equal (buffer-string) "second"))
      (dsh-bridge-prompt-next-history)
      (should (equal (buffer-string) "third"))
      (dsh-bridge-prompt-next-history)
      (should (equal (buffer-string) "my draft"))
      (should (null dsh-bridge--prompt-history-index)))))

(ert-deftest dsh-bridge-prompt-history-fetches ()
  "M-p fetches the effective session's prompts from the host when not cached."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (method path _payload)
                   (should (equal method "GET"))
                   (should (equal path "/prompts?sessionId=s1"))
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'prompts (list "new" "old")))))))
        (dsh-bridge-prompt-previous-history))
      (should (equal (buffer-string) "new"))
      (should (equal (cdr (assoc "s1" dsh-bridge--prompt-history))
                     (list "new" "old"))))))

(ert-deftest dsh-bridge-prompt-history-no-prompts ()
  "M-p with no cached prompts reports it and leaves the buffer untouched."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-history-session "s1")
      (setq dsh-bridge--prompt-history '(("s1")))
      (insert "draft")
      (dsh-bridge-prompt-previous-history)
      (should (equal (buffer-string) "draft"))
      (should (null dsh-bridge--prompt-history-index)))))

(ert-deftest dsh-bridge-prompt-history-record-send ()
  "A recorded send prepends the text and returns the buffer to the draft slot."
  (setq dsh-bridge--prompt-history '(("s1" "old")))
  (when (get-buffer "*dsh-bridge-prompt*")
    (kill-buffer "*dsh-bridge-prompt*"))
  (let ((buf (get-buffer-create "*dsh-bridge-prompt*")))
    (with-current-buffer buf
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-history-session "s1")
      (setq-local dsh-bridge--prompt-history-index 1))
    (dsh-bridge--prompt-history-record-send "s1" "just sent")
    (should (equal (cdr (assoc "s1" dsh-bridge--prompt-history))
                   (list "just sent" "old")))
    (with-current-buffer buf
      (should (null dsh-bridge--prompt-history-index)))
    (kill-buffer buf)))

(ert-deftest dsh-bridge-send-text-records-history ()
  "A successful send records the prompt into the session history cache."
  (let ((dsh-bridge-default-session "s1")
        (dsh-bridge--prompt-history nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload callback)
                 (funcall callback nil
                          "{\"ok\":true,\"sessionId\":\"s1\",\"title\":\"T\"}"
                          200))))
      (dsh-bridge-send-text "hello"))
    (should (equal (cdr (assoc "s1" dsh-bridge--prompt-history))
                   (list "hello")))))

;;; The view buffers

(ert-deftest dsh-bridge-view-mode-basics ()
  "The view mode is read-only and binds g/q/r/w/i/l plus M-p/M-n — and no
compose/fetch/targeting verbs."
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (should buffer-read-only)
    (should (eq major-mode 'dsh-bridge-view-mode)))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "g")) #'revert-buffer))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "q")) #'quit-window))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "r")) #'dsh-bridge-reply))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "w"))
              #'dsh-bridge-copy-reply))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "i"))
              #'dsh-bridge-receive))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "l"))
              #'dsh-bridge-list-sessions))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "M-p"))
              #'dsh-bridge-view-previous-reply))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "M-n"))
              #'dsh-bridge-view-next-reply))
  (dolist (key '("s" "d" "f" "t" "u"))
    (should-not (eq (lookup-key dsh-bridge-view-mode-map (kbd key))
                    (cadr (assoc key dsh-bridge--verb-suffixes))))))

(ert-deftest dsh-bridge-view-mode-gfm ()
  "When markdown-mode is loadable, the view mode font-locks GFM without
inheriting markdown's keymap."
  (when (require 'markdown-mode nil t)
    (with-temp-buffer
      (insert "# Heading\n")
      (dsh-bridge-view-mode)
      (should (derived-mode-p 'special-mode))
      (should font-lock-defaults)
      (should markdown-fontify-code-blocks-natively)
      (should buffer-read-only)
      ;; Markdown's outline keys must not leak into the view keymap.
      (should-not (eq (lookup-key dsh-bridge-view-mode-map (kbd "p"))
                      #'markdown-outline-previous))
      (should-not (eq (lookup-key dsh-bridge-view-mode-map (kbd "n"))
                      #'markdown-outline-next)))))

(ert-deftest dsh-bridge-reply-binds-shown-session ()
  "`dsh-bridge-reply' in the output buffer binds the prompt to the shown
session and never touches the default target."
  (let ((dsh-bridge-default-session "target")
        (bound nil) (popped nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "shown")
      (cl-letf (((symbol-function 'dsh-bridge--session-live-p) (lambda (_) t))
                ((symbol-function 'dsh-bridge--set-prompt-session)
                 (lambda (id) (setq bound id)))
                ((symbol-function 'dsh-bridge--prompt-buffer)
                 (lambda () (get-buffer-create "*dsh-bridge-prompt*")))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buf action) (setq popped (list buf action)))))
        (dsh-bridge-reply))
      (should (equal bound "shown"))
      (should (equal dsh-bridge-default-session "target"))
      (should (equal (car popped) (get-buffer-create "*dsh-bridge-prompt*")))
      (should (equal (cadr popped) dsh-bridge-prompt-display-action)))))

(ert-deftest dsh-bridge-reply-not-live-message ()
  "Reply to an unknown session gives the not-known message, no resume attempt."
  (let ((dsh-bridge--sessions-cache nil)
        (bound nil) (msg nil) (resumed nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "gone")
      (cl-letf (((symbol-function 'dsh-bridge--set-prompt-session)
                 (lambda (id) (setq bound id)))
                ((symbol-function 'dsh-bridge--resume-session)
                 (lambda (id) (setq resumed id) nil))
                ((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args)))))
        (dsh-bridge-reply))
      (should (null bound))
      (should (null resumed))
      (should (string-match-p "not known" msg)))))

(ert-deftest dsh-bridge-reply-resume-failure-keeps-host-message ()
  "A failed resume's host error is not overwritten by the not-known message."
  (let ((dsh-bridge--sessions-cache '(((id . "saved-1") (live . nil))))
        (bound nil) (msg nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "saved-1")
      (cl-letf (((symbol-function 'dsh-bridge--set-prompt-session)
                 (lambda (id) (setq bound id)))
                ((symbol-function 'dsh-bridge--resume-session)
                 (lambda (_id) (message "dsh-bridge: HTTP 409: subagent-owned") nil))
                ((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args)))))
        (dsh-bridge-reply))
      (should (null bound))
      (should (string-match-p "HTTP 409" msg)))))

(ert-deftest dsh-bridge-copy-reply ()
  "`dsh-bridge-copy-reply' copies the whole reply without a region."
  (with-temp-buffer
    (insert "the reply")
    (dsh-bridge-view-mode)
    (setq-local dsh-bridge--view-content-session "s1")
    (let ((killed nil))
      (cl-letf (((symbol-function 'copy-region-as-kill)
                 (lambda (beg end) (setq killed (buffer-substring beg end)))))
        (dsh-bridge-copy-reply))
      (should (equal killed "the reply")))))

;;; Receive (the DSH→Emacs push; the outbox is invisible transport)

(defconst dsh-bridge-test--receive-response
  (cons 200
        (list (cons 'entries
                    (list (list (cons 'id "e1")
                                (cons 'sessionId "s1")
                                (cons 'source "message-action")
                                (cons 'text "older")
                                (cons 'ts 1000000))
                          (list (cons 'id "e2")
                                (cons 'sessionId "s2")
                                (cons 'source "message-action")
                                (cons 'text "newest")
                                (cons 'ts 2000000))))
              (cons 'overflowed nil))))

(ert-deftest dsh-bridge-receive-shows-newest-and-acks-all ()
  "Receive displays the newest pending entry in the output buffer and acks
every collected id."
  (let (acked-payload)
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (cond
                  ((equal method "GET") dsh-bridge-test--receive-response)
                  ((equal method "POST") (setq acked-payload payload)
                   (cons 200 (list (cons 'ok t))))
                  (t (cons 404 (list (cons 'error "unexpected"))))))))
      (dsh-bridge-receive))
    (should (equal acked-payload '((ids . ("e1" "e2")))))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "newest"))
      (should (equal dsh-bridge--view-content-session "s2"))
      (should (string-match-p "s2 ·" (format "%s" header-line-format)))
      (should (string-match-p " · " (format "%s" header-line-format))))))

(ert-deftest dsh-bridge-receive-multiple-messages-message ()
  "Several pending entries produce the honest 'received' message."
  (let ((msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-receive))
    (should (string-match-p "2 messages received from DSH" msg))))

(ert-deftest dsh-bridge-receive-pops-by-default ()
  "With `dsh-bridge-receive-pop' (the default), receive selects the output
buffer."
  (let ((popped nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (dsh-bridge-receive))
    (should popped)))

(ert-deftest dsh-bridge-receive-does-not-pop-when-disabled ()
  "With `dsh-bridge-receive-pop' nil, receive fills the output buffer without
selecting it."
  (let ((popped nil)
        (dsh-bridge-receive-pop nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (dsh-bridge-receive))
    (should (null popped))))

(ert-deftest dsh-bridge-receive-nothing-pending ()
  "With nothing pending, receive says so and leaves the output alone."
  (let ((msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cons 200 (list (cons 'entries nil)))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-receive))
    (should (string-match-p "nothing to receive" msg))))

(ert-deftest dsh-bridge-receive-sets-workspace-best-effort ()
  "Receive points the output buffer at the session's workspace when known."
  (let ((dsh-bridge--sessions-cache '(((id . "s2") (cwd . "/w/sess2") (live . t)))))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t))))))))
      (dsh-bridge-receive))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal default-directory "/w/sess2/")))))

;;; Reply navigation (M-p / M-n in the output buffer)

(defconst dsh-bridge-test--replies-response
  (cons 200
        (list (cons 'sessionId "s1")
              (cons 'replies (list "newest" "middle" "oldest")))))

(ert-deftest dsh-bridge-view-reply-navigation ()
  "M-p/M-n cycle the output buffer through the session's replies and restore
the anchor at the newest."
  (let ((dsh-bridge--replies-cache nil))
    (with-temp-buffer
      (insert "newest")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (method path _payload)
                   (should (equal method "GET"))
                   (should (equal path "/replies?sessionId=s1"))
                   dsh-bridge-test--replies-response)))
        ;; First M-p: anchor the shown reply, move one older.
        (dsh-bridge-view-previous-reply)
        (should (equal (buffer-string) "middle"))
        (should (equal dsh-bridge--view-replies-anchor "newest"))
        (should (equal dsh-bridge--view-replies-index 1))
        (should (string-match-p " (2/3)" (format "%s" header-line-format)))
        ;; Older, then at the oldest it stays.
        (dsh-bridge-view-previous-reply)
        (should (equal (buffer-string) "oldest"))
        (should (equal dsh-bridge--view-replies-index 2))
        (dsh-bridge-view-previous-reply)
        (should (equal (buffer-string) "oldest"))
        ;; M-n walks back toward the newest, then restores the anchor.
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) "middle"))
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) "newest"))
        (should (equal dsh-bridge--view-replies-index 0))
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) "newest"))
        (should (null dsh-bridge--view-replies-index))))))

(ert-deftest dsh-bridge-view-reply-navigation-no-replies ()
  "With no replies, M-p reports it and leaves the buffer alone."
  (let ((dsh-bridge--replies-cache nil)
        (msg nil))
    (with-temp-buffer
      (insert "content")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (_method _path _payload)
                   (cons 200 (list (cons 'sessionId "s1") (cons 'replies nil)))))
                ((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args)))))
        (dsh-bridge-view-previous-reply))
      (should (equal (buffer-string) "content"))
      (should (string-match-p "no replies" msg)))))

(ert-deftest dsh-bridge-fetch-resets-reply-navigation ()
  "Fetching a fresh reply resets reply navigation to the anchor state."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          "{\"text\":\"fresh\",\"sessionId\":\"s1\"}" 200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-replies-index 2)
        (setq-local dsh-bridge--view-replies-anchor "old anchor"))
      (dsh-bridge-fetch)
      (with-current-buffer "*dsh-bridge-output*"
        (should (equal (buffer-string) "fresh"))
        (should (null dsh-bridge--view-replies-index))
        (should (null dsh-bridge--view-replies-anchor))))))

;;; The sessions list

(ert-deftest dsh-bridge-sessions-keymap ()
  "RET/r open, t sets the default target, u clears it, f peeks, v toggles
archived visibility, R renames, d archives, + creates, W renames the workspace,
and p is previous-line again."
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "RET"))
              #'dsh-bridge-open-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "r"))
              #'dsh-bridge-open-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "t"))
              #'dsh-bridge-set-default-target-at-point))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "u"))
              #'dsh-bridge-clear-default-target))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "f"))
              #'dsh-bridge-peek-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "v"))
              #'dsh-bridge-toggle-archived-sessions))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "R"))
              #'dsh-bridge-rename-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "d"))
              #'dsh-bridge-archive-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "+"))
              #'dsh-bridge-create-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "W"))
              #'dsh-bridge-rename-workspace))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "w"))
              #'dsh-bridge-copy-session-id))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "D"))
              #'dsh-bridge-describe-session))
  ;; `p' inherits previous-line from tabulated-list-mode again.
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "p"))
              #'previous-line)))

(ert-deftest dsh-bridge-open-session-binds-prompt-not-default ()
  "RET binds the prompt buffer to the row's session; the default target is
untouched."
  (let ((dsh-bridge--sessions-cache '(((id . "live-1") (live . t) (cwd . "/w"))))
        (dsh-bridge-default-session "default")
        (bound nil) (popped nil))
    ;; `tabulated-list-get-id' is a defsubst: byte-compilation inlines it,
    ;; so cl-letf cannot mock it.  Stand point on a real tabulated-list-id
    ;; text property instead.
    (cl-letf (((symbol-function 'dsh-bridge--set-prompt-session)
               (lambda (id) (setq bound id)))
              ((symbol-function 'dsh-bridge--prompt-buffer)
               (lambda () (get-buffer-create "*dsh-bridge-prompt*")))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (with-temp-buffer
        (insert (propertize "live-1 row" 'tabulated-list-id "live-1"))
        (goto-char (point-min))
        (dsh-bridge-open-session)))
    (should (equal bound "live-1"))
    (should (equal dsh-bridge-default-session "default"))
    (should popped)))

(ert-deftest dsh-bridge-open-session-not-live-message ()
  "RET on an unknown id reports the not-known message, with no resume attempt."
  (let ((dsh-bridge--sessions-cache nil)
        (bound nil) (msg nil) (resumed nil))
    (cl-letf (((symbol-function 'dsh-bridge--set-prompt-session)
               (lambda (id) (setq bound id)))
              ((symbol-function 'dsh-bridge--resume-session)
               (lambda (id) (setq resumed id) nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-temp-buffer
        (insert (propertize "gone row" 'tabulated-list-id "gone"))
        (goto-char (point-min))
        (dsh-bridge-open-session)))
    (should (null bound))
    (should (null resumed))
    (should (string-match-p "not known" msg))))

(ert-deftest dsh-bridge-open-session-resume-failure-keeps-host-message ()
  "RET on a saved row whose resume fails keeps the host's error message."
  (let ((dsh-bridge--sessions-cache '(((id . "saved-1") (live . nil))))
        (bound nil) (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--set-prompt-session)
               (lambda (id) (setq bound id)))
              ((symbol-function 'dsh-bridge--resume-session)
               (lambda (_id) (message "dsh-bridge: HTTP 409: subagent-owned") nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-temp-buffer
        (insert (propertize "saved-1 row" 'tabulated-list-id "saved-1"))
        (goto-char (point-min))
        (dsh-bridge-open-session)))
    (should (null bound))
    (should (string-match-p "HTTP 409" msg))))

(ert-deftest dsh-bridge-open-session-resumes-saved ()
  "RET on a saved row resumes it first, then binds the prompt buffer."
  (let ((dsh-bridge--sessions-cache '(((id . "saved-1") (live . nil))))
        (bound nil) (popped nil) (resumed nil))
    (cl-letf (((symbol-function 'dsh-bridge--set-prompt-session)
               (lambda (id) (setq bound id)))
              ((symbol-function 'dsh-bridge--resume-session)
               (lambda (id) (setq resumed id) t))
              ((symbol-function 'dsh-bridge--prompt-buffer)
               (lambda () (get-buffer-create "*dsh-bridge-prompt*")))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (with-temp-buffer
        (insert (propertize "saved-1 row" 'tabulated-list-id "saved-1"))
        (goto-char (point-min))
        (dsh-bridge-open-session)))
    (should (equal resumed "saved-1"))
    (should (equal bound "saved-1"))
    (should popped)))

(ert-deftest dsh-bridge-set-default-target-at-point ()
  "`t' sets the default target to the row's session."
  (let ((dsh-bridge--sessions-cache '(((id . "live-1") (live . t))))
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge-set-default-target)
               (lambda (id) (setq dsh-bridge-default-session id))))
      (with-temp-buffer
        (insert (propertize "live-1 row" 'tabulated-list-id "live-1"))
        (goto-char (point-min))
        (dsh-bridge-set-default-target-at-point)))
    (should (equal dsh-bridge-default-session "live-1"))))

(ert-deftest dsh-bridge-list-sessions-columns-and-marker ()
  "The session list shows marker/S/Session/Age/Workspace columns."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session "live-1")
        (dsh-bridge-status-indicator 'geometric))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 (let ((sessions
                        '(((id . "live-1") (live . t) (running . t) (title . "First live")
                           (cwd . "/a") (lastActive . 1700000000000)
                           (workspace . "WS A") (workspaceId . "w1"))
                          ((id . "saved-1") (live . nil) (title . "A saved one") (cwd . "/b")
                           (createdAt . 1690000000000)))))
                   (setq dsh-bridge--sessions-cache sessions)
                   sessions)))
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
        ;; Default-target marker (index 0): "*" + face for the default target.
        (should (equal (aref live-cells 0) "*"))
        (should (eq (get-text-property 0 'face (aref live-cells 0))
                    'dsh-bridge-default-target-face))
        (should (equal (aref saved-cells 0) " "))
        ;; Status cell (index 1): the state glyph — filled circle for running
        ;; (amber), `?' for saved (no live agent).
        (should (equal (aref live-cells 1) "●"))
        (should (equal (aref saved-cells 1) "?"))
        ;; Session name (index 2): unaltered name; cold rows have no face now.
        (should (equal (aref live-cells 2) "First live"))
        (should (equal (aref saved-cells 2) "A saved one"))
        ;; Age (index 3) carries the raw activity timestamp.
        (should (equal (get-text-property 0 'dsh-bridge-age-ts
                                          (aref live-cells 3))
                       1700000000000))
        (should (equal (get-text-property 0 'dsh-bridge-age-ts
                                          (aref saved-cells 3))
                       1690000000000))
        ;; Workspace (index 4) is the workspace title, else the cwd basename.
        (should (equal (aref live-cells 4) "WS A"))
        (should (equal (aref saved-cells 4) "b"))))))

(ert-deftest dsh-bridge-list-sessions-emoji-status-column ()
  "Under the `emoji' indicator the status column is two columns wide.
Emoji glyphs are double-width; in a one-column cell
`tabulated-list-print-col' would cover the glyph with an ellipsis
`display' property, so the row must print it unelided."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session nil)
        (dsh-bridge-status-indicator 'emoji))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 (let ((sessions
                        '(((id . "live-1") (live . t) (running . nil) (title . "First live")
                           (lastActive . 1700000000000) (workspace . "WS A")))))
                   (setq dsh-bridge--sessions-cache sessions)
                   sessions)))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (let ((buf (get-buffer "*dsh-bridge-sessions*")))
      (should buf)
      (should (= (nth 1 (aref (buffer-local-value 'tabulated-list-format buf) 1))
                 2))
      (with-current-buffer buf
        (goto-char (point-min))
        (should (search-forward "🟢" nil t))
        ;; The printed glyph must not be hidden behind an ellipsis display.
        (should-not (get-text-property (1- (point)) 'display))))))

(ert-deftest dsh-bridge-session-cell-untitled ()
  "The session cell shows the title, or the raw id (untitled face) otherwise."
  (let ((a '((id . "aaaaaa") (live . t) (cwd . "/x")))
        (b '((id . "bbbbbb") (live . t) (title . "B"))))
    (should (string= (dsh-bridge--session-cell a) "aaaaaa"))
    (should (eq (get-text-property 0 'face (dsh-bridge--session-cell a))
                'dsh-bridge-untitled-face))
    (should (string= (dsh-bridge--session-cell b) "B"))))

(ert-deftest dsh-bridge-list-sessions-shows-ids-when-enabled ()
  "With `dsh-bridge-show-session-ids' non-nil, an Id column appears."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session nil)
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

(ert-deftest dsh-bridge-sessions-archived-toggle ()
  "The `v' toggle shows/hides archived sessions; live and cold rows stay visible."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 '(((id . "live-1") (live . t) (cwd . "/a"))
                   ((id . "saved-1") (live . nil) (cwd . "/b"))
                   ((id . "arch-1") (live . nil) (archived . t) (cwd . "/c")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions)
      (let ((buf (get-buffer "*dsh-bridge-sessions*")))
        ;; Default: archived hidden.
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should (assoc "live-1" entries))
          (should (assoc "saved-1" entries))
          (should-not (assoc "arch-1" entries)))
        ;; Toggle on: archived shown too.
        (with-current-buffer buf (dsh-bridge-toggle-archived-sessions))
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should (assoc "arch-1" entries)))
        ;; Toggle off: archived hidden again.
        (with-current-buffer buf (dsh-bridge-toggle-archived-sessions))
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should-not (assoc "arch-1" entries)))))))

(ert-deftest dsh-bridge-session-visible-p ()
  "Visibility depends only on the archived flag and the archived toggle."
  (let ((dsh-bridge--sessions-archived-p nil))
    (should (dsh-bridge--session-visible-p '((live . t) (cwd . "/a"))))
    (should (dsh-bridge--session-visible-p '((live . nil) (cwd . "/b"))))
    (should-not (dsh-bridge--session-visible-p '((live . nil) (archived . t)))))
  (let ((dsh-bridge--sessions-archived-p t))
    (should (dsh-bridge--session-visible-p '((live . nil) (archived . t))))
    (should (dsh-bridge--session-visible-p '((live . t) (cwd . "/a"))))))

(ert-deftest dsh-bridge-rename-session-sends-row-id ()
  "Rename from the sessions list sends the row's session id and prompted title."
  (let ((calls nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional _default) "New title"))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) calls)
                 (cons 200 (list (cons 'ok t))))))
      (with-temp-buffer
        (insert (propertize "s1 row" 'tabulated-list-id "s1"))
        (goto-char (point-min))
        (dsh-bridge-rename-session)))
    (let ((rename (cadr (assoc "/sessions/rename"
                               (mapcar (lambda (c) (list (cadr c) c)) calls)))))
      (should rename)
      (should (equal (car rename) "POST"))
      (should (equal (cdr (assoc 'sessionId (caddr rename))) "s1"))
      (should (equal (cdr (assoc 'title (caddr rename))) "New title")))))

(ert-deftest dsh-bridge-archive-session-marshals-args ()
  "Archive confirms, then POSTs the session id to /sessions/archive."
  (let ((calls nil) (msg nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) calls)
                 (cons 200 (list (cons 'ok t)))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-temp-buffer
        (insert (propertize "s1 row" 'tabulated-list-id "s1"))
        (goto-char (point-min))
        (dsh-bridge-archive-session)))
    (let ((archive (cadr (assoc "/sessions/archive"
                                (mapcar (lambda (c) (list (cadr c) c)) calls)))))
      (should archive)
      (should (equal (car archive) "POST"))
      (should (equal (cdr (assoc 'sessionId (caddr archive))) "s1"))
      (should (string-match-p "archived session" msg)))))

(ert-deftest dsh-bridge-archive-session-aborts-on-no ()
  "Archive declines without a request when the user answers no."
  (let ((called nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (setq called (list method path payload))
                 (cons 200 (list (cons 'ok t))))))
      (with-temp-buffer
        (insert (propertize "s1 row" 'tabulated-list-id "s1"))
        (goto-char (point-min))
        (dsh-bridge-archive-session)))
    (should (null called))))

(ert-deftest dsh-bridge-rename-workspace-marshals-args ()
  "Rename-workspace POSTs the row's workspace id and new title."
  (let ((dsh-bridge--sessions-cache
         '(((id . "s1") (workspaceId . "w1") (workspace . "WS"))))
        (calls nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional _default) "New WS"))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) calls)
                 (cons 200 (list (cons 'ok t))))))
      (with-temp-buffer
        (insert (propertize "s1 row" 'tabulated-list-id "s1"))
        (goto-char (point-min))
        (dsh-bridge-rename-workspace)))
    (let ((rename (cadr (assoc "/workspaces/rename"
                               (mapcar (lambda (c) (list (cadr c) c)) calls)))))
      (should rename)
      (should (equal (cdr (assoc 'workspaceId (caddr rename))) "w1"))
      (should (equal (cdr (assoc 'title (caddr rename))) "New WS")))))

(ert-deftest dsh-bridge-create-session-marshals-args ()
  "Create GETs /workspaces, then POSTs the chosen workspace and binds the new
session as default target."
  (let ((called nil) (bound-target nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _table &optional _pred _req) "WS B"))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) called)
                 (if (equal path "/workspaces")
                     (cons 200
                           (list (cons 'workspaces
                                       (list (list (cons 'id "w1") (cons 'title "WS A"))
                                             (list (cons 'id "w2") (cons 'title "WS B"))))))
                   (cons 201 (list (cons 'sessionId "s-new"))))))
              ((symbol-function 'dsh-bridge--fetch-sessions) (lambda () nil))
              ((symbol-function 'dsh-bridge--refresh-sessions-buffer) (lambda () nil))
              ((symbol-function 'dsh-bridge-set-default-target)
               (lambda (id) (setq bound-target id))))
      (dsh-bridge-create-session))
    (let ((get (cdr (assoc "/workspaces" (mapcar (lambda (c) (list (cadr c) c)) called))))
          (create (cadr (assoc "/sessions/create"
                               (mapcar (lambda (c) (list (cadr c) c)) called)))))
      (should get)
      (should create)
      (should (equal (cdr (assoc 'workspaceId (caddr create))) "w2"))
      (should (equal bound-target "s-new")))))

(ert-deftest dsh-bridge-create-session-empty-workspaces ()
  "A 200 with an empty workspace list still offers \"New workspace…\"."
  (let ((called nil) (table-seen nil) (bound-target nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _rest)
                 (setq table-seen table)
                 "New workspace…"))
              ((symbol-function 'read-directory-name)
               (lambda (&rest _) default-directory))
              ((symbol-function 'read-string)
               (lambda (&rest _) ""))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) called)
                 (if (equal path "/workspaces")
                     (cons 200 (list (cons 'workspaces nil)))
                   (cons 201 (list (cons 'sessionId "s-new"))))))
              ((symbol-function 'dsh-bridge--fetch-sessions) (lambda () nil))
              ((symbol-function 'dsh-bridge--refresh-sessions-buffer) (lambda () nil))
              ((symbol-function 'dsh-bridge-set-default-target)
               (lambda (id) (setq bound-target id))))
      (dsh-bridge-create-session))
    (should (member "New workspace…" table-seen))
    (let ((create (cadr (assoc "/sessions/create"
                               (mapcar (lambda (c) (list (cadr c) c)) called)))))
      (should create)
      (should (equal (cdr (assoc 'path (caddr create))) default-directory)))
    (should (equal bound-target "s-new"))))

(ert-deftest dsh-bridge-create-session-rejects-non-directory ()
  "A \"New workspace…\" path that is not a directory is a user error, no POST."
  (let ((called nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "New workspace…"))
              ((symbol-function 'read-directory-name)
               (lambda (&rest _) "/nonexistent-dsh-bridge-test-dir/"))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) called)
                 (cons 200 (list (cons 'workspaces nil))))))
      (should-error (dsh-bridge-create-session) :type 'user-error))
    (should-not (assoc "/sessions/create"
                       (mapcar (lambda (c) (list (cadr c) c)) called)))))

(ert-deftest dsh-bridge-status-glyph-session-states ()
  "The status glyph reflects the session state: filled circle for running and
idle live sessions, `?' for saved (cold) sessions and for unknown ids."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache
         '(((id . "s-run") (live . t) (running . t))
           ((id . "s-idle") (live . t) (running . nil))
           ((id . "s-cold") (live . nil))))
        (dsh-bridge-status-indicator 'geometric))
    (should (string= (dsh-bridge--status-glyph "s-run") "●"))
    (should (string= (dsh-bridge--status-glyph "s-idle") "●"))
    (should (string= (dsh-bridge--status-glyph "s-cold") "?"))
    (should (string= (dsh-bridge--status-glyph "s-unknown") "?"))))

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
  (let ((dsh-bridge-default-session nil))
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

;;; Plugin management: probe, diagnosis, install/uninstall

(defun dsh-bridge-test--mock-response (status body)
  "Return a mock url-http response buffer with STATUS and BODY."
  (let ((buf (generate-new-buffer " *dsh-bridge-mock*")))
    (with-current-buffer buf
      (insert (format "HTTP/1.1 %s OK\r\n\r\n" status))
      (insert body)
      (set (make-local-variable 'url-http-response-status) status))
    buf))

(ert-deftest dsh-bridge-bridge-status-running ()
  "A 200 naming dsh-emacs-bridge with the package version means running."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response
                  200 (format "{\"name\":\"dsh-emacs-bridge\",\"version\":\"%s\"}"
                              dsh-bridge-version)))))
      (should (eq (dsh-bridge--bridge-status) 'running))
      (should (eq dsh-bridge--bridge-status-cache nil)))))

(ert-deftest dsh-bridge-bridge-status-incompatible ()
  "A version mismatch (or no reported version) means incompatible."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response
                  200 "{\"name\":\"dsh-emacs-bridge\",\"version\":\"0.0.0-test\"}"))))
      (should (eq (dsh-bridge--bridge-status) 'incompatible)))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response
                  200 "{\"name\":\"dsh-emacs-bridge\",\"version\":null}"))))
      (should (eq (dsh-bridge--bridge-status) 'incompatible)))))

(ert-deftest dsh-bridge-bridge-status-wrong-name ()
  "A 200 naming something else is not the bridge plugin."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response
                  200 "{\"name\":\"something-else\",\"version\":\"1.2.3\"}"))))
      (should (eq (dsh-bridge--bridge-status) 'not-running)))))

(ert-deftest dsh-bridge-bridge-status-html-body ()
  "A 200 with an HTML body (a catch-all SPA fallback) is not the plugin."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response 200 "<html><body>app</body></html>"))))
      (should (eq (dsh-bridge--bridge-status) 'not-running)))))

(ert-deftest dsh-bridge-bridge-status-404 ()
  "A 404 means the plugin is not loaded (the static-file fallback)."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response 404 ""))))
      (should (eq (dsh-bridge--bridge-status) 'not-running)))))

(ert-deftest dsh-bridge-bridge-status-forbidden ()
  "A 403 is reported distinctly from not-loaded."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response 403 "{\"error\":\"forbidden\"}"))))
      (should (eq (dsh-bridge--bridge-status) 'forbidden)))))

(ert-deftest dsh-bridge-bridge-status-unreachable ()
  "A transport failure means `dsh web' is unreachable."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _) nil)))
      (should (eq (dsh-bridge--bridge-status) 'unreachable)))))

(ert-deftest dsh-bridge-bridge-status-cached ()
  "`dsh-bridge--ensure-plugin' caches the probe result per session."
  (let ((dsh-bridge--bridge-status-cache nil) (calls 0)
        (dsh-bridge--plugin-diagnosed nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (setq calls (1+ calls))
                 (dsh-bridge-test--mock-response
                  200 (format "{\"name\":\"dsh-emacs-bridge\",\"version\":\"%s\"}"
                              dsh-bridge-version)))))
      (dsh-bridge--ensure-plugin)
      (dsh-bridge--ensure-plugin)
      (should (= calls 1))
      (should (eq dsh-bridge--bridge-status-cache 'running)))
    (dsh-bridge--note-request-failure)
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (setq calls (1+ calls))
                 (dsh-bridge-test--mock-response
                  200 (format "{\"name\":\"dsh-emacs-bridge\",\"version\":\"%s\"}"
                              dsh-bridge-version)))))
      (dsh-bridge--ensure-plugin)
      (should (= calls 2))
      (should (eq dsh-bridge--bridge-status-cache 'running)))
    ;; Do not leak the cached state into later tests.
    (setq dsh-bridge--bridge-status-cache nil)))

(ert-deftest dsh-bridge-note-request-failure ()
  "A 404 drops the cache only when it contradicts the cached state."
  (let ((dsh-bridge--bridge-status-cache 'running))
    (dsh-bridge--note-request-failure)
    (should (null dsh-bridge--bridge-status-cache)))
  (let ((dsh-bridge--bridge-status-cache 'not-running))
    (dsh-bridge--note-request-failure)
    (should (eq dsh-bridge--bridge-status-cache 'not-running)))
  (let ((dsh-bridge--bridge-status-cache 'running))
    (dsh-bridge--note-request-failure)
    (should (null dsh-bridge--bridge-status-cache))))

(ert-deftest dsh-bridge-plugin-install-state-manifest ()
  "The profile manifest decides installed state: dependencies or bundles."
  (let ((dsh-bridge-profile "web")
        (home (make-temp-file "dsh-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-bridge--dsh-home) (lambda () home)))
          (make-directory (expand-file-name "profiles/web" home) t)
          ;; In dependencies.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{\"dependencies\":{\"dsh-emacs-bridge\":\"file:.\"}}"))
          (should (eq (dsh-bridge--plugin-install-state) 'installed))
          ;; In dsh.profile.bundles.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{\"dsh\":{\"profile\":{\"bundles\":[\"dsh-emacs-bridge\"]}}}"))
          (should (eq (dsh-bridge--plugin-install-state) 'installed))
          ;; Neither.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{}"))
          (should (eq (dsh-bridge--plugin-install-state) 'not-installed))
          ;; Invalid JSON.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "not json"))
          (should (eq (dsh-bridge--plugin-install-state) 'not-installed)))
      (delete-directory home t))))

(ert-deftest dsh-bridge-dsh-command-config-overrides ()
  "The defcustom wins over auto-detection."
  (let ((dsh-bridge-dsh-command '("npx" "--yes" "@deepseek-ai/dsh")))
    (should (equal (dsh-bridge--dsh-command)
                   '("npx" "--yes" "@deepseek-ai/dsh")))))

(ert-deftest dsh-bridge-dsh-command-string-split ()
  "A string setting is split shell-style; a list stays verbatim."
  (let ((dsh-bridge-dsh-command "npx --yes @deepseek-ai/dsh"))
    (should (equal (dsh-bridge--dsh-command)
                   '("npx" "--yes" "@deepseek-ai/dsh"))))
  (let ((dsh-bridge-dsh-command "node \"/path with space/bin.js\""))
    (should (equal (dsh-bridge--dsh-command)
                   '("node" "/path with space/bin.js"))))
  (let ((dsh-bridge-dsh-command "/usr/local/bin/dsh"))
    (should (equal (dsh-bridge--dsh-command) '("/usr/local/bin/dsh")))))

(ert-deftest dsh-bridge-dsh-command-auto-detect ()
  "Auto-detection falls back PATH -> npm global bin -> npx."
  ;; dsh on PATH wins.
  (let ((dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "dsh") "dsh"))))
      (should (equal (dsh-bridge--dsh-command) '("dsh")))))
  ;; npm global bin is found when dsh isn't on PATH.
  (let ((dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "npm") "npm")))
              ((symbol-function 'process-lines)
               (lambda (&rest _) '("/fake/prefix")))
              ((symbol-function 'file-executable-p)
               (lambda (file) (string-suffix-p "bin/dsh" file))))
      (should (equal (dsh-bridge--dsh-command) '("/fake/prefix/bin/dsh")))))
  ;; Neither dsh nor a global bin: npx fallback.
  (let ((dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "npx") "npx"))))
      (should (equal (dsh-bridge--dsh-command) '("npx" "--yes" "@deepseek-ai/dsh")))))
  ;; Nothing available.
  (let ((dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
      (should (null (dsh-bridge--dsh-command))))))

(ert-deftest dsh-bridge-ensure-plugin-running-noop ()
  "A running plugin needs no diagnosis and produces no message."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'running))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should (null msg))
    (should (null dsh-bridge--plugin-diagnosed))))

(ert-deftest dsh-bridge-ensure-plugin-incompatible-offers-reinstall ()
  "An incompatible (version-mismatched) plugin offers a reinstall."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil)
        (offered nil) (msg nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'incompatible))
              ;; The reinstall offer fires regardless of the profile state.
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'no-profile))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p)
               (lambda (question)
                 (setq offered question)
                 nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should (string-match-p "Reinstall" offered))
    (should (string-match-p "install aborted" msg))))

(ert-deftest dsh-bridge-ensure-plugin-offers-when-missing ()
  "Not-running + not installed + `ask' offers; declining latches."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (offered nil) (msg nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'not-running))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq offered t) nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should offered)
    (should (string-match-p "install aborted" msg))
    ;; The diagnosis is latched: a second call does not re-prompt.
    (let ((offered 0))
      (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
                 (lambda () 'not-running))
                ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq offered (1+ offered)) nil))
                ((symbol-function 'message) (lambda (&rest _) nil)))
        (dsh-bridge--ensure-plugin))
      (should (= offered 0)))))

(ert-deftest dsh-bridge-ensure-plugin-installs-on-yes ()
  "Accepting the offer starts the asynchronous install."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (installed nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'not-running))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'dsh-bridge--install-plugin-async)
               (lambda (dir) (setq installed dir)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--ensure-plugin))
    (should (equal installed "/tmp/plugin"))))

(ert-deftest dsh-bridge-ensure-plugin-installed-not-loaded ()
  "Not-running + installed says to restart, with no offer."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'not-running))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'installed))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should (string-match-p "restart" msg))))

(ert-deftest dsh-bridge-ensure-plugin-unreachable ()
  "Unreachable + installed reports the server is down, no offer."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'unreachable))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'installed))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should (string-match-p "not running" msg))))

(ert-deftest dsh-bridge-ensure-plugin-unreachable-not-installed ()
  "Unreachable + not installed still offers (installing needs no server)."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (offered nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'unreachable))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq offered t) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--ensure-plugin))
    (should offered)))

(ert-deftest dsh-bridge-ensure-plugin-no-dsh-no-offer ()
  "No profile and no real CLI: point at installing DSH, with no offer.
This is the case the npx fallback must not paper over: downloading the
whole CLI to install a plugin for a DSH the user never set up."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil)
        (offered nil) (msg nil)
        (dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'unreachable))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'no-profile))
              ((symbol-function 'dsh-bridge--dsh-installed-p) (lambda () nil))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq offered t) nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should-not offered)
    (should (string-match-p "no DSH installation found" msg))))

(ert-deftest dsh-bridge-ensure-plugin-no-profile-but-cli-offers ()
  "No profile but a real CLI (DSH exists, profile never created): offer."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil)
        (offered nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'unreachable))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'no-profile))
              ((symbol-function 'dsh-bridge--dsh-installed-p) (lambda () t))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq offered t) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--ensure-plugin))
    (should offered)))

(ert-deftest dsh-bridge-plugin-install-state-tri-state ()
  "The profile probe distinguishes installed / not-installed / no-profile."
  (let ((dsh-bridge-profile "web")
        (home (make-temp-file "dsh-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-bridge--dsh-home) (lambda () home)))
          ;; No profile directory at all.
          (should (eq (dsh-bridge--plugin-install-state) 'no-profile))
          ;; Profile directory without a manifest.
          (make-directory (expand-file-name "profiles/web" home) t)
          (should (eq (dsh-bridge--plugin-install-state) 'not-installed))
          ;; Manifest without the plugin.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{}"))
          (should (eq (dsh-bridge--plugin-install-state) 'not-installed))
          ;; Manifest with the plugin.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{\"dependencies\":{\"dsh-emacs-bridge\":\"file:.\"}}"))
          (should (eq (dsh-bridge--plugin-install-state) 'installed)))
      (delete-directory home t))))

(ert-deftest dsh-bridge-validate-plugin-install ()
  "`--dump-config' success means the profile composes."
  (let ((dsh-bridge-profile "web")
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest args)
                 (if (member "--dump-config" args) 0 1))))
      (should (dsh-bridge--validate-plugin-install)))
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 1)))
      (should-not (dsh-bridge--validate-plugin-install)))))

(ert-deftest dsh-bridge-install-plugin-sync ()
  "The internal install runs pnpm via `dsh plugin add', and needs pnpm."
  (let ((dsh-bridge-profile "web") (argv nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "found"))
              ((symbol-function 'call-process)
               (lambda (&rest args) (setq argv args) 0)))
      (should (dsh-bridge--install-plugin "/tmp/plugin"))
      (should (equal (seq-filter #'stringp argv)
                     '("dsh" "plugin" "--profile" "web" "add" "file:/tmp/plugin"))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "found"))
              ((symbol-function 'call-process) (lambda (&rest _) 1)))
      (should-not (dsh-bridge--install-plugin "/tmp/plugin")))
    ;; Missing pnpm aborts without invoking dsh.
    (let ((called nil))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (prog) (unless (equal prog "pnpm") "found")))
                ((symbol-function 'call-process)
                 (lambda (&rest _) (setq called t) 0)))
        (should-not (dsh-bridge--install-plugin "/tmp/plugin"))
        (should-not called)))))

(ert-deftest dsh-bridge-install-plugin-interactive ()
  "The interactive install validates and says to restart on success."
  (let ((dsh-bridge-profile "web") (msg nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'dsh-bridge--install-plugin) (lambda (_) t))
              ((symbol-function 'dsh-bridge--validate-plugin-install) (lambda () t))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-install-plugin))
    (should (string-match-p "restart" msg))))

(ert-deftest dsh-bridge-install-sentinel-chains-validation ()
  "The async install sentinel chains into async validation."
  (let ((dsh-bridge-profile "web") (validated nil))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'dsh-bridge--validate-plugin-install-async)
               (lambda () (setq validated t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--install-sentinel 'fake-process "finished\n"))
    (should validated)))

(ert-deftest dsh-bridge-install-sentinel-failure ()
  "A failed async install reports the failure and skips validation."
  (let ((validated nil) (msg nil))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'dsh-bridge--validate-plugin-install-async)
               (lambda () (setq validated t)))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--install-sentinel 'fake-process "finished\n"))
    (should-not validated)
    (should (string-match-p "failed" msg))))

(ert-deftest dsh-bridge-validate-sentinel-reports ()
  "The validation sentinel reports composition success and failure."
  (let ((msg nil))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--validate-sentinel 'fake-process "finished\n"))
    (should (string-match-p "restart" msg)))
  (let ((msg nil))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--validate-sentinel 'fake-process "finished\n"))
    (should (string-match-p "does not compose" msg))))

(ert-deftest dsh-bridge-uninstall-skips-when-not-installed ()
  "Uninstall pre-checks the manifest and skips pnpm otherwise."
  (let ((called nil))
    (cl-letf (((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
              ((symbol-function 'call-process)
               (lambda (&rest _) (setq called t) 0))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge-uninstall-plugin))
    (should-not called)))

(ert-deftest dsh-bridge-uninstall-runs-remove ()
  "Uninstall runs `dsh plugin remove dsh-emacs-bridge' when installed."
  (let ((dsh-bridge-profile "web") (argv nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'installed))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'call-process)
               (lambda (&rest args) (setq argv args) 0))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge-uninstall-plugin))
    (let ((strings (seq-filter #'stringp argv)))
      (should (member "remove" strings))
      (should (member "dsh-emacs-bridge" strings)))))

(ert-deftest dsh-bridge-uninstall-remove-failure ()
  "A failing `remove' (exit status 1) signals an error, not false success.
Exit statuses are integers and 1 is truthy, so this guards the `zerop'."
  (let ((dsh-bridge-profile "web")
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'installed))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'call-process) (lambda (&rest _) 1))
              ((symbol-function 'display-buffer) (lambda (&rest _) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (should-error (dsh-bridge-uninstall-plugin) :type 'user-error))))

(ert-deftest dsh-bridge-plugin-directory-source-load ()
  "plugin-directory returns nil-or-a-dir (never signals) off load-path.
Loading by path from a source checkout makes `locate-library' nil; the helper
must fall back to the loaded file and never call `file-name-directory' on nil."
  (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil)))
    (let ((dir (dsh-bridge--plugin-directory)))   ; must not signal
      (should (or (null dir) (stringp dir))))))

;;; Dispatcher and menus

(ert-deftest dsh-bridge-dispatcher-suffixes ()
  "Every verb is a dispatcher suffix; reply/open is `r' (not `p'), the inbox
(`i') and the `S' mnemonic are gone, and targeting lives on `t'/`u'."
  (dolist (spec dsh-bridge--verb-suffixes)
    (should (transient-get-suffix 'dsh-bridge (car spec))))
  (should (transient-get-suffix 'dsh-bridge "r"))
  (should (transient-get-suffix 'dsh-bridge "t"))
  (should (transient-get-suffix 'dsh-bridge "u"))
  ;; `transient-get-suffix' signals when the key is absent.
  (dolist (absent '("p" "i" "S"))
    (should-not (condition-case nil
                    (progn (transient-get-suffix 'dsh-bridge absent) t)
                  (error nil)))))

(ert-deftest dsh-bridge-mode-menus ()
  "Each dsh-bridge mode installs a menu-bar menu."
  (let ((key (vector 'menu-bar (intern "dsh bridge"))))
    (dolist (map (list dsh-bridge-sessions-mode-map
                       dsh-bridge-view-mode-map
                       dsh-bridge-prompt-mode-map))
      (should (lookup-key map key)))))

;;; SSE machinery (unchanged behavior)

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
  "Only outbox-kind events trigger a receive."
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

;;; Turn notifications, session status, and the header line

(ert-deftest dsh-bridge-status-tracker ()
  "status-set/seed drive status-state, with an unknown fallback."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil))
    (should (eq (dsh-bridge--status-state "s1") 'unknown))
    (dsh-bridge--status-set "s1" 'running)
    (should (eq (dsh-bridge--status-state "s1") 'running))
    (dsh-bridge--status-set "s1" 'idle)
    (should (eq (dsh-bridge--status-state "s1") 'idle))
    ;; Seeding an empty list drops all tracked sessions.
    (dsh-bridge--seed-status nil)
    (should (eq (dsh-bridge--status-state "s1") 'unknown))
    ;; Seeding from a /sessions list sets running and drops dead sessions.
    (dsh-bridge--seed-status '(((id . "a") (running . t))
                               ((id . "b") (running . nil))))
    (should (eq (dsh-bridge--status-state "a") 'running))
    (should (eq (dsh-bridge--status-state "b") 'idle))
    (should (eq (dsh-bridge--status-state "c") 'unknown))
    (should (null (assoc "s1" dsh-bridge--session-status)))))

(ert-deftest dsh-bridge-status-unknown-fallback ()
  "With no tracker and no session row, the status is unknown; the row's
`running' flag is a seed when the tracker has no opinion."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil))
    (should (eq (dsh-bridge--status-state "s1") 'unknown)))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (live . t) (running . t)))))
    (should (eq (dsh-bridge--status-state "s1") 'running)))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (live . t) (running . nil)))))
    (should (eq (dsh-bridge--status-state "s1") 'idle))))

(ert-deftest dsh-bridge-status-glyph ()
  "The status glyph reflects the indicator type and the session state."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil)
        (dsh-bridge-status-indicator 'geometric))
    (should (string= (dsh-bridge--status-glyph nil) "?"))
    (dsh-bridge--status-set "s1" 'idle)
    (should (string= (dsh-bridge--status-glyph "s1") "●"))
    (dsh-bridge--status-set "s1" 'running)
    (should (string= (dsh-bridge--status-glyph "s1") "●")))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil)
        (dsh-bridge-status-indicator 'text))
    (dsh-bridge--status-set "s1" 'idle)
    (should (string= (dsh-bridge--status-glyph "s1") "✓")))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil)
        (dsh-bridge-status-indicator 'none))
    (should (string= (dsh-bridge--status-glyph "s1") ""))))

(ert-deftest dsh-bridge-notification-turn-events ()
  "The notification dispatch updates the tracker for start/complete frames."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil))
    (dsh-bridge--notification-handle-events
     '(((kind . "turn-start") (sessionId . "s1"))))
    (should (eq (dsh-bridge--status-state "s1") 'running))
    (dsh-bridge--notification-handle-events
     '(((kind . "turn-complete") (sessionId . "s1") (reason . "completed"))))
    (should (eq (dsh-bridge--status-state "s1") 'idle))))

(ert-deftest dsh-bridge-view-position ()
  "The view position is newest-first (k/n), at rest and while cycling."
  (let ((dsh-bridge--replies-cache '(("s1" "newest" "middle" "oldest"))))
    (with-temp-buffer
      (insert "middle")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-replies-index nil)
      (should (equal (dsh-bridge--view-reply-position) " (2/3)"))
      (setq-local dsh-bridge--view-replies-index 0)
      (should (equal (dsh-bridge--view-reply-position) " (1/3)"))
      (setq-local dsh-bridge--view-replies-index 2)
      (should (equal (dsh-bridge--view-reply-position) " (3/3)"))
      ;; Unknown text at rest omits the indicator.
      (setq-local dsh-bridge--view-replies-index nil)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "opaque"))
      (should (equal (dsh-bridge--view-reply-position) "")))))

(ert-deftest dsh-bridge-view-header-provenance ()
  "The output header separates the session and time with `·', for both fetches
and pushed messages."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge-status-indicator 'geometric))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-timestamp "14:22:05")
      (setq-local dsh-bridge--view-received-at nil)
      (should (string-match-p "· 14:22:05" (dsh-bridge--view-header-line)))
      (should-not (string-match-p "↓" (dsh-bridge--view-header-line)))
      (setq-local dsh-bridge--view-received-at 2000000)
      (should (string-match-p "· " (dsh-bridge--view-header-line)))
      (should-not (string-match-p "↓" (dsh-bridge--view-header-line))))))

(ert-deftest dsh-bridge-prompt-sent-marker ()
  "The prompt header's `✓ sent' marker appears after a send and clears on edit."
  (let ((dsh-bridge--last-sent '(("s1" . ("hello" . 1234567.0)))))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (erase-buffer)
      (insert "hello")
      (should (string-match-p "sent" (dsh-bridge--prompt-sent-marker "s1")))
      (erase-buffer)
      (insert "hello!")
      (should (equal (dsh-bridge--prompt-sent-marker "s1") "")))))

(ert-deftest dsh-bridge-resend-guard ()
  "The resend guard fires only for an identical re-send to the same session."
  (let ((dsh-bridge--last-sent '(("s1" . ("hello" . 1234567.0)))))
    (should (dsh-bridge--resend-guard-p "s1" "hello"))
    (should-not (dsh-bridge--resend-guard-p "s1" "hello!"))
    (should-not (dsh-bridge--resend-guard-p "s2" "hello"))
    (should-not (dsh-bridge--resend-guard-p nil "hello"))))

(ert-deftest dsh-bridge-turn-reason-phrase ()
  "The turn-end reason kind maps to a truthful human verb."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T")))))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "completed")
                   "session \"T\" finished"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "aborted")
                   "session \"T\" interrupted"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "error")
                   "session \"T\" failed"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "max-tokens")
                   "session \"T\" stopped at the token limit"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "blocked")
                   "session \"T\" blocked"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "bogus")
                   "session \"T\" ended"))))

(ert-deftest dsh-bridge-send-exit-buries ()
  "The send-and-exit success branch buries the prompt buffer (no output shown)."
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*"))
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (setq-local dsh-bridge--prompt-session "s1")
    (let ((buried nil))
      (cl-letf (((symbol-function 'bury-buffer) (lambda (&rest _) (setq buried t)))
                ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
        (dsh-bridge--prompt-exit "s1"))
      (should buried))))

;;; Prompt-buffer model selection and context occupancy

(ert-deftest dsh-bridge-prompt-model-label ()
  "The model segment reads the catalog display name, with fallbacks."
  (let ((dsh-bridge--session-models
         '(("s1" (current . ((provider . "p") (model . "m")))
            (groups . (((id . "p") (name . "P")
                        (models . (((id . "m") (name . "Model M")))))))))))
    (should (equal (dsh-bridge--prompt-model-label "s1") "Model M")))
  (let ((dsh-bridge--session-models
         '(("s1" (current . ((provider . "p") (model . "x")))
            (groups . (((id . "p") (name . "P") (models . (((id . "m") (name . "M")))))))))))
    (should (equal (dsh-bridge--prompt-model-label "s1") "x")))
  (let ((dsh-bridge--session-models nil))
    (should (null (dsh-bridge--prompt-model-label "s1")))))

(ert-deftest dsh-bridge-prompt-context-label ()
  "The context segment applies the DSH percent formula, clamps, and rounds."
  (let ((dsh-bridge--session-context '(("s1" . (45000 . 100000)))))
    (should (equal (dsh-bridge--prompt-context-label "s1") "45%")))
  (let ((dsh-bridge--session-context '(("s1" . (150000 . 100000)))))
    (should (equal (dsh-bridge--prompt-context-label "s1") "100%")))
  (let ((dsh-bridge--session-context '(("s1" . (1 . 3)))))
    (should (equal (dsh-bridge--prompt-context-label "s1") "33%")))
  (let ((dsh-bridge--session-context nil))
    (should (null (dsh-bridge--prompt-context-label "s1")))))

(ert-deftest dsh-bridge-prompt-header-model-context ()
  "The header appends model and context segments when cached, and omits them
when the caches are empty."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge--last-sent nil)
        (dsh-bridge--session-models
         '(("s1" (current . ((provider . "p") (model . "m")))
            (groups . (((id . "p") (name . "P")
                        (models . (((id . "m") (name . "Model M"))))))))))
        (dsh-bridge--session-context '(("s1" . (45000 . 100000)))))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (let ((header (dsh-bridge--prompt-header-line)))
        (should (string-match-p "Model M" header))
        (should (string-match-p "45%" header)))))
  (let ((dsh-bridge--session-models nil)
        (dsh-bridge--session-context nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (should-not (string-match-p " · " (dsh-bridge--prompt-header-line))))))

(ert-deftest dsh-bridge-model-catalog ()
  "The catalog flattens provider groups into provider/model triples."
  (let ((data '((groups .
                  (((id . "p1") (name . "P1")
                    (models . (((id . "m1") (name . "M1"))
                               ((id . "m2") (name . "M2")))))
                   ((id . "p2") (name . "P2")
                    (models . (((id . "m3") (name . "M3"))))))))))
    (let ((catalog (dsh-bridge--model-catalog data)))
      (should (equal (mapcar #'car catalog) '("p1/m1" "p1/m2" "p2/m3")))
      (should (equal (cadr (assoc "p1/m2" catalog)) "p1"))
      (should (equal (alist-get 'id (caddr (assoc "p2/m3" catalog))) "m3")))))

(ert-deftest dsh-bridge-fetch-models-cache ()
  "fetch-models caches per session and force-refreshes."
  (let ((dsh-bridge--session-models nil) (calls 0))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path _payload)
                 (setq calls (1+ calls))
                 (should (equal method "GET"))
                 (should (equal path "/models?sessionId=s1"))
                 (cons 200 '((current . ((provider . "p") (model . "m")))
                             (groups . nil))))))
      (dsh-bridge--fetch-models "s1")
      (dsh-bridge--fetch-models "s1")
      (should (= calls 1))
      (dsh-bridge--fetch-models "s1" t)
      (should (= calls 2)))))

(ert-deftest dsh-bridge-fetch-context ()
  "fetch-context seeds the cache once and skips when cached."
  (let ((dsh-bridge--session-context nil) (calls 0))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (setq calls (1+ calls))
                 (cons 200 '((usedTokens . 45) (contextWindow . 100000))))))
      (should (equal (dsh-bridge--fetch-context "s1") (cons 45 100000)))
      (dsh-bridge--fetch-context "s1")
      (should (= calls 1)))))

(ert-deftest dsh-bridge-notification-context ()
  "A context SSE frame folds into the session-context cache."
  (let ((dsh-bridge--session-context nil))
    (dsh-bridge--notification-handle-events
     '(((kind . "context") (sessionId . "s1") (usedTokens . 45) (contextWindow . 100000))))
    (should (equal (assoc "s1" dsh-bridge--session-context) '("s1" 45 . 100000)))))

(provide 'dsh-bridge-tests)
;;; dsh-bridge-tests.el ends here
