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

(ert-deftest dsh-bridge-set-default-target-offers-live-sessions-only ()
  "Completion offers live sessions (plus the last-active choice) only."
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
                   '("a" "(last-active)")))))

(ert-deftest dsh-bridge-target-label ()
  (let ((dsh-bridge-default-session nil)
        (dsh-bridge--sessions-cache nil))
    (should (equal (dsh-bridge--target-label) "last-active")))
  (let ((dsh-bridge-default-session "s1")
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T")))))
    (should (equal (dsh-bridge--target-label) "T"))))

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
    ;; Nothing bound: resolved last-active with (last-active) qualifier.
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active nil))
        (should (equal (dsh-bridge--effective-session-label)
                       "T (last-active)"))))))

(ert-deftest dsh-bridge-resolved-active-label ()
  "The advisory last-active label uses the last verb response, then the cache."
  (let ((dsh-bridge--last-resolved-active '("s2" . "Second"))
        (dsh-bridge--sessions-cache nil))
    (should (equal (dsh-bridge--resolved-active-label) "Second")))
  (let ((dsh-bridge--last-resolved-active nil)
        (dsh-bridge--sessions-cache
         '(((id . "s1") (title . "T") (live . t))
           ((id . "s2") (title . "Older") (live . t) (lastActive . 1)))))
    ;; s1 has no activity timestamps -> 0; s2's lastActive wins.
    (should (equal (dsh-bridge--resolved-active-label) "Older"))))

(ert-deftest dsh-bridge-session-not-live-message ()
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T")))))
    (should (string-match-p "session T is not live"
                            (dsh-bridge--session-not-live-message "s1")))))

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
  "The label is the title, else the cwd basename, else the raw id."
  (should (equal (dsh-bridge--session-label '((title . "T") (cwd . "/x") (id . "i")))
                 "T"))
  (should (equal (dsh-bridge--session-label '((cwd . "/x/y") (id . "i"))) "y"))
  (should (equal (dsh-bridge--session-label '((cwd . "/x/") (id . "i"))) "x"))
  (should (equal (dsh-bridge--session-label '((id . "i"))) "i"))
  (should (equal (dsh-bridge--session-label '((title . "") (cwd . "/x") (id . "i")))
                 "x")))

(ert-deftest dsh-bridge-session-label-disambiguates-on-collision ()
  "A basename label shared with another row gains a short-id qualifier; a
unique label stays plain; a title is never disambiguated."
  (let ((a '((id . "ab1234") (cwd . "/w/x")))
        (b '((id . "cd5678") (cwd . "/w/x"))))
    (should (equal (dsh-bridge--session-label a nil) "x"))
    (should (equal (dsh-bridge--session-label a (list a b)) "x · ab1234"))
    (should (equal (dsh-bridge--session-label b (list a b)) "x · cd5678"))
    (should (equal (dsh-bridge--session-label '((id . "ef9012") (title . "T"))
                                              (list a b))
                   "T"))))

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
not the default target."
  (let ((dsh-bridge-default-session "s1"))
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
      (should-not (string-match-p "target:" (format "%s" header-line-format))))))

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
                          200))))
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
    (should (string-match-p "session" (format "%s" header-line-format))))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-c"))
              #'dsh-bridge-send))
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
      (setq header-line-format (dsh-bridge--prompt-header-line))
      (should (string-match-p "session: T$" (format "%s" header-line-format))))
    (with-temp-buffer
      (let ((dsh-bridge-default-session "s1"))
        (dsh-bridge-prompt-mode)
        (should (string-match-p "session: T (default)"
                                (format "%s" header-line-format)))))
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active nil))
        (dsh-bridge-prompt-mode)
        (should (string-match-p "(last-active)"
                                (format "%s" header-line-format)))))))

(ert-deftest dsh-bridge-set-buffer-session-binds ()
  "`C-c C-s' rebinds the prompt buffer's session."
  (let ((dsh-bridge-default-session "default"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (cl-letf (((symbol-function 'dsh-bridge--read-live-session-id)
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
  "Reply to a dead shown session gives the not-live message, no binding."
  (let ((dsh-bridge--sessions-cache '(((id . "gone") (live . nil))))
        (bound nil) (msg nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "gone")
      (cl-letf (((symbol-function 'dsh-bridge--set-prompt-session)
                 (lambda (id) (setq bound id)))
                ((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args)))))
        (dsh-bridge-reply))
      (should (null bound))
      (should (string-match-p "not live" msg)))))

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
      (should (string-match-p "received from: s2"
                              (format "%s" header-line-format)))
      (should (string-match-p " · sent "
                              (format "%s" header-line-format))))))

(ert-deftest dsh-bridge-receive-multiple-messages-message ()
  "Several pending entries produce the honest 'showing the latest' message."
  (let ((msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-receive))
    (should (string-match-p "2 messages received, showing the latest" msg))))

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
        (should (string-match-p " · 2/3" (format "%s" header-line-format)))
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
                          "{\"text\":\"fresh\",\"sessionId\":\"s1\"}" 200))))
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
  "RET/r open, t sets the default target, u clears it, f peeks, and p is
