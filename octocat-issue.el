;;; octocat-issue.el --- Issue detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Issue data fetching, detail rendering, and the octocat-issue-mode major mode.
;; Depends on octocat-core.el for shared infrastructure; must not depend on
;; octocat.el to avoid a circular require.

;;; Code:

(require 'octocat-core)

;; These commands are defined in octocat.el which loads this file, so we
;; cannot require it here.  Declare them to silence the byte-compiler.
(declare-function octocat-browse "octocat" ())


;;;; Buffer-local declarations

(defvar-local octocat--issue-repo nil
  "The \"owner/repo\" this issue buffer belongs to.")

(defvar-local octocat--issue-number nil
  "The issue number this buffer is displaying.")


;;;; Data fetching

(defun octocat--fetch-issue (repo number callback)
  "Fetch detail for issue NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of issue data, or a cons \\=(error . MSG)."
  (octocat--run-gh "issue"
                   (list "issue" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "number,title,author,state,body,"
                                          "createdAt,closedAt,"
                                          "labels,comments,url"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))


;;;; Rendering helpers

(defun octocat--issue-state-face (state)
  "Return the face for issue STATE string."
  (if (equal state "OPEN") 'octocat-pr-state-open 'octocat-pr-state-closed))


;;;; Rendering

(defun octocat--render-issue-loading (number title state)
  "Render a loading skeleton for issue NUMBER with TITLE and STATE."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-issue-root)
      (magit-insert-heading
        (concat (propertize (or octocat--issue-repo "") 'face 'octocat-repo)
                "  "
                (propertize "issue" 'face 'octocat-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                title
                "  "
                (propertize (downcase state) 'face (octocat--issue-state-face state))))
      (magit-insert-section (issue-meta)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (issue-body)
        (magit-insert-heading (propertize "Body" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (issue-labels)
        (magit-insert-heading (propertize "Labels" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (issue-comments)
        (magit-insert-heading (propertize "Comments" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-issue (issue)
  "Erase the current buffer and render issue detail from hash-table ISSUE."
  (let* ((number   (gethash "number"    issue))
         (title    (or (gethash "title"  issue) ""))
         (state    (or (gethash "state"  issue) "OPEN"))
         (author   (or (gethash "login" (gethash "author" issue)) ""))
         (body     (or (gethash "body"   issue) ""))
         (created  (or (gethash "createdAt" issue) ""))
         (closed   (gethash "closedAt" issue))
         (labels   (let ((v (gethash "labels" issue)))
                     (if (or (null v) (eq v :null)) [] v)))
         (comments (let ((v (gethash "comments" issue)))
                     (if (or (null v) (eq v :null)) [] v)))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-issue-root)
      ;; ── Header ────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--issue-repo "") 'face 'octocat-repo)
                "  "
                (propertize "issue" 'face 'octocat-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                title
                "  "
                (propertize (downcase state)
                            'face (octocat--issue-state-face state))))
      ;; ── Info ──────────────────────────────────────────────────────────
      (magit-insert-section (issue-meta)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (format "  Author   %s\n"
                        (propertize (concat "@" author) 'face 'octocat-pr-author)))
        (insert (format "  Created  %s\n"
                        (substring created 0 (min 10 (length created)))))
        (when (and closed (not (eq closed :null)) (not (string-empty-p closed)))
          (insert (format "  Closed   %s\n"
                          (substring closed 0 (min 10 (length closed)))))))
      ;; ── Body ──────────────────────────────────────────────────────────
      (magit-insert-section (issue-body)
        (magit-insert-heading (propertize "Body" 'face 'octocat-section-heading))
        (if (string-empty-p (string-trim body))
            (insert (propertize "  (no description)\n" 'face 'octocat-dimmed))
          (dolist (line (split-string body "\n"))
            (insert "  " line "\n"))))
      ;; ── Labels ────────────────────────────────────────────────────────
      (magit-insert-section (issue-labels)
        (magit-insert-heading
          (propertize (format "Labels (%d)" (length labels))
                      'face 'octocat-section-heading))
        (if (zerop (length labels))
            (insert (propertize "  (no labels)\n" 'face 'octocat-dimmed))
          (cl-loop for label across labels do
                   (let ((name (or (gethash "name" label) "")))
                     (insert (format "  %s\n"
                                     (propertize name 'face 'octocat-branch)))))))
      ;; ── Comments ──────────────────────────────────────────────────────
      (magit-insert-section (issue-comments)
        (magit-insert-heading
          (propertize (format "Comments (%d)" (length comments))
                      'face 'octocat-section-heading))
        (if (zerop (length comments))
            (insert (propertize "  (no comments)\n" 'face 'octocat-dimmed))
          (cl-loop for comment across comments do
                   (let* ((login  (or (gethash "login" (gethash "author" comment)) ""))
                          (cbody  (or (gethash "body" comment) ""))
                          (snippet (truncate-string-to-width
                                    (replace-regexp-in-string "\n" " " cbody)
                                    72 nil ?\s "…")))
                     (insert (format "  %-20s  %s\n"
                                     (propertize (concat "@" login)
                                                 'face 'octocat-pr-author)
                                     snippet)))))))
    (goto-char (point-min))))


;;;; Major mode

(defvar octocat-issue-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "o")       #'octocat-browse)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    ;; Shadow magit-section-mode-map's "g" → revert-buffer with a prefix map.
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-issue-refresh)
    map)
  "Keymap for `octocat-issue-mode'.")

(define-derived-mode octocat-issue-mode magit-section-mode "Octocat-Issue"
  "Major mode for viewing a GitHub Issue.

\\{octocat-issue-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-issue-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-issue-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue detail buffer asynchronously."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (let ((buf  (current-buffer))
        (repo octocat--issue-repo)
        (num  octocat--issue-number))
    (octocat--fetch-issue repo num
                          (lambda (result)
                            (when (buffer-live-p buf)
                              (with-current-buffer buf
                                (if (eq (car-safe result) 'error)
                                    (let ((inhibit-read-only t))
                                      (erase-buffer)
                                      (insert (propertize
                                               (format "  Error: %s\n" (cdr result))
                                               'face 'error)))
                                  (octocat--render-issue result))))))))

(provide 'octocat-issue)
;;; octocat-issue.el ends here
