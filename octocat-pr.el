;;; octocat-pr.el --- Pull Request detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; PR data fetching, the PR timeline view, and the octocat-pr-mode major
;; mode.  Like the issue view, the detail view is vui.el-rendered as a
;; GitHub-style timeline (octocat-timeline.el), here with reviews and
;; commits in it and the checks below it.  Depends on octocat-core.el for
;; shared infrastructure; must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-commit)
(require 'octocat-edit)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-list, vui-vstack, etc.

;; The PR page and the PR list page below reuse the row builder and fetch
;; plumbing from octocat-repo.el, which requires this file (so cannot be
;; required here).
(defvar octocat-section-limit)
(declare-function octocat-repo-vui--pr-row "octocat-repo" (repo pr current-branch layout))
(declare-function octocat-repo-vui--cells "octocat-repo" (item current-branch repo))
(declare-function octocat-repo-vui--layout "octocat-repo" (cells width))
(defvar octocat-repo-vui--state-width)  ; defconst in octocat-repo.el
(declare-function octocat-repo-vui--state-label"octocat-repo" (state &optional draft))
(declare-function octocat-repo-vui--detail-header "octocat-repo" (repo number state title chips on-edit-title))
(declare-function octocat-repo-vui--detail-fields "octocat-repo" (fields))
(declare-function octocat-repo-vui--logins "octocat-repo" (users))
(declare-function octocat-repo-vui--numbers "octocat-repo" (refs))
(declare-function octocat-repo-vui--milestone "octocat-repo" (item))
(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))

;; The views the PR page opens; octocat.el loads them all.
(declare-function octocat-checks-open  "octocat-checks"  (repo sha ref))
(declare-function octocat-pr-diff-open "octocat-pr-diff" (repo number))

;; Forward declarations for buffer-locals defined later in this file.
;; Needed so the byte-compiler doesn't warn about free variables in
;; rendering functions that run in `octocat-pr-mode' buffers.
(defvar octocat--pr-repo)
(defvar octocat--pr-number)

;;;; Edit / comment commands — submit helpers

(defun octocat-pr--submit-comment (body source on-success on-error)
  "Submit BODY as a new comment on the PR in SOURCE buffer.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (with-current-buffer source
    (let ((repo octocat--pr-repo)
          (num  (number-to-string octocat--pr-number)))
      (octocat--run-gh "comment"
        (list "pr" "comment" num "--repo" repo "--body" body)
        (lambda (out) (string-trim out))
        (lambda (result)
          (if (eq (car-safe result) 'error)
              (funcall on-error (cdr result))
            (funcall on-success)))))))

(defun octocat-pr--submit-edit-body (body source on-success on-error)
  "Replace the body of the PR in SOURCE buffer with BODY.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (with-current-buffer source
    (let ((repo octocat--pr-repo)
          (num  (number-to-string octocat--pr-number)))
      (octocat--run-gh "edit-body"
        (list "pr" "edit" num "--repo" repo "--body" body)
        (lambda (out) (string-trim out))
        (lambda (result)
          (if (eq (car-safe result) 'error)
              (funcall on-error (cdr result))
            (funcall on-success)))))))

(defun octocat-pr--submit-edit-comment (body source on-success on-error)
  "Edit the comment identified in `octocat-edit--user-data' with BODY.
The :comment-id plist key is read from the edit buffer (current-buffer at
call time).  SOURCE supplies the repo string.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (let ((repo       (with-current-buffer source octocat--pr-repo))
        (comment-id (plist-get octocat-edit--user-data :comment-id)))
    (octocat--run-gh "edit-comment"
      (list "api"
            (format "repos/%s/issues/comments/%s" repo comment-id)
            "--method" "PATCH"
            "-f" (format "body=%s" body))
      (lambda (out) (string-trim out))
      (lambda (result)
        (if (eq (car-safe result) 'error)
            (funcall on-error (cdr result))
          (funcall on-success))))))

;;;; Edit / comment commands

