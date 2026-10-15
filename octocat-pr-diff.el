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
(require 'octocat-edit)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-repo-vui-use-cached "octocat-repo"
                  (type repo number fetch &optional as-list))
(declare-function octocat-pr--use-data "octocat-pr" (repo number))
(declare-function octocat-pr--header "octocat-pr" (repo pr bg &optional tab))
(declare-function octocat-pr--merge-icon "octocat-pr" (kind))
(declare-function octocat-pr-refresh "octocat-pr" (&optional _ignore-auto _noconfirm))
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


;;;; Review submission

(defconst octocat-pr-diff--review-events
  '(("Comment"         . "--comment")
    ("Approve"         . "--approve")
    ("Request changes" . "--request-changes"))
  "Review events offered on submit, with their `gh pr review' flag.")

(defun octocat-pr-diff--review-args (repo number flag body)
  "Return the `gh' arguments submitting a FLAG review of PR NUMBER of REPO.
An empty BODY is left out, as `gh' rejects an empty --body."
  (append (list "pr" "review" (number-to-string number) "--repo" repo flag)
          (unless (string-empty-p body) (list "--body" body))))

(defun octocat-pr-diff--review-data (event)
  "Return the edit buffer's user data for an EVENT review.
Only an approval may be submitted without text."
  (let ((flag (cdr (assoc event octocat-pr-diff--review-events))))
    (list :event event :flag flag :allow-empty (equal flag "--approve"))))

(defun octocat-pr-diff--review-header (title event)
  "Return the review dialog's header line for TITLE with EVENT chosen."
  (concat "  " title "    "
          (mapconcat (lambda (e)
                       (if (equal (car e) event)
                           (propertize (format "(•) %s" (car e)) 'face 'bold)
                         (propertize (format "( ) %s" (car e)) 'face 'octocat-dimmed)))
                     octocat-pr-diff--review-events "  ")
          "    "
          (propertize "C-c C-t" 'face 'help-key-binding) " decision   "
          (propertize "C-c C-c" 'face 'help-key-binding) " submit   "
          (propertize "C-c C-k" 'face 'help-key-binding) " discard"))

(defvar-local octocat-pr-diff--reviewing nil
  "Non-nil while this PR diff buffer's review is being submitted.")

(defun octocat-pr-diff--set-reviewing (buf reviewing)
  "Set BUF's review submission under way to REVIEWING and show it in its page."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq octocat-pr-diff--reviewing reviewing)
      (octocat-vui-update-page :reviewing reviewing))))

(defun octocat-pr-diff--submit-review (body source on-success on-error)
  "Submit BODY as a review of the PR in SOURCE buffer.
The review flag is read from the edit buffer's :flag user data; there
is none until the user picks a decision.  The dialog closes at once,
through ON-SUCCESS, and SOURCE shows the review under way until it is
sent, so a slow GitHub does not block; ON-ERROR is called only for a
missing decision."
  (let ((flag (plist-get octocat-edit--user-data :flag)))
    (if (not flag)
        (funcall on-error "Pick a decision with C-c C-t first")
      (with-current-buffer source
        (let ((repo   octocat--pr-diff-repo)
              (number octocat--pr-diff-number))
          (setq octocat-pr-diff--reviewing t)
          (octocat--run-gh "review"
            (octocat-pr-diff--review-args repo number flag body)
            #'string-trim
            (lambda (result)
              (if (eq (car-safe result) 'error)
                  (progn
                    (message "Octocat: Failed to review PR #%d: %s" number (cdr result))
                    (octocat-pr-diff--set-reviewing source nil))
                (message "Octocat: Reviewed PR #%d" number)
                (when (buffer-live-p source)
                  (with-current-buffer source
                    (setq octocat-pr-diff--reviewing nil)
                    (octocat-pr-diff-refresh)))
                ;; The review joins the conversation's timeline and may
                ;; change its merge box.
                (when-let* ((pr-buf (get-buffer (format "*%s pr %d*" repo number))))
                  (with-current-buffer pr-buf
                    (octocat-pr-refresh))))))))
      (funcall on-success))))

(defun octocat-pr-diff-review-cycle ()
  "Switch the review dialog to the next decision."
  (interactive)
  (let* ((events (mapcar #'car octocat-pr-diff--review-events))
         (next   (or (cadr (member (plist-get octocat-edit--user-data :event) events))
                     (car events))))
    (setq octocat-edit--user-data (octocat-pr-diff--review-data next))
    (setq header-line-format
          (octocat-pr-diff--review-header octocat-edit--title next))
    (force-mode-line-update)))

(defvar octocat-pr-diff-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'octocat-pr-diff-review-cycle)
    map)
  "Keymap for `octocat-pr-diff-review-mode'.")

;; A minor mode so the decision key lives only in review dialogs, not in
;; every `octocat-edit-mode' buffer.
(define-minor-mode octocat-pr-diff-review-mode
  "Pick the decision of a PR review in its edit buffer."
  :keymap octocat-pr-diff-review-mode-map)

(defun octocat-pr-diff-review ()
  "Open the dialog to submit a review of this PR.
Write the review text, pick Comment, Approve or Request changes with
\\<octocat-pr-diff-review-mode-map>\\[octocat-pr-diff-review-cycle], then submit."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (when octocat-pr-diff--reviewing
    (user-error "Octocat: A review of PR #%d is being submitted" octocat--pr-diff-number))
  (let* ((title (format "Review PR #%d" octocat--pr-diff-number))
         (win   (octocat--open-edit-buffer
                 title
                 #'octocat-pr-diff--submit-review
                 (lambda (source) (octocat-pr-diff--set-reviewing source t))
                 nil
                 ;; No default decision: it must be a deliberate choice.
                 (octocat-pr-diff--review-data nil))))
    (with-current-buffer (window-buffer win)
      (octocat-pr-diff-review-mode 1)
      (setq header-line-format (octocat-pr-diff--review-header title nil)))))


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
       ('pending (vui-text (octocat-vui-skeleton '(("  " 36)))))
       ('error   (vui-text (format "  %s" (plist-get comments :error)) :face 'octocat-dimmed))
       (_ (vui-text (if (zerop n)
                        "  (no review comments)"
                      (format "  (%d inline review comment%s shown in the diff above)"
                              n (if (= n 1) "" "s")))
                    :face 'octocat-dimmed))))))

(vui-defcomponent octocat-pr-diff--page (repo number raw reviewing)
  "The diff of pull request NUMBER of REPO, under the PR page's header.
RAW shows the review comments' markdown verbatim.  REVIEWING non-nil
shows a review being submitted in place of the submit button."
  :render
  (let* ((pr       (octocat-pr--use-data repo number))
         (files    (octocat-repo-vui-use-cached
                    "pr-diff" repo number #'octocat--fetch-pr-diff))
         (comments (octocat-repo-vui-use-cached
                    "pr-review-comments" repo number
                    #'octocat--fetch-pr-review-comments t))
         (loading  (and (or (memq 'pending (list (plist-get pr :status)
                                                 (plist-get files :status)
                                                 (plist-get comments :status)))
                            (plist-get pr :refreshing)
                            (plist-get files :refreshing)
                            (plist-get comments :refreshing))
                        t))
         (by-path  (vui-use-memo ((plist-get comments :data))
                     (octocat-diff-by-path (plist-get comments :data)))))
    (octocat-vui-use-mode-line-loading loading)
    (vui-vstack
     ;; The same header as the conversation, so the pages read as tabs.
     (pcase (plist-get pr :status)
       ('ready (apply #'vui-vstack
                      (delq nil (octocat-pr--header
                                 repo (plist-get pr :data)
                                 (octocat--label-background) 'files))))
       ('error (vui-vstack
                (vui-text (format "Error: %s" (plist-get pr :error)) :face 'error)
                (octocat-pr--tabs 'files repo number)))
       (_      (vui-vstack
                (vui-text (format "%s#%d  diff" repo number)
                          :face 'octocat-dimmed)
                (octocat-pr--tabs 'files repo number))))
     (pcase (plist-get files :status)
       ('pending (vui-text (octocat-vui-skeleton '(("  " 40) ("  " 28) ("  " 34)))))
       ('error   (vui-text (format "  Error: %s" (plist-get files :error)) :face 'error))
       (_ (octocat-diff-files-section (plist-get files :data) by-path
                                      raw (octocat--markdown-width))))
     (vui-newline)
     (octocat-pr-diff--comments-section comments)
     (if reviewing
         (vui-text (concat "  " (octocat-pr--merge-icon 'wait) " Submitting review…")
                   :face 'bold)
       (apply #'vui-vstack
              (octocat-timeline-buttons
               (list (list "Submit review" "RET: comment on, approve or request changes"
                           #'octocat-pr-diff-review))))))))


;;;; Major mode

(defun octocat-pr-diff-browse ()
  "Open the files changed of this pull request in a browser."
  (interactive)
  (unless (and octocat--pr-diff-repo octocat--pr-diff-number)
    (user-error "Octocat: Buffer is not associated with a pull request diff"))
  (message "Octocat: Opening PR #%d diff in browser…" octocat--pr-diff-number)
  (octocat-browse-external (format "https://github.com/%s/pull/%d/files"
                                   octocat--pr-diff-repo octocat--pr-diff-number)))

(defvar octocat-pr-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-pr-diff-mode'.")
(define-key octocat-pr-diff-mode-map (kbd "q") #'quit-window)
(define-key octocat-pr-diff-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-pr-diff-mode-map (kbd "C-c C-a") #'octocat-pr-diff-review)
(define-key octocat-pr-diff-mode-map (kbd "C-c C-o") #'octocat-pr-diff-browse)
(define-key octocat-pr-diff-mode-map (kbd "C-c C-v") #'octocat-toggle-markdown)
(define-key octocat-pr-diff-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-pr-diff-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-pr-diff-mode vui-mode "Octocat-PR-Diff"
  "Major mode for viewing the complete diff of a GitHub Pull Request.

\\{octocat-pr-diff-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-diff-refresh)
  (setq-local octocat--refresh-fn #'octocat-pr-diff-refresh)
  (octocat-markdown--ensure-invisibility)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup))


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
                              :number octocat--pr-diff-number
                              :raw octocat--markdown-raw
                              :reviewing octocat-pr-diff--reviewing)
               (buffer-name))))

(defun octocat-pr-diff-open (repo number)
  "Show the diff of pull request NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s pr %d diff*" repo number))))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-pr-diff-mode)
      (octocat-pr-diff-mode))
    (setq octocat--pr-diff-repo   repo
          octocat--pr-diff-number number)
    (octocat-pr-diff-refresh)))

(provide 'octocat-pr-diff)
;;; octocat-pr-diff.el ends here
