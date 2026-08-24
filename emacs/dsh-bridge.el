;;; dsh-bridge.el --- Emacs <-> DeepSeek Harness bridge -*- lexical-binding: t; -*-

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

;; Author: Chong Yidong <cyd@stupidchicken.com>
;; Version: 0.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience

;;; Commentary:

;; Two-way bridge between Emacs and a running DeepSeek Harness session.  Talks
;; to the `dsh-emacs-bridge' DSH plugin over loopback HTTP.
;;
;; MVP (see PLAN.md in the project root):
;;   - dsh-bridge-send-region / dsh-bridge-send-buffer  -> POST /dsh-bridge/send
;;   - dsh-bridge-get-output                            -> GET  /dsh-bridge/output
;;   - dsh-bridge-list-sessions / dsh-bridge-select-session / dsh-bridge-current-session
;;     -> session inventory and targeting (GET /sessions, POST /select, GET /current)

;;; Code:

(require 'url)
(require 'url-util)
(require 'json)

(defgroup dsh-bridge nil
  "Emacs <-> DeepSeek Harness bridge."
  :group 'tools)

(defcustom dsh-bridge-url "http://127.0.0.1:3080/dsh-bridge"
  "Base URL of the `dsh-emacs-bridge' HTTP route."
  :type 'string
  :group 'dsh-bridge)

