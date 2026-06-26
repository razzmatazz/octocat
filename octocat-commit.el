;;; octocat-commit.el --- Commit detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Commit data fetching, Magit-style detail rendering, and the
;; `octocat-commit-mode' major mode.  Depends on octocat-core.el;
;; must not depend on octocat.el or octocat-pr.el to avoid circular
;; requires.

;;; Code:

(require 'octocat-core)

;; These commands are defined in octocat.el which loads this file, so we
;; cannot require it here.  Declare them to silence the byte-compiler.
(declare-function octocat-browse        "octocat"        ())
(declare-function octocat-visit         "octocat"        ())
;; octocat-checks.el is loaded after this file; declare to silence compiler.
(declare-function octocat--fetch-checks "octocat-checks" (repo sha callback))



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

(defun octocat--fetch-commit-comments (repo sha callback)
  "Fetch all comments on commit SHA in REPO asynchronously.
Calls CALLBACK with a list of comment hash-tables (snake_case REST API
keys), or a cons \\=(error . MSG) on failure.  The list includes both
general comments (\\='path\\=' is :null or nil) and inline comments
\(\\='path\\=' is a file path string, \\='line\\=' is the target line number)."
  (octocat--run-gh
   "commit-comments"
   (list "api"
         (format "repos/%s/commits/%s/comments" repo sha))
   #'octocat--parse-json-list
   callback))


;;;; Comment rendering

(defun octocat--render-commit-comment-list (comments)
  "Insert commit COMMENTS into the current buffer as collapsible sections.
COMMENTS is a list of comment hash-tables from the GitHub REST commits
comments endpoint (snake_case keys).  Only general comments (those with
no \\='path\\=' field) are rendered here; inline comments are displayed
directly in the diff within the Files section.  A dimmed note states how
many inline comments were shown there."
  (if (null comments)
      (insert (propertize "  (no comments)\n" 'face 'octocat-dimmed))
    (let* ((general  (cl-remove-if
                      (lambda (c) (octocat--nonempty (gethash "path" c)))
                      comments))
           (n-inline (- (length comments) (length general))))
      ;; Note about inline comments shown in the Files diff above.
      (when (> n-inline 0)
        (insert (propertize
                 (format "  (%d inline comment%s shown in diff above)\n"
                         n-inline (if (= n-inline 1) "" "s"))
                 'face 'octocat-dimmed)))
      ;; General comments.
      (if (null general)
          (when (zerop n-inline)
            (insert (propertize "  (no comments)\n" 'face 'octocat-dimmed)))
        (dolist (comment general)
          (let* ((user   (gethash "user" comment))
                 (login  (or (and user (octocat--nonempty (gethash "login" user))) ""))
                 (author (if (string-empty-p login) "(unknown)" (concat "@" login)))
                 (body   (or (gethash "body" comment) ""))
                 (date   (octocat--format-ts-full
                          (or (octocat--nonempty (gethash "created_at" comment)) ""))))
            (magit-insert-section (commit-comment comment)
              (magit-insert-heading
                (concat "  "
                        (propertize author 'face 'octocat-pr-author)
                        "  "
                        (propertize date 'face 'octocat-dimmed)
                        "\n"))
              (if (string-empty-p (string-trim body))
                  (insert (propertize "  (empty)\n" 'face 'octocat-dimmed))
                (octocat--insert-markdown body))
              (insert "\n"))))))))


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

(defun octocat--insert-patch-comment (comment)
  "Insert one inline diff COMMENT as a collapsible magit section.
COMMENT is a commit comment hash-table from the REST API.  Renders a
compact bordered block using box-drawing characters, intended to be
called from within a diff-rendering context."
  (let* ((user   (gethash "user" comment))
         (login  (or (and user (octocat--nonempty (gethash "login" user))) ""))
         (author (if (string-empty-p login) "(unknown)" (concat "@" login)))
         (body   (or (gethash "body" comment) ""))
         (date   (octocat--format-ts-full
                  (or (octocat--nonempty (gethash "created_at" comment)) ""))))
    (magit-insert-section (commit-comment comment)
      (magit-insert-heading
        (concat (propertize "  ┌─ " 'face 'octocat-dimmed)
                (propertize author 'face 'octocat-pr-author)
                (propertize (concat "  " date) 'face 'octocat-dimmed)
                "\n"))
      (if (string-empty-p (string-trim body))
          (insert (propertize "  │ (empty)\n" 'face 'octocat-dimmed))
        (dolist (bline (split-string (string-trim body) "\n"))
          (insert (propertize "  │ " 'face 'octocat-dimmed) bline "\n")))
      (insert (propertize "  └─\n" 'face 'octocat-dimmed)))))

(defun octocat--insert-patch-with-comments (patch comments-by-line
                                            &optional comments-by-pos)
  "Insert PATCH with inline comments interleaved at the correct lines.
PATCH is a unified diff string.
COMMENTS-BY-LINE is an alist mapping integer right-side (new-file) line
numbers to lists of comment hash-tables.  Used for comments that carry a
\\='line\\=' field from the GitHub API.
COMMENTS-BY-POS is an optional alist mapping integer diff-position numbers
\(1-based, counting every line in the diff including hunk headers and removed
lines) to lists of comment hash-tables.  Used for older-style comments that
carry only a \\='position\\=' field and no \\='line\\=' field.
Parses `@@' hunk headers to track both counters simultaneously and inserts
matching comments immediately after each rendered diff line."
  (let ((right-line 0)
        (diff-pos   0))
    (dolist (raw-line (split-string patch "\n"))
      (cl-incf diff-pos)   ; every line counts toward position (1-based)
      (cond
       ;; Hunk header — extract the new-file start line from `+N' field.
       ((string-prefix-p "@@" raw-line)
        (when (string-match
               "@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" raw-line)
          (setq right-line (string-to-number (match-string 1 raw-line))))
        (insert (propertize (concat "  " raw-line "\n")
                            'face 'octocat-diff-hunk-heading))
        (dolist (c (cdr (assq diff-pos comments-by-pos)))
          (octocat--insert-patch-comment c)))
       ;; Deleted line — exists only in old file; do not advance right-line.
       ((string-prefix-p "-" raw-line)
        (insert (propertize (concat "  " raw-line "\n") 'face 'diff-removed))
        (dolist (c (cdr (assq diff-pos comments-by-pos)))
          (octocat--insert-patch-comment c)))
       ;; Added line — exists in new file at right-line.
       ((string-prefix-p "+" raw-line)
        (insert (propertize (concat "  " raw-line "\n") 'face 'diff-added))
        (dolist (c (cdr (assq right-line comments-by-line)))
          (octocat--insert-patch-comment c))
        (dolist (c (cdr (assq diff-pos comments-by-pos)))
          (octocat--insert-patch-comment c))
        (cl-incf right-line))
       ;; Context line — exists in both; also in new file at right-line.
       (t
        (insert "  " raw-line "\n")
        (dolist (c (cdr (assq right-line comments-by-line)))
          (octocat--insert-patch-comment c))
        (dolist (c (cdr (assq diff-pos comments-by-pos)))
          (octocat--insert-patch-comment c))
        (cl-incf right-line))))))


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
        (let ((hint (list 'mouse-face 'magit-section-highlight
                          'help-echo  "RET: open repo view")))
          (magit-insert-section (repo-nav octocat--commit-repo)
            (magit-insert-heading
              (concat (apply #'propertize "  Repo     " hint)
                      (apply #'propertize (or octocat--commit-repo "")
                             'face 'octocat-repo hint)
                      (apply #'propertize "\n" hint)))))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (commit-message)
        (magit-insert-heading (propertize "Message" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (commit-checks)
        (magit-insert-heading (propertize "Checks" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (commit-files)
        (magit-insert-heading (propertize "Files" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (commit-comments)
        (magit-insert-heading (propertize "Comments" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-commit (commit &optional checks-list comments-list)
  "Erase the current buffer and render commit detail from hash-table COMMIT.
COMMIT is the JSON object returned by the GitHub commits API endpoint.
CHECKS-LIST is an optional list of check-run hash-tables from the Checks
API; when the symbol `loading\\=' a placeholder is shown instead.
COMMENTS-LIST is an optional list of comment hash-tables from the GitHub
REST commits comments endpoint; when the symbol `loading\\=' a placeholder
is shown instead."
  (let* ((sha       (or (gethash "sha" commit) ""))
         (short     (substring sha 0 (min 7 (length sha))))
         (c         (gethash "commit" commit))
         (message   (or (and c (gethash "message" c)) ""))
         (lines     (split-string message "\n"))
         (subject   (car lines))
         (author-obj    (and c (gethash "author" c)))
         (author        (octocat--commit-author-full commit))
         (github-handle (octocat--commit-author-login commit))
         (date-raw      (or (and author-obj (gethash "date" author-obj)) ""))
         (date      (octocat--format-ts-full date-raw))
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
        (let ((hint (list 'mouse-face 'magit-section-highlight
                          'help-echo  "RET: open repo view")))
          (magit-insert-section (repo-nav octocat--commit-repo)
            (magit-insert-heading
              (concat (apply #'propertize "  Repo    " hint)
                      (apply #'propertize (or octocat--commit-repo "")
                             'face 'octocat-repo hint)
                      (apply #'propertize "\n" hint)))))
        (insert (format "  Author  %s\n"
                        (propertize author 'face 'octocat-pr-author)))
        (when github-handle
          (insert (format "  GitHub  %s\n"
                          (propertize github-handle 'face 'octocat-pr-author))))
        (insert (format "  Date    %s\n" date))
        (insert (format "  SHA     %s\n"
                        (propertize sha 'face 'octocat-commit-sha))))
      ;; ── Message ───────────────────────────────────────────────────────
      (insert "\n")
      (magit-insert-section (commit-message)
        (magit-insert-heading (propertize "Message" 'face 'octocat-section-heading))
        (if (string-empty-p (string-trim message))
            (insert (propertize "  (no message)\n" 'face 'octocat-dimmed))
          (octocat--insert-markdown message)))
      ;; ── Checks ────────────────────────────────────────────────────────
      (insert "\n")
      (magit-insert-section (commit-checks)
        (magit-insert-heading
          (if (and checks-list (listp checks-list))
              (propertize (format "Checks (%d)" (length checks-list))
                          'face 'octocat-section-heading)
            (propertize "Checks" 'face 'octocat-section-heading)))
        (cond
         ((eq checks-list 'loading)
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
         ((or (null checks-list) (zerop (length checks-list)))
          (insert (propertize "  (no checks)\n" 'face 'octocat-dimmed)))
         (t
          (dolist (check checks-list)
            (let* ((name       (or (gethash "name"       check) ""))
                   (status     (downcase (or (gethash "status"  check) "")))
                   (conc-raw   (gethash "conclusion" check))
                   (conclusion (and (octocat--nonempty conc-raw) (downcase conc-raw)))
                   (started    (octocat--nonempty (gethash "started_at"  check)))
                   (completed  (octocat--nonempty (gethash "completed_at" check)))
                   (duration   (octocat--run-duration started completed))
                   (app        (gethash "app" check))
                   (app-name   (or (and app (octocat--nonempty (gethash "name" app))) ""))
                   (icon       (octocat--run-icon status conclusion))
                   (hint       '(mouse-face magit-section-highlight
                                 help-echo  "RET: view checks for this commit")))
              (magit-insert-section (check-run check)
                (magit-insert-heading
                  (concat "  "
                          icon
                          "  "
                          (apply #'propertize
                                 (truncate-string-to-width name 40 nil ?\s "…")
                                 hint)
                          "  "
                          (propertize (truncate-string-to-width
                                       (format "%-20s" app-name) 20 nil ?\s "…")
                                      'face 'octocat-dimmed)
                          (if duration
                              (concat "  " (propertize duration 'face 'octocat-dimmed))
                            "")
                          "\n"))))))))
      ;; ── Files ─────────────────────────────────────────────────────────
      ;; Build two path-keyed lookup tables for inline comments:
      ;;   inline-by-path     — keyed by actual right-side line number (line field)
      ;;   inline-by-path-pos — keyed by diff-position (position field), for older
      ;;                        comments that have no line field
      (let* ((inline-by-path
              (when (and comments-list (listp comments-list))
                (let ((tbl '()))
                  (dolist (c comments-list)
                    (let* ((path (octocat--nonempty (gethash "path" c)))
                           (lv   (gethash "line" c))
                           (line (and lv (not (eq lv :null)) lv)))
                      (when (and path line)
                        (let ((entry (assoc path tbl)))
                          (if entry
                              (setcdr entry
                                      (append (cdr entry) (list (cons line c))))
                            (push (cons path (list (cons line c))) tbl))))))
                  tbl)))
             (inline-by-path-pos
              (when (and comments-list (listp comments-list))
                (let ((tbl '()))
                  (dolist (c comments-list)
                    (let* ((path (octocat--nonempty (gethash "path" c)))
                           (lv   (gethash "line" c))
                           (line (and lv (not (eq lv :null)) lv))
                           (pv   (gethash "position" c))
                           (pos  (and pv (not (eq pv :null)) pv)))
                      ;; Only use position for comments that lack a line number.
                      (when (and path pos (not line))
                        (let ((entry (assoc path tbl)))
                          (if entry
                              (setcdr entry
                                      (append (cdr entry) (list (cons pos c))))
                            (push (cons path (list (cons pos c))) tbl))))))
                  tbl))))
        (insert "\n")
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
                            (has-patch  (and patch (not (eq patch :null))
                                             (not (string-empty-p patch))))
                            ;; Inline comments for this file keyed by line number
                            ;; and by diff-position (for older position-only comments).
                            (file-by-line
                             (cdr (assoc filename inline-by-path)))
                            (file-by-pos
                             (cdr (assoc filename inline-by-path-pos))))
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
                         (when has-patch
                           (if (or file-by-line file-by-pos)
                               ;; Group multiple comments on the same key into
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
                             (octocat--insert-patch patch)))))))))

      ;; ── Comments ──────────────────────────────────────────────────────
      (insert "\n")
      (magit-insert-section (commit-comments)
        (magit-insert-heading
          (if (and comments-list (listp comments-list))
              (propertize (format "Comments (%d)" (length comments-list))
                          'face 'octocat-section-heading)
            (propertize "Comments" 'face 'octocat-section-heading)))
        (cond
         ((eq comments-list 'loading)
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
         (t
          (octocat--render-commit-comment-list comments-list)))))))


;;;; Major mode

(defvar octocat-commit-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "RET")     #'octocat-visit)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-v") #'octocat-toggle-markdown)
    (define-key map (kbd "C-c C-r") #'octocat-switch-repo)
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
  (setq-local octocat--refresh-fn #'octocat-commit-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-commit-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current commit detail buffer asynchronously.
Renders a cached copy immediately when one is available, then always
fetches fresh data in the background and re-renders on arrival.
Check-run and comment data are fetched in parallel with the commit
data; their sections show Loading… placeholders until they arrive."
  (interactive)
  (unless (and octocat--commit-repo octocat--commit-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (let* ((buf         (current-buffer))
         (repo        octocat--commit-repo)
         (sha         octocat--commit-sha)
         (saved-point (octocat--save-point))
         ;; Load commit, checks, and comments caches immediately.
         (cache          (octocat--detail-cache-load repo "commit" sha))
         (checks-cache   (let ((raw (octocat--detail-cache-load repo "checks" sha)))
                           (and raw (if (vectorp raw)
                                        (cl-coerce raw 'list)
                                      (list raw)))))
         (comments-cache (let ((raw (octocat--detail-cache-load repo "commit-comments" sha)))
                           (and raw (if (vectorp raw)
                                        (cl-coerce raw 'list)
                                      (list raw))))))
    (when cache
      (octocat--render-commit cache checks-cache comments-cache)
      (octocat--restore-point saved-point))
    (setq mode-line-process " [refreshing…]")
    ;; Fire all three fetches in parallel; do a final render once all arrive.
    (let ((commit-result   'pending)
          (checks-result   'pending)
          (comments-result 'pending))
      (cl-labels
          ((maybe-done ()
             (unless (or (eq commit-result   'pending)
                         (eq checks-result   'pending)
                         (eq comments-result 'pending))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq mode-line-process nil)
                   (if (eq (car-safe commit-result) 'error)
                       (let ((inhibit-read-only t))
                         (erase-buffer)
                         (insert (propertize
                                  (format "  Error: %s\n" (cdr commit-result))
                                  'face 'error)))
                     (octocat--detail-cache-save repo "commit" sha commit-result)
                     (octocat--render-commit commit-result checks-result comments-result)
                     (octocat--restore-point saved-point)))))))
        (octocat--fetch-commit
         repo sha
         (lambda (result)
           (setq commit-result result)
           ;; Intermediate render: show commit content immediately with
           ;; loading placeholders for whichever sibling fetches are still
           ;; in flight.
           (when (and (buffer-live-p buf)
                      (not (eq (car-safe result) 'error))
                      (or (eq checks-result   'pending)
                          (eq comments-result 'pending)))
             (with-current-buffer buf
               (octocat--render-commit
                result
                (if (eq checks-result   'pending) 'loading checks-result)
                (if (eq comments-result 'pending) 'loading comments-result))
               (octocat--restore-point saved-point)))
           (maybe-done)))
        (octocat--fetch-checks
         repo sha
         (lambda (result)
           (setq checks-result (if (eq (car-safe result) 'error) nil result))
           (when (and checks-result (listp checks-result))
             (octocat--detail-cache-save repo "checks" sha (vconcat checks-result)))
           (maybe-done)))
        (octocat--fetch-commit-comments
         repo sha
         (lambda (result)
           (setq comments-result (if (eq (car-safe result) 'error) nil result))
           (when (and comments-result (listp comments-result))
             (octocat--detail-cache-save repo "commit-comments" sha
                                         (vconcat comments-result)))
           (maybe-done)))))))

(provide 'octocat-commit)
;;; octocat-commit.el ends here
