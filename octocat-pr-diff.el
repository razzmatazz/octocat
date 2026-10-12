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
;; The files themselves are rendered by octocat-diff.el, shared with the
;; commit page.  Must not depend on octocat.el to avoid a circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-diff)
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-repo-vui-use-cached "octocat-repo"
                  (type repo number fetch &optional as-list))
(declare-function octocat-pr--use-data "octocat-pr" (repo number))
(declare-function octocat-pr--header "octocat-pr" (repo pr &optional tab loading))
(declare-function octocat-pr--tabs "octocat-pr" (current repo number &optional files))
(declare-function octocat-switch-repo "octocat-core" ())
(declare-function octocat-search-repo "octocat-search" ())


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


;;;; Components

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
  "The diff of pull request NUMBER of REPO, under the PR page's header."
  :state ((spin 0))
  :render
  (let* ((pr       (octocat-pr--use-data repo number))
         (files    (octocat-repo-vui-use-cached
                    "pr-diff" repo number #'octocat--fetch-pr-diff))
         (comments (octocat-repo-vui-use-cached
                    "pr-review-comments" repo number
                    #'octocat--fetch-pr-review-comments t))
         (loading  (and (or (plist-get pr :refreshing)
                            (plist-get files :refreshing)
                            (plist-get comments :refreshing))
                        t))
         (by-path  (vui-use-memo ((plist-get comments :data))
                     (octocat-diff-by-path (plist-get comments :data)))))
    (octocat-vui-use-spinner loading)
    (vui-vstack
     ;; The same header as the conversation, so the pages read as tabs.
     (pcase (plist-get pr :status)
       ('ready (apply #'vui-vstack
                      (delq nil (octocat-pr--header
                                 repo (plist-get pr :data) 'files
                                 (and loading (octocat-vui-loading-suffix
                                               '(:refreshing t) spin))))))
       ('error (vui-vstack
                (vui-text (format "Error: %s" (plist-get pr :error)) :face 'error)
                (octocat-pr--tabs 'files repo number)))
       (_      (vui-vstack
                (vui-text (format "%s#%d  diff  (loading…)" repo number)
                          :face 'octocat-dimmed)
                (octocat-pr--tabs 'files repo number))))
     (pcase (plist-get files :status)
       ('pending (vui-text "  (loading files…)" :face 'octocat-dimmed))
       ('error   (vui-text (format "  Error: %s" (plist-get files :error)) :face 'error))
       (_ (octocat-diff-files-section (plist-get files :data) by-path)))
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
  (setq-local revert-buffer-function #'octocat-pr-diff-refresh)
  (octocat--ts-eldoc-setup))


;;;; Refresh

(defun octocat-pr-diff-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR diff buffer.
Mounts the vui.el page, which fetches the file diffs and the inline
review comments independently."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-pr-diff--page
                              :repo octocat--pr-diff-repo
                              :number octocat--pr-diff-number)
               (buffer-name))))

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
