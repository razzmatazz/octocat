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

(require 'cl-lib)
(require 'seq)
(require 'octocat-core)
(require 'octocat-checks)
(require 'octocat-commit)
(require 'octocat-edit)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-list, vui-vstack, etc.

;; The PR page and the PR list page below reuse the row builder and fetch
;; plumbing from octocat-repo.el, which requires this file (so cannot be
;; required here).
(declare-function octocat-repo-vui--pr-row "octocat-repo" (repo pr width bg &optional compact))
(declare-function octocat-repo-vui--state-label"octocat-repo" (state &optional draft))
(declare-function octocat-repo-vui--detail-header "octocat-repo" (repo item state on-edit-title bg &optional branch omit))
(declare-function octocat-repo-vui--detail-fields "octocat-repo" (fields))
(declare-function octocat-repo-vui--logins "octocat-repo" (users))
(declare-function octocat-repo-vui--numbers "octocat-repo" (repo refs open))
(declare-function octocat-repo-vui--login-link "octocat-repo" (login))
(declare-function octocat-repo-vui--separate "octocat-repo" (items sep))
(declare-function octocat-issue-open "octocat-issue" (repo number))
(declare-function octocat-repo-vui--milestone "octocat-repo" (item))
(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))
(declare-function octocat-repo-vui--commit-row "octocat-repo"
                  (repo commit head-info author-w &optional subject-w))
(declare-function octocat-repo-vui--subject-width "octocat-repo" (commits width author-w))
(declare-function octocat-repo-vui--author-width "octocat-repo" (commits))

;; The views the PR page opens; octocat.el loads them all.
(declare-function octocat-checks-open  "octocat-checks"  (repo sha ref))
(declare-function octocat-pr-diff-open "octocat-pr-diff" (repo number))
(declare-function octocat-pr-diff-refresh "octocat-pr-diff" (&optional _ignore-auto _noconfirm))

;; Forward declarations for buffer-locals defined later in this file.
;; Needed so the byte-compiler doesn't warn about free variables in
;; rendering functions that run in `octocat-pr-mode' buffers.
(defvar octocat--pr-repo)
(defvar octocat--pr-number)

;;;; Edit / comment commands — submit helpers

(defun octocat-pr--submit-comment (body source on-success _on-error)
  "Submit BODY as a new comment on the PR in SOURCE buffer.
See `octocat-timeline-submit' for ON-SUCCESS."
  (octocat-timeline-submit
   "Posting comment…" "comment"
   (with-current-buffer source
     (list "pr" "comment" (number-to-string octocat--pr-number)
           "--repo" octocat--pr-repo "--body" body))
   body source on-success))

(defun octocat-pr--submit-edit-body (body source on-success _on-error)
  "Replace the body of the PR in SOURCE buffer with BODY.
See `octocat-timeline-submit' for ON-SUCCESS."
  (octocat-timeline-submit
   "Saving description…" "edit-body"
   (with-current-buffer source
     (list "pr" "edit" (number-to-string octocat--pr-number)
           "--repo" octocat--pr-repo "--body" body))
   body source on-success))

(defun octocat-pr--submit-edit-comment (body source on-success _on-error)
  "Edit the comment identified in `octocat-edit--user-data' with BODY.
The :comment-id plist key is read from the edit buffer (current-buffer at
call time).  SOURCE supplies the repo string.
See `octocat-timeline-submit' for ON-SUCCESS."
  (let ((repo       (with-current-buffer source octocat--pr-repo))
        (comment-id (plist-get octocat-edit--user-data :comment-id)))
    (octocat-timeline-submit
     "Saving comment…" "edit-comment"
     (list "api"
           (format "repos/%s/issues/comments/%s" repo comment-id)
           "--method" "PATCH"
           "-f" (format "body=%s" body))
     body source on-success)))

;;;; Edit / comment commands

(defun octocat-pr-add-comment ()
  "Open an edit buffer to add a comment to the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-timeline-ensure-idle)
  (octocat--open-edit-buffer
   (format "New comment on PR #%d" octocat--pr-number)
   #'octocat-pr--submit-comment
   #'ignore))

(defun octocat-pr-edit-body ()
  "Open an edit buffer to replace the body of the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-timeline-ensure-idle)
  ;; Pre-populate with the current body from the cache so the user can
  ;; edit in-place rather than retyping everything.
  (let* ((cache (octocat--detail-cache-load octocat--pr-repo "pr" octocat--pr-number))
         (body  (and cache (octocat--nonempty (gethash "body" cache)))))
    (octocat--open-edit-buffer
     (format "Edit body of PR #%d" octocat--pr-number)
     #'octocat-pr--submit-edit-body
     #'ignore
     body)))

(defun octocat-pr--rename (repo num refresh)
  "Prompt for a new title of pull request NUM of REPO and apply it.
REFRESH is the function that re-renders the current buffer afterwards;
it runs in that buffer, so the PR and PR diff pages can share this."
  (let* ((cache   (octocat--detail-cache-load repo "pr" num))
         (current (or (and cache (octocat--nonempty (gethash "title" cache))) ""))
         (new     (string-trim (read-string "PR title: " current)))
         (buf     (current-buffer)))
    (when (string-empty-p new)
      (user-error "Octocat: Title must not be empty"))
    (unless (string-equal new current)
      ;; In the mode line: the page has no button for this to replace.
      (octocat-vui-mode-line-action buf ":saving")
      (octocat--run-gh
       "edit-title"
       (list "pr" "edit" (number-to-string num) "--repo" repo "--title" new)
       #'identity
       (lambda (result)
         (octocat-vui-mode-line-action buf nil)
         (if (eq (car-safe result) 'error)
             (message "Octocat: failed to update title: %s" (cdr result))
           (when (buffer-live-p buf)
             (with-current-buffer buf (funcall refresh)))))))))

(defun octocat-pr-edit-title ()
  "Prompt in the minibuffer to rename the title of the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-pr--rename octocat--pr-repo octocat--pr-number #'octocat-pr-refresh))

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
        (octocat-timeline-ensure-idle)
        (octocat--open-edit-buffer
         (format "Edit comment on PR #%d" octocat--pr-number)
         #'octocat-pr--submit-edit-comment
         #'ignore
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
      (octocat-browse-external url))
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
                                 octocat--pr-number))

(defun octocat-pr-close ()
  "Close the current PR, after asking."
  (interactive)
  (octocat-pr--change-state "close"))

(defun octocat-pr-reopen ()
  "Reopen the current PR, after asking."
  (interactive)
  (octocat-pr--change-state "reopen"))


;;;; Merge

(defconst octocat-pr--merge-methods
  '(("Merge"  "--merge"  "mergeCommitAllowed")
    ("Squash" "--squash" "squashMergeAllowed")
    ("Rebase" "--rebase" "rebaseMergeAllowed"))
  "Merge methods: name, `gh pr merge' flag, and the repo field allowing it.")

(defun octocat-pr--merge-allowed (repo-info)
  "Return the names of the merge methods allowed by REPO-INFO, a hash-table."
  (delq nil (mapcar (lambda (m) (and (eq (gethash (nth 2 m) repo-info) t) (car m)))
                    octocat-pr--merge-methods)))

(defun octocat-pr--merge-message (method pr)
  "Return GitHub's default commit message for a METHOD merge of PR.
The first line is the subject; a rebase keeps the commits, so has none."
  (let ((number (gethash "number" pr))
        (title  (or (gethash "title" pr) "")))
    (pcase method
      ("Merge"
       (format "Merge pull request #%d from %s/%s\n\n%s" number
               (or (octocat--get pr "headRepositoryOwner" "login") "")
               (or (gethash "headRefName" pr) "")
               title))
      ("Squash"
       (concat (format "%s (#%d)" title number)
               (let ((commits (append (octocat--get pr "commits") nil)))
                 (and commits
                      (concat "\n\n"
                              (mapconcat (lambda (c)
                                           (concat "* " (or (gethash "messageHeadline" c) "")))
                                         commits "\n"))))))
      (_ ""))))

(defun octocat-pr--merge-args (repo number method text delete)
  "Return the `gh' arguments merging PR NUMBER of REPO by METHOD.
TEXT is the commit message, its first line the subject; a rebase has
none.  DELETE non-nil deletes the head branch as well."
  (let ((lines (split-string text "\n")))
    (append (list "pr" "merge" (number-to-string number) "--repo" repo
                  (nth 1 (assoc method octocat-pr--merge-methods)))
            (unless (equal method "Rebase")
              (list "--subject" (car lines)
                    "--body" (string-trim (mapconcat #'identity (cdr lines) "\n"))))
            (and delete (list "--delete-branch")))))

(defun octocat-pr--check-counts (rollup)
  "Return the outcome tally of ROLLUP: (FAILING PENDING SKIPPED SUCCESSFUL).
ROLLUP is a `statusCheckRollup' vector; outcomes are as in
`octocat--checks-ci-status'."
  (let ((counts (list 0 0 0 0)))
    (seq-doseq (c rollup)
      (let ((outcome (upcase (or (octocat--nonempty (gethash "conclusion" c))
                                 (octocat--nonempty (gethash "state" c))
                                 "PENDING"))))
        (cl-incf (nth (cond ((member outcome '("SUCCESS" "NEUTRAL")) 3)
                            ((equal outcome "SKIPPED") 2)
                            ((member outcome '("PENDING" "EXPECTED" "QUEUED"
                                               "IN_PROGRESS" "WAITING"))
                             1)
                            (t 0))
                      counts))))
    counts))

(defun octocat-pr--merge-icon (kind)
  "Return the merge box icon of KIND: `ok', `fail' or `wait'."
  (pcase kind
    ('ok   (propertize "✓" 'face 'octocat-ci-success))
    ('fail (propertize "✗" 'face 'octocat-ci-failure))
    (_     (propertize "●" 'face 'octocat-ci-pending))))

(defun octocat-pr--merge-rows (pr)
  "Return the status rows of PR's merge box, as GitHub words them.
Each is (KIND TITLE SUBTITLE CHECKS), KIND as for `octocat-pr--merge-icon'
and SUBTITLE nil or a line under TITLE; CHECKS marks the row of the
checks, under which they are listed."
  (let* ((checks  (or (octocat--get pr "statusCheckRollup") []))
         (counts  (octocat-pr--check-counts checks))
         (approvals (seq-count (lambda (r) (equal (gethash "state" r) "APPROVED"))
                               (or (octocat--get pr "latestReviews") []))))
    (delq nil
     (list
      (pcase (octocat--get pr "reviewDecision")
        ("APPROVED"
         (list 'ok "Changes approved"
               (format "%d approving review%s" approvals (if (= approvals 1) "" "s"))))
        ("CHANGES_REQUESTED"
         (list 'fail "Changes requested"
               "Changes must be addressed before merging."))
        ("REVIEW_REQUIRED"
         (list 'fail "Review required"
               "At least 1 approving review is required by reviewers with write access.")))
      (unless (zerop (length checks))
        (list (cond ((> (nth 0 counts) 0) 'fail) ((> (nth 1 counts) 0) 'wait) (t 'ok))
              (cond ((> (nth 0 counts) 0) "Some checks were not successful")
                    ((> (nth 1 counts) 0) "Some checks haven't completed yet")
                    (t "All checks have passed"))
              (concat (mapconcat #'identity
                                 (delq nil (cl-mapcar (lambda (n label)
                                                        (and (> n 0) (format "%d %s" n label)))
                                                      counts
                                                      '("failing" "in progress" "skipped" "successful")))
                                 ", ")
                      (if (= (length checks) 1) " check" " checks"))
              t))
      (cond
       ((octocat-pr--conflicts-p pr)
        (list 'fail "This branch has conflicts that must be resolved"
              "Use the web editor or the command line to resolve conflicts."))
       ((equal (octocat--get pr "mergeStateStatus") "BEHIND")
        (list 'wait "This branch is out-of-date with the base branch"
              (format "Merge the latest changes from %s into this branch."
                      (or (gethash "baseRefName" pr) "the base branch"))))
       ((equal (octocat--get pr "mergeable") "MERGEABLE")
        (list 'ok "No conflicts with base branch"))
       (t (list 'wait "Checking for the ability to merge automatically…")))))))

(defun octocat-pr--conflicts-p (pr)
  "Return non-nil when PR conflicts with its base branch."
  (or (equal (octocat--get pr "mergeable") "CONFLICTING")
      (equal (octocat--get pr "mergeStateStatus") "DIRTY")))

(defun octocat-pr--merge-refusal (pr)
  "Return why PR cannot be merged at all, or nil.
A blocked merge is not refused: it may pass with admin rights."
  (cond ((eq (gethash "isDraft" pr) t) "Draft pull requests cannot be merged.")
        ((octocat-pr--conflicts-p pr) "This branch has conflicts that must be resolved")))

(defun octocat-pr--merge-section (pr on-visit-check merging)
  "Return the vnodes of the merge box of open PR, or nil.
Like GitHub's, it holds the review, checks and conflict status, then
the merge (or, for a draft, the ready for review) button.
ON-VISIT-CHECK is called by RET on a check.  MERGING, a label such as
\"Merging pull request…\", shows a change under way in place of the
buttons."
  (when (equal (gethash "state" pr) "OPEN")
    (let ((draft  (eq (gethash "isDraft" pr) t))
          (checks (or (octocat--get pr "statusCheckRollup") [])))
      (append
       (list (vui-text "Merge" :face 'octocat-section-heading))
       (mapcan (lambda (row)
                 (pcase-let ((`(,kind ,title ,subtitle ,checks-p) row))
                   (delq nil
                         (list (vui-text (concat "  " (octocat-pr--merge-icon kind) " " title))
                               (and subtitle
                                    (vui-text (concat "    " subtitle) :face 'octocat-dimmed))
                               (and checks-p
                                    (octocat-checks-rows checks on-visit-check "    "))))))
               (octocat-pr--merge-rows pr))
       (list (vui-newline))
       (cond
        (merging
         (list (vui-text (concat "  " (octocat-vui-spinner) " " merging)
                         :face 'bold)))
        (draft
         (append
          (list (vui-text "  This pull request is still a work in progress" :face 'bold))
          (octocat-timeline-buttons
           '(("Ready for review" "RET: mark this pull request ready for review"
              octocat-pr-ready "Draft pull requests cannot be merged."))
           'tight)))
        (t
         (append
          (unless (octocat-pr--conflicts-p pr)
            (list
             (if (equal (octocat--get pr "mergeStateStatus") "BLOCKED")
                 (vui-text "  Merging is blocked" :face 'octocat-ci-failure)
               (vui-text "  Merging can be performed automatically."
                         :face 'octocat-merge-ready))))
          (octocat-timeline-buttons
           (list (and (not (octocat-pr--conflicts-p pr))
                      '("Merge pull request" "RET: merge this pull request"
                        octocat-pr-merge))
                 '("Convert to draft" "RET: convert this pull request to a draft"
                   octocat-pr-convert-to-draft "Still in progress?"))
           'tight))))))))

(defun octocat-pr--merge-data (method methods defaults delete)
  "Return the merge dialog's user data for METHOD, one of METHODS or nil.
DEFAULTS is an alist of each method's default message; DELETE whether
to delete the head branch."
  (list :method method :methods methods :defaults defaults :delete delete
        :allow-empty (member method '(nil "Rebase"))))

(defun octocat-pr--merge-header (title data)
  "Return the merge dialog's two header lines for TITLE with user DATA.
The first shows the choices, the second their keys: one line overflows
a narrow window."
  (let ((method (plist-get data :method))
        (key    (lambda (k) (propertize k 'face 'help-key-binding))))
    (list
     (concat "  " title "    "
             (mapconcat (lambda (m)
                          (if (equal m method)
                              (propertize (format "(•) %s" m) 'face 'bold)
                            (propertize (format "( ) %s" m) 'face 'octocat-dimmed)))
                        (plist-get data :methods) "  ")
             "    "
             (if (plist-get data :delete)
                 (propertize "[x] Delete branch" 'face 'bold)
               (propertize "[ ] Delete branch" 'face 'octocat-dimmed))
             (pcase method
               ('nil (propertize "    (pick a method)" 'face 'warning))
               ("Rebase" (propertize "    (message unused)" 'face 'octocat-dimmed))))
     (concat "  "
             (funcall key "C-c C-t") " method   "
             (funcall key "C-c C-d") " delete branch   "
             (funcall key "C-c C-c") " merge   "
             (funcall key "C-c C-k") " cancel"))))

(defun octocat-pr--merge-update (data)
  "Store DATA as the merge dialog's user data and redraw its header."
  (setq octocat-edit--user-data data)
  (let ((lines (octocat-pr--merge-header octocat-edit--title data)))
    ;; The tab line sits above the header line, giving a second line.
    (setq tab-line-format    (car lines)
          header-line-format (cadr lines)))
  (force-mode-line-update))

(defvar-local octocat-pr--merging nil
  "The merge box's change under way, such as \"Merging pull request…\", or nil.")

(defun octocat-pr--set-merging (buf merging)
  "Set BUF's merge box change under way to MERGING and show it in its page."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq octocat-pr--merging merging)
      (octocat-vui-update-page :merging merging))))

(defun octocat-pr--submit-merge (text source on-success on-error)
  "Merge the PR in SOURCE buffer with commit message TEXT.
The method and branch deletion are read from the edit buffer's user
data.  The dialog closes at once, through ON-SUCCESS, and SOURCE shows
the merge under way until it ends, so a slow GitHub does not block;
ON-ERROR is called only for a missing method."
  (let ((method (plist-get octocat-edit--user-data :method))
        (delete (plist-get octocat-edit--user-data :delete)))
    (if (not method)
        (funcall on-error (substitute-command-keys
                           "Pick a merge method with \\[octocat-pr-merge-cycle]"))
      (with-current-buffer source
        (let ((number octocat--pr-number))
          (setq octocat-pr--merging "Merging pull request…")
          (octocat--run-gh "merge"
            (octocat-pr--merge-args octocat--pr-repo number method text delete)
            #'string-trim
            (lambda (result)
              (if (eq (car-safe result) 'error)
                  (progn
                    (message "Octocat: Failed to merge PR #%d: %s" number (cdr result))
                    (octocat-pr--set-merging source nil))
                (message "Octocat: Merged PR #%d" number)
                (when (buffer-live-p source)
                  (with-current-buffer source
                    (setq octocat-pr--merging nil)
                    (octocat-pr-refresh))))))))
      (funcall on-success))))

(defun octocat-pr-merge-cycle ()
  "Switch the merge dialog to the next allowed method.
An unedited default message is replaced by the next method's."
  (interactive)
  (let* ((data     octocat-edit--user-data)
         (methods  (plist-get data :methods))
         (defaults (plist-get data :defaults))
         (method   (plist-get data :method))
         (next     (or (cadr (member method methods)) (car methods))))
    (when (equal (string-trim (buffer-string))
                 (string-trim (or (cdr (assoc method defaults)) "")))
      (erase-buffer)
      (insert (cdr (assoc next defaults)))
      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (octocat-pr--merge-update
     (octocat-pr--merge-data next methods defaults (plist-get data :delete)))))

(defun octocat-pr-merge-toggle-delete ()
  "Toggle whether the merge dialog deletes the head branch."
  (interactive)
  (let ((data octocat-edit--user-data))
    (octocat-pr--merge-update
     (plist-put (copy-sequence data) :delete (not (plist-get data :delete))))))

(defvar octocat-pr-merge-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'octocat-pr-merge-cycle)
    (define-key map (kbd "C-c C-d") #'octocat-pr-merge-toggle-delete)
    map)
  "Keymap for `octocat-pr-merge-mode'.")

;; A minor mode so the dialog keys live only in merge dialogs.
(define-minor-mode octocat-pr-merge-mode
  "Pick the method of a PR merge in its edit buffer."
  :keymap octocat-pr-merge-mode-map)

(defun octocat-pr--open-merge-dialog (pr methods delete)
  "Open the dialog merging PR (a hash-table) by one of METHODS.
DELETE is the initial choice to delete the head branch.
With several METHODS none is preselected, so a merge is never the
accidental choice."
  (let* ((title    (format "Merge PR #%d" octocat--pr-number))
         (defaults (mapcar (lambda (m) (cons m (octocat-pr--merge-message m pr)))
                           methods))
         (method   (and (null (cdr methods)) (car methods)))
         (data     (octocat-pr--merge-data method methods defaults delete))
         (win      (octocat--open-edit-buffer
                    title #'octocat-pr--submit-merge
                    (lambda (source) (octocat-pr--set-merging source "Merging pull request…"))
                    (cdr (assoc method defaults)) data)))
    (with-current-buffer (window-buffer win)
      (goto-char (point-min))
      ;; Draw the tab line used as a second header line like the header
      ;; line; themes style it for tabs, some hiding its text.
      (face-remap-set-base 'tab-line 'header-line)
      (octocat-pr-merge-mode 1)
      (octocat-pr--merge-update octocat-edit--user-data))))

(defun octocat-pr-merge ()
  "Open the dialog to merge the current PR.
Edit the commit message and pick the method with
\\<octocat-pr-merge-mode-map>\\[octocat-pr-merge-cycle]; submitting the dialog
is the confirmation."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (let* ((pr      (octocat--detail-cache-load octocat--pr-repo "pr" octocat--pr-number))
         (refusal (and pr (octocat-pr--merge-refusal pr)))
         (source  (current-buffer)))
    (cond
     ((not pr) (user-error "Octocat: PR not loaded yet"))
     (octocat-pr--merging (user-error "Octocat: Wait for \"%s\" to finish" octocat-pr--merging))
     ((not (equal (gethash "state" pr) "OPEN"))
      (user-error "Octocat: PR #%d is not open" octocat--pr-number))
     (refusal (user-error "Octocat: %s" refusal)))
    (message "Octocat: Fetching merge options…")
    (octocat--run-gh "merge-methods"
      (list "repo" "view" octocat--pr-repo "--json"
            (mapconcat #'identity
                       (cons "deleteBranchOnMerge"
                             (mapcar (lambda (m) (nth 2 m)) octocat-pr--merge-methods))
                       ","))
      (lambda (out) (json-parse-string (string-trim out)))
      (lambda (result)
        (let ((methods (and (hash-table-p result) (octocat-pr--merge-allowed result))))
          (cond
           ((eq (car-safe result) 'error)
            (message "Octocat: Failed to fetch merge options: %s" (cdr result)))
           ((not methods) (message "Octocat: The repo allows no merge method"))
           ((buffer-live-p source)
            (message nil)
            (with-current-buffer source
              (octocat-pr--open-merge-dialog
               pr methods (eq (gethash "deleteBranchOnMerge" result) t))))))))))

(defun octocat-pr--set-draft (draft)
  "Mark the current PR a draft if DRAFT, else ready for review."
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (when octocat-pr--merging
    (user-error "Octocat: Wait for \"%s\" to finish" octocat-pr--merging))
  (let ((buf    (current-buffer))
        (number octocat--pr-number))
    (octocat-pr--set-merging
     buf (if draft "Converting to draft…" "Marking ready for review…"))
    (octocat--run-gh "ready"
      (append (list "pr" "ready" (number-to-string number) "--repo" octocat--pr-repo)
              (and draft (list "--undo")))
      #'identity
      (lambda (result)
        (if (eq (car-safe result) 'error)
            (progn
              (message "Octocat: Failed to update PR #%d: %s" number (cdr result))
              (octocat-pr--set-merging buf nil))
          (message "Octocat: PR #%d %s" number
                   (if draft "converted to draft" "is ready for review"))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (setq octocat-pr--merging nil)
              (octocat-pr-refresh))))))))

(defun octocat-pr-ready ()
  "Mark the current draft PR ready for review."
  (interactive)
  (octocat-pr--set-draft nil))

(defun octocat-pr-convert-to-draft ()
  "Convert the current PR to a draft, after asking, as GitHub does."
  (interactive)
  (when (y-or-n-p (format "Convert PR #%d to draft? " octocat--pr-number))
    (octocat-pr--set-draft t)))


;;;; Data fetching

(defun octocat--fetch-pr (repo number callback)
  "Fetch detail for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of PR data, or a cons \\=(error . MSG)."
  (octocat--run-gh "pr"
                   (list "pr" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "number,title,author,state,body,"
                                          "createdAt,mergedAt,closedAt,"
                                          "baseRefName,headRefName,headRepositoryOwner,"
                                          "isDraft,mergeable,mergeStateStatus,"
                                          "changedFiles,"
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
  (let* ((commits  (or (octocat--get pr "commits") []))
         (head-oid (and (> (length commits) 0)
                        (gethash "oid" (aref commits (1- (length commits)))))))
    (mapcar
     (lambda (commit)
       (let* ((oid     (or (gethash "oid" commit) ""))
              (writers (octocat--get commit "authors"))
              (login   (and writers (> (length writers) 0)
                            (octocat--get (aref writers 0) "login"))))
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
       (list :time (or (octocat--get review "submittedAt") "")
             :kind 'review
             :actor (octocat--author-login review)
             :verb (pcase state
                     ("APPROVED"          "approved these changes")
                     ("CHANGES_REQUESTED" "requested changes")
                     ("DISMISSED"         "had a review dismissed")
                     (_                   "reviewed"))
             :body (or (octocat--get review "body") "")
             :state (downcase state))))
   (or (octocat--get pr "reviews") [])))

(defun octocat-pr--items (repo pr events bg)
  "Return the timeline items of PR in REPO, with its EVENTS (or nil).
BG is as for `octocat--label-face'."
  (octocat-timeline-items pr "opened this pull request" events bg
                          (append (octocat-pr--review-items pr)
                                  (octocat-pr--commit-items repo pr))))

(defun octocat-pr--head-sha (pr)
  "Return the SHA of the newest commit of PR (a hash-table), or nil."
  (let ((commits (octocat--get pr "commits")))
    (and commits (> (length commits) 0)
         (gethash "oid" (aref commits (1- (length commits)))))))

(defun octocat-pr--rest-commit (commit)
  "Return COMMIT of `gh pr view' shaped as the REST commits endpoint has it.
That is what `octocat-repo-vui--commit-row' reads."
  (let* ((writers (octocat--get commit "authors"))
         (writer  (and writers (> (length writers) 0) (aref writers 0)))
         (login   (and writer (octocat--nonempty (octocat--get writer "login"))))
         (c       (make-hash-table :test #'equal))
         (ca      (make-hash-table :test #'equal))
         (rest    (make-hash-table :test #'equal)))
    (puthash "name" (or (and writer (octocat--get writer "name")) "") ca)
    (puthash "date" (or (octocat--get commit "authoredDate") "") ca)
    (puthash "message" (or (octocat--get commit "messageHeadline") "") c)
    (puthash "author" ca c)
    (puthash "sha" (or (octocat--get commit "oid") "") rest)
    (puthash "commit" c rest)
    (puthash "author" (if login
                          (let ((u (make-hash-table :test #'equal)))
                            (puthash "login" login u)
                            u)
                        :null)
             rest)
    rest))

(defun octocat-pr--commit-days (pr)
  "Return the commits of PR grouped by local day, oldest first, as GitHub.
Each group is (HEADING . COMMITS), COMMITS shaped by
`octocat-pr--rest-commit'."
  (let (groups)
    (mapc (lambda (commit)
            (let* ((ts  (octocat--get commit "committedDate"))
                   (day (condition-case nil
                            (format-time-string "Commits on %b %-d, %Y" (date-to-time ts))
                          (error "Commits")))
                   (rest (octocat-pr--rest-commit commit)))
              (if (equal day (caar groups))
                  (push rest (cdar groups))
                (push (list day rest) groups))))
          (or (octocat--get pr "commits") []))
    (nreverse (mapcar (lambda (g) (cons (car g) (nreverse (cdr g)))) groups))))

(defun octocat-pr--tabs (current repo number width &optional files commits)
  "Return the \"Conversation | Commits | Files changed\" tab strip of a PR.
CURRENT is `conversation', `commits' or `files', the tab shown by this
buffer; the others open that page of pull request NUMBER of REPO.
FILES and COMMITS, when non-nil, are the counts shown on their tabs, as
GitHub does.  See `octocat-vui-tab-row' for WIDTH."
  (octocat-vui-tab-row
   (list (list "Conversation" "RET: show the conversation"
               (unless (eq current 'conversation)
                 (lambda () (octocat-pr-open repo number))))
         (list (if commits (format "Commits (%d)" commits) "Commits")
               "RET: show the commits"
               (unless (eq current 'commits)
                 (lambda () (octocat-pr-commits-open repo number))))
         (list (if files (format "Files changed (%d)" files) "Files changed")
               "RET: show the files changed"
               (unless (eq current 'files)
                 (lambda () (octocat-pr-diff-open repo number)))))
   width))

(defun octocat-pr--header (repo pr bg width &optional tab)
  "Return the vnodes above the body: repo, title, branches, labels, tabs.
PR is the hash-table of the pull request in REPO.  BG is as for
`octocat--label-face'.  WIDTH is that of the tabs, see `octocat-pr--tabs'.
TAB is the page showing it, `conversation' (the default), `commits' or
`files'."
  (let* ((number   (gethash "number" pr))
         (state    (or (gethash "state" pr) "OPEN"))
         (head    (or (gethash "headRefName" pr) ""))
         (base     (or (gethash "baseRefName" pr) ""))
         (local    (octocat--current-branch))
         (reviewers (octocat-pr--reviewers pr)))
    (append
     (octocat-repo-vui--detail-header
      repo pr
      (octocat-repo-vui--state-label state (gethash "isDraft" pr))
      (lambda ()
        (octocat-pr--rename repo number
                            (pcase tab
                              ('files   #'octocat-pr-diff-refresh)
                              ('commits #'octocat-pr-commits-refresh)
                              (_        #'octocat-pr-refresh))))
      bg
      ;; The list leaves the branch out; the page shows it and its base.
      (concat (propertize head 'face (if (equal head local)
                                         'octocat-branch-current
                                       'octocat-branch))
              (propertize " → " 'face 'octocat-dimmed)
              (propertize base 'face 'octocat-branch))
      ;; The checks and comments are further down the page.
      '(:ci :comments))
     (list
      (octocat-repo-vui--detail-fields
       (list (cons "Reviewers" reviewers)
             (cons "Assignees" (octocat-repo-vui--logins (gethash "assignees" pr)))
             (cons "Milestone" (octocat-repo-vui--milestone pr))
             (cons "Closes"    (octocat-repo-vui--numbers
                                repo (gethash "closingIssuesReferences" pr)
                                #'octocat-issue-open))))
      (vui-newline)
      (octocat-pr--tabs (or tab 'conversation) repo number width
                        (gethash "changedFiles" pr)
                        (length (or (octocat--get pr "commits") [])))))))

(defun octocat-pr--use-data (repo number)
  "Return the `vui-use-async' result for the pull request NUMBER of REPO.
The disk cache shows until the fresh data arrives (see
`octocat-vui-with-stale') and is updated from it.  Must be called during
render, like any hook; shared by the conversation and the diff page."
  (let* ((cached (vui-use-memo (repo number)
                   (octocat--detail-cache-load repo "pr" number)))
         (async  (vui-use-async (list 'pr repo number)
                   (lambda (resolve reject)
                     (octocat--fetch-pr
                      repo number
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (fresh  (and (eq (plist-get async :status) 'ready)
                      (plist-get async :data))))
    (vui-use-effect (fresh)
      (when fresh (octocat--detail-cache-save repo "pr" number fresh))
      nil)
    (octocat-vui-with-stale async cached)))

(defun octocat-pr--reviewers (pr)
  "Return the reviewers of PR as a list of vnodes, or nil when there are none.
Each is \"@login (state)\": the state of their latest review, or
\"pending\" for a requested review not yet given; the login opens the
user's page."
  (let* ((reviews  (octocat--get pr "latestReviews"))
         (requests (octocat--get pr "reviewRequests"))
         (reviewer (lambda (login name state)
                     (list (if (octocat--nonempty login)
                               (octocat-repo-vui--login-link login)
                             (vui-text (concat "@" (or name ""))))
                           (vui-text (format " (%s)" state)))))
         (parts
          (append
           (and (vectorp reviews)
                (mapcar (lambda (r)
                          (funcall reviewer
                                   (string-remove-prefix "@" (octocat--author-login r))
                                   nil
                                   (downcase (replace-regexp-in-string
                                              "_" " " (or (gethash "state" r) "")))))
                        reviews))
           (and (vectorp requests)
                (mapcar (lambda (u)
                          (funcall reviewer (gethash "login" u) (gethash "name" u)
                                   "pending"))
                        requests)))))
    (and parts (octocat-repo-vui--separate parts ", "))))

(vui-defcomponent octocat-pr--page (repo number raw merging action)
  "Pull request NUMBER of REPO as a timeline; RAW shows markdown verbatim.
MERGING and ACTION, labels or nil, show a change under way in the merge
box and under the timeline."
  :render
  (let* ((width  (octocat-vui-window-width))
         (bg     (octocat--label-background))
         (result (octocat-pr--use-data repo number))
         (timeline (octocat-timeline-use-events repo number))
         (events   (car timeline))
         (loading  (or (eq (plist-get result :status) 'pending)
                       (plist-get result :refreshing)
                       (cdr timeline)))
         ;; WIDTH is a dependency: tables are laid out for the window.
         (entries  (vui-use-memo (result events raw width bg)
                     (and (eq (plist-get result :status) 'ready)
                          (octocat-timeline-entries
                           (octocat-pr--items repo (plist-get result :data) events bg)
                           raw (octocat--markdown-width))))))
    (octocat-vui-use-mode-line-loading loading)
    (pcase (plist-get result :status)
      ('pending (vui-text (octocat-vui-detail-skeleton repo number width)))
      ('error   (vui-text (format "  Error: %s" (plist-get result :error)) :face 'error))
      ('ready
       (let* ((pr (plist-get result :data))
              (on-visit-check
               (lambda ()
                 (octocat-checks-open repo (or (octocat-pr--head-sha pr) "")
                                      (octocat--nonempty (gethash "headRefName" pr))))))
         (apply #'vui-vstack
                (append
                 (delq nil (octocat-pr--header repo pr bg (octocat--markdown-width)))
                 entries
                 ;; Under the timeline, as they add to it; the checks and
                 ;; merge are about the PR as a whole.
                 (octocat-timeline-buttons-or-action
                  (list '("+ Add a comment" "RET: write a comment" octocat-pr-add-comment)
                        (pcase (gethash "state" pr)
                          ("OPEN"   '("Close pull request" "RET: close this pull request"
                                      octocat-pr-close))
                          ("CLOSED" '("Reopen pull request" "RET: reopen this pull request"
                                      octocat-pr-reopen))))
                  action)
                 (list (vui-newline))
                 ;; An open PR's checks are in its merge box, as on GitHub.
                 (or (octocat-pr--merge-section pr on-visit-check merging)
                     (octocat-checks-block
                      (or (octocat--get pr "statusCheckRollup") [])
                      on-visit-check)))))))))


(vui-defcomponent octocat-pr-commits--page (repo number)
  "The commits of pull request NUMBER of REPO, under the PR page's header."
  :render
  (let* ((width  (octocat--markdown-width))
         (result (octocat-pr--use-data repo number))
         (days   (vui-use-memo ((plist-get result :data))
                   (octocat-pr--commit-days (plist-get result :data)))))
    (octocat-vui-use-mode-line-loading
     (or (eq (plist-get result :status) 'pending)
         (plist-get result :refreshing)))
    (pcase (plist-get result :status)
      ('pending (vui-text (octocat-vui-detail-skeleton repo number (octocat-vui-window-width))))
      ('error   (vui-vstack
                 (vui-text (format "Error: %s" (plist-get result :error)) :face 'error)
                 (octocat-pr--tabs 'commits repo number width)))
      ('ready
       (let* ((commits   (apply #'append (mapcar #'cdr days)))
              (author-w  (octocat-repo-vui--author-width commits))
              (subject-w (octocat-repo-vui--subject-width commits width author-w)))
         (apply #'vui-vstack
                (append
                 (delq nil (octocat-pr--header repo (plist-get result :data)
                                               (octocat--label-background) width 'commits))
                 (mapcan (lambda (day)
                           (cons (vui-text (car day) :face 'octocat-section-heading)
                                 (append
                                  (mapcar (lambda (c)
                                            (octocat-repo-vui--commit-row
                                             repo c nil author-w subject-w))
                                          (cdr day))
                                  (list (vui-newline)))))
                         days))))))))


;;;; Major mode

(defvar octocat-pr-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-pr-mode'.")
(define-key octocat-pr-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-pr-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-pr-mode-map (kbd "C-c C-o") #'octocat-pr-browse)
(define-key octocat-pr-mode-map (kbd "C-c C-a") #'octocat-pr-add-comment)
(define-key octocat-pr-mode-map (kbd "C-c C-e") #'octocat-pr-edit)
(define-key octocat-pr-mode-map (kbd "C-c C-m") #'octocat-pr-merge)
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
  (setq-local octocat--refresh-fn #'octocat-pr-refresh)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup))

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
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-pr--page
                              :repo octocat--pr-repo
                              :number octocat--pr-number
                              :raw octocat--markdown-raw
                              :action octocat-timeline--action
                              :merging octocat-pr--merging)
               (buffer-name))))

(defun octocat-pr-open (repo number)
  "Show pull request NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s pr %d*" repo number))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-pr-mode)
      (octocat-pr-mode))
    (setq octocat--pr-repo   repo
          octocat--pr-number number)
    (octocat-pr-refresh)))



;;;; Commits page

(defvar-local octocat--pr-commits-repo nil
  "The \"owner/repo\" this PR commits buffer belongs to.")

(defvar-local octocat--pr-commits-number nil
  "The PR number this buffer is listing the commits of.")

(defun octocat-pr-commits-browse ()
  "Open the commits of this pull request in a browser."
  (interactive)
  (unless (and octocat--pr-commits-repo octocat--pr-commits-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (message "Octocat: Opening PR #%d commits in browser…" octocat--pr-commits-number)
  (octocat-browse-external (format "https://github.com/%s/pull/%d/commits"
                                   octocat--pr-commits-repo octocat--pr-commits-number)))

(defvar octocat-pr-commits-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-pr-commits-mode'.")
(define-key octocat-pr-commits-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-pr-commits-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-pr-commits-mode-map (kbd "C-c C-o") #'octocat-pr-commits-browse)
(define-key octocat-pr-commits-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-pr-commits-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-pr-commits-mode vui-mode "Octocat-PR-Commits"
  "Major mode for the commits of a GitHub Pull Request.

\\{octocat-pr-commits-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-pr-commits-refresh)
  (setq-local octocat--refresh-fn #'octocat-pr-commits-refresh)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup))

(defun octocat-pr-commits-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR commits buffer."
  (interactive)
  (unless (and octocat--pr-commits-repo octocat--pr-commits-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-pr-commits--page
                              :repo octocat--pr-commits-repo
                              :number octocat--pr-commits-number)
               (buffer-name))))

(defun octocat-pr-commits-open (repo number)
  "Show the commits of pull request NUMBER of REPO in their own buffer."
  (let ((buf (get-buffer-create (format "*%s pr %d commits*" repo number))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-pr-commits-mode)
      (octocat-pr-commits-mode))
    (setq octocat--pr-commits-repo   repo
          octocat--pr-commits-number number)
    (octocat-pr-commits-refresh)))


;;;; PR list page
;;
;; Opened by `M-x octocat-pr-list' (octocat.el); the page is
;; `octocat-vui-search-list'.

(defun octocat-pr-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR list buffer."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-preserving-view
    (let ((repo octocat-vui-list--repo)
          (bg   (octocat--label-background)))
      (vui-mount (vui-component 'octocat-vui-search-list
                                :repo repo
                                :kind 'pulls
                                :query (octocat-vui-list-query)
                                :compact (octocat-vui-list-compact-p)
                                :row-fn (lambda (pr width compact)
                                          (octocat-repo-vui--pr-row
                                           repo pr width bg compact)))
                 (buffer-name)))))

(define-derived-mode octocat-pr-list-mode octocat-vui-list-mode "Octocat-PRs"
  "Major mode for the pull request list of a repository.

\\{octocat-pr-list-mode-map}"
  :group 'octocat
  (setq-local octocat-vui-list--states '("open" "closed" "merged" "all"))
  (setq-local octocat-vui-list--view "pr-list")
  (setq-local revert-buffer-function #'octocat-pr-list-refresh))

(provide 'octocat-pr)
;;; octocat-pr.el ends here
