;;; octocat-edit.el --- Edit buffer for octocat PRs and issues  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Provides a Magit-style dedicated edit buffer used whenever the user needs
;; to write multi-line markdown text:
;;
;;   - Adding a comment to a PR or issue (`C-c C-a' in the detail views)
;;   - Editing the body of a PR or issue (`C-c C-e' or RET on the body section)
;;   - Editing an existing comment you authored (`C-c C-e' or RET on a comment section)
;;
;; The workflow mirrors Magit's commit-message buffer:
;;   C-c C-c  — submit (validate, call submit-fn, kill buffer, call refresh-fn)
;;   C-c C-k  — abort  (confirm, kill buffer)
;;
;; This file is intentionally free of PR/issue domain knowledge.  All
;; submit logic is provided by the caller via two function arguments:
;;
;;   SUBMIT-FN  (body source-buffer on-success on-error)
;;     Called with the trimmed buffer text.  Must arrange its own async
;;     operation and invoke ON-SUCCESS () or ON-ERROR (msg) when done.
;;
;;   REFRESH-FN (source-buffer)
;;     Called with the source buffer after a successful submit.
;;
;; Entry point: `octocat--open-edit-buffer'.

;;; Code:

(require 'octocat-core)


;;;; Buffer-local state

(defvar-local octocat-edit--title nil
  "Short human-readable title shown in the buffer name and header line.")

(defvar-local octocat-edit--submit-fn nil
  "Function (BODY SOURCE-BUFFER ON-SUCCESS ON-ERROR) called on submit.
BODY is the trimmed buffer text.  The function must perform its async
operation and call ON-SUCCESS () on success or ON-ERROR (MSG) on failure.")

(defvar-local octocat-edit--refresh-fn nil
  "Function called with SOURCE-BUFFER after a successful submit.")

(defvar-local octocat-edit--source-buffer nil
  "The PR/issue buffer that opened this edit buffer.")

(defvar-local octocat-edit--user-data nil
  "Caller-supplied plist for arbitrary extra state.
Set via the USER-DATA argument to `octocat--open-edit-buffer'.
Submit functions can read this with `octocat-edit--user-data' on
`current-buffer', since they are called from inside the edit buffer.")

(defvar-local octocat-edit--window nil
  "The window displaying this edit buffer.
Used by `quit-window' to close the split cleanly on submit or abort.")


;;;; Keymap

(defvar octocat-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'octocat-edit-submit)
    (define-key map (kbd "C-c C-k") #'octocat-edit-abort)
    map)
  "Keymap for `octocat-edit-mode'.
\\[octocat-edit-submit] submits, \\[octocat-edit-abort] discards.")


;;;; Major mode

(define-derived-mode octocat-edit-mode gfm-mode "Octocat-Edit"
  "Major mode for composing GitHub PR/issue bodies and comments.

Type your markdown text, then:
  \\[octocat-edit-submit]  — submit (post / save)
  \\[octocat-edit-abort]   — discard and return

\\{octocat-edit-mode-map}"
  :group 'octocat
  ;; Re-bind C-c C-c / C-c C-k after gfm-mode has set up its own keymap, so
  ;; our bindings take precedence.  We use `keymap-set' to target the mode's
  ;; *local* keymap specifically (not an auxiliary or parent map).
  (use-local-map octocat-edit-mode-map))


;;;; Internal helpers

(defun octocat-edit--buffer-name (title)
  "Return the name for an edit buffer with TITLE."
  (format "*octocat-edit: %s*" title))

(defun octocat-edit--header-line (title)
  "Return a header-line string for TITLE."
  (format "  %s    %s  submit   %s  discard"
          title
          (propertize "C-c C-c" 'face 'help-key-binding)
          (propertize "C-c C-k" 'face 'help-key-binding)))




;;;; Commands

(defun octocat-edit-submit ()
  "Submit the edit buffer: validate, call submit-fn, kill buffer, refresh source."
  (interactive)
  (let ((body (string-trim (buffer-string))))
    (when (string-empty-p body)
      (user-error "Octocat: body is empty — nothing to submit"))
    (let ((submit-fn  octocat-edit--submit-fn)
          (refresh-fn octocat-edit--refresh-fn)
          (source     octocat-edit--source-buffer)
          (edit-win   octocat-edit--window)
          (edit-buf   (current-buffer)))
      (setq mode-line-process " [submitting…]")
      (funcall submit-fn body source
               ;; on-success: close edit window then refresh source
               (lambda ()
                 (when (buffer-live-p edit-buf)
                   (with-current-buffer edit-buf
                     (set-buffer-modified-p nil)))
                 (if (window-live-p edit-win)
                     (quit-window t edit-win)
                   (when (buffer-live-p edit-buf)
                     (kill-buffer edit-buf)))
                 (when (buffer-live-p source)
                   (funcall refresh-fn source)))
               ;; on-error: report but leave buffer open so user can retry
               (lambda (msg)
                 (when (buffer-live-p edit-buf)
                   (with-current-buffer edit-buf
                     (setq mode-line-process nil)
                     (message "Octocat submit error: %s" msg))))))))

(defun octocat-edit-abort ()
  "Discard the edit buffer and return to the source buffer."
  (interactive)
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "Discard edit? "))
    (let ((win octocat-edit--window))
      (set-buffer-modified-p nil)
      (quit-window t win))))


;;;; Public entry point

(defun octocat--open-edit-buffer (title submit-fn refresh-fn
                                        &optional initial-content user-data)
  "Open (or reuse) an edit buffer with TITLE, wired to SUBMIT-FN and REFRESH-FN.

TITLE       — short human-readable string used in the buffer name and header.
SUBMIT-FN   — function (BODY SOURCE-BUFFER ON-SUCCESS ON-ERROR) called on
              \\[octocat-edit-submit].  Must perform its async operation and
              invoke ON-SUCCESS () on success or ON-ERROR (MSG) on failure.
              It is called from inside the edit buffer, so submit functions
              can read `octocat-edit--user-data' from `current-buffer'.
REFRESH-FN  — function (SOURCE-BUFFER) called after a successful submit.
INITIAL-CONTENT — string pre-populated into the buffer; nil for blank.
USER-DATA   — optional plist stored as `octocat-edit--user-data', available
              to SUBMIT-FN via `(octocat-edit--user-data)' on current buffer.

The buffer is shown in a bottom window.  The source buffer is the one
that was current when this function was called.
Use \\[octocat-edit-abort] to discard."
  (let* ((name   (octocat-edit--buffer-name title))
         (source (current-buffer))
         (buf    (get-buffer-create name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'octocat-edit-mode)
        (octocat-edit-mode))
      ;; Restore state even if buffer already existed (e.g. re-opened after
      ;; a failed submit).
      (setq octocat-edit--title          title
            octocat-edit--submit-fn      submit-fn
            octocat-edit--refresh-fn     refresh-fn
            octocat-edit--source-buffer  source
            octocat-edit--user-data      user-data)
      (setq-local header-line-format
                  (octocat-edit--header-line title))
      ;; Only pre-populate when the buffer is fresh (not dirty from a
      ;; previous failed attempt the user wants to keep).
      (when (and initial-content
                 (not (buffer-modified-p))
                 (string-empty-p (string-trim (buffer-string))))
        (erase-buffer)
        (insert (string-replace "\r\n" "\n" initial-content))
        (goto-char (point-max)))
      (set-buffer-modified-p nil))
    ;; display-buffer returns the window and automatically stamps it with a
    ;; quit-restore parameter so quit-window knows how to clean it up.
    (let ((win (display-buffer buf
                               '(display-buffer-below-selected
                                 . ((window-height . 0.35))))))
      (with-current-buffer buf
        (setq octocat-edit--window win))
      (select-window win))))

(provide 'octocat-edit)
;;; octocat-edit.el ends here