(defun octocat-pr-add-comment ()
  "Open an edit buffer to add a comment to the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat--open-edit-buffer
   (format "New comment on PR #%d" octocat--pr-number)
   #'octocat-pr--submit-comment
   #'octocat-pr-refresh))

(defun octocat-pr-edit-body ()
  "Open an edit buffer to replace the body of the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  ;; Pre-populate with the current body from the cache so the user can
  ;; edit in-place rather than retyping everything.
  (let* ((cache (octocat--detail-cache-load octocat--pr-repo "pr" octocat--pr-number))
         (body  (and cache (octocat--nonempty (gethash "body" cache)))))
    (octocat--open-edit-buffer
     (format "Edit body of PR #%d" octocat--pr-number)
     #'octocat-pr--submit-edit-body
     #'octocat-pr-refresh
     body)))

(defun octocat-pr-edit-title ()
  "Prompt in the minibuffer to rename the title of the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (let* ((cache   (octocat--detail-cache-load octocat--pr-repo "pr" octocat--pr-number))
         (current (or (and cache (octocat--nonempty (gethash "title" cache))) ""))
         (new     (string-trim (read-string "PR title: " current))))
    (when (string-empty-p new)
      (user-error "Octocat: Title must not be empty"))
    (unless (string-equal new current)
      (let ((repo octocat--pr-repo)
            (num  octocat--pr-number)
            (buf  (current-buffer)))
        (octocat--run-gh
         "edit-title"
         (list "pr" "edit" (number-to-string num) "--repo" repo "--title" new)
         #'identity
         (lambda (result)
           (if (eq (car-safe result) 'error)
               (message "Octocat: failed to update title: %s" (cdr result))
             (when (buffer-live-p buf)
               (with-current-buffer buf (octocat-pr-refresh))))))))))

