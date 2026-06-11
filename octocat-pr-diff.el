;;; octocat-pr-diff.el --- PR diff view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Full-diff view for a GitHub Pull Request, opened by pressing RET on the
;; "Changes" info field inside `octocat-pr-mode'.  Fetches per-file patches
;; via the GitHub REST API and renders them with collapsible
;; `magit-section' file sections — the same presentation as the commit diff
;; view in `octocat-commit.el'.
;;
;; Depends on octocat-core.el and octocat-commit.el (for the shared helpers
;; `octocat--insert-patch', `octocat--commit-file-icon', and
;; `octocat--commit-file-face').  Must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-commit)

;; Forward declarations for commands defined in octocat.el.
(declare-function octocat-browse "octocat" ())


;;;; Buffer-local declarations

(defvar-local octocat--pr-diff-repo nil
  "The \"owner/repo\" this PR diff buffer belongs to.")

(defvar-local octocat--pr-diff-number nil
  "The PR number this buffer is displaying a diff for.")


;;;; Data fetching

(defun octocat--fetch-pr-diff (repo number callback)
  "Fetch the per-file diff for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a vector of file hash-tables (same shape as the
GitHub commits API \\='files\\=' array — each entry has \\='filename\\=',
\\='status\\=', \\='additions\\=', \\='deletions\\=', and \\='patch\\='),
or a cons \\=(error . MSG) on failure.
Uses the GitHub REST API via `gh api'."
  (octocat--run-gh
   "pr-diff"
   (list "api"
         (format "repos/%s/pulls/%d/files" repo number))
   (lambda (output)
     (json-parse-string (string-trim output)))
   callback))


;;;; Rendering

(defun octocat--render-pr-diff-loading (number)
  "Render a loading skeleton for the diff of PR NUMBER."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-pr-diff-root)
      (magit-insert-heading
        (concat (propertize (or octocat--pr-diff-repo "") 'face 'octocat-repo)
                "  "
                (propertize "PR" 'face 'octocat-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                (propertize "diff" 'face 'octocat-dimmed)))
      (magit-insert-section (pr-diff-files)
        (magit-insert-heading (propertize "Files" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-pr-diff (files)
  "Erase the current buffer and render the PR diff from FILES vector.
FILES is a vector of file hash-tables as returned by the GitHub
pulls/NUMBER/files REST endpoint."
  (let* ((total-add (cl-reduce #'+ (cl-loop for f across files
                                            collect (or (gethash "additions" f) 0))
                               :initial-value 0))
         (total-del (cl-reduce #'+ (cl-loop for f across files
                                            collect (or (gethash "deletions" f) 0))
                               :initial-value 0))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-pr-diff-root)
      ;; ── Header ────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--pr-diff-repo "") 'face 'octocat-repo)
                "  "
                (propertize "PR" 'face 'octocat-dimmed)
                " "
                (propertize (format "#%d" octocat--pr-diff-number)
                            'face 'octocat-pr-number)
                "  "
                (propertize "diff" 'face 'octocat-dimmed)
                "  "
                (propertize (format "+%d" total-add) 'face 'diff-added)
                " "
                (propertize (format "-%d" total-del) 'face 'diff-removed)
                (propertize (format "  %d file(s)" (length files))
                            'face 'octocat-dimmed)))
      ;; ── Files ─────────────────────────────────────────────────────────
      (magit-insert-section (pr-diff-files)
        (magit-insert-heading
          (propertize (format "Files (%d)" (length files))
                      'face 'octocat-section-heading))
        (if (zerop (length files))
            (insert (propertize "  (no files changed)\n" 'face 'octocat-dimmed))
          (cl-loop for file across files do
                   (let* ((filename  (or (gethash "filename"  file) ""))
                          (status    (or (gethash "status"    file) "modified"))
                          (additions (or (gethash "additions" file) 0))
                          (deletions (or (gethash "deletions" file) 0))
                          (patch     (gethash "patch" file))
                          (icon      (octocat--commit-file-icon status))
                          (fface     (octocat--commit-file-face status))
                          (has-patch (and patch
                                          (not (eq patch :null))
                                          (not (string-empty-p patch)))))
                     (magit-insert-section (pr-diff-file file)
                       (magit-insert-heading
                         (concat "  "
                                 icon
                                 " "
                                 (propertize filename 'face fface)
                                 (propertize
                                  (format "  +%d -%d" additions deletions)
                                  'face 'octocat-dimmed)
                                 "\n"))
                       (when has-patch
                         (octocat--insert-patch patch))))))))))


;;;; Major mode

(defvar octocat-pr-diff-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "o")       #'octocat-browse)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    ;; Shadow magit-section-mode-map's "g" → revert-buffer with a prefix map.
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-pr-diff-refresh)
    map)
  "Keymap for `octocat-pr-diff-mode'.")

(define-derived-mode octocat-pr-diff-mode magit-section-mode "Octocat-PR-Diff"
  "Major mode for viewing the complete diff of a GitHub Pull Request.

\\{octocat-pr-diff-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-diff-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-pr-diff-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR diff buffer asynchronously."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (let* ((buf         (current-buffer))
         (repo        octocat--pr-diff-repo)
         (number      octocat--pr-diff-number)
         (saved-point (octocat--save-point)))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-pr-diff
     repo number
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
             (octocat--render-pr-diff result)
             (octocat--restore-point saved-point))))))))

(provide 'octocat-pr-diff)
;;; octocat-pr-diff.el ends here
