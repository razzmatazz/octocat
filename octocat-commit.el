;;; octocat-commit.el --- Commit detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Commit data fetching, Magit-style detail rendering, and the
;; `octocat-commit-mode' major mode.  Depends on octocat-core.el;
;; must not depend on octocat.el or octocat-pr.el to avoid circular
;; requires.

;;; Code:

(require 'octocat-core)

;; These commands are defined in octocat.el which loads this file, so we
;; cannot require it here.  Declare them to silence the byte-compiler.
(declare-function octocat-browse "octocat" ())


;;;; Custom faces

(defface octocat-commit-sha
  '((t :inherit font-lock-constant-face))
  "Face for a commit SHA in the commit view."
  :group 'octocat)

(defface octocat-commit-file-modified
  '((t :inherit default))
  "Face for a modified file in the commit view."
  :group 'octocat)

(defface octocat-commit-file-added
  '((t :inherit diff-added))
  "Face for an added file in the commit view."
  :group 'octocat)

(defface octocat-commit-file-removed
  '((t :inherit diff-removed))
  "Face for a removed file in the commit view."
  :group 'octocat)

(defface octocat-commit-file-renamed
  '((t :inherit octocat-branch))
  "Face for a renamed file in the commit view."
  :group 'octocat)

(defface octocat-diff-hunk-heading
  '((t :inherit diff-header))
  "Face for a diff hunk header line."
  :group 'octocat)


;;;; Buffer-local declarations

(defvar-local octocat--commit-repo nil
  "The \"owner/repo\" this commit buffer belongs to.")

(defvar-local octocat--commit-sha nil
  "The full commit SHA this buffer is displaying.")


;;;; Data fetching

(defun octocat--fetch-commit (repo sha callback)
  "Fetch commit detail for SHA in REPO asynchronously.
Calls CALLBACK with a single hash-table of commit data, or the
symbol `error'.  Uses the GitHub REST API via `gh api'."
  (octocat--run-gh
   "commit"
   (list "api"
         (format "repos/%s/commits/%s" repo sha))
   (lambda (output)
     (json-parse-string (string-trim output)))
   callback))


;;;; Internal helpers

