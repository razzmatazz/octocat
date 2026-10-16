;;; octocat-issue.el --- Issue detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Issue data fetching, the issue timeline view, and the octocat-issue-mode
;; major mode.  The detail view is vui.el-rendered as a GitHub-style
;; timeline (opening post, comments and events in time order), built with
;; the pieces in octocat-timeline.el.  Depends on octocat-core.el for shared
;; infrastructure; must not depend on octocat.el to avoid a circular
;; require.

;;; Code:

(require 'octocat-core)
(require 'octocat-edit)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-list, vui-vstack, etc.

;; The issue list page below reuses the row builder and fetch plumbing
;; from octocat-repo.el, which requires this file (so cannot be required
;; here).
(declare-function octocat-repo-vui--issue-row "octocat-repo" (repo issue width bg &optional compact))
(declare-function octocat-repo-vui--state-label "octocat-repo" (state &optional draft))
(declare-function octocat-repo-vui--detail-header "octocat-repo" (repo item state on-edit-title bg &optional branch omit))
(declare-function octocat-repo-vui--detail-fields "octocat-repo" (fields))
(declare-function octocat-repo-vui--logins "octocat-repo" (users))
(declare-function octocat-repo-vui--numbers "octocat-repo" (repo refs open))
(declare-function octocat-pr-open "octocat-pr" (repo number))
(declare-function octocat-repo-vui--milestone "octocat-repo" (item))
(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))


;;;; Edit / comment commands — submit helpers

(defun octocat-issue--submit-comment (body source on-success _on-error)
  "Submit BODY as a new comment on the issue in SOURCE buffer.
See `octocat-timeline-submit' for ON-SUCCESS."
  (octocat-timeline-submit
   "Posting comment…" "comment"
   (with-current-buffer source
     (list "issue" "comment" (number-to-string octocat--issue-number)
           "--repo" octocat--issue-repo "--body" body))
   body source on-success))

(defun octocat-issue--submit-edit-body (body source on-success _on-error)
  "Replace the body of the issue in SOURCE buffer with BODY.
See `octocat-timeline-submit' for ON-SUCCESS."
  (octocat-timeline-submit
   "Saving description…" "edit-body"
   (with-current-buffer source
     (list "issue" "edit" (number-to-string octocat--issue-number)
           "--repo" octocat--issue-repo "--body" body))
   body source on-success))

(defun octocat-issue--submit-edit-comment (body source on-success _on-error)
  "Edit the comment identified in `octocat-edit--user-data' with BODY.
The :comment-id plist key is read from the edit buffer (current-buffer at
call time).  SOURCE supplies the repo string.
See `octocat-timeline-submit' for ON-SUCCESS."
  (let ((repo       (with-current-buffer source octocat--issue-repo))
        (comment-id (plist-get octocat-edit--user-data :comment-id)))
    (octocat-timeline-submit
     "Saving comment…" "edit-comment"
     (list "api"
           (format "repos/%s/issues/comments/%s" repo comment-id)
           "--method" "PATCH"
           "-f" (format "body=%s" body))
     body source on-success)))

;;;; Edit / comment commands

(defun octocat-issue-add-comment ()
  "Open an edit buffer to add a comment to the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-timeline-ensure-idle)
  (octocat--open-edit-buffer
   (format "New comment on issue #%d" octocat--issue-number)
   #'octocat-issue--submit-comment
   #'ignore))

(defun octocat-issue-edit-body ()
  "Open an edit buffer to replace the body of the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-timeline-ensure-idle)
  ;; Pre-populate with the current body from the cache so the user can
  ;; edit in-place rather than retyping everything.
  (let* ((cache (octocat--detail-cache-load octocat--issue-repo "issue" octocat--issue-number))
         (body  (and cache (octocat--nonempty (gethash "body" cache)))))
    (octocat--open-edit-buffer
     (format "Edit body of issue #%d" octocat--issue-number)
     #'octocat-issue--submit-edit-body
     #'ignore
     body)))

(defun octocat-issue-edit-title ()
  "Prompt in the minibuffer to rename the title of the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (let* ((cache   (octocat--detail-cache-load octocat--issue-repo "issue" octocat--issue-number))
         (current (or (and cache (octocat--nonempty (gethash "title" cache))) ""))
         (new     (string-trim (read-string "Issue title: " current))))
    (when (string-empty-p new)
      (user-error "Octocat: Title must not be empty"))
    (unless (string-equal new current)
      (let ((repo octocat--issue-repo)
            (num  octocat--issue-number)
            (buf  (current-buffer)))
        ;; In the mode line: the page has no button for this to replace.
        (octocat-vui-mode-line-action buf ":saving")
        (octocat--run-gh
         "edit-title"
         (list "issue" "edit" (number-to-string num) "--repo" repo "--title" new)
         #'identity
         (lambda (result)
           (octocat-vui-mode-line-action buf nil)
           (if (eq (car-safe result) 'error)
               (message "Octocat: failed to update title: %s" (cdr result))
             (when (buffer-live-p buf)
               (with-current-buffer buf (octocat-issue-refresh))))))))))

(defun octocat-issue-edit ()
  "Edit the thing at point in the current issue buffer.
On the title: rename the issue.
On the opening post: replace the issue body.
On a comment you authored: edit that comment.
On someone else\\='s comment: signal an error."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (let ((target (octocat-timeline-target)))
    (cond
     ((eq target 'title) (octocat-issue-edit-title))
     ((eq target 'body)  (octocat-issue-edit-body))
     ((hash-table-p target)
      (let* ((authored   (eq (gethash "viewerDidAuthor" target) t))
             (comment-id (octocat--comment-numeric-id target))
             (body       (octocat--nonempty (gethash "body" target))))
        (unless authored
          (user-error "Octocat: You can't edit someone else's comment"))
        (unless comment-id
          (user-error "Octocat: Could not determine comment ID from URL"))
        (octocat-timeline-ensure-idle)
        (octocat--open-edit-buffer
         (format "Edit comment on issue #%d" octocat--issue-number)
         #'octocat-issue--submit-edit-comment
         #'ignore
         body
         (list :comment-id comment-id))))
     (t
      (user-error "Octocat: Nothing to edit here")))))

(defun octocat-issue-browse ()
  "Open the comment at point, or else the whole issue, in the browser."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (let* ((target (octocat-timeline-target))
         (url    (and (hash-table-p target) (gethash "url" target)))
         (gh     (executable-find "gh")))
    (cond
     ((stringp url)
      (message "Octocat: Opening comment in browser…")
      (octocat-browse-external url))
     (gh
      (message "Octocat: Opening issue #%d in browser…" octocat--issue-number)
      (start-process "octocat-browse" nil gh
                     "issue" "view" "--web"
                     (number-to-string octocat--issue-number)
                     "--repo" octocat--issue-repo))
     (t (user-error "Octocat: `gh' executable not found")))))

(defun octocat-issue--change-state (verb)
  "Close or reopen (VERB) the current issue, after asking."
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-timeline-state-change "issue" verb octocat--issue-repo
                                 octocat--issue-number))

(defun octocat-issue-close ()
  "Close the current issue, after asking."
  (interactive)
  (octocat-issue--change-state "close"))

(defun octocat-issue-reopen ()
  "Reopen the current issue, after asking."
  (interactive)
  (octocat-issue--change-state "reopen"))


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
                                          "labels,comments,url,assignees,milestone,"
                                          "closedByPullRequestsReferences"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))

