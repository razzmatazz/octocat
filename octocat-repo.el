;;; octocat-repo.el --- Per-repository view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Per-repository buffer: Pull Requests, Issues, Workflow Runs, Commits.
;; Entry point: M-x octocat-repo.

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
(require 'octocat-tree)

;; octocat-visit and octocat-browse live in octocat.el; we cannot require
;; that file here (circular dependency), so declare them for the compiler.
(declare-function octocat-visit    "octocat"      ())
(declare-function octocat-browse   "octocat"      ())
(declare-function octocat-tree-open      "octocat-tree" ())
(declare-function octocat-tree-find-file "octocat-tree" ())
(declare-function octocat-file-log-open  "octocat-tree" ())

;; Forward declarations for sub-module buffer-locals referenced by
;; octocat-visit (defined in octocat.el) but used here via the shared
;; keymap / mode.  These silence the byte-compiler.
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
(defvar octocat--job-repo)       ; defined as buffer-local in octocat-job.el
(defvar octocat--job-run-id)     ; defined as buffer-local in octocat-job.el
(defvar octocat--job-id)         ; defined as buffer-local in octocat-job.el
(defvar octocat--job-name)       ; defined as buffer-local in octocat-job.el
(defvar octocat--checks-repo)    ; defined as buffer-local in octocat-checks.el
(defvar octocat--checks-sha)     ; defined as buffer-local in octocat-checks.el
(defvar octocat--checks-ref)     ; defined as buffer-local in octocat-checks.el

;; declare-function stubs for functions called from octocat-visit (defined
;; in octocat.el) that live in sub-modules.
(declare-function octocat-pr-edit-body            "octocat-pr"      ())
(declare-function octocat-pr-edit-title           "octocat-pr"      ())
(declare-function octocat-issue-edit-body         "octocat-issue"   ())
(declare-function octocat-issue-edit-title        "octocat-issue"   ())
(declare-function octocat--render-pr-diff-loading "octocat-pr-diff" (number))
(declare-function octocat-pr-diff-refresh         "octocat-pr-diff" (&optional _ignore-auto _noconfirm))
(declare-function octocat--render-checks-loading  "octocat-checks"  (sha))
(declare-function octocat-checks-refresh          "octocat-checks"  (&optional _ignore-auto _noconfirm))
(declare-function octocat-checks-mode             "octocat-checks"  ())
(declare-function octocat-commit-mode             "octocat-commit"  ())
(declare-function octocat-commit-refresh          "octocat-commit"  (&optional _ignore-auto _noconfirm))
(declare-function octocat--render-commit-loading  "octocat-commit"  (sha))


;;;; User options

(defcustom octocat-section-limit 15
  "Default number of items to display per section in the repo buffer.
Used as the initial page size for Pull Requests, Issues, Workflow Runs,
and Commits.  Each section starts with this many items and increments
by this amount on each `octocat-repo-load-more'."
  :type 'integer
  :group 'octocat)


;;;; Buffer-local state

(defvar-local octocat-repo--repo nil
  "The \"owner/repo\" string this buffer is tracking.")

(defvar-local octocat-repo--local-dir nil
  "Absolute path to the local clone directory, or nil when detached.
Set at buffer-open time from `default-directory' when the buffer is
opened from inside a git working tree.  Nil means the buffer was opened
in detached mode — tracking a remote repository without a local clone.")

(defvar-local octocat-repo--current-branch nil
  "The local git branch checked out when this buffer last refreshed.
Used to highlight matching PR and workflow-run rows.  Nil when HEAD is
detached or the directory is not a git repository.")

(defvar-local octocat-repo--head-info nil
  "Plist describing the local HEAD when this buffer last refreshed.
Keys: :branch (string or nil), :hash (short hash string), :subject
\(one-line commit message).  Nil when not in a git repository or the
buffer was opened in detached mode.")

(defvar-local octocat-repo--section-hidden nil
  "List of section type symbols that were hidden before the last render.
Used to restore collapse state across buffer refreshes.")

(defvar-local octocat-repo--counts nil
  "Alist mapping section-type symbol to current item count.
Keys: prs, issues, commits, recent-runs.
Nil until first refresh; each key is then initialised from
`octocat-section-limit' and incremented by `octocat-repo-load-more'.")


;;;; Repo detection

(defun octocat-repo--current-repo ()
  "Return the \"owner/repo\" string for the current Git repository.
Reads the \\='origin\\=' remote URL and parses both SSH and HTTPS
GitHub remote forms.  Signals an error when the working directory
is not inside a GitHub repository."
  (let ((url (string-trim
              (shell-command-to-string
               "git remote get-url origin 2>/dev/null"))))
    (when (string-empty-p url)
      (user-error "Octocat: Could not find a Git remote named `origin'"))
    (or
     ;; SSH:  git@github.com:owner/repo.git
     (and (string-match
           "git@github\\.com:\\([^/]+/[^/]+?\\)\\(\\.git\\)?$" url)
          (match-string 1 url))
     ;; HTTPS: https://github.com/owner/repo[.git]
     (and (string-match
           "https://github\\.com/\\([^/]+/[^/]+?\\)\\(\\.git\\)?$" url)
          (match-string 1 url))
     (user-error "Octocat: `%s' does not look like a GitHub remote" url))))


(defun octocat-repo--local-dir-for (repo)
  "Return the local clone directory for REPO, or nil.
REPO is an \"owner/repo\" string.  Returns the absolute path to the root
of the current working tree when its \\='origin\\=' remote resolves to REPO,
and nil in every other case — including when `default-directory' is not
inside any git repository, when there is no \\='origin\\=' remote, or when
the remote points to a different repository."
  (condition-case nil
      (let ((root (locate-dominating-file default-directory ".git")))
        (and root
             (string= repo (octocat-repo--current-repo))
             (expand-file-name root)))
    (error nil)))


;;;; gh integration

(defun octocat-repo--disabled-feature-p (result)
  "Return non-nil when RESULT signals a disabled-feature error from gh.
Matches messages like \"X has disabled issues\" / \"disabled pull requests\" /
\"disabled Actions\" that the gh CLI emits for repos where the feature is
turned off, so callers can treat them as empty lists rather than real errors."
  (and (eq (car-safe result) 'error)
       (string-match-p "disabled" (cdr result))))

(defun octocat-repo--list-workflows (repo callback)
  "Fetch workflows for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of workflow hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "workflows"
                   (list "workflow" "list"
                         "--repo" repo
                         "--json" "id,name,state,path")
                   #'octocat--parse-json-list
                   callback))

(defun octocat-repo--list-workflow-runs (repo workflow-id callback)
  "Fetch recent run history for WORKFLOW-ID in REPO asynchronously.
Retrieves the 20 most recent entries and calls CALLBACK with a list of
run hash-tables, or a cons \\=(error . MSG) on failure."
  (octocat--run-gh
   (format "workflow-runs-%d" workflow-id)
   (list "run" "list"
         "--repo"     repo
         "--workflow" (number-to-string workflow-id)
         "--limit"    "20"
         "--json"     "databaseId,displayTitle,status,conclusion,createdAt,headBranch")
   #'octocat--parse-json-list
   callback))

(defun octocat-repo--list-recent-runs (repo limit callback)
  "Fetch the LIMIT most recent workflow run entries across all workflows in REPO.
Call CALLBACK with a list of run hash-tables (each including a
\\='workflowName\\=' key), or a cons \\=(error . MSG) on failure."
  (octocat--run-gh
   "recent-runs"
   (list "run" "list"
         "--repo"  repo
         "--limit" (number-to-string limit)
         "--json"  "databaseId,displayTitle,status,conclusion,createdAt,headBranch,workflowName")
   #'octocat--parse-json-list
   callback))

(defun octocat-repo--list-commits (repo limit callback)
  "Fetch the LIMIT most recent commits on the default branch of REPO.
Calls CALLBACK with a list of commit hash-tables, or a cons \\=(error . MSG).
Uses the GitHub REST API via `gh api'.  The default branch is determined
automatically by the API when no SHA is specified.
The commit limit is embedded in the URL query string so that `gh api'
always issues a GET request."
  (octocat--run-gh
   "commits"
   (list "api"
         (format "repos/%s/commits?per_page=%d" repo limit))
   #'octocat--parse-json-list
   callback))

(defun octocat-repo--fetch-default-branch (repo callback)
  "Fetch the default branch name for REPO asynchronously.
Calls CALLBACK with a non-empty string such as \"main\", or a cons
\\=(error . MSG) on failure.  Uses the GitHub REST API via `gh api'."
  (octocat--run-gh
   "default-branch"
   (list "api"
         (format "repos/%s" repo)
         "--jq" ".default_branch")
   (lambda (output)
     (let ((s (string-trim output)))
       (if (string-empty-p s)
           (error "Empty default_branch in repo response")
         s)))
   callback))


;;;; Buffer rendering

(defmacro octocat-repo--hide-if-saved (type section)
  "Hide SECTION at creation time if TYPE is in `octocat-repo--section-hidden'.
SECTION must be an expression that returns a `magit-section' object
\(typically a `magit-insert-section' call).  When TYPE is present in
`octocat-repo--section-hidden', wraps the section with `magit-section-hide'
so the overlay is applied immediately, as required by magit-section."
  `(let ((s ,section))
     (when (memq ,type (buffer-local-value 'octocat-repo--section-hidden
                                           (current-buffer)))
       (magit-section-hide s))
     s))

(defun octocat-repo--render-prs (prs &optional current-branch)
  "Insert the collapsible Pull Requests section for PRS.
PRS may be a list of pull-request hash-tables or a cons (error . MSG).
CURRENT-BRANCH, when non-nil, is the local HEAD branch name; the
matching PR row's branch column is highlighted with `octocat-branch-current'."
  (magit-insert-section (pull-requests)
    (magit-insert-heading
      (propertize "Pull Requests" 'face 'octocat-section-heading))
    (cond
     ((eq (car-safe prs) 'error)
      (if (octocat-repo--disabled-feature-p prs)
          (insert "  (no pull requests)\n")
        (insert (propertize (format "  %s\n" (cdr prs)) 'face 'octocat-dimmed))))
     ((null prs)
      (insert "  (no pull requests)\n"))
     (t
      (dolist (pr prs)
        (let* ((number  (format "%11s" (format "#%d" (gethash "number" pr))))
               (title   (or (gethash "title"  pr) ""))
               (branch  (or (gethash "headRefName" pr) ""))
               (activep (and current-branch (string= branch current-branch)))
               (b-face  (if activep 'octocat-branch-current 'octocat-branch))
               (author  (octocat--author-login pr))
               (state   (downcase (or (gethash "state" pr) "open")))
               (state-face (cond ((equal state "merged") 'octocat-pr-state-merged)
                                 ((equal state "closed") 'octocat-pr-state-closed)
                                 (t                      'octocat-pr-state-open)))
               (ci      (octocat--ci-label pr)))
          (magit-insert-section (pr pr)
            (magit-insert-heading
              (concat
               "  "
               (let* ((name (truncate-string-to-width branch octocat-branch-max-width nil nil "…"))
                      (pad  (make-string (- octocat-branch-max-width (string-width name)) ?\s)))
                 (concat (propertize name 'face b-face) pad))
               "  "
               (propertize number 'face 'octocat-pr-number)
               "  "
               (octocat--format-title title)
               "  "
               (propertize (format "%-16s" author) 'face 'octocat-pr-author)
               "  "
               (propertize (format "%-6s" state) 'face state-face)
               "  "
               ci
               "\n")))))
      (when (>= (length prs) (alist-get 'prs octocat-repo--counts))
          (let ((hint '(mouse-face magit-section-highlight
                        help-echo  "RET / +: load more pull requests")))
            (magit-insert-section (load-more 'prs)
              (magit-insert-heading
                (concat (apply #'propertize
                               (format "  [+] Load %d more…" octocat-section-limit)
                               'face 'octocat-dimmed hint)
                        "\n")))))))))

(defun octocat-repo--render-issues (issues)
  "Insert the collapsible Issues section for ISSUES.
ISSUES may be a list of issue hash-tables or a cons (error . MSG)."
  (magit-insert-section (issues)
    (magit-insert-heading
      (propertize "Issues" 'face 'octocat-section-heading))
    (cond
     ((eq (car-safe issues) 'error)
      (if (octocat-repo--disabled-feature-p issues)
          (insert "  (no issues)\n")
        (insert (propertize (format "  %s\n" (cdr issues)) 'face 'octocat-dimmed))))
     ((null issues)
      (insert "  (no issues)\n"))
     (t
      (dolist (issue issues)
        (let* ((number (format "%11s" (format "#%d" (gethash "number" issue))))
               (title  (or (gethash "title"  issue) ""))
               (author (octocat--author-login issue))
               (state  (downcase (or (gethash "state" issue) "open")))
               (state-face (if (equal state "open")
                               'octocat-pr-state-open
                             'octocat-pr-state-closed)))
          (magit-insert-section (issue issue)
            (magit-insert-heading
              (concat
               "  "
               (make-string octocat-branch-max-width ?\s)
               "  "
               (propertize number 'face 'octocat-pr-number)
               "  "
               (octocat--format-title title)
               "  "
               (propertize (format "%-16s" author) 'face 'octocat-pr-author)
               "  "
               (propertize (format "%-6s" state) 'face state-face)
               "\n")))))
      (when (>= (length issues) (alist-get 'issues octocat-repo--counts))
        (let ((hint '(mouse-face magit-section-highlight
                      help-echo  "RET / +: load more issues")))
          (magit-insert-section (load-more 'issues)
            (magit-insert-heading
              (concat (apply #'propertize
                             (format "  [+] Load %d more…" octocat-section-limit)
                             'face 'octocat-dimmed hint)
                      "\n")))))))))

(defun octocat-repo--render-workflows (workflows)
  "Insert the collapsible Workflows section for WORKFLOWS.
WORKFLOWS may be a list of workflow hash-tables or a cons (error . MSG).
Each workflow is shown as a single flat row (name + state); run history
is displayed in the separate Workflow Runs section."
  (magit-insert-section (workflows)
    (magit-insert-heading
      (propertize "Workflows" 'face 'octocat-section-heading))
    (cond
     ((eq (car-safe workflows) 'error)
      (if (octocat-repo--disabled-feature-p workflows)
          (insert "  (no workflows)\n")
        (insert (propertize (format "  %s\n" (cdr workflows)) 'face 'octocat-dimmed))))
     ((null workflows)
      (insert "  (no workflows)\n"))
     (t
      (dolist (workflow workflows)
        (let* ((name       (or (gethash "name"  workflow) ""))
               (state      (downcase (or (gethash "state" workflow) "")))
               (state-face (if (equal state "active") 'success 'octocat-dimmed)))
          (magit-insert-section (workflow workflow)
            (magit-insert-heading
              (concat
               "  "
               (truncate-string-to-width name 40 nil nil "…")
               "  "
               (propertize state 'face state-face)
               "\n")))))))))

(defun octocat-repo--render-workflow-runs (recent-runs &optional current-branch)
  "Insert the collapsible Workflow Run history section for RECENT-RUNS.
RECENT-RUNS is a flat list of run hash-tables (each with a
\\='workflowName\\=' key) or a cons (error . MSG).
CURRENT-BRANCH, when non-nil, is the local HEAD branch name; the
matching run row's branch column is highlighted with `octocat-branch-current'.
Show up to 20 most recent workflow entries across all workflows."
  (magit-insert-section (workflow-runs)
    (magit-insert-heading
      (propertize "Workflow Runs" 'face 'octocat-section-heading))
    (cond
     ((eq (car-safe recent-runs) 'error)
      (if (octocat-repo--disabled-feature-p recent-runs)
          (insert "  (no workflow runs)\n")
        (insert (propertize (format "  %s\n" (cdr recent-runs)) 'face 'octocat-dimmed))))
     ((null recent-runs)
      (insert "  (no workflow runs)\n"))
     (t
      (let ((wf-w (min 25 (apply #'max 1
                                (mapcar (lambda (r)
                                          (length (or (gethash "workflowName" r) "")))
                                        recent-runs)))))
        (dolist (run recent-runs)
          (let* ((run-id     (or (gethash "databaseId"   run) 0))
                 (title      (or (gethash "displayTitle" run) ""))
                 (status     (downcase (or (gethash "status" run) "")))
                 (conclusion (let ((c (gethash "conclusion" run)))
                               (and (octocat--nonempty c) (downcase c))))
                 (branch     (or (gethash "headBranch"   run) ""))
                 (activep    (and current-branch (string= branch current-branch)))
                 (b-face     (if activep 'octocat-branch-current 'octocat-branch))
                 (wf-name    (or (gethash "workflowName" run) ""))
                 (created    (or (gethash "createdAt"    run) ""))
                 (date       (octocat--relative-ts created))
                 (icon       (octocat--workflow-run-icon status conclusion)))
            (magit-insert-section (workflow-run run)
              (magit-insert-heading
                (concat
                 "  "
                 (let* ((name (truncate-string-to-width branch octocat-branch-max-width nil nil "…"))
                        (pad  (make-string (- octocat-branch-max-width (string-width name)) ?\s)))
                   (concat (propertize name 'face b-face) pad))
                 "  "
                 (propertize (format "%-11s" (number-to-string run-id))
                             'face 'octocat-pr-number)
                 "  "
                 (propertize (truncate-string-to-width wf-name wf-w nil ?\s "…")
                             'face 'octocat-dimmed)
                 "  "
                 icon
                 "  "
                 (octocat--format-title title)
                 "  "
                 (propertize date 'face 'octocat-dimmed)
                 "\n")))))
        (when (>= (length recent-runs) (alist-get 'recent-runs octocat-repo--counts))
          (let ((hint '(mouse-face magit-section-highlight
                        help-echo  "RET / +: load more runs")))
            (magit-insert-section (load-more 'recent-runs)
              (magit-insert-heading
                (concat (apply #'propertize
                               (format "  [+] Load %d more…" octocat-section-limit)
                               'face 'octocat-dimmed hint)
                        "\n"))))))))))

(defun octocat-repo--render-commits (commits &optional default-branch current-branch
                                             head-info)
  "Insert the collapsible Commits section for COMMITS.
COMMITS is a list of commit hash-tables as returned by the GitHub REST
API \\='repos/{owner}/{repo}/commits\\=' endpoint, or a cons (error . MSG).
DEFAULT-BRANCH is an optional string such as \"main\" shown on each commit row.
CURRENT-BRANCH, when non-nil, is the local HEAD branch name; when it
matches DEFAULT-BRANCH the label is highlighted with `octocat-branch-current'.
HEAD-INFO is an optional plist (:branch :hash :subject) from
`octocat--head-info'.  When a row's SHA starts with HEAD-INFO's :hash the
row is marked with a `*' indicator and its SHA is highlighted with
`octocat-commit-sha', signalling that this commit is the local HEAD.
Each row shows the short SHA, branch, subject, author, and date.  RET on a row
navigates to the commit detail view via `octocat-visit'."
  (let* ((branch-label (and (stringp default-branch)
                             (not (string-empty-p (or default-branch "")))
                             default-branch))
         (label-face   (if (and branch-label current-branch
                                (string= branch-label current-branch))
                           'octocat-branch-current
                         'octocat-branch))
         (head-hash    (and head-info (plist-get head-info :hash))))
    (magit-insert-section (commits)
      (magit-insert-heading
        (propertize "Commits" 'face 'octocat-section-heading))
      (cond
       ((eq (car-safe commits) 'error)
        (insert (propertize (format "  %s\n" (cdr commits)) 'face 'octocat-dimmed)))
       ((null commits)
        (insert "  (no commits)\n"))
       (t
        (dolist (commit commits)
          (let* ((sha       (or (gethash "sha" commit) ""))
                 (short     (substring sha 0 (min 11 (length sha))))
                 (is-head   (and head-hash
                                 (>= (length sha) (length head-hash))
                                 (string-prefix-p head-hash sha)))
                 (c         (gethash "commit" commit))
                 (message   (or (and c (gethash "message" c)) ""))
                 (subject   (car (split-string message "\n")))
                 (ca        (and c (gethash "author" c))) ; git author (date)
                 (author    (octocat--commit-author commit))
                 (date      (octocat--relative-ts
                             (or (and ca (gethash "date" ca)) ""))))
            (magit-insert-section (octocat-commit commit)
              (magit-insert-heading
                (concat
                 "  "
                 (if branch-label
                     (let* ((name (truncate-string-to-width branch-label octocat-branch-max-width nil nil "…"))
                            (pad  (make-string (- octocat-branch-max-width (string-width name)) ?\s)))
                       (concat (propertize name 'face label-face) pad))
                   (make-string octocat-branch-max-width ?\s))
                 "  "
                 (propertize (format "%-11s" short)
                             'face (if is-head 'octocat-branch-current 'octocat-commit-sha))
                 "  "
                 (if is-head
                     (let* ((text (truncate-string-to-width subject octocat-title-width nil nil "…"))
                            (pad  (make-string (- octocat-title-width (string-width text)) ?\s)))
                       (concat (propertize text 'face 'octocat-branch-current) pad))
                   (octocat--format-title subject))
                 "  "
                 (propertize (format "%-16s" author) 'face 'octocat-pr-author)
                 "  "
                 (propertize date 'face 'octocat-dimmed)
                 "\n")))))
        (when (>= (length commits) (alist-get 'commits octocat-repo--counts))
          (let ((hint '(mouse-face magit-section-highlight
                        help-echo  "RET / +: load more commits")))
            (magit-insert-section (load-more 'commits)
              (magit-insert-heading
                (concat (apply #'propertize
                               (format "  [+] Load %d more…" octocat-section-limit)
                               'face 'octocat-dimmed hint)
                        "\n"))))))))))

(defun octocat-repo--render-loading (repo)
  "Render a skeleton repo view for REPO while data is still loading.
Shows the repo header and collapsed section expanders for Pull Requests,
Issues, and Workflows, each with a dimmed \\='Loading…\\=' placeholder."
  (octocat-repo--save-section-state)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (concat
         (propertize repo 'face 'octocat-repo)
         "  "
         (propertize "[Browse files]"
                     'face       'octocat-dimmed
                     'mouse-face 'magit-section-highlight
                     'help-echo  "RET: browse file tree"
                     'octocat-action 'browse-files)))
      (when octocat-repo--local-dir
        (let* ((hi      octocat-repo--head-info)
               (branch  (and hi (plist-get hi :branch)))
               (hash    (and hi (plist-get hi :hash)))
               (subject (and hi (plist-get hi :subject))))
          (insert (concat (propertize "Local Head:" 'face 'octocat-dimmed)
                          "  "
                          (propertize octocat-repo--local-dir 'face 'octocat-branch)
                          (when branch
                            (concat "  " (octocat-tree--branch-glyph) "  "
                                    (propertize branch 'face 'octocat-branch-current)))
                          (when hash
                            (concat "  " (propertize hash 'face 'octocat-commit-sha)))
                          (when (and subject (not (string-empty-p subject)))
                            (concat "  " subject))
                          "\n"))))
      (insert "\n")
      (octocat-repo--hide-if-saved 'issues
        (magit-insert-section (issues)
          (magit-insert-heading
            (propertize "Issues" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (insert "\n")
      (octocat-repo--hide-if-saved 'pull-requests
        (magit-insert-section (pull-requests)
          (magit-insert-heading
            (propertize "Pull Requests" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (insert "\n")
      (octocat-repo--hide-if-saved 'commits
        (magit-insert-section (commits)
          (magit-insert-heading
            (propertize "Commits" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (insert "\n")
      (octocat-repo--hide-if-saved 'workflow-runs
        (magit-insert-section (workflow-runs)
          (magit-insert-heading
            (propertize "Workflow Runs" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (insert "\n")
      (octocat-repo--hide-if-saved 'workflows
        (magit-insert-section (workflows)
          (magit-insert-heading
            (propertize "Workflows" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))))))

(defun octocat-repo--render (prs issues workflows repo
                             &optional recent-runs commits default-branch current-branch
                             head-info)
  "Erase the buffer and render repo sections for REPO.
PRS, ISSUES, WORKFLOWS may each be a list of hash-tables or a cons
\(error . MSG) when the corresponding feature is disabled or unavailable.
RECENT-RUNS is an optional flat list of run hash-tables (each with a
\\='workflowName\\=' key) representing the last N workflow runs.
COMMITS is an optional list of commit hash-tables from the REST API.
DEFAULT-BRANCH is an optional string such as \"main\" shown in the Commits
section heading.
CURRENT-BRANCH is an optional string naming the local HEAD branch; when
non-nil the matching branch column in the PR and Workflow Runs lists is
highlighted with `octocat-branch-current'.
HEAD-INFO is an optional plist (:branch :hash :subject) from
`octocat--head-info', used to render the Local Head line.
Render collapsible sections; delegate to the individual render helpers."
  (octocat-repo--save-section-state)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (concat (propertize repo 'face 'octocat-repo)
                (propertize
                 (format "  %s  %s  %s"
                         (cond ((octocat-repo--disabled-feature-p prs)    "0 open PR(s)")
                               ((eq (car-safe prs) 'error)                "PRs: n/a")
                               (t (format "%d open PR(s)" (length prs))))
                         (cond ((octocat-repo--disabled-feature-p issues)  "0 open issue(s)")
                               ((eq (car-safe issues) 'error)              "issues: n/a")
                               (t (format "%d open issue(s)" (length issues))))
                         (cond ((octocat-repo--disabled-feature-p workflows) "0 workflow(s)")
                               ((eq (car-safe workflows) 'error)             "workflows: n/a")
                               (t (format "%d workflow(s)" (length workflows)))))
                 'face 'octocat-dimmed)
                "  "
                (propertize "[Browse files]"
                            'face       'octocat-dimmed
                            'mouse-face 'magit-section-highlight
                            'help-echo  "RET: browse file tree"
                            'octocat-action 'browse-files)))
      (when octocat-repo--local-dir
        (let* ((hi      head-info)
               (branch  (and hi (plist-get hi :branch)))
               (hash    (and hi (plist-get hi :hash)))
               (subject (and hi (plist-get hi :subject))))
          (insert (concat (propertize "Local Head:" 'face 'octocat-dimmed)
                          "  "
                          (propertize octocat-repo--local-dir 'face 'octocat-branch)
                          (when branch
                            (concat "  " (octocat-tree--branch-glyph) "  "
                                    (propertize branch 'face 'octocat-branch-current)))
                          (when hash
                            (concat "  " (propertize hash 'face 'octocat-commit-sha)))
                          (when (and subject (not (string-empty-p subject)))
                            (concat "  " subject))
                          "\n"))))
      (insert "\n")
      (octocat-repo--hide-if-saved 'issues        (octocat-repo--render-issues issues))
      (insert "\n")
      (octocat-repo--hide-if-saved 'pull-requests (octocat-repo--render-prs prs current-branch))
      (insert "\n")
      (octocat-repo--hide-if-saved 'commits       (octocat-repo--render-commits commits default-branch current-branch head-info))
      (insert "\n")
      (octocat-repo--hide-if-saved 'workflow-runs (octocat-repo--render-workflow-runs recent-runs current-branch))
      (insert "\n")
      (octocat-repo--hide-if-saved 'workflows     (octocat-repo--render-workflows workflows)))))


;;;; Major mode

(defvar octocat-repo-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `octocat-repo-mode'.")
(define-key octocat-repo-mode-map (kbd "q")       #'quit-window)
(define-key octocat-repo-mode-map (kbd "RET")     #'octocat-visit)
(define-key octocat-repo-mode-map (kbd "+")       #'octocat-repo-load-more)
(define-key octocat-repo-mode-map (kbd "C-c C-t") #'octocat-tree-open)
(define-key octocat-repo-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)

(define-key octocat-repo-mode-map (kbd "C-c C-o") #'octocat-browse)
(define-derived-mode octocat-repo-mode magit-section-mode "Octocat-Repo"
  "Major mode for browsing a GitHub repository.

\\{octocat-repo-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-repo-refresh)
  (font-lock-mode -1))


;;;; Section state

(defun octocat-repo--save-section-state ()
  "Save the hidden/collapsed state of root-level repo sections.
Records which direct children of `magit-root-section' are currently
hidden into `octocat-repo--section-hidden'.
`magit-root-section' is the `octocat-root' section itself; its direct
children are the `pull-requests', `issues', and `workflows' sections."
  (setq octocat-repo--section-hidden
        (when (and (boundp 'magit-root-section) magit-root-section)
          (delq nil
                (mapcar (lambda (s)
                          (when (oref s hidden) (oref s type)))
                        (oref magit-root-section children))))))


;;;; Async refresh

(defun octocat-repo-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat-repo buffer asynchronously.
Loads a disk cache (if present) and renders it immediately, then always
fetches fresh data in the background and re-renders when it arrives.
Issues 6 parallel API requests: PRs, issues, workflow list, the most
recent workflow runs across all workflows, the last N commits on the
default branch (where N is the current per-session limit), and the
default branch name itself."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  ;; Initialise per-session limits from the defcustom default on the
  ;; first call (nil → default).  Subsequent calls preserve whatever the
  ;; user may have increased via "load more".
  (dolist (key '(prs issues commits recent-runs))
    (unless (alist-get key octocat-repo--counts)
      (setf (alist-get key octocat-repo--counts) octocat-section-limit)))
  (let* ((buf           (current-buffer))
         (repo          octocat-repo--repo)
         (cache         (octocat--cache-load repo))
         ;; Snapshot limits now so all six fetch closures and maybe-render
         ;; use the same values, even if the user triggers "load more"
         ;; while a refresh is in flight.
         (prs-count     (alist-get 'prs     octocat-repo--counts))
         (issues-count  (alist-get 'issues  octocat-repo--counts))
         (commits-count (alist-get 'commits octocat-repo--counts))
         (runs-count    (alist-get 'recent-runs octocat-repo--counts))
         ;; Capture the local HEAD branch and full head info once; the branch
         ;; is used to highlight matching rows in the PR and Workflow Runs
         ;; lists; head-info is used to render the Local Head line.
         (_ (setq octocat-repo--head-info    (octocat--head-info)
                  octocat-repo--current-branch (plist-get octocat-repo--head-info :branch)))
         (current-branch octocat-repo--current-branch)
         (head-info      octocat-repo--head-info)
         ;; Capture point position before any render so both the cache
         ;; render and the live render can restore it afterwards.
         (saved-point   (octocat--save-point)))
    ;; Render cache immediately if available — but only when every limit is
    ;; at its default.  If the user has loaded more items than the cache
    ;; holds, rendering the cache would briefly shrink the list back to its
    ;; default size and then snap back when the live fetch arrives (jitter).
    ;; In that case keep whatever is currently in the buffer; the live fetch
    ;; will update it.  On a genuine first open with no cache and an empty
    ;; buffer, show the loading skeleton so the user sees something.
    (let ((at-defaults (seq-every-p (lambda (pair) (= (cdr pair) octocat-section-limit))
                                    octocat-repo--counts)))
      (cond
       ((and cache at-defaults)
        (octocat-repo--render (plist-get cache :prs)
                              (plist-get cache :issues)
                              (plist-get cache :workflows)
                              repo
                              (plist-get cache :recent-runs)
                              (plist-get cache :commits)
                              (plist-get cache :default-branch)
                              current-branch
                              head-info)
        (octocat--restore-point saved-point))
       ((zerop (buffer-size))
        (octocat-repo--render-loading repo))))
    ;; Always fetch fresh data in the background.
    ;; All 6 requests fire in parallel; render once all have returned.
    (setq mode-line-process " [refreshing…]")
    (let ((pr-result       'pending)
          (issue-result    'pending)
          (workflow-result 'pending)
          (runs-result     'pending)
          (commits-result  'pending)
          (branch-result   'pending))
      (cl-labels
          ((maybe-render ()
             (unless (or (eq pr-result       'pending)
                         (eq issue-result    'pending)
                         (eq workflow-result 'pending)
                         (eq runs-result     'pending)
                         (eq commits-result  'pending)
                         (eq branch-result   'pending))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq mode-line-process nil)
                   (let ((branch (and (stringp branch-result) branch-result)))
                     ;; Only persist to cache when every limit is at its
                     ;; default, so "load more" results never corrupt the
                     ;; stale-while-revalidate snapshot.
                     (when (seq-every-p (lambda (pair)
                                          (= (cdr pair) octocat-section-limit))
                                        octocat-repo--counts)
                       (octocat--cache-save repo pr-result issue-result
                                            workflow-result runs-result
                                            commits-result branch))
                     (octocat-repo--render pr-result issue-result workflow-result
                                           repo runs-result commits-result branch
                                           current-branch head-info))
                   (octocat--restore-point saved-point))))))
        (octocat--list-prs repo prs-count
                           (lambda (result)
                             (setq pr-result result)
                             (maybe-render)))
        (octocat--list-issues repo issues-count
                              (lambda (result)
                                (setq issue-result result)
                                (maybe-render)))
        (octocat-repo--list-workflows repo
                                      (lambda (result)
                                        (setq workflow-result result)
                                        (maybe-render)))
        (octocat-repo--list-recent-runs repo runs-count
                                        (lambda (result)
                                          (setq runs-result result)
                                          (maybe-render)))
        (octocat-repo--list-commits repo commits-count
                                    (lambda (result)
                                      (setq commits-result result)
                                      (maybe-render)))
        (octocat-repo--fetch-default-branch repo
                                            (lambda (result)
                                              (setq branch-result result)
                                              (maybe-render)))))))


;;;; Load-more command

(defun octocat-repo--pageable-section-at-point ()
  "Return the pageable section type symbol at or above point, or nil.
Walks up the section tree from `magit-current-section' until it finds
a section whose type is one of `pull-requests', `issues', `commits', or
`workflow-runs', and returns that type symbol.  Returns nil when point
is not inside any pageable section."
  (let ((s (magit-current-section)))
    (while (and s (not (memq (oref s type)
                             '(pull-requests issues commits workflow-runs))))
      (setq s (oref s parent)))
    (and s (oref s type))))

(defun octocat-repo-load-more ()
  "Load more items in the pageable list section at point.
Increments the per-session fetch limit for whichever of the Pull
Requests, Issues, Commits, or Workflow Runs sections contains point,
then re-runs `octocat-repo-refresh'.  Signals an error when point is not
inside a pageable section."
  (interactive)
  (pcase (octocat-repo--pageable-section-at-point)
    ('pull-requests
     (cl-incf (alist-get 'prs octocat-repo--counts) octocat-section-limit)
     (octocat-repo-refresh))
    ('issues
     (cl-incf (alist-get 'issues octocat-repo--counts) octocat-section-limit)
     (octocat-repo-refresh))
    ('commits
     (cl-incf (alist-get 'commits octocat-repo--counts) octocat-section-limit)
     (octocat-repo-refresh))
    ('workflow-runs
     (cl-incf (alist-get 'recent-runs octocat-repo--counts) octocat-section-limit)
     (octocat-repo-refresh))
    (_ (user-error "Octocat: No pageable section at point"))))


;;;; Entry point

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

(provide 'octocat-repo)
;;; octocat-repo.el ends here