(defvar dsh-bridge-target-session nil
  "DSH session id the bridge targets, or nil for the last-active session.
Set with `dsh-bridge-select-session'.")

(defun dsh-bridge--response-body (buffer)
  "Return the HTTP response body (text after the headers) of BUFFER.
The url-http response buffer is unibyte, so decode the body as UTF-8."
  (with-current-buffer buffer
    (goto-char (point-min))
    (if (re-search-forward "\r?\n\r?\n" nil t)
        (decode-coding-string
         (buffer-substring-no-properties (point) (point-max)) 'utf-8)
      "")))

(defun dsh-bridge--call (method path payload callback)
  "Perform METHOD request to PATH under `dsh-bridge-url'.
PAYLOAD is an alist encoded as JSON (for POST) or nil (for GET).
CALLBACK is invoked with (status body-string)."
  (let ((url-request-method method)
        (url-request-data
         (and payload (encode-coding-string (json-encode payload) 'utf-8)))
        (url-request-extra-headers
         (and payload '(("Content-Type" . "application/json")))))
    (url-retrieve (concat dsh-bridge-url path)
                  (lambda (status)
                    (let ((body (dsh-bridge--response-body (current-buffer))))
                      (kill-buffer (current-buffer))
                      (funcall callback status body)))
                  nil t)))

(defun dsh-bridge-send-text (text)
  "Send TEXT to the DSH session as a prompt."
  (let ((payload `((text . ,text)
                   ,@(when dsh-bridge-target-session
                       (list (cons 'sessionId dsh-bridge-target-session))))))
    (dsh-bridge--call "POST" "/send" payload
      (lambda (status body)
        (let ((transport-error (plist-get status :error))
              (alist (condition-case nil
                         (json-parse-string body :object-type 'alist)
                       (error nil))))
          (cond
           (transport-error
            (message "dsh-bridge: request failed: %s" transport-error))
           ((assoc 'error alist)
            (message "dsh-bridge: %s" (cdr (assoc 'error alist))))
           ((null alist)
            (message "dsh-bridge: unreadable response: %s" body))
           (t (message "dsh-bridge: sent"))))))))

;;;###autoload
(defun dsh-bridge-send-region (beg end)
  "Send the region to DSH as a prompt."
  (interactive "r")
  (dsh-bridge-send-text (buffer-substring-no-properties beg end)))

;;;###autoload
(defun dsh-bridge-send-buffer ()
  "Send the whole buffer to DSH as a prompt."
  (interactive)
  (dsh-bridge-send-text (buffer-substring-no-properties (point-min) (point-max))))

;;;###autoload
(defun dsh-bridge-get-output ()
  "Fetch the latest DSH assistant reply into *dsh-bridge-output*."
  (interactive)
  (let ((path (if dsh-bridge-target-session
                  (format "/output?sessionId=%s"
                          (url-hexify-string dsh-bridge-target-session))
                "/output")))
    (dsh-bridge--call "GET" path nil
      (lambda (status body)
        (let ((transport-error (plist-get status :error))
              (alist (condition-case nil
                         (json-parse-string body :object-type 'alist)
                       (error nil))))
          (cond
           (transport-error
            (message "dsh-bridge: request failed: %s" transport-error))
           ((assoc 'error alist)
            (message "dsh-bridge: %s" (cdr (assoc 'error alist))))
           (t
            (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
              (erase-buffer)
              (insert (or (cdr (assoc 'text alist)) ""))
              (goto-char (point-min)))
            (pop-to-buffer "*dsh-bridge-output*"))))))))

(defun dsh-bridge--request (method path payload)
  "Perform METHOD request to PATH and return (STATUS . ALIST).
STATUS is the HTTP status code, or nil on transport failure.  ALIST is the
decoded JSON object (JSON null/false become nil, arrays become lists), or nil
when the body is not a JSON object."
  (let ((url-request-method method)
        (url-request-data
         (and payload (encode-coding-string (json-encode payload) 'utf-8)))
        (url-request-extra-headers
         (and payload '(("Content-Type" . "application/json")))))
    (let ((buf (url-retrieve-synchronously (concat dsh-bridge-url path) t)))
      (if (null buf)
          (cons nil nil)
        (with-current-buffer buf
          (let* ((status (and (boundp 'url-http-response-status)
                              url-http-response-status))
                 (body (dsh-bridge--response-body buf))
                 (alist (condition-case nil
                            (json-parse-string body :object-type 'alist
                                               :array-type 'list
                                               :null-object nil
                                               :false-object nil)
                          (error nil))))
            (kill-buffer buf)
            (cons status alist)))))))

(defun dsh-bridge--fetch-sessions ()
  "Return the DSH session list as a list of alists, or nil on error."
  (let* ((result (dsh-bridge--request "GET" "/sessions" nil))
         (alist (cdr result)))
    (and alist (assoc 'sessions alist) (cdr (assoc 'sessions alist)))))

(define-derived-mode dsh-bridge-sessions-mode tabulated-list-mode "DSH-Sessions"
  "Major mode for browsing DSH sessions.")

(define-key dsh-bridge-sessions-mode-map (kbd "RET")
            #'dsh-bridge-select-session-at-point)

(defun dsh-bridge-select-session-at-point ()
  "Select the DSH session shown on the current line of the session list."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (when id
      (dsh-bridge-select-session id))))

(defun dsh-bridge-list-sessions ()
  "List DSH sessions in a buffer.
In the session list, RET selects the session under point."
  (interactive)
  (let ((sessions (dsh-bridge--fetch-sessions)))
    (if (null sessions)
        (message "dsh-bridge: no sessions (or request failed)")
      (with-current-buffer (get-buffer-create "*dsh-bridge-sessions*")
        (dsh-bridge-sessions-mode)
        (setq tabulated-list-format [("Session" 40 t)
                                     ("State" 8 t)
                                     ("Cwd" 40 t)])
        (setq tabulated-list-sort-key '("State" . nil))
        (setq tabulated-list-entries
              (mapcar (lambda (s)
                        (list (alist-get 'id s)
                              (vector (alist-get 'id s)
                                      (if (alist-get 'live s) "live" "saved")
                                      (or (alist-get 'cwd s) ""))))
                      sessions))
        (tabulated-list-init-header)
        (tabulated-list-print)
        (pop-to-buffer (current-buffer))))))

(defun dsh-bridge-select-session (session-id)
  "Set the DSH session the bridge targets to SESSION-ID.
SESSION-ID is a session id string, or nil to target the last-active session."
  (interactive
   (list
    (let* ((sessions (dsh-bridge--fetch-sessions))
           (choices (append (and sessions
                                 (mapcar (lambda (s) (alist-get 'id s)) sessions))
                            '("(last-active)")))
           (choice (completing-read "Target session: " choices nil t)))
      (if (string= choice "(last-active)") nil choice))))
  (let* ((result (dsh-bridge--request "POST" "/select"
                  (if session-id
                      `((sessionId . ,session-id))
                    '((sessionId . :json-null)))))
         (status (car result))
         (alist (cdr result)))
    (cond
     ((and status (>= status 400))
      (message "dsh-bridge: %s"
               (or (alist-get 'error alist) (format "HTTP %s" status))))
     ((and alist (assoc 'error alist))
      (message "dsh-bridge: %s" (alist-get 'error alist)))
     (t
      (setq dsh-bridge-target-session session-id)
      (message "dsh-bridge: targeting %s"
               (or session-id "last-active session"))))))

(defun dsh-bridge-current-session ()
  "Message the DSH session the bridge currently targets."
  (interactive)
  (let* ((result (dsh-bridge--request "GET" "/current" nil))
         (status (car result))
         (alist (cdr result))
         (session-id (and alist (alist-get 'sessionId alist))))
    (cond
     ((and status (>= status 400))
      (message "dsh-bridge: %s"
               (or (and alist (alist-get 'error alist))
                   (format "HTTP %s" status))))
     (session-id
      (setq dsh-bridge-target-session session-id)
      (message "dsh-bridge: targeting session %s" session-id))
     (t
      (setq dsh-bridge-target-session nil)
      (message "dsh-bridge: targeting the last-active session")))))

(provide 'dsh-bridge)
;;; dsh-bridge.el ends here