previous-line again."
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
              #'dsh-bridge-toggle-sessions-display))
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
    (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () "live-1"))
              ((symbol-function 'dsh-bridge--set-prompt-session)
               (lambda (id) (setq bound id)))
              ((symbol-function 'dsh-bridge--prompt-buffer)
               (lambda () (get-buffer-create "*dsh-bridge-prompt*")))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (dsh-bridge-open-session))
    (should (equal bound "live-1"))
    (should (equal dsh-bridge-default-session "default"))
    (should popped)))

(ert-deftest dsh-bridge-open-session-not-live-message ()
  "RET on a saved row reports the consistent not-live message."
  (let ((dsh-bridge--sessions-cache '(((id . "saved-1") (live . nil))))
        (bound nil) (msg nil))
    (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () "saved-1"))
              ((symbol-function 'dsh-bridge--set-prompt-session)
               (lambda (id) (setq bound id)))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-open-session))
    (should (null bound))
    (should (string-match-p "not live" msg))))

(ert-deftest dsh-bridge-set-default-target-at-point ()
  "`t' sets the default target to the row's session."
  (let ((dsh-bridge--sessions-cache '(((id . "live-1") (live . t))))
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () "live-1"))
              ((symbol-function 'dsh-bridge-set-default-target)
               (lambda (id) (setq dsh-bridge-default-session id))))
      (dsh-bridge-set-default-target-at-point))
    (should (equal dsh-bridge-default-session "live-1"))))

(ert-deftest dsh-bridge-list-sessions-columns-and-marker ()
  "The session list shows marker/R/Session/Age/Workspace columns."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session "live-1"))
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
        ;; Default-target marker (index 0): "*" + face for the default target.
        (should (equal (aref live-cells 0) "*"))
        (should (eq (get-text-property 0 'face (aref live-cells 0))
                    'dsh-bridge-default-target-face))
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

(ert-deftest dsh-bridge-session-cell-disambiguates-untitled ()
  "Untitled cells that collide gain a short-id qualifier; unique ones stay
plain."
  (let ((a '((id . "aaaaaa") (live . t) (cwd . "/x")))
        (b '((id . "bbbbbb") (live . t) (cwd . "/x"))))
    (should (string-match-p "Untitled session$"
                            (dsh-bridge--session-cell a nil)))
    (should (string-match-p "Untitled session · aaaaaa"
                            (dsh-bridge--session-cell a (list a b))))
    (should (string-match-p "Untitled session · bbbbbb"
                            (dsh-bridge--session-cell b (list a b))))))

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

(ert-deftest dsh-bridge-sessions-display-modes ()
  "Display modes cycle live+saved, live, and live+saved+archived."
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
        ;; Default (live+saved): live + saved shown, archived excluded.
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should (assoc "live-1" entries))
          (should (assoc "saved-1" entries))
          (should-not (assoc "arch-1" entries)))
        ;; Cycle -> live: only live.
        (with-current-buffer buf (dsh-bridge-toggle-sessions-display))
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should (assoc "live-1" entries))
          (should-not (assoc "saved-1" entries))
          (should-not (assoc "arch-1" entries)))
        ;; Cycle -> all: everything, including archived.
        (with-current-buffer buf (dsh-bridge-toggle-sessions-display))
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should (assoc "live-1" entries))
          (should (assoc "saved-1" entries))
          (should (assoc "arch-1" entries)))
        ;; Cycle again -> back to live+saved.
        (with-current-buffer buf (dsh-bridge-toggle-sessions-display))
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should (assoc "live-1" entries))
          (should (assoc "saved-1" entries))
          (should-not (assoc "arch-1" entries)))))))

(ert-deftest dsh-bridge-session-visible-p ()
  "Visibility depends on the display mode, live state, and archived flag."
  (let ((dsh-bridge--sessions-display 'live-saved))
    (should (dsh-bridge--session-visible-p '((live . t) (cwd . "/a"))))
    (should (dsh-bridge--session-visible-p '((live . nil) (cwd . "/b"))))
    (should-not (dsh-bridge--session-visible-p '((live . nil) (archived . t)))))
  (let ((dsh-bridge--sessions-display 'live))
    (should (dsh-bridge--session-visible-p '((live . t) (cwd . "/a"))))
    (should-not (dsh-bridge--session-visible-p '((live . nil) (cwd . "/b"))))
    (should-not (dsh-bridge--session-visible-p '((live . t) (archived . t)))))
  (let ((dsh-bridge--sessions-display 'all))
    (should (dsh-bridge--session-visible-p '((live . nil) (archived . t))))
    (should (dsh-bridge--session-visible-p '((live . t) (cwd . "/a"))))))

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

(provide 'dsh-bridge-tests)
;;; dsh-bridge-tests.el ends here
