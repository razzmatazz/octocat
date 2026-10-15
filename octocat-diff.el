;;; octocat-diff.el --- Diff rendering for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; The changed files of a diff page, shared by the commit page
;; (octocat-commit.el) and the PR diff page (octocat-pr-diff.el): a fold
;; per file, its patch in the diff faces, with the inline comments boxed
;; after the lines they are on.  The files start folded unless the whole
;; diff fits in the window.  Commit comments and PR review comments have
;; the same shape, so both pass theirs in.  An unfolded patch wider than
;; the page's centred column widens it (`octocat--page-width').

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'octocat-core)
(require 'octocat-vui)
(require 'vui)


;;;; Faces

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


;;;; File status

(defun octocat-diff--file-face (status)
  "Return a face for a file with given STATUS string."
  (cond ((equal status "added")    'octocat-commit-file-added)
        ((equal status "removed")  'octocat-commit-file-removed)
        ((equal status "renamed")  'octocat-commit-file-renamed)
        (t                         'octocat-commit-file-modified)))

(defun octocat-diff--file-icon (status)
  "Return a one-char icon string for STATUS."
  (cond ((equal status "added")    (propertize "A" 'face 'octocat-commit-file-added))
        ((equal status "removed")  (propertize "D" 'face 'octocat-commit-file-removed))
        ((equal status "renamed")  (propertize "R" 'face 'octocat-commit-file-renamed))
        (t                         (propertize "M" 'face 'octocat-commit-file-modified))))

;;;; Patch text
;;
;; The patch of a file is built as one string: the diff lines in the diff
;; faces, each inline review comment boxed right after the line it is on.

(defun octocat-diff--comment-lines (comment raw width)
  "Return the lines of the boxed inline review COMMENT, without newlines.
Its body is markdown, rendered unless RAW, to fit WIDTH columns."
  (let* ((user   (gethash "user" comment))
         (login  (or (and (hash-table-p user)
                          (octocat--nonempty (gethash "login" user)))
                     ""))
         (author (if (string-empty-p login) "(unknown)" (concat "@" login)))
         (body   (string-trim (or (gethash "body" comment) "")))
         (date   (octocat--format-ts-relative
                  (or (octocat--nonempty (gethash "created_at" comment)) "")))
         (bar    (propertize "  │ " 'face 'octocat-dimmed)))
    (append
     (list (concat (propertize "  ┌─ " 'face 'octocat-dimmed)
                   (propertize author 'face 'octocat-pr-author)
                   (propertize (concat "  " date) 'face 'octocat-dimmed)))
     (if (string-empty-p body)
         (list (concat bar (propertize "(empty)" 'face 'octocat-dimmed)))
       (list (string-remove-suffix
              "\n" (octocat--markdown-string body bar raw width))))
     (list (propertize "  └─" 'face 'octocat-dimmed)))))

(defun octocat-diff--index (comments)
  "Index the review COMMENTS of one file for `octocat-diff--patch-text'.
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

(defun octocat-diff--patch-text (patch index raw width)
  "Return the unified diff PATCH as a propertized string, without final newline.
INDEX is the comment index of the file, see `octocat-diff--index'.  RAW
and WIDTH are as for `octocat-diff--comment-lines'.
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
    ;; Diff lines are not indented, so they copy out as a valid patch.
    (cl-flet ((emit (text &optional face)
                (push (if face (propertize text 'face face) text) out))
              (comments (key table)
                (dolist (c (cdr (assq key table)))
                  (dolist (l (octocat-diff--comment-lines c raw width))
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

(defvar-local octocat-diff--open-widths nil
  "Alist of the unfolded files of the page, by name, to their patch's width.")

(defun octocat-diff--patch-width (patch)
  "Return the columns the widest line of PATCH takes."
  (seq-reduce (lambda (w line) (max w (string-width line)))
              (split-string patch "\n") 0))

(defun octocat-diff--note-open (filename width)
  "Record that FILENAME is unfolded with a patch WIDTH wide, or folded if nil.
The page's column widens to the widest unfolded patch, see
`octocat--page-width'."
  (setf (alist-get filename octocat-diff--open-widths nil t #'equal) width)
  (let ((page (seq-reduce #'max (mapcar #'cdr octocat-diff--open-widths) 0)))
    (unless (eql page octocat--page-width)
      (setq octocat--page-width page)
      (mapc #'octocat--fit-window (get-buffer-window-list nil nil t)))))

(defun octocat-diff--file (file comments bulk raw width)
  "Return one changed FILE (a files-endpoint hash-table) with its inline COMMENTS.
It is folded unless BULK, as for `octocat-vui-fold', says otherwise; a
file without a patch (binary, or too large for GitHub to show) is just
its heading.  RAW and WIDTH are as for `octocat-diff--comment-lines'."
  (let* ((filename (or (gethash "filename" file) ""))
         (status   (or (gethash "status" file) "modified"))
         (patch    (let ((p (gethash "patch" file)))
                     (and (stringp p) (not (string-empty-p p)) p)))
         (title    (concat (octocat-diff--file-icon status)
                           " "
                           (propertize filename 'face (octocat-diff--file-face status))
                           (propertize (format "  +%d -%d"
                                               (or (gethash "additions" file) 0)
                                               (or (gethash "deletions" file) 0))
                                       'face 'octocat-dimmed))))
    (if (null patch)
        (vui-text (concat "  " title))
      (vui-component
       'octocat-vui-fold
       :key (intern filename)
       :bulk bulk
       :header (lambda (open toggle)
                 (octocat-vui-fold-header "" open toggle title
                                          '("RET: show diff" . "RET: hide diff")))
       :deps (list patch comments raw width)
       :on-open (lambda (open)
                  (octocat-diff--note-open
                   filename (and open (octocat-diff--patch-width patch))))
       :prepare (lambda ()
                  (octocat-vui-text-body
                   (octocat-diff--patch-text
                    patch (octocat-diff--index comments) raw width)))))))

(defun octocat-diff--line-count (files)
  "Return how many lines FILES take with every patch shown."
  (cl-loop for f across files
           sum (let ((p (gethash "patch" f)))
                 (1+ (if (stringp p) (1+ (cl-count ?\n p)) 0)))))

(defun octocat-diff-by-path (comments)
  "Return an alist mapping a file path to the review COMMENTS made on it."
  (let (table)
    (dolist (c comments)
      (when-let* ((path (octocat--nonempty (gethash "path" c))))
        (push c (alist-get path table nil nil #'equal))))
    (mapcar (lambda (e) (cons (car e) (reverse (cdr e)))) table)))

(vui-defcomponent octocat-diff--files (files by-path fits raw width)
  "The Files section: FILES with the review comments BY-PATH, folded.
They start unfolded when FITS, the whole diff fitting in the window.
RAW and WIDTH are as for `octocat-diff--comment-lines'.
The heading's \"Expand all\" button unfolds or folds every file."
  :state ((bulk (and fits (cons 0 t))))
  :render
  (let ((heading (vui-text (propertize (format "Files (%d)" (length files))
                                       'face 'octocat-section-heading))))
    (vui-vstack
     (if (cl-some (lambda (f) (stringp (gethash "patch" f))) files)
         (vui-hstack :spacing 2
                     heading
                     (octocat-vui-expand-all-button
                      bulk (vui-async-callback (v) (vui-set-state :bulk v))))
       heading)
     (if (zerop (length files))
         (vui-text "  (no files changed)" :face 'octocat-dimmed)
       (vui-list (append files nil)
                 (lambda (f)
                   (octocat-diff--file f (cdr (assoc (gethash "filename" f) by-path))
                                      bulk raw width))
                 (lambda (f) (gethash "filename" f)))))))

(defun octocat-diff-files-section (files by-path raw width)
  "Return the vnode of the Files section: the heading and one entry per file.
FILES is the files vector and BY-PATH the review comments by file path.
Files start folded, unless the whole diff fits in the window.  The
comments are markdown, rendered unless RAW, to fit WIDTH columns."
  (vui-component 'octocat-diff--files
                 :files files
                 :by-path by-path
                 :raw raw
                 :width width
                 :fits (<= (octocat-diff--line-count files) (octocat-vui-window-height))))

(provide 'octocat-diff)
;;; octocat-diff.el ends here
