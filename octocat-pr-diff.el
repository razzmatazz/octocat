;;; octocat-pr-diff.el --- PR diff view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Full-diff view for a GitHub Pull Request, opened by pressing RET on the
;; "Changes" info field inside `octocat-pr-mode'.  Fetches per-file patches
;; via the GitHub REST API and renders them with collapsible
;; `magit-section' file sections — the same presentation as the commit diff
;; view in `octocat-commit.el'.
;;
;; Depends on octocat-core.el and octocat-commit.el (for the shared helpers
;; `octocat--insert-patch', `octocat--insert-patch-with-comments',
;; `octocat--insert-patch-comment', `octocat--commit-file-icon', and
;; `octocat--commit-file-face').  Must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-commit)

;; Forward declarations for commands defined in octocat.el.
(declare-function octocat-browse                        "octocat"        ())
(declare-function octocat--commit-file-icon             "octocat-commit" (status))
(declare-function octocat--commit-file-face             "octocat-commit" (status))
(declare-function octocat--insert-patch                 "octocat-commit" (patch))
(declare-function octocat--insert-patch-comment         "octocat-commit" (comment))
(declare-function octocat--insert-patch-with-comments   "octocat-commit" (patch comments-by-line &optional comments-by-pos))


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


(defun octocat--fetch-pr-review-comments (repo number callback)
  "Fetch inline review comments for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a list of review-comment hash-tables (snake_case REST
API keys), or a cons \\=(error . MSG) on failure.  Each comment has keys
\\='path\\=' (file path), \\='line\\=' (new-file line number, may be absent),
\\='position\\=' (1-based diff position), \\='body\\=', \\='user\\=',
\\='created_at\\='.
Uses the GitHub REST API via `gh api'."
  (octocat--run-gh
   "pr-review-comments"
   (list "api"
         (format "repos/%s/pulls/%d/comments" repo number))
   #'octocat--parse-json-list
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
      (let ((hint (list 'mouse-face 'magit-section-highlight
                        'help-echo  "RET: open repo view")))
        (magit-insert-section (repo-nav octocat--pr-diff-repo)
          (magit-insert-heading
            (concat (apply #'propertize "  Repo     " hint)
                    (apply #'propertize (or octocat--pr-diff-repo "")
                           'face 'octocat-repo hint)
                    (apply #'propertize "\n" hint)))))
      (insert "\n")
      (magit-insert-section (pr-diff-files)
        (magit-insert-heading (propertize "Files" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (pr-diff-review-comments)
        (magit-insert-heading
          (propertize "Review Comments" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-pr-diff (files &optional review-comments)
  "Erase the current buffer and render the PR diff from FILES vector.
FILES is a vector of file hash-tables as returned by the GitHub
pulls/NUMBER/files REST endpoint.
REVIEW-COMMENTS is a list of review-comment hash-tables from the
pulls/NUMBER/comments endpoint, or the symbol `loading' when the fetch
is still in flight, or nil when there are no comments."
  (let* ((total-add (cl-reduce #'+ (cl-loop for f across files
                                            collect (or (gethash "additions" f) 0))
                               :initial-value 0))
         (total-del (cl-reduce #'+ (cl-loop for f across files
                                            collect (or (gethash "deletions" f) 0))
                               :initial-value 0))
         ;; Build path-keyed lookup tables for inline review comments.
         ;; inline-by-path     — (path . ((line . comment) …))  right-side line
         ;; inline-by-path-pos — (path . ((pos  . comment) …))  diff position
         (inline-by-path
          (when (and review-comments (listp review-comments))
            (let ((tbl '()))
              (dolist (c review-comments)
                (let* ((path (octocat--nonempty (gethash "path" c)))
                       (lv   (gethash "line" c))
                       (line (and lv (not (eq lv :null)) lv)))
                  (when (and path line)
                    (let ((entry (assoc path tbl)))
                      (if entry
                          (setcdr entry (append (cdr entry) (list (cons line c))))
                        (push (cons path (list (cons line c))) tbl))))))
              tbl)))
         (inline-by-path-pos
          (when (and review-comments (listp review-comments))
            (let ((tbl '()))
              (dolist (c review-comments)
                (let* ((path (octocat--nonempty (gethash "path" c)))
                       (lv   (gethash "line" c))
                       (line (and lv (not (eq lv :null)) lv))
                       (pv   (gethash "position" c))
                       (pos  (and pv (not (eq pv :null)) pv)))
                  ;; Only use position for comments that lack a line number.
                  (when (and path pos (not line))
                    (let ((entry (assoc path tbl)))
                      (if entry
                          (setcdr entry (append (cdr entry) (list (cons pos c))))
                        (push (cons path (list (cons pos c))) tbl))))))
              tbl)))
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
      ;; ── Repo breadcrumb ───────────────────────────────────────────────
      (let ((hint (list 'mouse-face 'magit-section-highlight
                        'help-echo  "RET: open repo view")))
        (magit-insert-section (repo-nav octocat--pr-diff-repo)
          (magit-insert-heading
            (concat (apply #'propertize "  Repo     " hint)
                    (apply #'propertize (or octocat--pr-diff-repo "")
                           'face 'octocat-repo hint)
                    (apply #'propertize "\n" hint)))))
      (insert "\n")
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
                                          (not (string-empty-p patch))))
                          ;; Inline comments for this file keyed by line number
                          ;; and by diff-position (for older position-only comments).
                          (file-by-line (cdr (assoc filename inline-by-path)))
                          (file-by-pos  (cdr (assoc filename inline-by-path-pos))))
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
                         (if (or file-by-line file-by-pos)
                             ;; Group multiple comments at the same key into
                             ;; lists for assq lookup.
                             (cl-flet ((group (pairs)
                                         (let ((tbl2 '()))
                                           (dolist (p pairs)
                                             (let* ((k (car p)) (v (cdr p))
                                                    (e (assq k tbl2)))
                                               (if e
                                                   (setcdr e (append (cdr e) (list v)))
                                                 (push (cons k (list v)) tbl2))))
                                           tbl2)))
                               (octocat--insert-patch-with-comments
                                patch
                                (group file-by-line)
                                (group file-by-pos)))
                           (octocat--insert-patch patch))))))))
      ;; ── Review Comments ───────────────────────────────────────────────
      (insert "\n")
      (magit-insert-section (pr-diff-review-comments)
        (magit-insert-heading
          (if (and review-comments (listp review-comments))
              (propertize (format "Review Comments (%d)" (length review-comments))
                          'face 'octocat-section-heading)
            (propertize "Review Comments" 'face 'octocat-section-heading)))
        (cond
         ((eq review-comments 'loading)
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
         ((or (null review-comments) (null (listp review-comments)))
          (insert (propertize "  (no review comments)\n" 'face 'octocat-dimmed)))
         (t
          (let ((n (length review-comments)))
            (insert (propertize
                     (format "  (%d inline review comment%s shown in diff above)\n"
                             n (if (= n 1) "" "s"))
                     'face 'octocat-dimmed)))))))))


;;;; Major mode

(defvar octocat-pr-diff-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-r") #'octocat-switch-repo)
    (define-key map (kbd "C-c C-s") #'octocat-search-repo)
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
  "Refresh the current PR diff buffer asynchronously.
Fires two parallel fetches — the file diffs and the inline review
comments — and re-renders once both arrive.  Shows a Loading… placeholder
in the Review Comments section while the second fetch is in flight."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (let* ((buf         (current-buffer))
         (repo        octocat--pr-diff-repo)
         (number      octocat--pr-diff-number)
         (saved-point (octocat--save-point))
         (files-result    'pending)
         (comments-result 'pending))
    (setq mode-line-process " [refreshing…]")
    (cl-labels
        ((maybe-done ()
           (unless (or (eq files-result    'pending)
                       (eq comments-result 'pending))
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (setq mode-line-process nil)
                 (if (eq (car-safe files-result) 'error)
                     (let ((inhibit-read-only t))
                       (erase-buffer)
                       (insert (propertize
                                (format "  Error: %s\n" (cdr files-result))
                                'face 'error)))
                   (octocat--render-pr-diff
                    files-result
                    (if (eq (car-safe comments-result) 'error) nil comments-result))
                   (octocat--restore-point saved-point)))))))
      (octocat--fetch-pr-diff
       repo number
       (lambda (result)
         (setq files-result result)
         ;; Intermediate render: show file diffs immediately while review
         ;; comments are still loading.
         (when (and (buffer-live-p buf)
                    (not (eq (car-safe result) 'error))
                    (eq comments-result 'pending))
           (with-current-buffer buf
             (octocat--render-pr-diff result 'loading)
             (octocat--restore-point saved-point)))
         (maybe-done)))
      (octocat--fetch-pr-review-comments
       repo number
       (lambda (result)
         (setq comments-result result)
         (maybe-done))))))


(provide 'octocat-pr-diff)
;;; octocat-pr-diff.el ends here
