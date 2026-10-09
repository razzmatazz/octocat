;;; octocat-pr-diff.el --- PR diff view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-5-5

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
;; "Changes" line of the PR page (`octocat-pr-mode').  Fetches per-file
;; patches and the inline review comments from the GitHub REST API and
;; renders one collapsible section per file.
;;
;; Rendered with vui.el (https://github.com/d12frosted/vui.el), like the PR
;; page itself.  The two fetches are independent `vui-use-async' hooks, so
;; the diff shows as soon as the files arrive and the review comments
;; appear in it when theirs do.  Each file is a component of its own, whose
;; patch text (with the comments interleaved) is only rebuilt when that
;; file or its comments change.
;;
;; Depends on octocat-core.el and octocat-commit.el (for the file status
;; icon and face).  Must not depend on octocat.el to avoid a circular
;; require.

;;; Code:

(require 'cl-lib)
(require 'octocat-core)
(require 'octocat-commit)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-collapsible

(declare-function octocat--commit-file-icon "octocat-commit" (status))
(declare-function octocat--commit-file-face "octocat-commit" (status))
(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))
(declare-function octocat-visit-repo "octocat-core" (repo))
(declare-function octocat-switch-repo "octocat-core" ())
(declare-function octocat-search-repo "octocat-core" ())


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


;;;; Patch text
;;
;; The patch of a file is built as one string: the diff lines in the diff
;; faces, each inline review comment boxed right after the line it is on.

(defun octocat-pr-diff--comment-lines (comment)
  "Return the lines of the boxed inline review COMMENT, without newlines."
  (let* ((user   (gethash "user" comment))
         (login  (or (and (hash-table-p user)
                          (octocat--nonempty (gethash "login" user)))
                     ""))
         (author (if (string-empty-p login) "(unknown)" (concat "@" login)))
         (body   (string-trim (or (gethash "body" comment) "")))
         (date   (octocat--format-ts-full
                  (or (octocat--nonempty (gethash "created_at" comment)) "")))
         (bar    (propertize "  │ " 'face 'octocat-dimmed)))
    (append
     (list (concat (propertize "  ┌─ " 'face 'octocat-dimmed)
                   (propertize author 'face 'octocat-pr-author)
                   (propertize (concat "  " date) 'face 'octocat-dimmed)))
     (if (string-empty-p body)
         (list (concat bar (propertize "(empty)" 'face 'octocat-dimmed)))
       (mapcar (lambda (line) (concat bar line)) (split-string body "\n")))
     (list (propertize "  └─" 'face 'octocat-dimmed)))))

(defun octocat-pr-diff--index (comments)
  "Index the review COMMENTS of one file for `octocat-pr-diff--patch-text'.
Returns (BY-LINE . BY-POS): alists mapping a right-side line number, and
for older comments that have no line a diff position, to the list of
comments there, in order."
  (let (by-line by-pos)
    (dolist (c comments)
      (let ((line (let ((v (gethash "line" c))) (and (integerp v) v)))
            (pos  (let ((v (gethash "position" c))) (and (integerp v) v))))
        (cond (line (push c (alist-get line by-line)))
              (pos  (push c (alist-get pos by-pos))))))
    (cons (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) by-line)
          (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) by-pos))))

(defun octocat-pr-diff--patch-text (patch index)
  "Return the unified diff PATCH as a propertized string, without final newline.
INDEX is the comment index of the file, see `octocat-pr-diff--index'.
Each comment is placed right after the diff line it is on, found by
tracking the right-side line number (from the `@@' headers) and the
1-based position in the diff."
  (let ((by-line (car index))
        (by-pos  (cdr index))
        (right 0)
        (pos   0)
        (lines (split-string patch "\n"))
        out)
    (when (equal (car (last lines)) "")
      (setq lines (butlast lines)))
    (cl-flet ((emit (text &optional face)
                (push (if face
                          (propertize (concat "  " text) 'face face)
                        (concat "  " text))
                      out))
              (comments (key table)
                (dolist (c (cdr (assq key table)))
                  (dolist (l (octocat-pr-diff--comment-lines c))
                    (push l out)))))
      (dolist (raw lines)
        (cl-incf pos)
        (cond
         ((string-prefix-p "@@" raw)
          (when (string-match "@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" raw)
            (setq right (string-to-number (match-string 1 raw))))
          (emit raw 'octocat-diff-hunk-heading)
          (comments pos by-pos))
         ;; Deleted: only in the old file, so the right line stays.
         ((string-prefix-p "-" raw)
          (emit raw 'diff-removed)
          (comments pos by-pos))
         (t
          (if (string-prefix-p "+" raw) (emit raw 'diff-added) (emit raw))
          (comments right by-line)
          (comments pos by-pos)
          (cl-incf right)))))
    (mapconcat #'identity (nreverse out) "\n")))


;;;; Components

(vui-defcomponent octocat-pr-diff--file (file comments)
  "One changed FILE (a files-endpoint hash-table) with its inline COMMENTS.
A collapsible section, expanded at first; a file without a patch (binary,
or too large for GitHub to show) is just its heading."
  :render
  (let* ((filename  (or (gethash "filename" file) ""))
         (status    (or (gethash "status" file) "modified"))
         (patch     (let ((p (gethash "patch" file)))
                      (and (stringp p) (not (string-empty-p p)) p)))
         (title     (concat (octocat--commit-file-icon status)
                            " "
                            (propertize filename 'face (octocat--commit-file-face status))
                            (propertize (format "  +%d -%d"
                                                (or (gethash "additions" file) 0)
                                                (or (gethash "deletions" file) 0))
                                        'face 'octocat-dimmed)))
         (text      (vui-use-memo (patch comments)
                      (and patch
                           (octocat-pr-diff--patch-text
                            patch (octocat-pr-diff--index comments))))))
    (if (null text)
        (vui-text (concat "  " title))
      (vui-collapsible
       :title title :key (intern filename) :initially-expanded t :indent 0
       (vui-text text)))))

(defun octocat-pr-diff--by-path (comments)
  "Return an alist mapping a file path to the review COMMENTS made on it."
  (let (table)
    (dolist (c comments)
      (when-let* ((path (octocat--nonempty (gethash "path" c))))
        (push c (alist-get path table nil nil #'equal))))
    (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) table)))

(defun octocat-pr-diff--sum (files key)
  "Return the sum of the KEY field over the FILES vector."
  (cl-loop for f across files sum (or (gethash key f) 0)))

(defun octocat-pr-diff--files-section (repo number files by-path)
  "Return the vnode of the Files section: the header and one entry per file.
REPO and NUMBER name the pull request, FILES is the files vector and
BY-PATH the review comments by file path."
  (vui-vstack
   (octocat-vui-row
    (concat (propertize repo 'face 'octocat-repo)
            (propertize (format "#%d" number) 'face 'octocat-pr-number))
    (lambda () (octocat-visit-repo repo))
    "RET: open repo view")
   (vui-text (concat (propertize "diff" 'face 'octocat-dimmed)
                     "  "
                     (propertize (format "+%d" (octocat-pr-diff--sum files "additions"))
                                 'face 'diff-added)
                     " "
                     (propertize (format "-%d" (octocat-pr-diff--sum files "deletions"))
                                 'face 'diff-removed)
                     (propertize (format "  %d file(s)" (length files))
                                 'face 'octocat-dimmed)))
   (vui-newline)
   (vui-text (propertize (format "Files (%d)" (length files))
                         'face 'octocat-section-heading))
   (if (zerop (length files))
       (vui-text "  (no files changed)" :face 'octocat-dimmed)
     (vui-list (append files nil)
               (lambda (f)
                 (vui-component 'octocat-pr-diff--file
                                :file f
                                :comments (cdr (assoc (gethash "filename" f) by-path))))
               (lambda (f) (gethash "filename" f))))))

(defun octocat-pr-diff--comments-section (comments)
  "Return the vnode of the Review Comments section.
COMMENTS is the `vui-use-async' result for the review comments."
  (let ((n (length (plist-get comments :data))))
    (vui-vstack
     (vui-text (concat (propertize "Review Comments" 'face 'octocat-section-heading)
                       (when (eq (plist-get comments :status) 'ready)
                         (propertize (format " (%d)" n) 'face 'octocat-section-heading))))
     (pcase (plist-get comments :status)
       ('pending (vui-text "  (loading…)" :face 'octocat-dimmed))
       ('error   (vui-text (format "  %s" (plist-get comments :error)) :face 'octocat-dimmed))
       (_ (vui-text (if (zerop n)
                        "  (no review comments)"
                      (format "  (%d inline review comment%s shown in the diff above)"
                              n (if (= n 1) "" "s")))
                    :face 'octocat-dimmed))))))

(vui-defcomponent octocat-pr-diff--page (repo number)
  "The diff of pull request NUMBER of REPO."
  :render
  (let* ((files    (vui-use-async (list 'pr-diff-files repo number)
                     (lambda (resolve reject)
                       (octocat--fetch-pr-diff
                        repo number
                        (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (comments (vui-use-async (list 'pr-diff-comments repo number)
                     (lambda (resolve reject)
                       (octocat--fetch-pr-review-comments
                        repo number
                        (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (by-path  (vui-use-memo ((plist-get comments :data))
                     (octocat-pr-diff--by-path (plist-get comments :data)))))
    (vui-vstack
     (pcase (plist-get files :status)
       ('pending (vui-text (format "%s#%d  diff  (loading…)" repo number)
                           :face 'octocat-dimmed))
       ('error   (vui-text (format "Error: %s" (plist-get files :error)) :face 'error))
       (_ (octocat-pr-diff--files-section repo number (plist-get files :data) by-path)))
     (vui-newline)
     (octocat-pr-diff--comments-section comments))))


;;;; Major mode

(defun octocat-pr-diff-browse ()
  "Open the files changed of this pull request in a browser."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (message "Octocat: Opening PR #%d diff in browser…" octocat--pr-diff-number)
  (browse-url (format "https://github.com/%s/pull/%d/files"
                      octocat--pr-diff-repo octocat--pr-diff-number)))

(defvar octocat-pr-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-pr-diff-mode'.")
(define-key octocat-pr-diff-mode-map (kbd "q") #'quit-window)
(define-key octocat-pr-diff-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-pr-diff-mode-map (kbd "C-c C-o") #'octocat-pr-diff-browse)
(define-key octocat-pr-diff-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-pr-diff-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-pr-diff-mode vui-mode "Octocat-PR-Diff"
  "Major mode for viewing the complete diff of a GitHub Pull Request.

\\{octocat-pr-diff-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-diff-refresh))


;;;; Refresh

(defun octocat-pr-diff-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR diff buffer.
Mounts the vui.el page, which fetches the file diffs and the inline
review comments independently."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (vui-mount (vui-component 'octocat-pr-diff--page
                            :repo octocat--pr-diff-repo
                            :number octocat--pr-diff-number)
             (buffer-name)))

(defun octocat-pr-diff-open (repo number)
  "Show the diff of pull request NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*octocat-pr-diff: %s#%d*" repo number))))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-pr-diff-mode)
      (octocat-pr-diff-mode))
    (setq octocat--pr-diff-repo   repo
          octocat--pr-diff-number number)
    (octocat-pr-diff-refresh)))

(provide 'octocat-pr-diff)
;;; octocat-pr-diff.el ends here
