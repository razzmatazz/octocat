;;; octocat.el --- GitHub Client powered by the gh CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; Author: octocat.el contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "3.0") (transient "0.4") (markdown-mode "2.0"))
;; Keywords: tools, vc, github
;; URL: https://github.com/octocat.el/octocat.el

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Emacs client for GitHub, powered by the gh CLI.

;;; Code:

(require 'octocat-core)
(require 'octocat-pr)
(require 'octocat-commit)
(require 'octocat-pr-diff)
(require 'octocat-issue)
(require 'octocat-workflow)
(require 'octocat-run)
(require 'octocat-job)

(defvar octocat--pr-repo)        ; defined as buffer-local in octocat-pr.el
(defvar octocat--pr-number)      ; defined as buffer-local in octocat-pr.el
(defvar octocat--pr-diff-repo)   ; defined as buffer-local in octocat-pr-diff.el
(defvar octocat--pr-diff-number) ; defined as buffer-local in octocat-pr-diff.el
(defvar octocat--issue-repo)     ; defined as buffer-local in octocat-issue.el
(defvar octocat--issue-number)   ; defined as buffer-local in octocat-issue.el
(defvar octocat--workflow-repo)  ; defined as buffer-local in octocat-workflow.el
(defvar octocat--workflow-id)    ; defined as buffer-local in octocat-workflow.el
(defvar octocat--workflow-name)  ; defined as buffer-local in octocat-workflow.el
(defvar octocat--run-repo)           ; defined as buffer-local in octocat-run.el
(defvar octocat--run-id)             ; defined as buffer-local in octocat-run.el
(defvar octocat--job-repo)       ; defined as buffer-local in octocat-job.el
(defvar octocat--job-run-id)     ; defined as buffer-local in octocat-job.el
(defvar octocat--job-id)         ; defined as buffer-local in octocat-job.el
(defvar octocat--job-name)       ; defined as buffer-local in octocat-job.el

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


;;;; Repo detection

(defun octocat--current-repo ()
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


;;;; gh integration

(defun octocat--disabled-feature-p (result)
  "Return non-nil when RESULT signals a disabled-feature error from gh.
Matches messages like \"X has disabled issues\" / \"disabled pull requests\" /
\"disabled Actions\" that the gh CLI emits for repos where the feature is
turned off, so callers can treat them as empty lists rather than real errors."
  (and (eq (car-safe result) 'error)
       (string-match-p "disabled" (cdr result))))

(defun octocat--list-workflows (repo callback)
  "Fetch workflows for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of workflow hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "workflows"
                   (list "workflow" "list"
                         "--repo" repo
                         "--json" "id,name,state,path")
                   #'octocat--parse-json-list
                   callback))

(defun octocat--list-workflow-runs (repo workflow-id callback)
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

(defun octocat--list-recent-runs (repo limit callback)
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

(defcustom octocat-prs-limit 15
  "Default number of open pull requests to display on the dashboard."
  :type 'integer
  :group 'octocat)

(defcustom octocat-issues-limit 15
  "Default number of open issues to display on the dashboard."
  :type 'integer
  :group 'octocat)

(defcustom octocat-runs-limit 15
  "Default number of recent workflow runs to display on the dashboard."
  :type 'integer
  :group 'octocat)

(defcustom octocat-commits-limit 15
  "Default number of recent commits to display on the dashboard."
  :type 'integer
  :group 'octocat)

;; Per-session fetch limits — buffer-local counterparts to the defcustoms
;; above.  Nil until the first refresh; the render functions read these to
;; decide whether to show a "load more" row.  Declared here (before the
;; render functions) so the byte-compiler knows they are intentional
;; buffer-locals and not free variables.
(defvar-local octocat--prs-count nil
  "Current per-session PR fetch limit for this dashboard buffer.
Nil until first refresh, then initialised from `octocat-prs-limit'.")

(defvar-local octocat--issues-count nil
  "Current per-session issue fetch limit for this dashboard buffer.
Nil until first refresh, then initialised from `octocat-issues-limit'.")

(defvar-local octocat--commits-count nil
  "Current per-session commit fetch limit for this dashboard buffer.
Nil until first refresh, then initialised from `octocat-commits-limit'.")

(defvar-local octocat--runs-count nil
  "Current per-session recent-run fetch limit for this dashboard buffer.
Nil until first refresh, then initialised from `octocat-runs-limit'.")

(defun octocat--list-commits (repo limit callback)
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

(defun octocat--fetch-default-branch (repo callback)
  "Fetch the default branch name for REPO asynchronously.
Calls CALLBACK with a non-empty string such as \\\"main\\\", or a cons
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

(defmacro octocat--hide-if-saved (type section)
  "Hide SECTION at creation time if TYPE is in `octocat--section-hidden'.
SECTION must be an expression that returns a `magit-section' object
\(typically a `magit-insert-section' call).  When TYPE is present in
`octocat--section-hidden', wraps the section with `magit-section-hide'
so the overlay is applied immediately, as required by magit-section."
  `(let ((s ,section))
     (when (memq ,type (buffer-local-value 'octocat--section-hidden
                                           (current-buffer)))
       (magit-section-hide s))
     s))

(defun octocat--render-prs (prs &optional current-branch)
  "Insert the collapsible Pull Requests section for PRS.
PRS may be a list of pull-request hash-tables or a cons (error . MSG).
CURRENT-BRANCH, when non-nil, is the local HEAD branch name; the
matching PR row's branch column is highlighted with `octocat-branch-current'."
  (magit-insert-section (pull-requests)
    (magit-insert-heading
      (propertize "Pull Requests" 'face 'octocat-section-heading))
    (cond
     ((eq (car-safe prs) 'error)
      (if (octocat--disabled-feature-p prs)
          (insert "  (no pull requests)\n")
        (insert (propertize (format "  %s\n" (cdr prs)) 'face 'octocat-dimmed))))
     ((null prs)
      (insert "  (no pull requests)\n"))
     (t
      (let ((branch-w (octocat--branch-column-width prs "headRefName")))
        (dolist (pr prs)
          (let* ((number  (format "%-11s" (format "#%d" (gethash "number" pr))))
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
                 (propertize number 'face 'octocat-pr-number)
                 "  "
                 (let* ((name (truncate-string-to-width branch branch-w nil nil "…"))
                        (pad  (make-string (- branch-w (string-width name)) ?\s)))
                   (concat (propertize name 'face b-face) pad))
                 "  "
                 (octocat--format-title title)
                 "  "
                 (propertize (format "%-16s" author) 'face 'octocat-pr-author)
                 "  "
                 (propertize (format "%-6s" state) 'face state-face)
                 "  "
                 ci
                 "\n")))))
        (when (>= (length prs) octocat--prs-count)
          (let ((hint '(mouse-face magit-section-highlight
                        help-echo  "RET / +: load more pull requests")))
            (magit-insert-section (load-more 'prs)
              (magit-insert-heading
                (concat (apply #'propertize
                               (format "  [+] Load %d more…" octocat-prs-limit)
                               'face 'octocat-dimmed hint)
                        "\n"))))))))))

(defun octocat--render-issues (issues)
  "Insert the collapsible Issues section for ISSUES.
ISSUES may be a list of issue hash-tables or a cons (error . MSG)."
  (magit-insert-section (issues)
    (magit-insert-heading
      (propertize "Issues" 'face 'octocat-section-heading))
    (cond
     ((eq (car-safe issues) 'error)
      (if (octocat--disabled-feature-p issues)
          (insert "  (no issues)\n")
        (insert (propertize (format "  %s\n" (cdr issues)) 'face 'octocat-dimmed))))
     ((null issues)
      (insert "  (no issues)\n"))
     (t
      (dolist (issue issues)
        (let* ((number (format "%-11s" (format "#%d" (gethash "number" issue))))
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
               (propertize number 'face 'octocat-pr-number)
               "  "
               (octocat--format-title title)
               "  "
               (propertize (format "%-16s" author) 'face 'octocat-pr-author)
               "  "
               (propertize (format "%-6s" state) 'face state-face)
               "\n")))))
      (when (>= (length issues) octocat--issues-count)
        (let ((hint '(mouse-face magit-section-highlight
                      help-echo  "RET / +: load more issues")))
          (magit-insert-section (load-more 'issues)
            (magit-insert-heading
              (concat (apply #'propertize
                             (format "  [+] Load %d more…" octocat-issues-limit)
                             'face 'octocat-dimmed hint)
                      "\n")))))))))

(defun octocat--render-workflows (workflows)
  "Insert the collapsible Workflows section for WORKFLOWS.
WORKFLOWS may be a list of workflow hash-tables or a cons (error . MSG).
Each workflow is shown as a single flat row (name + state); run history
is displayed in the separate Workflow Runs section."
  (magit-insert-section (workflows)
    (magit-insert-heading
      (propertize "Workflows" 'face 'octocat-section-heading))
    (cond
     ((eq (car-safe workflows) 'error)
      (if (octocat--disabled-feature-p workflows)
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

(defun octocat--render-workflow-runs (recent-runs &optional current-branch)
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
      (if (octocat--disabled-feature-p recent-runs)
          (insert "  (no workflow runs)\n")
        (insert (propertize (format "  %s\n" (cdr recent-runs)) 'face 'octocat-dimmed))))
     ((null recent-runs)
      (insert "  (no workflow runs)\n"))
     (t
      (let ((branch-w (octocat--branch-column-width recent-runs "headBranch"))
            (wf-w (min 25 (apply #'max 1
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
                 (propertize (format "%-11s" (number-to-string run-id))
                             'face 'octocat-pr-number)
                 "  "
                 (let* ((name (truncate-string-to-width branch branch-w nil nil "…"))
                        (pad  (make-string (- branch-w (string-width name)) ?\s)))
                   (concat (propertize name 'face b-face) pad))
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
        (when (>= (length recent-runs) octocat--runs-count)
          (let ((hint '(mouse-face magit-section-highlight
                        help-echo  "RET / +: load more runs")))
            (magit-insert-section (load-more 'recent-runs)
              (magit-insert-heading
                (concat (apply #'propertize
                               (format "  [+] Load %d more…" octocat-runs-limit)
                               'face 'octocat-dimmed hint)
                        "\n"))))))))))


(defun octocat--render-commits (commits &optional default-branch current-branch)
  "Insert the collapsible Commits section for COMMITS.
COMMITS is a list of commit hash-tables as returned by the GitHub REST
API \\='repos/{owner}/{repo}/commits\\=' endpoint, or a cons (error . MSG).
DEFAULT-BRANCH is an optional string such as \"main\" shown on each commit row.
CURRENT-BRANCH, when non-nil, is the local HEAD branch name; when it
matches DEFAULT-BRANCH the label is highlighted with `octocat-branch-current'.
Each row shows the short SHA, branch, subject, author, and date.  RET on a row
navigates to the commit detail view via `octocat-visit'."
  (let* ((branch-label (and (stringp default-branch)
                             (not (string-empty-p (or default-branch "")))
                             default-branch))
         (label-face   (if (and branch-label current-branch
                                (string= branch-label current-branch))
                           'octocat-branch-current
                         'octocat-branch)))
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
          (let* ((sha     (or (gethash "sha" commit) ""))
                 (short   (substring sha 0 (min 11 (length sha))))
                 (c       (gethash "commit" commit))
                 (message (or (and c (gethash "message" c)) ""))
                 (subject (car (split-string message "\n")))
                 (ca      (and c (gethash "author" c))) ; git author (date)
                 (author  (octocat--commit-author commit))
                 (date    (octocat--relative-ts
                           (or (and ca (gethash "date" ca)) ""))))
            (magit-insert-section (commit commit)
              (magit-insert-heading
                (concat
                 "  "
                 (propertize (format "%-11s" short) 'face 'octocat-commit-sha)
                 (if branch-label
                     (concat "  "
                             (propertize branch-label 'face label-face))
                   "")
                 "  "
                 (octocat--format-title subject)
                 "  "
                 (propertize (format "%-16s" author) 'face 'octocat-pr-author)
                 "  "
                 (propertize date 'face 'octocat-dimmed)
                 "\n")))))
        (when (>= (length commits) octocat--commits-count)
          (let ((hint '(mouse-face magit-section-highlight
                        help-echo  "RET / +: load more commits")))
            (magit-insert-section (load-more 'commits)
              (magit-insert-heading
                (concat (apply #'propertize
                               (format "  [+] Load %d more…" octocat-commits-limit)
                               'face 'octocat-dimmed hint)
                        "\n"))))))))))

(defun octocat--render-loading (repo)
  "Render a skeleton front view for REPO while data is still loading.
Shows the repo header and collapsed section expanders for Pull Requests,
Issues, and Workflows, each with a dimmed \\='Loading…\\=' placeholder."
  (octocat--save-section-state)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (propertize repo 'face 'octocat-repo))
      (octocat--hide-if-saved 'issues
        (magit-insert-section (issues)
          (magit-insert-heading
            (propertize "Issues" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (insert "\n")
      (octocat--hide-if-saved 'pull-requests
        (magit-insert-section (pull-requests)
          (magit-insert-heading
            (propertize "Pull Requests" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (insert "\n")
      (octocat--hide-if-saved 'commits
        (magit-insert-section (commits)
          (magit-insert-heading
            (propertize "Commits" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (insert "\n")
      (octocat--hide-if-saved 'workflow-runs
        (magit-insert-section (workflow-runs)
          (magit-insert-heading
            (propertize "Workflow Runs" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (insert "\n")
      (octocat--hide-if-saved 'workflows
        (magit-insert-section (workflows)
          (magit-insert-heading
            (propertize "Workflows" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))))))

(defun octocat--render (prs issues workflows repo
                        &optional recent-runs commits default-branch current-branch)
  "Erase the buffer and render dashboard sections for REPO.
PRS, ISSUES, WORKFLOWS may each be a list of hash-tables or a cons
\(error . MSG) when the corresponding feature is disabled or unavailable.
RECENT-RUNS is an optional flat list of run hash-tables (each with a
\\='workflowName\\=' key) representing the last 20 workflow runs.
COMMITS is an optional list of commit hash-tables from the REST API,
representing the last `octocat-commits-limit' commits on the default branch.
DEFAULT-BRANCH is an optional string such as \"main\" shown in the Commits
section heading.
CURRENT-BRANCH is an optional string naming the local HEAD branch; when
non-nil the matching branch column in the PR and Workflow Runs lists is
highlighted with `octocat-branch-current'.
Render collapsible sections; delegate to the individual render helpers."
  (octocat--save-section-state)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (concat (propertize repo 'face 'octocat-repo)
                (propertize
                 (format "  %s  %s  %s"
                         (cond ((octocat--disabled-feature-p prs)    "0 open PR(s)")
                               ((eq (car-safe prs) 'error)           "PRs: n/a")
                               (t (format "%d open PR(s)" (length prs))))
                         (cond ((octocat--disabled-feature-p issues)  "0 open issue(s)")
                               ((eq (car-safe issues) 'error)         "issues: n/a")
                               (t (format "%d open issue(s)" (length issues))))
                         (cond ((octocat--disabled-feature-p workflows) "0 workflow(s)")
                               ((eq (car-safe workflows) 'error)        "workflows: n/a")
                               (t (format "%d workflow(s)" (length workflows)))))
                 'face 'octocat-dimmed)))
      (octocat--hide-if-saved 'issues        (octocat--render-issues issues))
      (insert "\n")
      (octocat--hide-if-saved 'pull-requests (octocat--render-prs prs current-branch))
      (insert "\n")
      (octocat--hide-if-saved 'commits       (octocat--render-commits commits default-branch current-branch))
      (insert "\n")
      (octocat--hide-if-saved 'workflow-runs (octocat--render-workflow-runs recent-runs current-branch))
      (insert "\n")
      (octocat--hide-if-saved 'workflows     (octocat--render-workflows workflows)))))


;;;; Major mode

(defvar octocat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `octocat-mode'.")
(define-key octocat-mode-map (kbd "q")       #'quit-window)
(define-key octocat-mode-map (kbd "RET")     #'octocat-visit)
(define-key octocat-mode-map (kbd "+")       #'octocat-load-more)
(define-key octocat-mode-map (kbd "o")       #'octocat-browse)
(define-key octocat-mode-map (kbd "C-c C-o") #'octocat-browse)
(define-derived-mode octocat-mode magit-section-mode "Octocat"
  "Major mode for browsing GitHub Pull Requests.

\\{octocat-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-refresh)
  (font-lock-mode -1))


;;;; Async refresh

(defvar-local octocat--repo nil
  "The \"owner/repo\" string this buffer is tracking.")

(defvar-local octocat--current-branch nil
  "The local git branch that was checked out when this buffer last refreshed.
Used to highlight matching PR and workflow-run rows.  Nil when HEAD is
detached or the directory is not a git repository.")

(defvar-local octocat--section-hidden nil
  "List of section type symbols that were hidden before the last render.
Used to restore collapse state across buffer refreshes.")

(defun octocat--save-section-state ()
  "Save the hidden/collapsed state of root-level dashboard sections.
Records which direct children of `magit-root-section' are currently
hidden into `octocat--section-hidden'.
`magit-root-section' is the `octocat-root' section itself; its direct
children are the `pull-requests', `issues', and `workflows' sections."
  (setq octocat--section-hidden
        (when (and (boundp 'magit-root-section) magit-root-section)
          (delq nil
                (mapcar (lambda (s)
                          (when (oref s hidden) (oref s type)))
                        (oref magit-root-section children))))))



(defun octocat-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat buffer asynchronously.
Loads a disk cache (if present) and renders it immediately, then always
fetches fresh data in the background and re-renders when it arrives.
Issues 6 parallel API requests: PRs, issues, workflow list, the most
recent workflow runs across all workflows, the last N commits on the
default branch (where N is the current per-session limit), and the
default branch name itself."
  (interactive)
  (unless octocat--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  ;; Initialise per-session limits from their defcustom defaults on the
  ;; first call (nil → default).  Subsequent calls preserve whatever the
  ;; user may have increased via "load more".
  (unless octocat--prs-count    (setq octocat--prs-count    octocat-prs-limit))
  (unless octocat--issues-count (setq octocat--issues-count octocat-issues-limit))
  (unless octocat--commits-count (setq octocat--commits-count octocat-commits-limit))
  (unless octocat--runs-count   (setq octocat--runs-count   octocat-runs-limit))
  (let* ((buf           (current-buffer))
         (repo          octocat--repo)
         (cache         (octocat--cache-load repo))
         ;; Snapshot limits now so all six fetch closures and maybe-render
         ;; use the same values, even if the user triggers "load more"
         ;; while a refresh is in flight.
         (prs-count     octocat--prs-count)
         (issues-count  octocat--issues-count)
         (commits-count octocat--commits-count)
         (runs-count    octocat--runs-count)
         ;; Capture the local HEAD branch once; used to highlight matching
         ;; rows in the PR and Workflow Runs lists.
         (_ (setq octocat--current-branch (octocat--current-branch)))
         (current-branch octocat--current-branch)
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
    (let ((at-defaults (and (= prs-count     octocat-prs-limit)
                            (= issues-count  octocat-issues-limit)
                            (= commits-count octocat-commits-limit)
                            (= runs-count    octocat-runs-limit))))
      (cond
       ((and cache at-defaults)
        (octocat--render (plist-get cache :prs)
                         (plist-get cache :issues)
                         (plist-get cache :workflows)
                         repo
                         (plist-get cache :recent-runs)
                         (plist-get cache :commits)
                         (plist-get cache :default-branch)
                         current-branch)
        (octocat--restore-point saved-point))
       ((zerop (buffer-size))
        (octocat--render-loading repo))))
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
                     ;; stale-while-revalidate snapshot that greets the
                     ;; user on the next buffer open.
                     (when (and (= prs-count     octocat-prs-limit)
                                (= issues-count  octocat-issues-limit)
                                (= commits-count octocat-commits-limit)
                                (= runs-count    octocat-runs-limit))
                       (octocat--cache-save repo pr-result issue-result
                                            workflow-result runs-result
                                            commits-result branch))
                     (octocat--render pr-result issue-result workflow-result
                                      repo runs-result commits-result branch
                                      current-branch))
                   (octocat--restore-point saved-point))))))
        (octocat--list-prs repo prs-count
                           (lambda (result)
                             (setq pr-result result)
                             (maybe-render)))
        (octocat--list-issues repo issues-count
                              (lambda (result)
                                (setq issue-result result)
                                (maybe-render)))
        (octocat--list-workflows repo
                                 (lambda (result)
                                   (setq workflow-result result)
                                   (maybe-render)))
        (octocat--list-recent-runs repo runs-count
                                   (lambda (result)
                                     (setq runs-result result)
                                     (maybe-render)))
        (octocat--list-commits repo commits-count
                               (lambda (result)
                                 (setq commits-result result)
                                 (maybe-render)))
        (octocat--fetch-default-branch repo
                                       (lambda (result)
                                         (setq branch-result result)
                                         (maybe-render)))))))


;;;; Visitor and browser

(defun octocat-visit ()
  "Open the detail view for the item at point."
  (interactive)
  (let ((section (magit-current-section)))
    (pcase (and section (oref section type))
      ('pr
       (let* ((pr     (oref section value))
              (number (gethash "number" pr))
              (title  (or (gethash "title" pr) ""))
              (state  (or (gethash "state" pr) "OPEN"))
              (repo   octocat--repo)
              (buf-name (format "*octocat-pr: %s#%d*" repo number))
              (buf (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-pr-mode)
           (octocat-pr-mode))
         (setq octocat--pr-repo repo
               octocat--pr-number number)
         (octocat--render-pr-loading number title state)
         (octocat-pr-refresh)))
      ('commit
       (let* ((commit   (oref section value))
              (c        (gethash "commit" commit))
              (oid      (or (gethash "oid" commit)
                            (gethash "sha" commit)
                            ""))
              (msg      (or (and c (gethash "message" c)) ""))
              (_subject (car (split-string msg "\n")))
              (repo     (or octocat--pr-repo octocat--repo))
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
              (repo   octocat--repo)
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
              (repo octocat--repo)
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
              (repo   octocat--repo)
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
      ;; RET on a "load more" row fetches the next page of that list.
      ('load-more
       (pcase (oref section value)
         ('prs
          (cl-incf octocat--prs-count octocat-prs-limit)
          (octocat-refresh))
         ('issues
          (cl-incf octocat--issues-count octocat-issues-limit)
          (octocat-refresh))
         ('commits
          (cl-incf octocat--commits-count octocat-commits-limit)
          (octocat-refresh))
         ('recent-runs
          (cl-incf octocat--runs-count octocat-runs-limit)
          (octocat-refresh))))
      (_ nil))))

(defun octocat-browse ()
  "Open the item at point in the browser via gh."
  (interactive)
  (let* ((section (magit-current-section))
         (type    (and section (oref section type)))
         (value   (and section (oref section value)))
         (repo    (or octocat--repo octocat--pr-repo octocat--run-repo))
         (gh      (executable-find "gh")))
    (unless gh
      (user-error "Octocat: `gh' executable not found"))
    (pcase type
      ('pr
       (let ((number (gethash "number" value)))
         (message "Octocat: Opening PR #%d in browser…" number)
         (start-process "octocat-browse" nil gh
                        "pr" "view" "--web"
                        (number-to-string number)
                        "--repo" repo)))
      ('commit
       (let* ((oid   (or (gethash "oid" value) ""))
              (url   (format "https://github.com/%s/commit/%s" repo oid)))
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
       (let* ((run-id (or (gethash "databaseId" value)
                          octocat--run-id))
              (url    (format "https://github.com/%s/actions/runs/%s"
                              repo (number-to-string run-id))))
         (message "Octocat: Opening run #%s in browser…" run-id)
         (browse-url url)))
      ('octocat-root
       (let ((url (format "https://github.com/%s" repo)))
         (message "Octocat: Opening %s in browser…" repo)
         (browse-url url)))
      (_ nil))))


;;;; Load-more command

(defun octocat--pageable-section-at-point ()
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

(defun octocat-load-more ()
  "Load more items in the pageable list section at point.
Increments the per-session fetch limit for whichever of the Pull
Requests, Issues, Commits, or Workflow Runs sections contains point,
then re-runs `octocat-refresh'.  Signals an error when point is not
inside a pageable section."
  (interactive)
  (pcase (octocat--pageable-section-at-point)
    ('pull-requests
     (cl-incf octocat--prs-count octocat-prs-limit)
     (octocat-refresh))
    ('issues
     (cl-incf octocat--issues-count octocat-issues-limit)
     (octocat-refresh))
    ('commits
     (cl-incf octocat--commits-count octocat-commits-limit)
     (octocat-refresh))
    ('workflow-runs
     (cl-incf octocat--runs-count octocat-runs-limit)
     (octocat-refresh))
    (_ (user-error "Octocat: No pageable section at point"))))


;;;; Entry point

;;;###autoload
(defun octocat ()
  "Open (or switch to) the octocat buffer for the current GitHub repository."
  (interactive)
  (let* ((repo (octocat--current-repo))
         (buf-name (format "*octocat: %s*" repo))
         (buf (get-buffer-create buf-name)))
    (switch-to-buffer buf)
    (unless (derived-mode-p 'octocat-mode)
      (octocat-mode))
    (setq octocat--repo repo)
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
