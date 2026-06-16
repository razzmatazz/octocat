;;; octocat.el --- GitHub Client powered by the gh CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; Author: octocat.el contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "3.0") (markdown-mode "2.0"))
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
;;   M-x octocat-repo — Per-repository view (PRs, Issues, Workflows, Commits)

;;; Code:

(require 'octocat-core)
(require 'octocat-pr)
(require 'octocat-commit)
(require 'octocat-pr-diff)
(require 'octocat-issue)
(require 'octocat-workflow)
(require 'octocat-run)
(require 'octocat-job)
(require 'octocat-checks)
(require 'octocat-repo)

;; Forward declarations for sub-module buffer-locals referenced by
;; octocat-visit (defined here).  These silence the byte-compiler.
(defvar octocat--pr-repo)        ; defined as buffer-local in octocat-pr.el
(defvar octocat--pr-number)      ; defined as buffer-local in octocat-pr.el
(defvar octocat--pr-diff-repo)   ; defined as buffer-local in octocat-pr-diff.el
(defvar octocat--pr-diff-number) ; defined as buffer-local in octocat-pr-diff.el
(defvar octocat--issue-repo)     ; defined as buffer-local in octocat-issue.el
(defvar octocat--issue-number)   ; defined as buffer-local in octocat-issue.el
(defvar octocat--workflow-repo)  ; defined as buffer-local in octocat-workflow.el
(defvar octocat--workflow-id)    ; defined as buffer-local in octocat-workflow.el
(defvar octocat--workflow-name)  ; defined as buffer-local in octocat-workflow.el
(defvar octocat--run-repo)       ; defined as buffer-local in octocat-run.el
(defvar octocat--run-id)         ; defined as buffer-local in octocat-run.el
(defvar octocat--commit-repo)    ; defined as buffer-local in octocat-commit.el
(defvar octocat--commit-sha)     ; defined as buffer-local in octocat-commit.el
(defvar octocat--job-repo)       ; defined as buffer-local in octocat-job.el
(defvar octocat--job-run-id)     ; defined as buffer-local in octocat-job.el
(defvar octocat--job-id)         ; defined as buffer-local in octocat-job.el
(defvar octocat--job-name)       ; defined as buffer-local in octocat-job.el
(defvar octocat--checks-repo)    ; defined as buffer-local in octocat-checks.el
(defvar octocat--checks-sha)     ; defined as buffer-local in octocat-checks.el
(defvar octocat--checks-ref)     ; defined as buffer-local in octocat-checks.el

;; Also forward-declare octocat-repo--repo so octocat-visit can read it
;; when called from a repo buffer (it is defined as buffer-local in
;; octocat-repo.el which we already require, but the compiler may still
;; warn without this).
(defvar octocat-repo--repo)      ; defined as buffer-local in octocat-repo.el

;; Evil integration is optional; declare its entry point to silence the
;; byte-compiler when `octocat-evil' has not been loaded yet.
(declare-function octocat-evil-setup "octocat-evil" ())

;; Edit commands defined in octocat-pr.el / octocat-issue.el (already
;; loaded via `require' above, but declare here so octocat-visit can call
;; them without the byte-compiler warning about forward references).
(declare-function octocat-pr-edit-body         "octocat-pr"      ())
(declare-function octocat-pr-edit-title        "octocat-pr"      ())
(declare-function octocat-issue-edit-body      "octocat-issue"   ())
(declare-function octocat-issue-edit-title     "octocat-issue"   ())
(declare-function octocat--render-pr-diff-loading "octocat-pr-diff" (number))
(declare-function octocat-pr-diff-refresh      "octocat-pr-diff" (&optional _ignore-auto _noconfirm))
(declare-function octocat--render-checks-loading "octocat-checks" (sha))
(declare-function octocat-checks-refresh         "octocat-checks" (&optional _ignore-auto _noconfirm))
(declare-function octocat-checks-mode            "octocat-checks" ())
(declare-function octocat-commit-mode             "octocat-commit" ())
(declare-function octocat-commit-refresh          "octocat-commit" (&optional _ignore-auto _noconfirm))
(declare-function octocat--render-commit-loading  "octocat-commit" (sha))

;; Repo-mode entry point (defined in octocat-repo.el, already required).
(declare-function octocat-repo-refresh      "octocat-repo" (&optional _ignore-auto _noconfirm))
(declare-function octocat-repo--local-dir-for "octocat-repo" (repo))


;;;; Shared navigation commands

(defun octocat-visit ()
  "Open the detail view for the item at point."
  (interactive)
  (let ((section (magit-current-section)))
    (pcase (and section (oref section type))
      ('repo
       ;; Dashboard: open the per-repo buffer for the selected repo.
       ;; Attach to the current working tree when its origin matches.
       (let* ((full-name (oref section value))
              (buf-name  (format "*octocat-repo: %s*" full-name))
              (buf       (get-buffer-create buf-name)))
         (switch-to-buffer buf)
         (unless (derived-mode-p 'octocat-repo-mode)
           (octocat-repo-mode))
         (setq octocat-repo--repo      full-name
               octocat-repo--local-dir (octocat-repo--local-dir-for full-name))
         (octocat-repo-refresh)))
      ('pr
       (let* ((pr     (oref section value))
              (number (gethash "number" pr))
              (title  (or (gethash "title" pr) ""))
              (state  (or (gethash "state" pr) "OPEN"))
              (repo   (or octocat-repo--repo octocat--pr-repo))
              (buf-name (format "*octocat-pr: %s#%d*" repo number))
              (buf (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-pr-mode)
           (octocat-pr-mode))
         (setq octocat--pr-repo repo
               octocat--pr-number number)
         (octocat--render-pr-loading number title state)
         (octocat-pr-refresh)))
      ('octocat-commit
       (let* ((commit   (oref section value))
              (c        (gethash "commit" commit))
              (oid      (or (gethash "oid" commit)
                            (gethash "sha" commit)
                            ""))
              (msg      (or (and c (gethash "message" c)) ""))
              (_subject (car (split-string msg "\n")))
              (repo     (or octocat--pr-repo octocat-repo--repo))
              (short    (substring oid 0 (min 7 (length oid))))
              (buf-name (format "*octocat-commit: %s@%s*" repo short))
              (buf      (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-commit-mode)
           (octocat-commit-mode))
         (setq octocat--commit-repo repo
               octocat--commit-sha  oid)
         (octocat--render-commit-loading oid)
         (octocat-commit-refresh)))
      ('issue
       (let* ((issue  (oref section value))
              (number (gethash "number" issue))
              (title  (or (gethash "title" issue) ""))
              (state  (or (gethash "state" issue) "OPEN"))
              (repo   (or octocat-repo--repo octocat--issue-repo))
              (buf-name (format "*octocat-issue: %s#%d*" repo number))
              (buf (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-issue-mode)
           (octocat-issue-mode))
         (setq octocat--issue-repo repo
               octocat--issue-number number)
         (octocat--render-issue-loading number title state)
         (octocat-issue-refresh)))
      ('workflow
       (let* ((wf   (oref section value))
              (id   (gethash "id"   wf))
              (name (or (gethash "name" wf) ""))
              (repo (or octocat-repo--repo octocat--workflow-repo))
              (buf-name (format "*octocat-workflow: %s/%s*" repo name))
              (buf (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-workflow-mode)
           (octocat-workflow-mode))
         (setq octocat--workflow-repo repo
               octocat--workflow-id   id
               octocat--workflow-name name)
         (octocat--render-workflow-loading name)
         (octocat-workflow-refresh)))
      ('workflow-run
       (let* ((run    (oref section value))
              (run-id (gethash "databaseId" run))
              (repo   (or octocat-repo--repo octocat--run-repo))
              (buf-name (format "*octocat-run: %s#%d*" repo run-id))
              (buf    (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-run-mode)
           (octocat-run-mode))
         (setq octocat--run-repo repo
               octocat--run-id   run-id)
         (octocat--render-run-loading run-id)
         (octocat-run-refresh)))
      ;; RET on the Title row inside the Info section edits the title.
      ('pr-title    (octocat-pr-edit-title))
      ('issue-title (octocat-issue-edit-title))
      ;; RET on a PR or issue body section opens the inline editor.
      ('pr-body    (octocat-pr-edit-body))
      ('issue-body (octocat-issue-edit-body))
      ;; RET on a comment opens the editor if the viewer authored it.
      ('comment
       (let* ((comment    (oref section value))
              (authored   (eq (gethash "viewerDidAuthor" comment) t))
              (comment-id (octocat--comment-numeric-id comment))
              (body       (octocat--nonempty (gethash "body" comment))))
         (unless authored
           (user-error "Octocat: You can't edit someone else's comment"))
         (unless comment-id
           (user-error "Octocat: Could not determine comment ID from URL"))
         (cond
          ((and octocat--pr-repo octocat--pr-number)
           (octocat--open-edit-buffer octocat--pr-repo 'pr octocat--pr-number
                                      'edit-comment body comment-id))
          ((and octocat--issue-repo octocat--issue-number)
           (octocat--open-edit-buffer octocat--issue-repo 'issue octocat--issue-number
                                      'edit-comment body comment-id))
          (t (user-error "Octocat: Buffer is not associated with a PR or issue")))))
      ;; RET on the Changes info field opens the full PR diff view.
      ('pr-changes
       (let* ((repo   octocat--pr-repo)
              (number octocat--pr-number)
              (buf-name (format "*octocat-pr-diff: %s#%d*" repo number))
              (buf    (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-pr-diff-mode)
           (octocat-pr-diff-mode))
         (setq octocat--pr-diff-repo   repo
               octocat--pr-diff-number number)
         (octocat--render-pr-diff-loading number)
         (octocat-pr-diff-refresh)))
      ;; RET on an individual check-run row opens the checks detail buffer.
      ;; Works from both commit buffers (sha is known directly) and PR
      ;; buffers (sha is retrieved from the PR's head commit in the cache).
      ('check-run
       (let* (;; Commit buffer: sha and repo are directly available.
              (commit-sha  (and (boundp 'octocat--commit-sha)  octocat--commit-sha))
              (commit-repo (and (boundp 'octocat--commit-repo) octocat--commit-repo))
              ;; PR buffer: look up the head SHA from the PR cache.
              (pr-repo     octocat--pr-repo)
              (pr-cache    (and pr-repo octocat--pr-number
                                (octocat--detail-cache-load
                                 pr-repo "pr" octocat--pr-number)))
              (pr-commits  (and pr-cache
                                (let ((v (gethash "commits" pr-cache)))
                                  (when (and v (not (eq v :null))
                                             (> (length v) 0))
                                    v))))
              (pr-head-sha (and pr-commits
                                (gethash "oid"
                                         (aref pr-commits
                                               (1- (length pr-commits))))))
              (pr-head-ref (and pr-cache
                                (octocat--nonempty
                                 (gethash "headRefName" pr-cache))))
              ;; Resolve to whichever context is active.
              (repo (or commit-repo pr-repo))
              (sha  (or commit-sha pr-head-sha ""))
              (ref  (unless commit-sha pr-head-ref))
              (short (if (string-empty-p sha) ""
                       (substring sha 0 (min 7 (length sha)))))
              (buf-name (format "*octocat-checks: %s@%s*" repo short))
              (buf      (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-checks-mode)
           (octocat-checks-mode))
         (setq octocat--checks-repo repo
               octocat--checks-sha  sha
               octocat--checks-ref  ref)
         (octocat--render-checks-loading sha)
         (octocat-checks-refresh)))
      ;; RET on a feed-event row opens the per-repo buffer for the repo
      ;; referenced by that event.  The event hash-table has a "repo" key
      ;; whose value is a hash-table with a "name" field of the form
      ;; "owner/repo".
      ('feed-event
       (let* ((ev        (oref section value))
              (repo-obj  (and ev (hash-table-p ev) (gethash "repo" ev)))
              (full-name (and repo-obj
                              (hash-table-p repo-obj)
                              (octocat--nonempty (gethash "name" repo-obj)))))
         (if (not full-name)
             (message "Octocat: No repository associated with this event")
           (let* ((buf-name (format "*octocat-repo: %s*" full-name))
                  (buf      (get-buffer-create buf-name)))
             (switch-to-buffer buf)
             (unless (derived-mode-p 'octocat-repo-mode)
               (octocat-repo-mode))
             (setq octocat-repo--repo      full-name
                   octocat-repo--local-dir (octocat-repo--local-dir-for full-name))
             (octocat-repo-refresh)))))
      ;; RET on a "load more" row fetches the next page of that list.
      ;; This case is handled by octocat-repo-mode's RET binding which
      ;; calls octocat-visit; dispatch to octocat-repo-load-more here.
      ('load-more
       (octocat-repo-load-more))
      ;; RET on the feed "[+] Load more…" row fetches more feed events.
      ('load-more-feed
       (octocat-feed-load-more))
      (_ nil))))

(defun octocat-browse ()
  "Open the item at point in the browser, or the current detail view.

Dispatches first by the type of the magit section at point; falls back to
the current major mode when point is not on a section that has a
corresponding GitHub URL (e.g. the header line of a PR detail buffer).

Section types handled:
  `repo'          → https://github.com/OWNER/REPO
  `pr'            → gh pr view --web (respects gh's host config)
  `issue'         → gh issue view --web
  `octocat-commit'→ https://github.com/REPO/commit/SHA
  `workflow'      → https://github.com/REPO/actions/workflows/FILE
  `workflow-run'  → https://github.com/REPO/actions/runs/ID
  `check-run'     → html_url from the GitHub Checks API response
  `comment'       → url field from the GitHub comment object
  `octocat-root'  → https://github.com/REPO

Major-mode fallback (used when the section type does not have its own
handler, e.g. point is on a title/header line):
  `octocat-pr-mode'       → gh pr view --web
  `octocat-issue-mode'    → gh issue view --web
  `octocat-commit-mode'   → https://github.com/REPO/commit/SHA
  `octocat-workflow-mode' → https://github.com/REPO/actions/workflows/ID
  `octocat-run-mode'      → https://github.com/REPO/actions/runs/ID
  `octocat-job-mode'      → https://github.com/REPO/actions/runs/RUN/job/JOB
  `octocat-checks-mode'   → https://github.com/REPO/commit/SHA/checks"
  (interactive)
  (let* ((section (magit-current-section))
         (type    (and section (oref section type)))
         (value   (and section (oref section value)))
         (repo    (or octocat-repo--repo octocat--pr-repo octocat--run-repo))
         (gh      (executable-find "gh")))
    (unless gh
      (user-error "Octocat: `gh' executable not found"))
    (or
     (pcase type
       ('repo
        (let ((url (format "https://github.com/%s" value)))
          (message "Octocat: Opening %s in browser…" value)
          (browse-url url)))
       ('pr
        (let ((number (gethash "number" value)))
          (message "Octocat: Opening PR #%d in browser…" number)
          (start-process "octocat-browse" nil gh
                         "pr" "view" "--web"
                         (number-to-string number)
                         "--repo" repo)))
       ('octocat-commit
        (let* ((oid (or (gethash "oid" value) (gethash "sha" value) ""))
               (url (format "https://github.com/%s/commit/%s" repo oid)))
          (message "Octocat: Opening commit %s in browser…"
                   (substring oid 0 (min 7 (length oid))))
          (browse-url url)))
       ('issue
        (let ((number (gethash "number" value)))
          (message "Octocat: Opening issue #%d in browser…" number)
          (start-process "octocat-browse" nil gh
                         "issue" "view" "--web"
                         (number-to-string number)
                         "--repo" repo)))
       ('workflow
        (let* ((path     (or (gethash "path" value) ""))
               (filename (file-name-nondirectory path))
               (url      (format "https://github.com/%s/actions/workflows/%s"
                                 repo filename)))
          (message "Octocat: Opening workflow in browser…")
          (browse-url url)))
       ('workflow-run
        (let* ((run-id (or (gethash "databaseId" value) octocat--run-id))
               (url    (format "https://github.com/%s/actions/runs/%s"
                               repo (number-to-string run-id))))
          (message "Octocat: Opening run #%s in browser…" run-id)
          (browse-url url)))
       ('check-run
        (let ((url (gethash "html_url" value)))
          (when url
            (message "Octocat: Opening check run in browser…")
            (browse-url url))))
       ('comment
        (let ((url (gethash "url" value)))
          (when url
            (message "Octocat: Opening comment in browser…")
            (browse-url url))))
       ('octocat-root
        (let ((url (format "https://github.com/%s" repo)))
          (message "Octocat: Opening %s in browser…" repo)
          (browse-url url))))
     ;; Major-mode fallback — fires when point is on a section type that has
     ;; no URL of its own (e.g. a title/header line), or when no section is
     ;; active at all.  Each branch uses the buffer-local vars set when the
     ;; detail buffer was opened.
     (cond
      ((derived-mode-p 'octocat-pr-mode)
       (when (and octocat--pr-repo octocat--pr-number)
         (message "Octocat: Opening PR #%d in browser…" octocat--pr-number)
         (start-process "octocat-browse" nil gh
                        "pr" "view" "--web"
                        (number-to-string octocat--pr-number)
                        "--repo" octocat--pr-repo)))
      ((derived-mode-p 'octocat-issue-mode)
       (when (and octocat--issue-repo octocat--issue-number)
         (message "Octocat: Opening issue #%d in browser…" octocat--issue-number)
         (start-process "octocat-browse" nil gh
                        "issue" "view" "--web"
                        (number-to-string octocat--issue-number)
                        "--repo" octocat--issue-repo)))
      ((derived-mode-p 'octocat-commit-mode)
       (when (and octocat--commit-repo octocat--commit-sha)
         (let* ((sha octocat--commit-sha)
                (url (format "https://github.com/%s/commit/%s"
                             octocat--commit-repo sha)))
           (message "Octocat: Opening commit %s in browser…"
                    (substring sha 0 (min 7 (length sha))))
           (browse-url url))))
      ((derived-mode-p 'octocat-workflow-mode)
       (when (and octocat--workflow-repo octocat--workflow-id)
         (let ((url (format "https://github.com/%s/actions/workflows/%s"
                            octocat--workflow-repo octocat--workflow-id)))
           (message "Octocat: Opening workflow in browser…")
           (browse-url url))))
      ((derived-mode-p 'octocat-run-mode)
       (when (and octocat--run-repo octocat--run-id)
         (let ((url (format "https://github.com/%s/actions/runs/%s"
                            octocat--run-repo octocat--run-id)))
           (message "Octocat: Opening run #%s in browser…" octocat--run-id)
           (browse-url url))))
      ((derived-mode-p 'octocat-job-mode)
       (when (and octocat--job-repo octocat--job-run-id octocat--job-id)
         (let ((url (format "https://github.com/%s/actions/runs/%s/job/%s"
                            octocat--job-repo octocat--job-run-id octocat--job-id)))
           (message "Octocat: Opening job in browser…")
           (browse-url url))))
      ((derived-mode-p 'octocat-checks-mode)
       (when (and octocat--checks-repo octocat--checks-sha)
         (let ((url (format "https://github.com/%s/commit/%s/checks"
                            octocat--checks-repo octocat--checks-sha)))
           (message "Octocat: Opening checks in browser…")
           (browse-url url))))))))


;;;; Dashboard major mode

(defcustom octocat-feed-limit 15
  "Number of feed events to fetch initially on the dashboard.
Each `octocat-feed-load-more' call fetches this many additional events."
  :type 'integer
  :group 'octocat)

(defvar-local octocat--feed-limit nil
  "Per-buffer feed event fetch limit.
Starts at `octocat-feed-limit' and grows with `octocat-feed-load-more'.")

(defvar octocat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `octocat-mode' (GitHub account dashboard).")
(define-key octocat-mode-map (kbd "q")       #'quit-window)
(define-key octocat-mode-map (kbd "RET")     #'octocat-visit)
(define-key octocat-mode-map (kbd "+")       #'octocat-feed-load-more)
(define-key octocat-mode-map (kbd "o")       #'octocat-browse)
(define-key octocat-mode-map (kbd "C-c C-o") #'octocat-browse)
(define-derived-mode octocat-mode magit-section-mode "Octocat"
  "Major mode for the GitHub account dashboard.

\\{octocat-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-refresh)
  (font-lock-mode -1))


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
       (let* ((commits (and (hash-table-p payload)
                            (gethash "commits" payload)))
              (n (if (vectorp commits) (length commits) 0))
              (ref (and (hash-table-p payload)
                        (octocat--nonempty (gethash "ref" payload))))
              (branch (if ref
                          (replace-regexp-in-string "^refs/heads/" "" ref)
                        "?"))
              (first-commit (and (vectorp commits) (> (length commits) 0)
                                 (aref commits 0)))
              (msg (and (hash-table-p first-commit)
                        (octocat--nonempty (gethash "message" first-commit))))
              (subject (and msg (car (split-string msg "\n")))))
         (if subject
             (format "pushed %d %s to %s: %s"
                     n (if (= n 1) "commit" "commits") branch
                     (truncate-string-to-width subject 30 nil nil "…"))
           (format "pushed %d %s to %s" n (if (= n 1) "commit" "commits") branch))))
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

(defun octocat--render-dashboard-repos (repos)
  "Insert the Recent Repositories section using REPOS list.
REPOS is a list of hash-tables from the GitHub user/repos endpoint."
  (magit-insert-section (recent-repos)
    (magit-insert-heading
      (propertize "Recent Repositories" 'face 'octocat-section-heading))
    (if (null repos)
        (insert (propertize "  (no repositories)\n" 'face 'octocat-dimmed))
      (dolist (r repos)
        (let* ((full-name (or (gethash "full_name" r) ""))
               (desc      (octocat--nonempty (gethash "description" r)))
               (lang      (or (octocat--nonempty (gethash "language"    r)) ""))
               (pushed-at (or (gethash "pushed_at"   r) ""))
               (date      (octocat--relative-ts pushed-at))
               (hint      '(mouse-face magit-section-highlight
                            help-echo  "RET: open repo  o: browse on GitHub")))
          (magit-insert-section (repo full-name)
            (magit-insert-heading
              (apply #'concat
                     (apply #'propertize
                            (format "  %-35s" full-name)
                            'face 'octocat-repo hint)
                     (propertize (format "  %-14s" lang) 'face 'octocat-dimmed)
                     (propertize (format "  %-12s" date) 'face 'octocat-dimmed)
                     (list (propertize
                            (format "  %s\n" (or desc ""))
                            'face 'octocat-dimmed))))))))))

(defun octocat--render-dashboard-feed (feed)
  "Insert the Feed section using FEED list.
FEED is a list of hash-tables from the GitHub received_events endpoint."
  (let ((limit (or octocat--feed-limit octocat-feed-limit)))
    (magit-insert-section (feed)
      (magit-insert-heading
        (propertize "Feed" 'face 'octocat-section-heading))
      (if (null feed)
          (insert (propertize "  (no recent activity)\n" 'face 'octocat-dimmed))
        (dolist (ev feed)
          (let* ((type   (or (gethash "type"       ev) ""))
                 (actor  (let ((a (gethash "actor" ev)))
                           (if (and a (hash-table-p a))
                               (or (gethash "login" a) "")
                             "")))
                 (repo   (let ((r (gethash "repo" ev)))
                           (if (and r (hash-table-p r))
                               (or (gethash "name" r) "")
                             "")))
                 (detail (octocat--dashboard-event-detail ev))
                 (date   (octocat--relative-ts
                          (or (gethash "created_at" ev) "")))
                 (hint   '(mouse-face magit-section-highlight
                           help-echo  "RET: open repo")))
            (magit-insert-section (feed-event ev)
              (magit-insert-heading
                (apply #'propertize
                       (concat
                        "  "
                        (octocat--dashboard-event-icon type)
                        "  "
                        (propertize (format "%-16s" actor) 'face 'octocat-pr-author)
                        "  "
                        (propertize (format "%-35s" repo)  'face 'octocat-branch)
                        "  "
                        (octocat--format-title detail)
                        "  "
                        (propertize date 'face 'octocat-dimmed)
                        "\n")
                       hint)))))
        (when (>= (length feed) limit)
          (let ((hint '(mouse-face magit-section-highlight
                        help-echo  "RET / +: load more feed events")))
            (magit-insert-section (load-more-feed)
              (magit-insert-heading
                (concat (apply #'propertize
                               (format "  [+] Load %d more…" octocat-feed-limit)
                               'face 'octocat-dimmed hint)
                        "\n")))))))))

(defun octocat--render-dashboard (repos feed)
  "Render the dashboard buffer content from REPOS and FEED data.
REPOS is a list of hash-tables (user/repos endpoint).
FEED is a list of hash-tables (received_events endpoint).
This helper is called both with cached data (synchronous, on refresh
start) and with freshly fetched data (async, after gh calls return)."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-dashboard)
      (magit-insert-heading
        (propertize "GitHub Dashboard" 'face 'octocat-repo))
      (octocat--render-dashboard-repos repos)
      (insert "\n")
      (octocat--render-dashboard-feed feed))))


;;;; Dashboard refresh (live data)

(defun octocat-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the octocat dashboard buffer from live gh API data.
Follows the standard stale-while-revalidate pattern:
1. Render cached data immediately (if any) so the buffer is not empty.
2. Set `mode-line-process' to \" [refreshing…]\" and fire gh API calls.
3. When all calls complete: re-render from fresh data, write cache,
   clear the mode-line indicator."
  (interactive)
  (let* ((buf     (current-buffer))
         (cache   (octocat--dashboard-cache-load))
         (c-repos (and cache (plist-get cache :repos)))
         (c-feed  (and cache (plist-get cache :feed))))
    ;; ── Step 1: render stale cache immediately ────────────────────────
    (if cache
        (octocat--render-dashboard c-repos c-feed)
      ;; No cache yet — render a loading skeleton.
      (let ((inhibit-read-only t))
        (erase-buffer)
        (magit-insert-section (octocat-dashboard)
          (magit-insert-heading
            (propertize "GitHub Dashboard" 'face 'octocat-repo))
          (magit-insert-section (recent-repos)
            (magit-insert-heading
              (propertize "Recent Repositories" 'face 'octocat-section-heading))
            (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
          (insert "\n")
          (magit-insert-section (feed)
            (magit-insert-heading
              (propertize "Feed" 'face 'octocat-section-heading))
            (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))
    ;; ── Step 2: fetch fresh data asynchronously ───────────────────────
    (setq mode-line-process " [refreshing…]")
    (force-mode-line-update)
    (let ((results  (make-hash-table :test #'equal))
          (pending  2))
      (cl-flet ((maybe-done
                 ()
                 (cl-decf pending)
                 (when (= pending 0)
                   (let ((fresh-repos (gethash "repos" results))
                         (fresh-feed  (gethash "feed"  results)))
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (let ((saved (octocat--save-point)))
                           (octocat--render-dashboard
                            (if (eq (car-safe fresh-repos) 'error)
                                (or c-repos '())
                              fresh-repos)
                            (if (eq (car-safe fresh-feed) 'error)
                                (or c-feed '())
                              fresh-feed))
                           (octocat--restore-point saved))
                         (setq mode-line-process nil)
                         (force-mode-line-update)))
                     ;; Write cache only when both calls succeeded.
                     (unless (or (eq (car-safe fresh-repos) 'error)
                                 (eq (car-safe fresh-feed)  'error))
                       (octocat--dashboard-cache-save fresh-repos
                                                      fresh-feed))))))
        ;; Kick off repo fetch directly.
        (octocat--fetch-recent-repos
         (lambda (repos)
           (puthash "repos" repos results)
           (maybe-done)))
        ;; Kick off feed fetch: need viewer login first.
        (let ((feed-limit (or octocat--feed-limit octocat-feed-limit)))
          (octocat--fetch-viewer-login
           (lambda (login)
             (if (eq (car-safe login) 'error)
                 (progn
                   (puthash "feed" login results)
                   (maybe-done))
               (octocat--fetch-received-events
                login
                feed-limit
                (lambda (feed)
                  (puthash "feed" feed results)
                  (maybe-done)))))))))))



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


;;;; Entry point

;;;###autoload
(defun octocat ()
  "Open (or switch to) the octocat GitHub account dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*octocat*")))
    (switch-to-buffer buf)
    (unless (derived-mode-p 'octocat-mode)
      (octocat-mode))
    (octocat-refresh)))


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