(defun octocat-pr-edit ()
  "Edit the thing at point in the current PR buffer.
On the title: rename the PR.
On the opening post: replace the PR body.
On a comment you authored: edit that comment.
On someone else\\='s comment: signal an error."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (let ((target (octocat-timeline-target)))
    (cond
     ((eq target 'title) (octocat-pr-edit-title))
     ((eq target 'body)  (octocat-pr-edit-body))
     ((hash-table-p target)
      (let* ((authored   (eq (gethash "viewerDidAuthor" target) t))
             (comment-id (octocat--comment-numeric-id target))
             (body       (octocat--nonempty (gethash "body" target))))
        (unless authored
          (user-error "Octocat: You can't edit someone else's comment"))
        (unless comment-id
          (user-error "Octocat: Could not determine comment ID from URL"))
        (octocat--open-edit-buffer
         (format "Edit comment on PR #%d" octocat--pr-number)
         #'octocat-pr--submit-edit-comment
         #'octocat-pr-refresh
         body
         (list :comment-id comment-id))))
     (t
      (user-error "Octocat: Nothing to edit here")))))

(defun octocat-pr-browse ()
  "Open the comment at point, or else the whole PR, in the browser."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (let* ((target (octocat-timeline-target))
         (url    (and (hash-table-p target) (gethash "url" target)))
         (gh     (executable-find "gh")))
    (cond
     ((stringp url)
      (message "Octocat: Opening comment in browser…")
      (browse-url url))
     (gh
      (message "Octocat: Opening PR #%d in browser…" octocat--pr-number)
      (start-process "octocat-browse" nil gh
                     "pr" "view" "--web"
                     (number-to-string octocat--pr-number)
                     "--repo" octocat--pr-repo))
     (t (user-error "Octocat: `gh' executable not found")))))

(defun octocat-pr--change-state (verb)
  "Close or reopen (VERB) the current PR, after asking."
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-timeline-state-change "pr" verb octocat--pr-repo
                                 octocat--pr-number #'octocat-pr-refresh))

(defun octocat-pr-close ()
  "Close the current PR, after asking."
  (interactive)
  (octocat-pr--change-state "close"))

(defun octocat-pr-reopen ()
  "Reopen the current PR, after asking."
  (interactive)
  (octocat-pr--change-state "reopen"))


;;;; Data fetching

(defun octocat--list-prs (repo limit callback &optional query)
  "Fetch up to LIMIT PRs for REPO asynchronously and call CALLBACK.
QUERY is a GitHub search query (see `octocat--filter-args'); by default
only open PRs are listed.
CALLBACK is called with a list of PR hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "prs"
                   (append (list "pr" "list"
                                 "--repo" repo)
                           (octocat--filter-args query)
                           (list "--limit" (number-to-string limit)
                                 "--json" "number,title,author,state,isDraft,statusCheckRollup,headRefName,labels,createdAt,comments"))
                   #'octocat--parse-json-list
                   callback))

(defun octocat--fetch-pr (repo number callback)
  "Fetch detail for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of PR data, or a cons \\=(error . MSG)."
  (octocat--run-gh "pr"
                   (list "pr" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "number,title,author,state,body,"
                                          "createdAt,mergedAt,closedAt,"
                                          "baseRefName,headRefName,"
                                          "additions,deletions,changedFiles,"
                                          "labels,reviewDecision,reviews,"
                                          "comments,statusCheckRollup,url,commits,"
                                          "assignees,milestone,latestReviews,"
                                          "reviewRequests,closingIssuesReferences"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))


;;;; Rendering

(defun octocat-pr--commit-items (repo pr)
  "Return a timeline item for each commit of PR (a hash-table) in REPO.
Each is a RET-able line opening the commit; the newest commit also shows
the CI status."
  (let* ((commits  (or (octocat-timeline--get pr "commits") []))
         (head-oid (and (> (length commits) 0)
                        (gethash "oid" (aref commits (1- (length commits)))))))
    (mapcar
     (lambda (commit)
       (let* ((oid     (or (gethash "oid" commit) ""))
              (writers (octocat-timeline--get commit "authors"))
              (login   (and writers (> (length writers) 0)
                            (octocat-timeline--get (aref writers 0) "login"))))
         (list :time (or (gethash "committedDate" commit) "")
               :kind 'commit
               :actor (if login (concat "@" login) "")
               :text (concat "committed "
                             (propertize (substring oid 0 (min 7 (length oid)))
                                         'face 'octocat-commit-sha)
                             " " (or (gethash "messageHeadline" commit) ""))
               :suffix (and (equal oid head-oid) (concat "  " (octocat--ci-label pr)))
               :on-visit (lambda () (octocat-commit-open repo oid))
               :help "RET: view commit")))
     commits)))

(defun octocat-pr--review-items (pr)
  "Return a timeline item for each review of PR (a hash-table)."
  (mapcar
   (lambda (review)
     (let ((state (or (gethash "state" review) "")))
       (list :time (or (octocat-timeline--get review "submittedAt") "")
             :kind 'review
             :actor (octocat--author-login review)
             :verb (pcase state
                     ("APPROVED"          "approved these changes")
                     ("CHANGES_REQUESTED" "requested changes")
                     ("DISMISSED"         "had a review dismissed")
                     (_                   "reviewed"))
             :body (or (octocat-timeline--get review "body") "")
             :state (downcase state))))
   (or (octocat-timeline--get pr "reviews") [])))

(defun octocat-pr--items (repo pr events)
  "Return the timeline items of PR in REPO, with its EVENTS (or nil)."
  (octocat-timeline-items pr "opened this pull request" events
                          (append (octocat-pr--review-items pr)
                                  (octocat-pr--commit-items repo pr))))

(defun octocat-pr--head-sha (pr)
  "Return the SHA of the newest commit of PR (a hash-table), or nil."
  (let ((commits (octocat-timeline--get pr "commits")))
    (and commits (> (length commits) 0)
         (gethash "oid" (aref commits (1- (length commits)))))))

(defconst octocat-pr--check-column-max '(50 30)
  "Widest the name and workflow columns of the checks list grow.")

(defun octocat-pr--check-fields (check)
  "Return the text columns of status CHECK (a hash-table).
That is a list (NAME WORKFLOW DURATION STARTED), plain strings."
  (let ((started (octocat-timeline--get check "startedAt")))
    (list (or (gethash "name" check) "")
          (or (gethash "workflowName" check) "")
          (or (octocat--run-duration started (octocat-timeline--get check "completedAt")) "")
          (octocat--format-ts (or started "")))))

(defun octocat-pr--check-widths (checks)
  "Return the width of each column of CHECKS, the widest field in it.
The name and workflow columns stop at `octocat-pr--check-column-max'."
  (let ((widths (list 0 0 0 0)))
    (seq-doseq (check checks)
      (setq widths (cl-mapcar (lambda (w field) (max w (string-width field)))
                              widths (octocat-pr--check-fields check))))
    (cl-mapcar (lambda (w cap) (if cap (min w cap) w))
               widths (append octocat-pr--check-column-max '(nil nil)))))

(defun octocat-pr--check-row (repo pr check widths)
  "Return a RET-able vnode for the status CHECK (a hash-table) of PR in REPO.
WIDTHS are the column widths, as from `octocat-pr--check-widths'.  A
column no check has anything in takes no space."
  (let ((cells (cl-mapcar
                (lambda (field width face)
                  (and (> width 0)
                       (propertize (truncate-string-to-width field width nil ?\s "…")
                                   'face face)))
                (octocat-pr--check-fields check) widths
                '(nil octocat-dimmed octocat-dimmed octocat-dimmed))))
    (octocat-vui-row
     (string-trim-right
      (concat "  "
              (octocat--run-icon (or (gethash "status" check) "")
                                 (octocat-timeline--get check "conclusion"))
              " "
              (mapconcat #'identity (delq nil cells) "  ")))
     (lambda ()
       (octocat-checks-open repo (or (octocat-pr--head-sha pr) "")
                            (octocat--nonempty (gethash "headRefName" pr))))
     "RET: view checks for this commit")))

(defcustom octocat-pr-checks-shown 5
  "Number of a pull request's checks shown before the rest is folded away.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)

(defun octocat-pr--checks (repo pr)
  "Return the vnodes of the checks block of PR in REPO."
  (let* ((checks (or (octocat-timeline--get pr "statusCheckRollup") []))
         ;; From all checks, so unfolding the rest shifts no column.
         (widths (octocat-pr--check-widths checks)))
    (cons
     (vui-text (concat (propertize (format "Checks (%d)" (length checks))
                                   'face 'octocat-section-heading)
                       (unless (zerop (length checks))
                         (concat "  " (octocat--ci-label pr)))))
     (if (zerop (length checks))
         (list (vui-text (propertize "  (no checks)" 'face 'octocat-dimmed)))
       (list (vui-component
              'octocat-timeline-fold
              :total (length checks)
              :limit octocat-pr-checks-shown
              :noun "checks"
              :key 'checks-fold
              :prefix "  "
              :render (lambda (shown)
                        (apply #'vui-vstack
                               (cl-loop for check across checks
                                        repeat shown
                                        collect (octocat-pr--check-row repo pr check widths))))))))))

(defun octocat-pr--header (repo pr)
  "Return the vnodes above the timeline: repo, title, branches, labels, changes.
PR is the hash-table of the pull request in REPO."
  (let* ((number   (gethash "number" pr))
         (state    (or (gethash "state" pr) "OPEN"))
         (title    (or (gethash "title" pr) ""))
         (head     (or (gethash "headRefName" pr) ""))
         (base     (or (gethash "baseRefName" pr) ""))
         (local    (octocat--current-branch))
         (chips    (octocat--format-labels (octocat-timeline--get pr "labels")))
         (indent   (make-string (+ octocat-repo-vui--state-width 2) ?\s))
         (changes  (concat indent
                           (propertize "Changes" 'face 'octocat-dimmed) " "
                           (propertize (format "+%d" (or (gethash "additions" pr) 0))
                                       'face 'diff-added)
                           " "
                           (propertize (format "-%d" (or (gethash "deletions" pr) 0))
                                       'face 'diff-removed)
                           (propertize (format " across %d file(s)"
                                               (or (gethash "changedFiles" pr) 0))
                                       'face 'octocat-dimmed)))
         (reviewers (octocat-pr--reviewers pr)))
    (append
     (octocat-repo-vui--detail-header
      repo number
      (octocat-repo-vui--state-label state (gethash "isDraft" pr))
      title chips #'octocat-pr-edit-title)
     (list
      (vui-text (concat indent
                        (propertize head 'face (if (equal head local)
                                                   'octocat-branch-current
                                                 'octocat-branch))
                        (propertize " → " 'face 'octocat-dimmed)
                        (propertize base 'face 'octocat-branch)))
      (octocat-repo-vui--detail-fields
       (list (cons "Reviewers" reviewers)
             (cons "Assignees" (octocat-repo-vui--logins (gethash "assignees" pr)))
             (cons "Milestone" (octocat-repo-vui--milestone pr))
             (cons "Closes"    (octocat-repo-vui--numbers
                                (gethash "closingIssuesReferences" pr)))))
      (octocat-vui-row changes
                       (lambda () (octocat-pr-diff-open repo number))
                       "RET: open diff view")))))

(defun octocat-pr--reviewers (pr)
  "Return the reviewers of PR as one string, or nil when there are none.
Each is \"@login (state)\": the state of their latest review, or
\"pending\" for a requested review not yet given."
  (let* ((reviews  (octocat-timeline--get pr "latestReviews"))
         (requests (octocat-timeline--get pr "reviewRequests"))
         (parts
          (append
           (and (vectorp reviews)
                (mapcar (lambda (r)
                          (format "%s (%s)"
                                  (octocat--author-login r)
                                  (downcase (replace-regexp-in-string
                                             "_" " " (or (gethash "state" r) "")))))
                        reviews))
           (and (vectorp requests)
                (mapcar (lambda (u)
                          (format "@%s (pending)"
                                  (or (gethash "login" u) (gethash "name" u) "")))
                        requests)))))
    (and parts (mapconcat #'identity parts ", "))))

(vui-defcomponent octocat-pr--page (repo number raw)
  "Pull request NUMBER of REPO as a timeline; RAW shows markdown verbatim."
  :state ((spin 0) (win-width nil))
  :render
  (let* ((width  (octocat-vui-use-window-width))
         (cached (vui-use-memo (repo number)
                   (octocat--detail-cache-load repo "pr" number)))
         (async  (vui-use-async (list 'pr repo number)
                   (lambda (resolve reject)
                     (octocat--fetch-pr
                      repo number
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (fresh  (and (eq (plist-get async :status) 'ready)
                      (plist-get async :data)))
         ;; Cached data shows until the fresh data arrives.
         (result (octocat-vui-with-stale async cached))
         (timeline (octocat-timeline-use-events repo number))
         (events   (car timeline))
         (loading  (or (plist-get result :refreshing) (cdr timeline)))
         ;; WIDTH is a dependency: tables are laid out for the window.
         (entries  (vui-use-memo (result events raw width)
                     (and (eq (plist-get result :status) 'ready)
                          (octocat-timeline-entries
                           (octocat-pr--items repo (plist-get result :data) events)
                           raw)))))
    (vui-use-effect (fresh)
      (when fresh (octocat--detail-cache-save repo "pr" number fresh))
      nil)
    (octocat-vui-use-spinner loading)
    (pcase (plist-get result :status)
      ('pending (vui-text (concat "  " repo " #" (number-to-string number) "  (loading…)")
                          :face 'octocat-dimmed))
      ('error   (vui-text (format "  Error: %s" (plist-get result :error)) :face 'error))
      ('ready
       (let ((pr (plist-get result :data)))
         (apply #'vui-vstack
                (append
                 (delq nil (octocat-pr--header repo pr))
                 entries
                 ;; Shown only while loading, below the timeline, so the
                 ;; header and the opening post sit tight and never shift.
                 (and loading
                      (list (vui-text (octocat-vui-loading-suffix
                                       '(:refreshing t) spin))))
                 (list (vui-newline))
                 (octocat-pr--checks repo pr)
                 (octocat-timeline-buttons
                  (list '("+ Add a comment" "RET: write a comment" octocat-pr-add-comment)
                        (pcase (gethash "state" pr)
                          ("OPEN"   '("Close pull request" "RET: close this pull request"
                                      octocat-pr-close))
                          ("CLOSED" '("Reopen pull request" "RET: reopen this pull request"
                                      octocat-pr-reopen))))))))))))


;;;; Major mode

(defvar octocat-pr-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-pr-mode'.")
(define-key octocat-pr-mode-map (kbd "q") #'quit-window)
(define-key octocat-pr-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-pr-mode-map (kbd "C-c C-o") #'octocat-pr-browse)
(define-key octocat-pr-mode-map (kbd "C-c C-a") #'octocat-pr-add-comment)
(define-key octocat-pr-mode-map (kbd "C-c C-e") #'octocat-pr-edit)
(define-key octocat-pr-mode-map (kbd "C-c C-v") #'octocat-toggle-markdown)
(define-key octocat-pr-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-pr-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-pr-mode vui-mode "Octocat-PR"
  "Major mode for viewing a GitHub Pull Request as a timeline.

\\{octocat-pr-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-refresh)
  (setq-local octocat--refresh-fn #'octocat-pr-refresh))

(defvar-local octocat--pr-number nil
  "The PR number this buffer is displaying.")

(defvar-local octocat--pr-repo nil
  "The \"owner/repo\" this PR buffer belongs to.")


;;;; Refresh

(defun octocat-pr-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR buffer.
Mounts the vui.el page for the pull request, which paints the disk cache
at once (stale-while-revalidate) and then fetches fresh data in the
background."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (vui-mount (vui-component 'octocat-pr--page
                            :repo octocat--pr-repo
                            :number octocat--pr-number
                            :raw octocat--markdown-raw)
             (buffer-name)))

(defun octocat-pr-open (repo number)
  "Show pull request NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*octocat-pr: %s#%d*" repo number))))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-pr-mode)
      (octocat-pr-mode))
    (setq octocat--pr-repo   repo
          octocat--pr-number number)
    (octocat-pr-refresh)))



;;;; PR list page
;;
;; Opened by `M-x octocat-prs' (octocat.el).  vui.el-rendered like the PR
;; detail buffer above; see "UI frameworks" in CONTRIBUTING.md.

(vui-defcomponent octocat-pr--list-page (repo current-branch query)
  "Pull request list page for REPO, narrowed by the search QUERY."
  :state ((limit octocat-section-limit) (win-width nil))
  :render
  (let* ((width  (octocat-vui-use-window-width))
         (id     (octocat--query-cache-id query))
         (cached (vui-use-memo (repo id) (octocat--items-cache-load repo "prs" id)))
         ;; Only the first page is cached; it shows until the fetch lands.
         (stale  (and (= limit octocat-section-limit) (plist-get cached :items)))
         (sticky (octocat-vui-use-async-sticky (list 'prs repo limit query)
                   (lambda (resolve reject)
                     (octocat--list-prs
                      repo limit
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))
                      query))))
         (fresh  (and (eq (plist-get sticky :status) 'ready)
                      (not (plist-get sticky :refreshing))
                      (plist-get sticky :data)))
         (result (octocat-vui-with-stale sticky stale)))
    (vui-use-effect (fresh)
      (when (and fresh (= limit octocat-section-limit))
        (octocat--items-cache-save repo "prs" id fresh))
      nil)
    (vui-vstack
     (vui-component 'octocat-vui-list-header
                    :repo repo :title "Pull Requests" :kind 'pulls
                    :loading (and (plist-get result :refreshing) t))
     (octocat-vui-list-filter-bar query)
     (pcase (plist-get result :status)
       ('pending (vui-text "(loading…)\n" :face 'octocat-dimmed))
       ('error   (vui-text (format "%s\n" (plist-get result :error)) :face 'octocat-dimmed))
       ('ready
        (let ((prs (plist-get result :data)))
          (vui-fragment
           (if (null prs)
               (vui-text (if (octocat-vui-list-filter-active-p query)
                             "(no pull requests match the filters)\n"
                           "(no pull requests)\n")
                         :face 'octocat-dimmed)
             (let ((layout (octocat-repo-vui--layout
                            (mapcar (lambda (pr)
                                      (octocat-repo-vui--cells pr current-branch repo))
                                    prs)
                            width)))
               (vui-list prs
                         (lambda (pr)
                           (octocat-repo-vui--pr-row repo pr current-branch layout))
                         (lambda (pr) (gethash "number" pr)))))
           (when (and prs
                      (or (>= (length prs) limit)
                          ;; Keep the button in place while a further page
                          ;; loads, but not for the first, cached paint.
                          (and (plist-get result :refreshing)
                               (> limit octocat-section-limit))))
             (octocat-vui-load-more-button
              'load-more-prs octocat-section-limit
              "RET: load more pull requests"
              (lambda () (vui-set-state :limit (+ limit octocat-section-limit)))
              (plist-get result :refreshing) 0)))))))))

(defun octocat-pr-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR list buffer."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (vui-mount (vui-component 'octocat-pr--list-page
                            :repo octocat-vui-list--repo
                            :current-branch (plist-get (octocat--head-info) :branch)
                            :query (octocat-vui-list-query))
             (buffer-name)))

(define-derived-mode octocat-pr-list-mode octocat-vui-list-mode "Octocat-PRs"
  "Major mode for the pull request list of a repository.

\\{octocat-pr-list-mode-map}"
  :group 'octocat
  (setq-local octocat-vui-list--states '("open" "closed" "merged" "all"))
  (setq-local revert-buffer-function #'octocat-pr-list-refresh))

(provide 'octocat-pr)
;;; octocat-pr.el ends here
