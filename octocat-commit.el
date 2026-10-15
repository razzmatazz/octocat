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

;; Commit data fetching and the `octocat-commit-mode' page, rendered with
;; vui.el like the issue and PR pages.  The commit, its check-runs and its
;; comments are three independent `vui-use-async' fetches, each shown
;; from the disk cache until it arrives.  The changed files are rendered
;; by octocat-diff.el, like the PR diff page's.
;;
;; Depends on octocat-core.el; must not depend on octocat.el or
;; octocat-pr.el to avoid circular requires.

;;; Code:

(require 'seq)
(require 'octocat-core)
(require 'octocat-checks)
(require 'octocat-diff)
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-search-repo "octocat-search" ())
(declare-function octocat-repo-vui-use-cached "octocat-repo"
                  (type repo number fetch &optional as-list))



;;;; Custom faces

(defface octocat-commit-sha
  '((t :inherit font-lock-constant-face))
  "Face for a commit SHA in the commit view."
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


;;;; Internal helpers

;;;; Sections
;;
;; Each returns the vnodes of one part of the page.  The files reuse the
;; PR diff's file component: commit comments have the same shape as PR
;; review comments.

(defun octocat-commit--header (repo sha commit)
  "Return the header vnodes of commit SHA of REPO.
COMMIT is the commit hash-table, or nil while it loads.  The top row is
the repo and short SHA, as `owner/repo#N' on an issue, then the tab
strip.  The subject is on the row below, and
the author, date and full SHA under it."
  (let* ((c      (and commit (gethash "commit" commit)))
         (msg    (or (and c (gethash "message" c)) ""))
         (author (and c (gethash "author" c)))
         (login  (and commit (octocat--commit-author-login commit))))
    (delq nil
          (list
           (octocat-vui-commit-top-row repo sha)
           (and commit (vui-text (car (split-string msg "\n"))))
           (and commit
                (vui-text
                 (mapconcat
                  #'identity
                  (delq nil
                        (list (propertize (octocat--commit-author-full commit)
                                          'face 'octocat-pr-author)
                              (and login (propertize login 'face 'octocat-pr-author))
                              (octocat--format-ts-relative
                               (or (and author (octocat--nonempty (gethash "date" author)))
                                   ""))))
                  (propertize " · " 'face 'octocat-dimmed))))
           (and commit
                (vui-text (concat (propertize "SHA " 'face 'octocat-dimmed)
                                  (propertize (or (gethash "sha" commit) sha)
                                              'face 'octocat-commit-sha))))))))

(defun octocat-commit--skeleton (width)
  "Return grey bars shaped like a commit page below its top row, cut to WIDTH.
Shown when there is neither a cache nor a response yet: the subject,
author and SHA rows, then a few changed files."
  (octocat-vui-skeleton '((48) (30) (44) nil ("  " 40) ("  " 28)) width))

(defun octocat-commit--body (commit raw width)
  "Return the Message section of COMMIT: the message below its subject.
Nil when the message is the subject alone.  RAW and WIDTH are as for
`octocat--markdown-string'."
  (let* ((c    (gethash "commit" commit))
         (msg  (or (and c (gethash "message" c)) ""))
         (body (string-trim (mapconcat #'identity (cdr (split-string msg "\n")) "\n"))))
    (unless (string-empty-p body)
      (vui-vstack
       (vui-text (propertize "Message" 'face 'octocat-section-heading))
       (vui-text (string-remove-suffix
                  "\n" (octocat--markdown-string body nil raw width)))))))

(defun octocat-commit--async-status (result empty)
  "Return a dimmed vnode for RESULT if it failed or is empty, else nil.
EMPTY is the text shown when it is ready but has no data.  Grey bars
while it is pending."
  (pcase (plist-get result :status)
    ('pending (vui-text (octocat-vui-skeleton '(("  " 40) ("  " 28)))))
    ('error   (vui-text (format "  %s" (plist-get result :error)) :face 'octocat-dimmed))
    (_ (and (zerop (length (plist-get result :data)))
            (vui-text (concat "  " empty) :face 'octocat-dimmed)))))

(defun octocat-commit--heading (label result)
  "Return the section heading LABEL, with RESULT's count once it is ready."
  (vui-text (propertize (if (eq (plist-get result :status) 'ready)
                            (format "%s (%d)" label (length (plist-get result :data)))
                          label)
                        'face 'octocat-section-heading)))

(defun octocat-commit--checks (repo sha checks)
  "Return the CI section of commit SHA of REPO.
Its check-runs are in CHECKS, a `vui-use-async' result."
  (or (and (eq (plist-get checks :status) 'pending)
           (octocat-commit--heading "Checks" checks))
      (when-let* ((status (octocat-commit--async-status checks "(no checks)")))
        (vui-vstack (octocat-commit--heading "Checks" checks) status))
      (apply #'vui-vstack
             (octocat-checks-block
              (vconcat (mapcar #'octocat-checks-from-rest (plist-get checks :data)))
              (lambda () (octocat-checks-open repo sha nil))))))

(defun octocat-commit--comment (comment raw width)
  "Return the vnode of the general COMMENT, its author, date and body.
RAW and WIDTH are as for `octocat--markdown-string'."
  (let* ((user   (gethash "user" comment))
         (login  (or (and (hash-table-p user) (octocat--nonempty (gethash "login" user)))
                     ""))
         (body   (string-trim (or (gethash "body" comment) ""))))
    (vui-text
     (concat "  "
             (propertize (if (string-empty-p login) "(unknown)" (concat "@" login))
                         'face 'octocat-pr-author)
             "  "
             (propertize (octocat--format-ts-relative
                          (or (octocat--nonempty (gethash "created_at" comment)) ""))
                         'face 'octocat-dimmed)
             "\n"
             (if (string-empty-p body)
                 (propertize "  (empty)" 'face 'octocat-dimmed)
               (string-remove-suffix
                "\n" (octocat--markdown-string body nil raw width)))))))

(defun octocat-commit--comments (comments raw width)
  "Return the Comments section.
COMMENTS is the `vui-use-async' result for the commit's comments.  Only
general comments are listed; inline ones are in the diff, and counted in
a dimmed note.  RAW and WIDTH are as for `octocat--markdown-string'."
  (let* ((all     (plist-get comments :data))
         (general (seq-remove (lambda (c) (octocat--nonempty (gethash "path" c))) all))
         (inline  (- (length all) (length general))))
    (apply #'vui-vstack
           (octocat-commit--heading "Comments" comments)
           (or (delq nil (list (octocat-commit--async-status comments "(no comments)")))
               (append
                (and (> inline 0)
                     (list (vui-text (format "  (%d inline comment%s shown in the diff above)"
                                             inline (if (= inline 1) "" "s"))
                                     :face 'octocat-dimmed)))
                (mapcar (lambda (c) (octocat-commit--comment c raw width)) general))))))


;;;; Page

(vui-defcomponent octocat-commit--page (repo sha raw)
  "Commit SHA of REPO: header, message, checks, files and comments.
RAW shows markdown verbatim.  The commit, its checks and its comments
are fetched independently; each shows its cached copy until then."
  :state ((win-width nil))
  :render
  (let* ((width    (octocat-vui-use-window-width))
         (commit   (octocat-repo-vui-use-cached "commit" repo sha #'octocat--fetch-commit))
         (checks   (octocat-repo-vui-use-cached "checks" repo sha #'octocat--fetch-checks t))
         (comments (octocat-repo-vui-use-cached
                    "commit-comments" repo sha #'octocat--fetch-commit-comments t))
         (data     (and (eq (plist-get commit :status) 'ready) (plist-get commit :data)))
         (loading  (and (or (memq 'pending (list (plist-get commit :status)
                                                 (plist-get checks :status)
                                                 (plist-get comments :status)))
                            (plist-get commit :refreshing)
                            (plist-get checks :refreshing)
                            (plist-get comments :refreshing))
                        t))
         (md-width (progn width (octocat--markdown-width)))
         (by-path  (vui-use-memo ((plist-get comments :data))
                     (octocat-diff-by-path (plist-get comments :data))))
         (body     (vui-use-memo (data raw width)
                     (and data (octocat-commit--body data raw md-width)))))
    (octocat-vui-use-mode-line-loading loading)
    (apply #'vui-vstack
           (append
            (octocat-commit--header repo sha data)
            (pcase (plist-get commit :status)
              ('error (list (vui-newline)
                            (vui-text (format "Error: %s" (plist-get commit :error))
                                      :face 'error)))
              ('pending (list (vui-text (octocat-commit--skeleton width))))
              (_ (delq nil
                       (list (and body (vui-newline))
                             body
                             (vui-newline)
                             (octocat-commit--checks repo sha checks)
                             (vui-newline)
                             (octocat-diff-files-section
                              (or (gethash "files" data) []) by-path raw md-width)
                             (vui-newline)
                             (octocat-commit--comments comments raw md-width)))))))))


;;;; Major mode

(defun octocat-commit-browse ()
  "Open this commit in a browser."
  (interactive)
  (unless (and octocat--commit-repo octocat--commit-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (message "Octocat: Opening commit %s in browser…"
           (substring octocat--commit-sha 0 (min 7 (length octocat--commit-sha))))
  (octocat-browse-external (format "https://github.com/%s/commit/%s"
                                   octocat--commit-repo octocat--commit-sha)))

(defvar octocat-commit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-commit-mode'.")
(define-key octocat-commit-mode-map (kbd "q") #'quit-window)
(define-key octocat-commit-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-commit-mode-map (kbd "C-c C-o") #'octocat-commit-browse)
(define-key octocat-commit-mode-map (kbd "C-c C-v") #'octocat-toggle-markdown)
(define-key octocat-commit-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-commit-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-commit-mode vui-mode "Octocat-Commit"
  "Major mode for viewing a GitHub commit.

\\{octocat-commit-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-commit-refresh)
  (setq-local octocat--refresh-fn #'octocat-commit-refresh)
  (octocat-markdown--ensure-invisibility)
  (octocat--ts-eldoc-setup))


;;;; Refresh

(defun octocat-commit-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current commit buffer.
Mounts the vui.el page, which paints the disk cache at once and fetches
the commit, its checks and its comments in the background."
  (interactive)
  (unless (and octocat--commit-repo octocat--commit-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-commit--page
                              :repo octocat--commit-repo
                              :sha octocat--commit-sha
                              :raw octocat--markdown-raw)
               (buffer-name))))

(defun octocat-commit-open (repo sha)
  "Show commit SHA of REPO in its own buffer."
  (let ((buf (get-buffer-create
              (format "*%s commit %s*" repo
                      (substring sha 0 (min 7 (length sha)))))))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-commit-mode)
      (octocat-commit-mode))
    (setq octocat--commit-repo repo
          octocat--commit-sha  sha)
    (octocat-commit-refresh)))

(provide 'octocat-commit)
;;; octocat-commit.el ends here