(defun octocat--commit-file-face (status)
  "Return a face for a file with given STATUS string."
  (cond ((equal status "added")    'octocat-commit-file-added)
        ((equal status "removed")  'octocat-commit-file-removed)
        ((equal status "renamed")  'octocat-commit-file-renamed)
        (t                         'octocat-commit-file-modified)))

(defun octocat--commit-file-icon (status)
  "Return a one-char icon string for STATUS."
  (cond ((equal status "added")    (propertize "A" 'face 'octocat-commit-file-added))
        ((equal status "removed")  (propertize "D" 'face 'octocat-commit-file-removed))
        ((equal status "renamed")  (propertize "R" 'face 'octocat-commit-file-renamed))
        (t                         (propertize "M" 'face 'octocat-commit-file-modified))))

(defun octocat--insert-patch (patch)
  "Insert a unified diff PATCH string with appropriate faces."
  (dolist (line (split-string patch "\n"))
    (cond
     ((string-prefix-p "@@" line)
      (insert (propertize (concat "  " line "\n")
                          'face 'octocat-diff-hunk-heading)))
     ((string-prefix-p "+" line)
      (insert (propertize (concat "  " line "\n")
                          'face 'diff-added)))
     ((string-prefix-p "-" line)
      (insert (propertize (concat "  " line "\n")
                          'face 'diff-removed)))
     (t
      (insert "  " line "\n")))))


;;;; Rendering

(defun octocat--render-commit-loading (sha)
  "Render a loading skeleton for commit SHA."
  (let ((inhibit-read-only t)
        (short (substring sha 0 (min 7 (length sha)))))
    (erase-buffer)
    (magit-insert-section (octocat-commit-root)
      (magit-insert-heading
        (concat (propertize (or octocat--commit-repo "") 'face 'octocat-repo)
                "  "
                (propertize "commit" 'face 'octocat-dimmed)
                " "
                (propertize short 'face 'octocat-commit-sha)))
      (magit-insert-section (commit-meta)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (commit-files)
        (magit-insert-heading (propertize "Files" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))))

(defun octocat--render-commit (commit)
  "Erase the current buffer and render commit detail from hash-table COMMIT.
COMMIT is the JSON object returned by the GitHub commits API endpoint."
  (let* ((sha       (or (gethash "sha" commit) ""))
         (short     (substring sha 0 (min 7 (length sha))))
         (c         (gethash "commit" commit))
         (message   (or (and c (gethash "message" c)) ""))
         (lines     (split-string message "\n"))
         (subject   (car lines))
         (body-lines (cdr lines))
         ;; Strip leading blank lines from body
         (body-lines (seq-drop-while #'string-empty-p body-lines))
         (author-obj (and c (gethash "author" c)))
         (author    (or (and author-obj (gethash "name" author-obj)) ""))
         (date-raw  (or (and author-obj (gethash "date" author-obj)) ""))
         (date      (octocat--format-ts date-raw))
         (files     (let ((v (gethash "files" commit)))
                      (if (or (null v) (eq v :null)) [] v)))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-commit-root)
      ;; ── Header ────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--commit-repo "") 'face 'octocat-repo)
                "  "
                (propertize "commit" 'face 'octocat-dimmed)
                " "
                (propertize short 'face 'octocat-commit-sha)
                "  "
                subject))
      ;; ── Meta ──────────────────────────────────────────────────────────
      (magit-insert-section (commit-meta)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (format "  Author  %s\n"
                        (propertize author 'face 'octocat-pr-author)))
        (insert (format "  Date    %s\n" date))
        (insert (format "  SHA     %s\n"
                        (propertize sha 'face 'octocat-commit-sha)))
        (when body-lines
          (insert "\n")
          (octocat--insert-markdown (string-join body-lines "\n"))))
      ;; ── Files ─────────────────────────────────────────────────────────
      (magit-insert-section (commit-files)
        (magit-insert-heading
          (propertize (format "Files (%d)" (length files))
                      'face 'octocat-section-heading))
        (if (zerop (length files))
            (insert (propertize "  (no files)\n" 'face 'octocat-dimmed))
          (cl-loop for file across files do
                   (let* ((filename  (or (gethash "filename"  file) ""))
                          (status    (or (gethash "status"    file) "modified"))
                          (additions (or (gethash "additions" file) 0))
                          (deletions (or (gethash "deletions" file) 0))
                          (patch      (gethash "patch" file))
                          (icon       (octocat--commit-file-icon status))
                          (fface      (octocat--commit-file-face status))
                          (patch-lines (if (and patch (not (eq patch :null))
                                               (not (string-empty-p patch)))
                                          (length (split-string patch "\n"))
                                        0)))
                     (magit-insert-section (commit-file file)
                       (magit-insert-heading
                         (concat "  "
                                 icon
                                 " "
                                 (propertize filename 'face fface)
                                 (propertize
                                  (format "  +%d -%d" additions deletions)
                                  'face 'octocat-dimmed)
                                 "\n"))
                       (when (> patch-lines 0)
                         (octocat--insert-patch patch)))))))))))


;;;; Major mode

(defvar octocat-commit-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "o")       #'octocat-browse)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    ;; Shadow magit-section-mode-map's "g" → revert-buffer with a prefix map.
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-commit-refresh)
    map)
  "Keymap for `octocat-commit-mode'.")
(define-derived-mode octocat-commit-mode magit-section-mode "Octocat-Commit"
  "Major mode for viewing a GitHub commit in Magit style.

\\{octocat-commit-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-commit-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-commit-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current commit detail buffer asynchronously."
  (interactive)
  (unless (and octocat--commit-repo octocat--commit-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (let* ((buf         (current-buffer))
         (repo        octocat--commit-repo)
         (sha         octocat--commit-sha)
         (saved-point (octocat--save-point)))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-commit repo sha
                           (lambda (result)
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (setq mode-line-process nil)
                                 (if (eq (car-safe result) 'error)
                                     (let ((inhibit-read-only t))
                                       (erase-buffer)
                                       (insert (propertize
                                                (format "  Error: %s\n" (cdr result))
                                                'face 'error)))
                                   (octocat--render-commit result)
                                   (octocat--restore-point saved-point))))))))

(provide 'octocat-commit)
;;; octocat-commit.el ends here