;;;; Rendering
;;
;; The timeline itself (items, entries, rail) is in octocat-timeline.el.

(defun octocat-issue--header (repo issue bg)
  "Return the vnodes above the timeline: repo, title and labels of ISSUE in REPO.
BG is as for `octocat--label-face'."
  (let ((state (or (gethash "state" issue) "OPEN")))
    (append
     (octocat-repo-vui--detail-header
      repo issue (octocat-repo-vui--state-label state)
      #'octocat-issue-edit-title bg nil '(:comments))
     (list
      (octocat-repo-vui--detail-fields
       (list (cons "Assignees" (octocat-repo-vui--logins (gethash "assignees" issue)))
             (cons "Milestone" (octocat-repo-vui--milestone issue))
             (cons "Fixed by"  (octocat-repo-vui--numbers
                                repo (gethash "closedByPullRequestsReferences" issue)
                                #'octocat-pr-open))))
      (vui-newline)))))

(vui-defcomponent octocat-issue--page (repo number raw action)
  "Issue NUMBER of REPO as a timeline; RAW shows markdown bodies verbatim.
ACTION, a label or nil, shows a change under way under the timeline."
  :render
  (let* ((width  (octocat-vui-window-width))
         (bg     (octocat--label-background))
         (cached (vui-use-memo (repo number)
                   (octocat--detail-cache-load repo "issue" number)))
         (async  (vui-use-async (list 'issue repo number)
                   (lambda (resolve reject)
                     (octocat--fetch-issue
                      repo number
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (fresh  (and (eq (plist-get async :status) 'ready)
                      (plist-get async :data)))
         ;; Cached data shows until the fresh data arrives.
         (result (octocat-vui-with-stale async cached))
         (timeline (octocat-timeline-use-events repo number))
         (events   (car timeline))
         (loading  (or (eq (plist-get result :status) 'pending)
                       (plist-get result :refreshing)
                       (cdr timeline)))
         ;; WIDTH is a dependency: tables are laid out for the window.
         (entries  (vui-use-memo (result events raw width bg)
                     (and (eq (plist-get result :status) 'ready)
                          (octocat-timeline-entries
                           (octocat-timeline-items (plist-get result :data)
                                                   "opened this issue" events bg)
                           raw (octocat--markdown-width))))))
    (vui-use-effect (fresh)
      (when fresh (octocat--detail-cache-save repo "issue" number fresh))
      nil)
    (octocat-vui-use-mode-line-loading loading)
    (pcase (plist-get result :status)
      ('pending (vui-text (octocat-vui-detail-skeleton repo number width)))
      ('error   (vui-text (format "  Error: %s" (plist-get result :error)) :face 'error))
      ('ready
       (let ((issue (plist-get result :data)))
         (apply #'vui-vstack
                (append
                 (delq nil (octocat-issue--header repo issue bg))
                 entries
                 (octocat-timeline-buttons-or-action
                  (list '("+ Add a comment" "RET: write a comment" octocat-issue-add-comment)
                        (if (equal (gethash "state" issue) "OPEN")
                            '("Close issue" "RET: close this issue" octocat-issue-close)
                          '("Reopen issue" "RET: reopen this issue" octocat-issue-reopen)))
                  action))))))))


;;;; Major mode

(defvar octocat-issue-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-issue-mode'.")
(define-key octocat-issue-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-issue-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-issue-mode-map (kbd "C-c C-o") #'octocat-issue-browse)
(define-key octocat-issue-mode-map (kbd "C-c C-a") #'octocat-issue-add-comment)
(define-key octocat-issue-mode-map (kbd "C-c C-e") #'octocat-issue-edit)
(define-key octocat-issue-mode-map (kbd "C-c C-v") #'octocat-toggle-markdown)
(define-key octocat-issue-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-issue-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-issue-mode vui-mode "Octocat-Issue"
  "Major mode for viewing a GitHub Issue as a timeline.

\\{octocat-issue-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-issue-refresh)
  (setq-local octocat--refresh-fn #'octocat-issue-refresh)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup))


;;;; Refresh

(defun octocat-issue-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue buffer.
Mounts the vui.el page for the issue, which paints the disk cache at once
\(stale-while-revalidate) and then fetches fresh data in the background."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-issue--page
                              :repo octocat--issue-repo
                              :number octocat--issue-number
                              :raw octocat--markdown-raw
                              :action octocat-timeline--action)
               (buffer-name))))

(defun octocat-issue-open (repo number)
  "Show issue NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s issue %d*" repo number))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-issue-mode)
      (octocat-issue-mode))
    (setq octocat--issue-repo   repo
          octocat--issue-number number)
    (octocat-issue-refresh)))



;;;; Issue list page
;;
;; Opened by `M-x octocat-issue-list' (octocat.el); the page is
;; `octocat-vui-search-list'.

(defun octocat-issue-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue list buffer."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-preserving-view
    (let ((repo octocat-vui-list--repo)
          (bg   (octocat--label-background)))
      (vui-mount (vui-component 'octocat-vui-search-list
                                :repo repo
                                :kind 'issues
                                :query (octocat-vui-list-query)
                                :compact (octocat-vui-list-compact-p)
                                :row-fn (lambda (issue width compact)
                                          (octocat-repo-vui--issue-row
                                           repo issue width bg compact)))
                 (buffer-name)))))

(define-derived-mode octocat-issue-list-mode octocat-vui-list-mode "Octocat-Issues"
  "Major mode for the issue list of a repository.

\\{octocat-issue-list-mode-map}"
  :group 'octocat
  (setq-local octocat-vui-list--states '("open" "closed" "all"))
  (setq-local octocat-vui-list--view "issue-list")
  (setq-local revert-buffer-function #'octocat-issue-list-refresh))

(provide 'octocat-issue)
;;; octocat-issue.el ends here
