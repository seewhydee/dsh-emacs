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

;;; Code:

(require 'url)
(require 'json)

(defgroup dsh-bridge nil
  "Emacs <-> DeepSeek Harness bridge."
  :group 'tools)

(defcustom dsh-bridge-url "http://127.0.0.1:3080/dsh-bridge"
  "Base URL of the `dsh-emacs-bridge' HTTP route."
  :type 'string
  :group 'dsh-bridge)

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
  (dsh-bridge--call "POST" "/send" `((text . ,text))
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
         (t (message "dsh-bridge: sent")))))))

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
  (dsh-bridge--call "GET" "/output" nil
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
          (pop-to-buffer "*dsh-bridge-output*")))))))

(provide 'dsh-bridge)
;;; dsh-bridge.el ends here
