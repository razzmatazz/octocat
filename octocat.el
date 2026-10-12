;;; octocat.el --- GitHub Client powered by the gh CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; Author: octocat.el contributors
;; Assisted-by: Claude:claude-sonnet-4-6
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (consult "1.0") (vui "0.1"))
;; Keywords: tools, vc, github
;; URL: https://github.com/octocat.el/octocat.el

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

;; Emacs client for GitHub, powered by the gh CLI.
;;
;; Entry points:
;;   M-x octocat      — GitHub account dashboard (recent repos, activity feed)
;;   M-x octocat-repo — Per-repository view (summary, Commits)
;;   M-x octocat-prs / octocat-issues / octocat-actions — list pages

;;; Code:

(require 'octocat-core)
(require 'octocat-pr)
(require 'octocat-commit)
(require 'octocat-pr-diff)
(require 'octocat-issue)
(require 'octocat-timeline)
(require 'octocat-workflow)
(require 'octocat-actions)
(require 'octocat-run)
(require 'octocat-job)
(require 'octocat-checks)
(require 'octocat-vui)
(require 'octocat-repo)
(require 'octocat-user)
(require 'octocat-tree)
(require 'octocat-search)

;; Buffer-locals of other files, used below.
(defvar octocat-repo--repo)           ; defined as buffer-local in octocat-repo.el
(defvar octocat-tree--repo)           ; defined as buffer-local in octocat-tree.el

;; Evil integration is optional; declare its entry point to silence the
;; byte-compiler when `octocat-evil' has not been loaded yet.
(declare-function octocat-evil-setup "octocat-evil" ())

;; Repo-mode entry point (defined in octocat-repo.el, already required).
(declare-function octocat-repo-refresh      "octocat-repo" (&optional _ignore-auto _noconfirm))
(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))
(declare-function octocat-repo--local-dir-for "octocat-repo" (repo))


;;;; Dashboard major mode

(defcustom octocat-feed-limit 15
  "Number of feed events to fetch initially on the dashboard.
Each `octocat-feed-load-more' call fetches this many additional events."
  :type 'integer
  :group 'octocat)

(defvar-local octocat--feed-limit nil
  "Per-buffer feed event fetch limit.
Starts at `octocat-feed-limit' and grows with `octocat-feed-load-more'.")

(defun octocat-dashboard-browse ()
  "Open the repository on the dashboard row at point in a browser.
Falls back to the user's GitHub page when point is not on a row."
  (interactive)
  (let ((repo (get-text-property (point) 'octocat-dashboard-repo)))
    (if repo
        (progn (message "Octocat: Opening %s in browser…" repo)
               (browse-url (format "https://github.com/%s" repo)))
      (message "Octocat: Opening GitHub in browser…")
      (browse-url "https://github.com"))))

(defvar octocat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-mode' (GitHub account dashboard).")
(define-key octocat-mode-map (kbd "q")       #'quit-window)
(define-key octocat-mode-map (kbd "g")       #'revert-buffer)
(define-key octocat-mode-map (kbd "+")       #'octocat-feed-load-more)
(define-key octocat-mode-map (kbd "C-c C-o") #'octocat-dashboard-browse)
(define-key octocat-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-mode-map (kbd "C-c C-s") #'octocat-search-repo)
(define-derived-mode octocat-mode vui-mode "Octocat"
  "Major mode for the GitHub account dashboard.

\\{octocat-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-refresh)
  (octocat--ts-eldoc-setup))


;;;; Dashboard cache

(defun octocat--dashboard-cache-file ()
  "Return the path to the dashboard-level cache file."
  (expand-file-name "dashboard.json" octocat-cache-directory))

(defun octocat--dashboard-cache-load ()
  "Load cached dashboard data from disk.
Returns a plist with keys :repos and :feed, or nil when the cache is
absent or cannot be parsed.  :repos is a list of hash-tables from the
GitHub REST user/repos endpoint.  :feed is a list of hash-tables from
the received_events endpoint."
  (let ((file (octocat--dashboard-cache-file)))
    (when (file-readable-p file)
      (condition-case nil
          (let* ((json (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))
                 (data  (json-parse-string json))
                 (repos (cl-coerce (or (gethash "repos" data) []) 'list))
                 (feed  (cl-coerce (or (gethash "feed"  data) []) 'list)))
            (list :repos repos :feed feed))
        (error nil)))))

(defun octocat--dashboard-cache-save (repos feed)
  "Persist REPOS and FEED lists to the dashboard cache file.
REPOS is a list of hash-tables from the user/repos API endpoint.
FEED is a list of hash-tables from the received_events API endpoint.
Skips silently when either argument is an error cons."
  (unless (or (eq (car-safe repos) 'error)
              (eq (car-safe feed)  'error))
    (let* ((file (octocat--dashboard-cache-file))
           (dir  (file-name-directory file))
           (obj  (let ((h (make-hash-table :test #'equal)))
                   (puthash "timestamp" (float-time)      h)
                   (puthash "repos"     (vconcat repos)   h)
                   (puthash "feed"      (vconcat feed)    h)
                   h)))
      (make-directory dir t)
      (condition-case nil
          (with-temp-file file
            (set-buffer-multibyte nil)
            (insert (json-serialize obj)))
        (error nil)))))


;;;; Dashboard fetch helpers

(defun octocat--fetch-recent-repos (callback)
  "Fetch the authenticated user's recently-pushed repos via gh.
Calls CALLBACK with a list of hash-tables (GitHub REST user/repos
response), or an (error . MSG) cons on failure."
  (octocat--run-gh
   "dashboard-repos"
   (list "api" "user/repos?sort=pushed&per_page=10")
   #'octocat--parse-json-list
   callback))

(defun octocat--fetch-viewer-login (callback)
  "Fetch the authenticated user's GitHub login via gh.
Calls CALLBACK with the login string, or an (error . MSG) cons."
  (octocat--run-gh
   "dashboard-login"
   (list "api" "user" "--jq" ".login")
   (lambda (output) (string-trim output))
   callback))

(defun octocat--fetch-received-events (login limit callback)
  "Fetch the received events feed for the user with LOGIN via gh.
LIMIT is the maximum number of events to request (per_page).
Calls CALLBACK with a list of hash-tables, or an (error . MSG) cons."
  (octocat--run-gh
   "dashboard-feed"
   (list "api" (format "users/%s/received_events?per_page=%d" login limit))
   #'octocat--parse-json-list
   callback))


;;;; Dashboard rendering helpers

(defun octocat--dashboard-event-icon (type)
  "Return a short propertized label string for dashboard feed event TYPE."
  (pcase type
    ("PushEvent"                    (propertize "push        " 'face 'octocat-dimmed))
    ("PullRequestEvent"             (propertize "pr          " 'face 'octocat-pr-state-open))
    ("IssueCommentEvent"            (propertize "comment     " 'face 'octocat-dimmed))
    ("IssuesEvent"                  (propertize "issue       " 'face 'octocat-dimmed))
    ("WatchEvent"                   (propertize "star        " 'face 'octocat-dimmed))
    ("ForkEvent"                    (propertize "fork        " 'face 'octocat-dimmed))
    ("CreateEvent"                  (propertize "create      " 'face 'octocat-dimmed))
    ("DeleteEvent"                  (propertize "delete      " 'face 'octocat-dimmed))
    ("ReleaseEvent"                 (propertize "release     " 'face 'octocat-dimmed))
    ("MemberEvent"                  (propertize "member      " 'face 'octocat-dimmed))
    ("GollumEvent"                  (propertize "wiki        " 'face 'octocat-dimmed))
    ("PullRequestReviewEvent"       (propertize "review      " 'face 'octocat-dimmed))
    ("PullRequestReviewCommentEvent" (propertize "review cmt  " 'face 'octocat-dimmed))
    ("CommitCommentEvent"           (propertize "cmt comment " 'face 'octocat-dimmed))
    ("PublicEvent"                  (propertize "public      " 'face 'octocat-dimmed))
    ("SponsorshipEvent"             (propertize "sponsor     " 'face 'octocat-dimmed))
    (_                              (propertize (format "%-12s" (or type "event"))
                                               'face 'octocat-dimmed))))

(defun octocat--dashboard-event-detail (event)
  "Return a short human-readable detail string for feed EVENT hash-table.
EVENT is a hash-table from the GitHub received_events REST endpoint.
The detail text is derived from the event type and payload fields."
  (let* ((type    (or (gethash "type"    event) ""))
         (payload (or (gethash "payload" event) (make-hash-table)))
         (action  (and (hash-table-p payload)
                       (octocat--nonempty (gethash "action" payload)))))
    (pcase type
      ("PushEvent"
       ;; The /received_events API omits commits[] and size for watched
       ;; repos — only ref, head, and before are provided.  Show the branch
       ;; and a short SHA instead of an unreliable commit count.
       (let* ((ref    (and (hash-table-p payload)
                           (octocat--nonempty (gethash "ref" payload))))
              (branch (if ref
                          (replace-regexp-in-string "^refs/heads/" "" ref)
                        "?"))
              (head   (and (hash-table-p payload)
                           (octocat--nonempty (gethash "head" payload))))
              (short  (and head (substring head 0 (min 7 (length head))))))
         (if short
             (format "pushed to %s (%s)" branch short)
           (format "pushed to %s" branch))))
      ("PullRequestEvent"
       (let* ((pr     (and (hash-table-p payload) (gethash "pull_request" payload)))
              (title  (and (hash-table-p pr) (octocat--nonempty (gethash "title" pr))))
              (number (and (hash-table-p pr) (gethash "number" pr))))
         (format "%s PR%s%s"
                 (or action "opened")
                 (if number (format " #%d" number) "")
                 (if title (format ": %s" (truncate-string-to-width title 30 nil nil "…")) ""))))
      ("IssuesEvent"
       (let* ((issue  (and (hash-table-p payload) (gethash "issue" payload)))
              (number (and (hash-table-p issue) (gethash "number" issue)))
              (title  (and (hash-table-p issue)
                           (octocat--nonempty (gethash "title" issue)))))
         (format "%s issue%s%s"
                 (or action "opened")
                 (if number (format " #%d" number) "")
                 (if title (format ": %s" (truncate-string-to-width title 35 nil nil "…")) ""))))
      ("IssueCommentEvent"
       (let* ((issue  (and (hash-table-p payload) (gethash "issue" payload)))
              (number (and (hash-table-p issue) (gethash "number" issue)))
              (title  (and (hash-table-p issue)
                           (octocat--nonempty (gethash "title" issue)))))
         (format "commented on issue%s%s"
                 (if number (format " #%d" number) "")
                 (if title (format ": %s" (truncate-string-to-width title 30 nil nil "…")) ""))))
      ("WatchEvent"   "starred")
      ("ForkEvent"    "forked")
      ("PullRequestReviewEvent"
       (let* ((pr     (and (hash-table-p payload) (gethash "pull_request" payload)))
              (number (and (hash-table-p pr) (gethash "number" pr)))
              (state  (and (hash-table-p payload)
                           (octocat--nonempty (gethash "state" payload)))))
         (format "reviewed PR%s%s"
                 (if number (format " #%d" number) "")
                 (if state (format " (%s)" state) ""))))
      ("PullRequestReviewCommentEvent"
       (let* ((pr     (and (hash-table-p payload) (gethash "pull_request" payload)))
              (number (and (hash-table-p pr) (gethash "number" pr))))
         (format "commented on PR%s review"
                 (if number (format " #%d" number) ""))))
      ("CommitCommentEvent"
       (let* ((comment (and (hash-table-p payload) (gethash "comment" payload)))
              (sha     (and (hash-table-p comment)
                            (octocat--nonempty (gethash "commit_id" comment)))))
         (format "commented on commit%s"
                 (if sha (format " %.7s" sha) ""))))
      ("GollumEvent"
       (let* ((pages (and (hash-table-p payload) (gethash "pages" payload)))
              (page  (and (vectorp pages) (> (length pages) 0) (aref pages 0)))
              (title (and (hash-table-p page)
                          (octocat--nonempty (gethash "title" page)))))
         (format "edited wiki%s" (if title (format ": %s" title) ""))))
      ("CreateEvent"
       (let ((ref-type (and (hash-table-p payload)
                            (octocat--nonempty (gethash "ref_type" payload)))))
         (format "created %s" (or ref-type "branch"))))
      ("DeleteEvent"
       (let ((ref-type (and (hash-table-p payload)
                            (octocat--nonempty (gethash "ref_type" payload)))))
         (format "deleted %s" (or ref-type "branch"))))
      ("ReleaseEvent"
       (let* ((release (and (hash-table-p payload) (gethash "release" payload)))
              (tag     (and (hash-table-p release)
                            (octocat--nonempty (gethash "tag_name" release)))))
         (format "released%s" (if tag (format " %s" tag) ""))))
      ("MemberEvent"
       (format "%s member" (or action "added")))
      (_
       (or action type "event")))))

(defun octocat--dashboard-visit-event (ev)
  "Open the buffer that best matches feed event EV.
Dispatches on the event type:
  PushEvent                       → octocat-commit for the head SHA
  PullRequestEvent / Review*      → octocat-pr for the PR number
  IssuesEvent / IssueCommentEvent → octocat-issue for the issue number
  everything else                 → octocat-repo for the repo"
  (let* ((type      (and (hash-table-p ev) (gethash "type" ev)))
         (repo-obj  (and (hash-table-p ev) (gethash "repo" ev)))
         (full-name (and (hash-table-p repo-obj)
                         (octocat--nonempty (gethash "name" repo-obj))))
         (payload   (and (hash-table-p ev) (gethash "payload" ev))))
    (cond
     ((not full-name)
      (message "Octocat: No repository associated with this event"))
     ((equal type "PushEvent")
      (octocat-commit-open
       full-name
       (or (and (hash-table-p payload)
                (octocat--nonempty (gethash "head" payload)))
           "")))
     ((member type '("PullRequestEvent"
                     "PullRequestReviewEvent"
                     "PullRequestReviewCommentEvent"))
      (let* ((pr-obj (and (hash-table-p payload)
                          (gethash "pull_request" payload)))
             (number (or (and (hash-table-p payload)
                              (gethash "number" payload))
                         (and (hash-table-p pr-obj)
                              (gethash "number" pr-obj)))))
        (if number
            (octocat-pr-open full-name number)
          (message "Octocat: No PR number in event payload"))))
     ((member type '("IssuesEvent" "IssueCommentEvent"))
      (let* ((issue-obj (and (hash-table-p payload)
                             (gethash "issue" payload)))
             (number    (and (hash-table-p issue-obj)
                             (gethash "number" issue-obj))))
        (if number
            (octocat-issue-open full-name number)
          (message "Octocat: No issue number in event payload"))))
     (t (octocat-visit-repo full-name)))))

(defun octocat--dashboard-repo-row (r)
  "Return the RET-able row vnode for repo hash-table R."
  (let* ((full-name (or (gethash "full_name" r) ""))
         (desc      (octocat--nonempty (gethash "description" r)))
         (lang      (or (octocat--nonempty (gethash "language" r)) ""))
         (date      (octocat--format-ts-relative (or (gethash "pushed_at" r) ""))))
    (octocat-vui-row
     (propertize
      (concat (propertize (format "  %-35s" full-name) 'face 'octocat-repo)
              (propertize (format "  %-14s" lang) 'face 'octocat-dimmed)
              (propertize (format "  %-12s" date) 'face 'octocat-dimmed)
              (propertize (format "  %s" (or desc "")) 'face 'octocat-dimmed))
      'octocat-dashboard-repo full-name)
     (lambda () (octocat-visit-repo full-name))
     "RET: open repo  C-c C-o: browse on GitHub")))

(defun octocat--dashboard-feed-row (ev)
  "Return the RET-able row vnode for feed event hash-table EV."
  (let* ((type   (or (gethash "type" ev) ""))
         (actor  (let ((a (gethash "actor" ev)))
                   (if (hash-table-p a) (or (gethash "login" a) "") "")))
         (repo   (let ((r (gethash "repo" ev)))
                   (if (hash-table-p r) (or (gethash "name" r) "") "")))
         (detail (octocat--dashboard-event-detail ev))
         (date   (octocat--format-ts-relative (or (gethash "created_at" ev) ""))))
    (octocat-vui-row
     (propertize
      (concat "  "
              (octocat--dashboard-event-icon type)
              "  "
              (propertize (format "%-16s" actor) 'face 'octocat-pr-author)
              "  "
              (propertize (format "%-35s" repo) 'face 'octocat-branch)
              "  "
              (octocat--format-title detail)
              "  "
              (propertize date 'face 'octocat-dimmed))
      'octocat-dashboard-repo (octocat--nonempty repo))
     (lambda () (octocat--dashboard-visit-event ev))
     "RET: open commit or repo  C-c C-o: browse repo on GitHub")))

(defun octocat--dashboard-section (title result empty rows)
  "Return a section vnode: heading TITLE, then the body for async RESULT.
EMPTY is the text shown when there is nothing to list, and ROWS a
function turning the loaded data into the vnode of its rows."
  (vui-vstack
   (vui-text title :face 'octocat-section-heading)
   (pcase (plist-get result :status)
     ('ready (let ((data (plist-get result :data)))
               (if (null data)
                   (vui-text (concat "  " empty) :face 'octocat-dimmed)
                 (funcall rows data))))
     ('error (vui-text (format "  %s" (plist-get result :error))
                       :face 'octocat-dimmed))
     (_      (vui-text "  Loading…" :face 'octocat-dimmed)))))

(vui-defcomponent octocat-dashboard--root (feed-limit)
  "Root component of the dashboard: recent repositories, then the feed.
FEED-LIMIT is how many feed events to fetch.  The disk cache shows until
the fresh data arrives (stale-while-revalidate)."
  :render
  (let* ((cached (vui-use-memo () (octocat--dashboard-cache-load)))
         (repos  (octocat-vui-use-async-sticky 'dashboard-repos
                   (lambda (resolve reject)
                     (octocat--fetch-recent-repos
                      (lambda (r) (octocat-repo-vui--resolve-or-reject
                                   r resolve reject))))))
         (feed   (octocat-vui-use-async-sticky (list 'dashboard-feed feed-limit)
                   (lambda (resolve reject)
                     (octocat--fetch-viewer-login
                      (lambda (login)
                        (if (eq (car-safe login) 'error)
                            (funcall reject (cdr login))
                          (octocat--fetch-received-events
                           login feed-limit
                           (lambda (r) (octocat-repo-vui--resolve-or-reject
                                        r resolve reject)))))))))
         (fresh-repos (and (eq (plist-get repos :status) 'ready)
                           (not (plist-get repos :refreshing))
                           (plist-get repos :data)))
         (fresh-feed  (and (eq (plist-get feed :status) 'ready)
                           (not (plist-get feed :refreshing))
                           (plist-get feed :data)))
         (repos  (octocat-vui-with-stale repos (plist-get cached :repos)))
         (feed   (octocat-vui-with-stale feed  (plist-get cached :feed)))
         (loading (and (or (memq 'pending (list (plist-get repos :status)
                                                (plist-get feed :status)))
                           (plist-get repos :refreshing)
                           (plist-get feed :refreshing))
                       t)))
    ;; Write the cache only once both calls have succeeded.
    (vui-use-effect (fresh-repos fresh-feed)
      (when (and fresh-repos fresh-feed)
        (octocat--dashboard-cache-save fresh-repos fresh-feed))
      nil)
    (octocat-vui-use-mode-line-loading loading)
    (vui-vstack
     (vui-text "GitHub Dashboard" :face 'octocat-repo)
     (octocat--dashboard-section
      "Recent Repositories" repos "(no repositories)"
      (lambda (data)
        (vui-list data #'octocat--dashboard-repo-row
                  (lambda (r) (gethash "full_name" r)))))
     (vui-newline)
     (octocat--dashboard-section
      "Feed" feed "(no recent activity)"
      (lambda (data)
        (vui-fragment
         (octocat-vui-reveal-list data #'octocat--dashboard-feed-row
                                  (lambda (ev) (gethash "id" ev)))
         (when (or (>= (length data) feed-limit)
                   ;; Keep the button in place while a further page
                   ;; loads (the limit has already grown), but not for
                   ;; the first, cached paint.
                   (and (plist-get feed :refreshing)
                        (> feed-limit octocat-feed-limit)))
           (octocat-vui-load-more-button
            'load-more-feed octocat-feed-limit
            "RET / +: load more feed events"
            #'octocat-feed-load-more
            (plist-get feed :refreshing)))))))))


;;;; Dashboard refresh

(defun octocat-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the octocat dashboard buffer.
Mounts the vui.el dashboard, which paints the disk cache at once and then
fetches the repositories and the feed in the background."
  (interactive)
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-dashboard--root
                              :feed-limit (or octocat--feed-limit
                                              octocat-feed-limit))
               (buffer-name))))



;;;; Feed load-more command

(defun octocat-feed-load-more ()
  "Fetch additional feed events in the dashboard buffer.
Increments the per-session feed fetch limit by `octocat-feed-limit' and
re-runs `octocat-refresh'."
  (interactive)
  (unless (derived-mode-p 'octocat-mode)
    (user-error "Octocat: Not in the dashboard buffer"))
  (unless octocat--feed-limit
    (setq octocat--feed-limit octocat-feed-limit))
  (cl-incf octocat--feed-limit octocat-feed-limit)
  (octocat-refresh))


;;;; Entry points
;;
;; All `;;;###autoload' commands live here, even when the mode/logic they
;; open is defined in another file (e.g. `octocat-repo' below only calls
;; into `octocat-repo.el').  This funnels every user-facing entry point
;; through this one file, guaranteeing `octocat--evil-init' (bottom of this
;; file) always runs on the very first octocat command of a session.  See
;; CONTRIBUTING.md, "Entry points", and
;; plans/repo-mode-evil-ret-binding.md for the bug this convention fixes.

;;;###autoload
(defun octocat ()
  "Open (or switch to) the octocat GitHub account dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*octocat*")))
    (switch-to-buffer buf)
    (unless (derived-mode-p 'octocat-mode)
      (octocat-mode))
    (octocat-refresh)))

;;;###autoload
(defun octocat-repo ()
  "Open (or switch to) the octocat-repo buffer for the current GitHub repository.
When invoked from inside a git working tree the buffer is opened in
\\='attached\\=' mode: `octocat-repo--local-dir' is set to the root of that
working tree, and the repo is derived from its \\='origin\\=' remote.
When invoked without a detectable working tree (or when the user supplies
a REPO argument in a future extension), the buffer runs in \\='detached\\='
mode with no local directory bound."
  (interactive)
  (let* ((repo     (octocat-repo--current-repo))
         (local-dir (locate-dominating-file default-directory ".git"))
         (buf-name (format "*octocat-repo: %s*" repo))
         (buf      (get-buffer-create buf-name)))
    (switch-to-buffer buf)
    (unless (derived-mode-p 'octocat-repo-mode)
      (octocat-repo-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (and local-dir
                                       (expand-file-name local-dir)))
    (octocat-repo-refresh)))

;;;###autoload
(defun octocat-user (login)
  "Open the page of the GitHub user or organization LOGIN, e.g. \"@octocat\".
With a nil or empty LOGIN, open the authenticated user's own page.
Interactively that is the default; with a prefix argument, prompt for
the handle instead (a leading \"@\" is optional)."
  (interactive
   (list (and current-prefix-arg
              (read-string "GitHub user or organization: "
                           (and (derived-mode-p 'octocat-user-mode)
                                octocat-user--login)))))
  (if (string-empty-p (string-trim (or login "")))
      (progn
        (message "Octocat: Looking up your GitHub login…")
        (octocat--fetch-viewer-login
         (lambda (result)
           (if (eq (car-safe result) 'error)
               (message "Octocat: Could not look up your login: %s" (cdr result))
             (octocat-user-open result)))))
    (octocat-user-open login)))

(defun octocat--open-list (mode name path &optional repo)
  "Open (or switch to) the list page for the current repository.
MODE is the list major mode to enable, NAME the prefix of the buffer
name, and PATH the github.com sub-path `octocat-vui-list-browse' opens.
REPO, an \"owner/name\" string, overrides the repository below.
Inside an octocat repo or list buffer the page is for that buffer's
repository and local clone; elsewhere the repository is derived from
the current git working tree."
  (let* ((repo      (cond (repo)
                          ((derived-mode-p 'octocat-repo-mode) octocat-repo--repo)
                          ((derived-mode-p 'octocat-vui-list-mode) octocat-vui-list--repo)
                          ((and (derived-mode-p 'octocat-tree-mode) octocat-tree--repo)
                           octocat-tree--repo)
                          (t (octocat-repo--current-repo))))
         (local-dir (if (derived-mode-p 'octocat-repo-mode)
                        octocat-repo--local-dir
                      (octocat-repo--local-dir-for repo)))
         (buf       (get-buffer-create (format "*octocat-%s: %s*" name repo))))
    (pop-to-buffer buf)
    (when local-dir
      (setq default-directory (file-name-as-directory local-dir)))
    (unless (derived-mode-p mode)
      (funcall mode))
    (setq octocat-vui-list--repo repo
          octocat-vui-list--path path)
    (funcall revert-buffer-function)))

;;;###autoload
(defun octocat-prs (&optional repo)
  "Open the pull request list for the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-pr-list-mode "pr-list" "pulls" repo))

;;;###autoload
(defun octocat-issues (&optional repo)
  "Open the issue list for the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-issue-list-mode "issue-list" "issues" repo))

;;;###autoload
(defun octocat-actions (&optional repo)
  "Open the Actions page for the current GitHub repository.
With REPO, an \"owner/name\" string, open it for that repository."
  (interactive)
  (octocat--open-list #'octocat-actions-mode "actions" "actions" repo))


;;;; Evil integration

(defun octocat--evil-init ()
  "Load and activate `octocat-evil' when Evil mode is enabled."
  (require 'octocat-evil)
  (octocat-evil-setup))

;; Run immediately if Evil is already active, otherwise hook into evil-mode.
(if (bound-and-true-p evil-mode)
    (octocat--evil-init)
  (add-hook 'evil-mode-hook #'octocat--evil-init))

(provide 'octocat)
;;; octocat.el ends here
