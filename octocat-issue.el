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
(defvar octocat-section-limit)
(declare-function octocat-repo-vui--issue-row "octocat-repo" (repo issue layout))
(declare-function octocat-repo-vui--cells "octocat-repo" (item current-branch repo))
(declare-function octocat-repo-vui--layout "octocat-repo" (cells width))
(declare-function octocat-repo-vui--state-label "octocat-repo" (state &optional draft))
(declare-function octocat-repo-vui--detail-header "octocat-repo" (repo number state title chips on-edit-title))
(declare-function octocat-repo-vui--detail-fields "octocat-repo" (fields))
(declare-function octocat-repo-vui--logins "octocat-repo" (users))
(declare-function octocat-repo-vui--numbers "octocat-repo" (refs))
(declare-function octocat-repo-vui--milestone "octocat-repo" (item))
(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))


;;;; Edit / comment commands — submit helpers

(defun octocat-issue--submit-comment (body source on-success on-error)
  "Submit BODY as a new comment on the issue in SOURCE buffer.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (with-current-buffer source
    (let ((repo octocat--issue-repo)
          (num  (number-to-string octocat--issue-number)))
      (octocat--run-gh "comment"
        (list "issue" "comment" num "--repo" repo "--body" body)
        (lambda (out) (string-trim out))
        (lambda (result)
          (if (eq (car-safe result) 'error)
              (funcall on-error (cdr result))
            (funcall on-success)))))))

(defun octocat-issue--submit-edit-body (body source on-success on-error)
  "Replace the body of the issue in SOURCE buffer with BODY.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (with-current-buffer source
    (let ((repo octocat--issue-repo)
          (num  (number-to-string octocat--issue-number)))
      (octocat--run-gh "edit-body"
        (list "issue" "edit" num "--repo" repo "--body" body)
        (lambda (out) (string-trim out))
        (lambda (result)
          (if (eq (car-safe result) 'error)
              (funcall on-error (cdr result))
            (funcall on-success)))))))

