;;; octocat-edit.el --- Edit buffer for octocat PRs and issues  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

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
;;   - Adding a comment to a PR or issue (`c' key in the detail views)
;;   - Editing the body of a PR or issue (RET on the body section)
;;   - Editing an existing comment you authored (RET on a comment section)
;;
;; The workflow mirrors Magit's commit-message buffer:
;;   C-c C-c  — submit (validate, call gh, kill buffer, refresh source)
;;   C-c C-k  — abort  (confirm, kill buffer)
;;
;; Entry point: `octocat--open-edit-buffer'.

;;; Code:

(require 'octocat-core)

;;; Forward declarations

(declare-function octocat-pr-refresh    "octocat-pr"    (&optional _ignore-auto _noconfirm))
(declare-function octocat-issue-refresh "octocat-issue" (&optional _ignore-auto _noconfirm))


;;;; Buffer-local state

(defvar-local octocat-edit--repo nil
  "The \"owner/repo\" string this edit buffer targets.")

(defvar-local octocat-edit--kind nil
  "Symbol: `pr' or `issue' — the kind of item being edited.")

(defvar-local octocat-edit--number nil
  "The integer number of the PR or issue being edited.")

(defvar-local octocat-edit--action nil
  "Symbol `comment', `edit-body', or `edit-comment'.
Determines what gh call `octocat-edit-submit' makes.")

(defvar-local octocat-edit--comment-id nil
  "Numeric REST comment ID string, set when action is `edit-comment'.")

(defvar-local octocat-edit--source-buffer nil
  "The PR/issue buffer that opened this edit buffer.
Used to refresh the source after a successful submit.")

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

(defun octocat-edit--buffer-name (repo kind number action)
  "Return the name for an edit buffer targeting REPO KIND NUMBER ACTION."
  (format "*octocat-edit: %s/%s #%d (%s)*"
          repo
          (if (eq kind 'pr) "pr" "issue")
          number
          (pcase action
            ('comment      "comment")
            ('edit-body    "body")
            ('edit-comment "edit-comment")
            (_             (symbol-name action)))))

(defun octocat-edit--header-line (kind number action)
  "Return a header-line string for KIND NUMBER ACTION."
  (let ((target (format "%s #%d"
                        (if (eq kind 'pr) "PR" "issue")
                        number))
        (verb (pcase action
                ('comment      "New comment on")
                ('edit-body    "Edit body of")
                ('edit-comment "Edit comment on")
                (_             (format "%s" action)))))
    (format "  %s %s    %s  submit   %s  discard"
            verb target
            (propertize "C-c C-c" 'face 'help-key-binding)
            (propertize "C-c C-k" 'face 'help-key-binding))))

(defun octocat-edit--gh-args (repo kind number action body comment-id)
  "Return a `gh' argument list to perform ACTION on KIND NUMBER in REPO.
BODY is the text to submit.  COMMENT-ID is the numeric REST comment ID
string, required when ACTION is `edit-comment'.  Returns a list of strings."
  (let ((num (number-to-string number)))
    (pcase action
      ('comment
       (list (if (eq kind 'pr) "pr" "issue")
             "comment" num
             "--repo" repo
             "--body" body))
      ('edit-body
       (list (if (eq kind 'pr) "pr" "issue")
             "edit" num
             "--repo" repo
             "--body" body))
      ('edit-comment
       (unless comment-id
         (error "Octocat-edit: edit-comment action requires a comment-id"))
       (list "api"
             (format "repos/%s/issues/comments/%s" repo comment-id)
             "--method" "PATCH"
             "-f" (format "body=%s" body)))
      (_ (error "Octocat-edit: unknown action %s" action)))))

(defun octocat-edit--refresh-source (buf)
  "Refresh the source PR/issue buffer BUF, if it is still live."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (cond
       ((derived-mode-p 'octocat-pr-mode)    (octocat-pr-refresh))
       ((derived-mode-p 'octocat-issue-mode) (octocat-issue-refresh))))))


;;;; Commands

(defun octocat-edit-submit ()
  "Submit the edit buffer: validate, call gh, kill buffer, refresh source."
  (interactive)
  (let ((body (string-trim (buffer-string))))
    (when (string-empty-p body)
      (user-error "Octocat: body is empty — nothing to submit"))
    (let* ((repo   octocat-edit--repo)
           (kind   octocat-edit--kind)
           (number octocat-edit--number)
           (action octocat-edit--action)
           (comment-id octocat-edit--comment-id)
           (source     octocat-edit--source-buffer)
           (edit-win   octocat-edit--window)
           (args       (octocat-edit--gh-args repo kind number action body comment-id))
           (edit-buf   (current-buffer)))
      (setq mode-line-process " [submitting…]")
      (octocat--run-gh
       (format "edit-%s" (symbol-name action))
       args
       ;; parse-fn: gh outputs a URL or nothing useful; we just ignore it.
       (lambda (output) (string-trim output))
       (lambda (result)
         (if (eq (car-safe result) 'error)
             ;; Report the error without closing the buffer so the user
             ;; can see their text and retry.
             (when (buffer-live-p edit-buf)
               (with-current-buffer edit-buf
                 (setq mode-line-process nil)
                 (message "Octocat submit error: %s" (cdr result))))
           ;; Success: close the edit window (kills buffer, restores split).
           (when (buffer-live-p edit-buf)
             (with-current-buffer edit-buf
               (set-buffer-modified-p nil)))
           (if (window-live-p edit-win)
               (quit-window t edit-win)
             (when (buffer-live-p edit-buf)
               (kill-buffer edit-buf)))
           (octocat-edit--refresh-source source)))))))

(defun octocat-edit-abort ()
  "Discard the edit buffer and return to the source buffer."
  (interactive)
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "Discard edit? "))
    (let ((win octocat-edit--window))
      (set-buffer-modified-p nil)
      (quit-window t win))))


;;;; Public entry point

(defun octocat--open-edit-buffer (repo kind number action
                                       &optional initial-content comment-id)
  "Open (or reuse) an edit buffer for REPO KIND NUMBER ACTION.

REPO           — \"owner/repo\" string.
KIND           — symbol `pr' or `issue'.
NUMBER         — integer PR or issue number.
ACTION         — symbol `comment' (add comment), `edit-body' (replace body),
                 or `edit-comment' (edit an existing comment).
INITIAL-CONTENT — string pre-populated into the buffer; nil for blank.
COMMENT-ID     — numeric REST comment ID string; required for `edit-comment'.

The buffer is shown in a bottom window.  When the user finishes with
\\[octocat-edit-submit], the source buffer is automatically refreshed.
Use \\[octocat-edit-abort] to discard."
  (let* ((name   (octocat-edit--buffer-name repo kind number action))
         (source (current-buffer))
         (buf    (get-buffer-create name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'octocat-edit-mode)
        (octocat-edit-mode))
      ;; Restore state even if buffer already existed (e.g. re-opened after
      ;; a failed submit).
      (setq octocat-edit--repo            repo
            octocat-edit--kind            kind
            octocat-edit--number          number
            octocat-edit--action          action
            octocat-edit--comment-id      comment-id
            octocat-edit--source-buffer   source)
      (setq-local header-line-format
                  (octocat-edit--header-line kind number action))
      ;; Only pre-populate when the buffer is fresh (not dirty from a
      ;; previous failed attempt the user wants to keep).
      (when (and initial-content
                 (not (buffer-modified-p))
                 (string-empty-p (string-trim (buffer-string))))
        (erase-buffer)
        (insert initial-content)
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