(defun octocat-issue--submit-edit-comment (body source on-success on-error)
  "Edit the comment identified in `octocat-edit--user-data' with BODY.
The :comment-id plist key is read from the edit buffer (current-buffer at
call time).  SOURCE supplies the repo string.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (let ((repo       (with-current-buffer source octocat--issue-repo))
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

(defun octocat-issue-add-comment ()
  "Open an edit buffer to add a comment to the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat--open-edit-buffer
   (format "New comment on issue #%d" octocat--issue-number)
   #'octocat-issue--submit-comment
   #'octocat-issue-refresh))

(defun octocat-issue-edit-body ()
  "Open an edit buffer to replace the body of the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  ;; Pre-populate with the current body from the cache so the user can
  ;; edit in-place rather than retyping everything.
  (let* ((cache (octocat--detail-cache-load octocat--issue-repo "issue" octocat--issue-number))
         (body  (and cache (octocat--nonempty (gethash "body" cache)))))
    (octocat--open-edit-buffer
     (format "Edit body of issue #%d" octocat--issue-number)
     #'octocat-issue--submit-edit-body
     #'octocat-issue-refresh
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
        (octocat--run-gh
         "edit-title"
         (list "issue" "edit" (number-to-string num) "--repo" repo "--title" new)
         #'identity
         (lambda (result)
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
        (octocat--open-edit-buffer
         (format "Edit comment on issue #%d" octocat--issue-number)
         #'octocat-issue--submit-edit-comment
         #'octocat-issue-refresh
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
      (browse-url url))
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
                                 octocat--issue-number #'octocat-issue-refresh))

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

(defun octocat--list-issues (repo limit callback &optional query)
  "Fetch up to LIMIT issues for REPO asynchronously and call CALLBACK.
QUERY is a GitHub search query (see `octocat--filter-args'); by default
only open issues are listed.
CALLBACK is called with a list of issue hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "issues"
                   (append (list "issue" "list"
                                 "--repo" repo)
                           (octocat--filter-args query)
                           (list "--limit" (number-to-string limit)
                                 "--json" "number,title,author,state,labels,createdAt,comments,closedByPullRequestsReferences"))
                   #'octocat--parse-json-list
                   callback))

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

(defun octocat-issue--header (repo issue)
  "Return the vnodes above the timeline: repo, title and labels of ISSUE in REPO."
  (let* ((number (gethash "number" issue))
         (state  (or (gethash "state" issue) "OPEN"))
         (title  (or (gethash "title" issue) ""))
         (chips  (octocat--format-labels (octocat-timeline--get issue "labels"))))
    (append
     (octocat-repo-vui--detail-header
      repo number (octocat-repo-vui--state-label state) title chips
      #'octocat-issue-edit-title)
     (list
      (octocat-repo-vui--detail-fields
       (list (cons "Assignees" (octocat-repo-vui--logins (gethash "assignees" issue)))
             (cons "Milestone" (octocat-repo-vui--milestone issue))
             (cons "Fixed by"  (octocat-repo-vui--numbers
                                (gethash "closedByPullRequestsReferences" issue)))))))))

(vui-defcomponent octocat-issue--page (repo number raw)
  "Issue NUMBER of REPO as a timeline; RAW shows markdown bodies verbatim."
  :state ((spin 0))
  :render
  (let* ((cached (vui-use-memo (repo number)
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
         (loading  (or (plist-get result :refreshing) (cdr timeline)))
         (entries  (vui-use-memo (result events raw)
                     (and (eq (plist-get result :status) 'ready)
                          (octocat-timeline-entries
                           (octocat-timeline-items (plist-get result :data)
                                                   "opened this issue" events)
                           raw)))))
    (vui-use-effect (fresh)
      (when fresh (octocat--detail-cache-save repo "issue" number fresh))
      nil)
    (octocat-vui-use-spinner loading)
    (pcase (plist-get result :status)
      ('pending (vui-text (concat "  " repo " #" (number-to-string number) "  (loading…)")
                          :face 'octocat-dimmed))
      ('error   (vui-text (format "  Error: %s" (plist-get result :error)) :face 'error))
      ('ready
       (let ((issue (plist-get result :data)))
         (apply #'vui-vstack
                (append
                 (delq nil (octocat-issue--header repo issue))
                 (list (vui-text (octocat-vui-loading-suffix
                                  (and loading '(:refreshing t)) spin))
                       (vui-newline))
                 entries
                 (octocat-timeline-buttons
                  (list '("+ Add a comment" "RET: write a comment" octocat-issue-add-comment)
                        (if (equal (gethash "state" issue) "OPEN")
                            '("Close issue" "RET: close this issue" octocat-issue-close)
                          '("Reopen issue" "RET: reopen this issue" octocat-issue-reopen)))
                  t))))))))


;;;; Major mode

(defvar octocat-issue-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-issue-mode'.")
(define-key octocat-issue-mode-map (kbd "q") #'quit-window)
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
  (setq-local octocat--refresh-fn #'octocat-issue-refresh))


;;;; Refresh

(defun octocat-issue-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue buffer.
Mounts the vui.el page for the issue, which paints the disk cache at once
(stale-while-revalidate) and then fetches fresh data in the background."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (vui-mount (vui-component 'octocat-issue--page
                            :repo octocat--issue-repo
                            :number octocat--issue-number
                            :raw octocat--markdown-raw)
             (buffer-name)))

(defun octocat-issue-open (repo number)
  "Show issue NUMBER of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*octocat-issue: %s#%d*" repo number))))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-issue-mode)
      (octocat-issue-mode))
    (setq octocat--issue-repo   repo
          octocat--issue-number number)
    (octocat-issue-refresh)))



;;;; Issue list page
;;
;; Opened by `M-x octocat-issues' (octocat.el).  vui.el-rendered like the
;; issue detail buffer above; see "UI frameworks" in CONTRIBUTING.md.

(vui-defcomponent octocat-issue--list-page (repo query)
  "Issue list page for REPO, narrowed by the search QUERY."
  :state ((limit octocat-section-limit) (win-width nil))
  :render
  (let* ((width  (octocat-vui-use-window-width))
         (id     (octocat--query-cache-id query))
         (cached (vui-use-memo (repo id) (octocat--items-cache-load repo "issues" id)))
         ;; Only the first page is cached; it shows until the fetch lands.
         (stale  (and (= limit octocat-section-limit) (plist-get cached :items)))
         (sticky (octocat-vui-use-async-sticky (list 'issues repo limit query)
                   (lambda (resolve reject)
                     (octocat--list-issues
                      repo limit
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))
                      query))))
         (fresh  (and (eq (plist-get sticky :status) 'ready)
                      (not (plist-get sticky :refreshing))
                      (plist-get sticky :data)))
         (result (octocat-vui-with-stale sticky stale)))
    (vui-use-effect (fresh)
      (when (and fresh (= limit octocat-section-limit))
        (octocat--items-cache-save repo "issues" id fresh))
      nil)
    (vui-vstack
     (vui-component 'octocat-vui-list-header
                    :repo repo :title "Issues" :kind 'issues
                    :loading (and (plist-get result :refreshing) t))
     (octocat-vui-list-filter-bar query)
     (pcase (plist-get result :status)
       ('pending (vui-text "(loading…)\n" :face 'octocat-dimmed))
       ('error   (vui-text (format "%s\n" (plist-get result :error)) :face 'octocat-dimmed))
       ('ready
        (let ((issues (plist-get result :data)))
          (vui-fragment
           (if (null issues)
               (vui-text (if (octocat-vui-list-filter-active-p query)
                             "(no issues match the filters)\n"
                           "(no issues)\n")
                         :face 'octocat-dimmed)
             (let ((layout (octocat-repo-vui--layout
                            (mapcar (lambda (issue)
                                      (octocat-repo-vui--cells issue nil repo))
                                    issues)
                            width)))
               (vui-list issues
                         (lambda (issue)
                           (octocat-repo-vui--issue-row repo issue layout))
                         (lambda (issue) (gethash "number" issue)))))
           (when (and issues
                      (or (>= (length issues) limit)
                          ;; Keep the button in place while a further page
                          ;; loads, but not for the first, cached paint.
                          (and (plist-get result :refreshing)
                               (> limit octocat-section-limit))))
             (octocat-vui-load-more-button
              'load-more-issues octocat-section-limit
              "RET: load more issues"
              (lambda () (vui-set-state :limit (+ limit octocat-section-limit)))
              (plist-get result :refreshing) 0)))))))))

(defun octocat-issue-list-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue list buffer."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (vui-mount (vui-component 'octocat-issue--list-page
                            :repo octocat-vui-list--repo
                            :query (octocat-vui-list-query))
             (buffer-name)))

(define-derived-mode octocat-issue-list-mode octocat-vui-list-mode "Octocat-Issues"
  "Major mode for the issue list of a repository.

\\{octocat-issue-list-mode-map}"
  :group 'octocat
  (setq-local octocat-vui-list--states '("open" "closed" "all"))
  (setq-local revert-buffer-function #'octocat-issue-list-refresh))

(provide 'octocat-issue)
;;; octocat-issue.el ends here
