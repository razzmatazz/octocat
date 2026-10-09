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

;; Per-repository overview buffer: a one-call summary (open issue/PR
;; counts, with buttons into the list pages in octocat-pr.el, octocat-issue.el, octocat-workflow.el) and the
;; recent Commits.  The PR, issue and workflow/run lists live on their own
;; pages; this file still holds their shared row builders and fetchers.
;; The `M-x octocat-repo' entry point is defined in octocat.el (see
;; CONTRIBUTING.md, "Entry points"); this file defines `octocat-repo-mode'
;; and all of its supporting logic.
;;
;; Rendered with vui.el (https://github.com/d12frosted/vui.el) instead of
;; magit-section.  This replaces:
;;   - octocat-repo--save-section-state / octocat-repo--hide-if-saved
;;     (collapse state had to be snapshotted before every erase and
;;     re-applied during construction) with vui-collapsible's own
;;     component state, which vui's reconciliation preserves automatically
;;     across re-renders.
;;   - octocat--save-point / octocat--restore-point + the
;;     magit-section-ident-value override on hash-tables (cursor identity
;;     across a full erase-and-rebuild) with vui's own path-based cursor
;;     tracking.
;;   - the buffer-local `octocat-repo--counts' alist + a global
;;     `octocat-repo-load-more' command that had to locate the pageable
;;     section at point, with a per-section `:limit' state var and a
;;     "Load more" button local to that section.
;;   - the hand-rolled `pending' sentinel + `cl-labels' `maybe-render'
;;     fan-in across 7 async gh calls with `vui-use-async', called once
;;     per section (and twice in the root, for default-branch and
;;     fork-parent); each section/hook manages its own pending/ready/error
;;     state independently.
;; See docs/magit-section.md for what the replaced machinery looked like.
;;
;; Known regressions / gaps in this first pass (see AGENTS.md's note on
;; this migration for context -- deliberately accepted for now):
;;   - No disk cache / stale-while-revalidate: every `octocat-repo-refresh'
;;     fully remounts the component tree via `vui-mount', so there is no
;;     "render stale cache instantly, then replace with live data" step,
;;     and no `mode-line-process' indicator (each section's own
;;     "Loading…" placeholder signals progress instead).
;;   - Because every refresh remounts, collapse state and "load more"
;;     limits reset to their defaults on each *explicit* refresh
;;     (`revert-buffer', reopening via `octocat-visit-repo', etc.).  They
;;     are preserved correctly for interactions *within* one mount
;;     (collapsing a section, clicking "load more", navigating away and
;;     back via `switch-to-buffer') since those go through vui's
;;     reconciliation, not a remount.
;;   - No Evil integration attempted.  Row navigation uses a `keymap' text
;;     property per row (via `vui-region'), which is not necessarily
;;     higher priority than Evil's normal/motion state keymaps (installed
;;     via `emulation-mode-map-alists'); RET may or may not reach the row
;;     handler under `evil-mode' and needs real investigation, unlike the
;;     aux-keymap-divergence fix documented in AGENTS.md for the
;;     magit-section-derived modes, which does not apply here since
;;     `octocat-repo-mode' no longer derives from `magit-section-mode'.
;;   - Per-row "open in browser" (what `octocat-browse' used to do for a
;;     `pr'/`issue'/`octocat-commit'/`workflow'/`workflow-run' section at
;;     point) is not implemented; `C-c C-o' opens the repository's GitHub
;;     page unconditionally instead.

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
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-collapsible, vui-heading-*, etc.

;; Cross-file calls: declared per AGENTS.md's "Byte-compiler warnings about
;; functions not known to be defined" -- `make ci' compiles all files in
;; parallel, so a plain `require' does not guarantee the callee is already
;; compiled when this file is.
(declare-function octocat-pr-mode                  "octocat-pr"       ())
(declare-function octocat--render-pr-loading       "octocat-pr"       (number title state))
(declare-function octocat-pr-refresh               "octocat-pr"       (&optional _ignore-auto _noconfirm))
(declare-function octocat-issue-mode               "octocat-issue"    ())
(declare-function octocat--render-issue-loading    "octocat-issue"    (number title state))
(declare-function octocat-issue-refresh            "octocat-issue"    (&optional _ignore-auto _noconfirm))
(declare-function octocat-workflow-mode            "octocat-workflow" ())
(declare-function octocat--render-workflow-loading "octocat-workflow" (name))
(declare-function octocat-workflow-refresh         "octocat-workflow" (&optional _ignore-auto _noconfirm))
(declare-function octocat-run-mode                 "octocat-run"      ())
(declare-function octocat--render-run-loading      "octocat-run"      (run-id))
(declare-function octocat-run-refresh              "octocat-run"      (&optional _ignore-auto _noconfirm))
(declare-function octocat-commit-mode              "octocat-commit"   ())
(declare-function octocat--render-commit-loading   "octocat-commit"   (sha))
(declare-function octocat-commit-refresh           "octocat-commit"   (&optional _ignore-auto _noconfirm))
(declare-function octocat-tree-open                "octocat-tree"     ())
(declare-function octocat-tree-find-file           "octocat-tree"     ())
(declare-function octocat-issues                   "octocat"          ())
(declare-function octocat-prs                      "octocat"          ())
(declare-function octocat-workflows                "octocat"          ())

;; Buffer-locals this file `setq's in a *different* buffer (the target
;; detail buffer, after `pop-to-buffer') than the one that defines them.
(defvar octocat--pr-repo)        ; defined as buffer-local in octocat-pr.el
(defvar octocat--pr-number)      ; defined as buffer-local in octocat-pr.el
(defvar octocat--issue-repo)     ; defined as buffer-local in octocat-issue.el
(defvar octocat--issue-number)   ; defined as buffer-local in octocat-issue.el
(defvar octocat--workflow-repo)  ; defined as buffer-local in octocat-workflow.el
(defvar octocat--workflow-id)    ; defined as buffer-local in octocat-workflow.el
(defvar octocat--workflow-name)  ; defined as buffer-local in octocat-workflow.el
(defvar octocat--run-repo)       ; defined as buffer-local in octocat-run.el
(defvar octocat--run-id)         ; defined as buffer-local in octocat-run.el
(defvar octocat--commit-repo)    ; defined as buffer-local in octocat-commit.el
(defvar octocat--commit-sha)     ; defined as buffer-local in octocat-commit.el


;;;; User options

(defcustom octocat-section-limit 15
  "Default number of items to display per section in the repo buffer.
Used as the initial page size for Pull Requests, Issues, Workflow Runs,
and Commits.  Each section starts with this many items and increments
by this amount every time its \"Load more\" button is used."
  :type 'integer
  :group 'octocat)


;;;; Buffer-local state
;;
;; Only the two identifying values survive as plain buffer-locals: they
;; are set directly by external callers (`octocat.el', `octocat-visit-repo'
;; in octocat-core.el) before `octocat-repo-refresh' is invoked.  Collapse
;; state, per-section pagination limits, and fetched data all live as vui
;; component state/hook results instead -- see the Commentary above.

(defvar-local octocat-repo--repo nil
  "The \"owner/repo\" string this buffer is tracking.")

(defvar-local octocat-repo--local-dir nil
  "Absolute path to the local clone directory, or nil when detached.
Set at buffer-open time from `default-directory' when the buffer is
opened from inside a git working tree.  Nil means the buffer was opened
in detached mode — tracking a remote repository without a local clone.")

(defvar-local octocat-repo--current-branch nil
  "Name of the local HEAD branch, or nil when detached or unknown.
Set by `octocat-repo-refresh'.  Read by `octocat-tree.el' (`C-c C-t',
`C-c C-f') to pick the branch whose tree to browse.")


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

(defun octocat-repo-vui--resolve-or-reject (result resolve reject)
  "Route RESULT from an octocat gh-fetch callback to RESOLVE or REJECT.
RESULT is whatever an octocat `octocat--run-gh'-based fetch function
passes to its callback: either the parsed data, or a cons
\\=(error . MSG).  A disabled-feature error (see
`octocat-repo--disabled-feature-p') resolves to nil (an empty list)
rather than rejecting, matching the previous magit-section
rendering's \"(no pull requests)\" treatment of disabled features."
  (cond
   ((not (eq (car-safe result) 'error)) (funcall resolve result))
   ((octocat-repo--disabled-feature-p result) (funcall resolve nil))
   (t (funcall reject (cdr result)))))

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

(defconst octocat-repo--summary-query
  "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){defaultBranchRef{name} parent{nameWithOwner} issues(states:OPEN){totalCount} pullRequests(states:OPEN){totalCount}}}"
  "GraphQL query behind `octocat-repo--fetch-summary'.")

(defun octocat-repo--parse-summary (json-string)
  "Parse the GraphQL response JSON-STRING into a summary plist.
Keys: :default-branch (string or nil), :fork-parent (\"owner/repo\" or
nil), :open-issues and :open-prs (integers)."
  (let* ((repo (gethash "repository"
                        (gethash "data" (json-parse-string json-string :null-object nil))))
         (ref    (gethash "defaultBranchRef" repo))
         (parent (gethash "parent" repo)))
    (list :default-branch (and ref (gethash "name" ref))
          :fork-parent    (and parent (gethash "nameWithOwner" parent))
          :open-issues    (gethash "totalCount" (gethash "issues" repo))
          :open-prs       (gethash "totalCount" (gethash "pullRequests" repo)))))

(defun octocat-repo--fetch-summary (repo callback)
  "Fetch the repo-view summary for REPO asynchronously in one API call.
Calls CALLBACK with the plist described in `octocat-repo--parse-summary',
or a cons \\=(error . MSG) on failure.  One GraphQL request replaces what
would otherwise be separate default-branch, fork-parent and
issue/PR-count lookups."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "repo-summary"
     (list "api" "graphql"
           "-f" (concat "query=" octocat-repo--summary-query)
           "-F" (concat "owner=" (car parts))
           "-F" (concat "name=" (cadr parts)))
     #'octocat-repo--parse-summary
     callback)))


(defun octocat-repo--summary-cache-load (repo)
  "Load the cached summary plist of REPO (see `octocat-repo--parse-summary')."
  (when-let* ((data (octocat--detail-cache-load repo "summary" "repo")))
    (let ((str (lambda (k) (let ((v (gethash k data))) (and (stringp v) v))))
          (num (lambda (k) (let ((v (gethash k data))) (and (integerp v) v)))))
      (list :default-branch (funcall str "default-branch")
            :fork-parent    (funcall str "fork-parent")
            :open-issues    (funcall num "open-issues")
            :open-prs       (funcall num "open-prs")))))

(defun octocat-repo--summary-cache-save (repo summary)
  "Persist the SUMMARY plist of REPO (see `octocat-repo--parse-summary')."
  (let ((data (make-hash-table :test #'equal)))
    (puthash "default-branch" (or (plist-get summary :default-branch) :null) data)
    (puthash "fork-parent"    (or (plist-get summary :fork-parent) :null) data)
    (puthash "open-issues"    (or (plist-get summary :open-issues) :null) data)
    (puthash "open-prs"       (or (plist-get summary :open-prs) :null) data)
    (octocat--detail-cache-save repo "summary" "repo" data)))


;;;; Row rendering
;;
;; The generic row / sticky-async / load-more helpers live in
;; `octocat-vui.el'; only the per-entity row builders are here (see
;; "Row builders" below).


;;;; Navigation
;;
;; Each of these opens (or switches to) the corresponding detail buffer.
;; This is the same buffer-setup sequence `octocat-visit' uses for these
;; section types in every other (magit-section-based) view, just called
;; directly from a row's `:on-click'/RET handler instead of being reached
;; through a shared "inspect the section at point" dispatcher -- there is
;; no section at point to inspect here.

(defun octocat-repo-vui--open-pr (repo pr)
  "Open the PR detail buffer for PR (a hash-table) in REPO."
  (let* ((number   (gethash "number" pr))
         (title    (or (gethash "title" pr) ""))
         (state    (or (gethash "state" pr) "OPEN"))
         (buf-name (format "*octocat-pr: %s#%d*" repo number))
         (buf      (get-buffer-create buf-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-pr-mode)
      (octocat-pr-mode))
    (setq octocat--pr-repo repo
          octocat--pr-number number)
    (octocat--render-pr-loading number title state)
    (octocat-pr-refresh)))

(defun octocat-repo-vui--open-issue (repo issue)
  "Open the issue detail buffer for ISSUE (a hash-table) in REPO."
  (let* ((number   (gethash "number" issue))
         (title    (or (gethash "title" issue) ""))
         (state    (or (gethash "state" issue) "OPEN"))
         (buf-name (format "*octocat-issue: %s#%d*" repo number))
         (buf      (get-buffer-create buf-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-issue-mode)
      (octocat-issue-mode))
    (setq octocat--issue-repo repo
          octocat--issue-number number)
    (octocat--render-issue-loading number title state)
    (octocat-issue-refresh)))

(defun octocat-repo-vui--open-commit (repo commit)
  "Open the commit detail buffer for COMMIT (a hash-table) in REPO."
  (let* ((oid      (or (gethash "sha" commit) (gethash "oid" commit) ""))
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

(defun octocat-repo-vui--open-workflow (repo workflow)
  "Open the workflow detail buffer for WORKFLOW (a hash-table) in REPO."
  (let* ((id       (gethash "id" workflow))
         (name     (or (gethash "name" workflow) ""))
         (buf-name (format "*octocat-workflow: %s/%s*" repo name))
         (buf      (get-buffer-create buf-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-workflow-mode)
      (octocat-workflow-mode))
    (setq octocat--workflow-repo repo
          octocat--workflow-id   id
          octocat--workflow-name name)
    (octocat--render-workflow-loading name)
    (octocat-workflow-refresh)))

(defun octocat-repo-vui--open-workflow-run (repo run)
  "Open the workflow-run detail buffer for RUN (a hash-table) in REPO."
  (let* ((run-id   (gethash "databaseId" run))
         (buf-name (format "*octocat-run: %s#%d*" repo run-id))
         (buf      (get-buffer-create buf-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-run-mode)
      (octocat-run-mode))
    (setq octocat--run-repo repo
          octocat--run-id   run-id)
    (octocat--render-run-loading run-id)
    (octocat-run-refresh)))


;;;; Row builders

(defconst octocat-repo-vui--number-width 6
  "Display width of the right-aligned #NUMBER column in PR and issue rows.")

(defconst octocat-repo-vui--state-width 6
  "Display width of the state column (\"closed\", \"merged\") in PR and issue rows.")

(defconst octocat-repo-vui--detail-indent
  (+ 2 octocat-repo-vui--state-width 1 octocat-repo-vui--number-width 2)
  "Column where titles, and the second detail line, start in PR/issue rows.
Margin, state column, space, number column, gap.")

(defun octocat-repo-vui--state-label (state &optional draft)
  "Return the coloured, padded state text for a PR/issue STATE (any case).
DRAFT is the JSON isDraft value; t shows an open pull request as \"draft\"."
  (let* ((state (downcase (or state "open")))
         (text  (cond ((equal state "merged") "merged")
                      ((equal state "closed") "closed")
                      ((eq draft t) "draft")
                      (t "open")))
         (face  (cond ((equal text "merged") 'octocat-pr-state-merged)
                      ((equal text "closed") 'octocat-pr-state-closed)
                      ((equal text "draft")  'octocat-dimmed)
                      (t                     'octocat-pr-state-open))))
    (propertize (format (format "%%-%ds" octocat-repo-vui--state-width) text)
                'face face)))

(defun octocat-repo-vui--detail-line (item &optional leading trailing)
  "Return a second row line for ITEM, or \"\" when there is nothing to show.
The line starts with a newline and is indented to sit under the title.
It holds the strings in LEADING (e.g. a branch name), then the coloured
label chips of ITEM, then the strings in TRAILING (e.g. CI status).  Nil
and empty strings are skipped."
  (let* ((chips (octocat--format-labels (gethash "labels" item)))
         (parts (seq-remove (lambda (s) (or (null s) (string-empty-p s)))
                            (append leading (list chips) trailing)))
         (indent octocat-repo-vui--detail-indent))
    (if (null parts)
        ""
      (concat "\n"
              (make-string indent ?\s)
              (mapconcat #'identity parts "  ")))))

(defun octocat-repo-vui--pr-row (repo pr current-branch)
  "Return a row vnode for PR in REPO.
CURRENT-BRANCH, when non-nil, is the local HEAD branch name; a matching
PR branch is highlighted with `octocat-branch-current'."
  (let* ((number  (format (format "%%%ds" octocat-repo-vui--number-width)
                          (format "#%d" (gethash "number" pr))))
         (title   (or (gethash "title" pr) ""))
         (branch  (or (gethash "headRefName" pr) ""))
         (activep (and current-branch (string= branch current-branch)))
         (b-face  (if activep 'octocat-branch-current 'octocat-branch))
         (author  (octocat--author-login pr))
         (ci      (octocat--ci-label pr))
         (has-checks (let ((c (gethash "statusCheckRollup" pr)))
                       (and c (not (eq c :null)) (> (length c) 0))))
         (line
          (concat
           "  "
           (octocat-repo-vui--state-label (gethash "state" pr)
                                          (gethash "isDraft" pr))
           " "
           (propertize number 'face 'octocat-pr-number)
           "  "
           (octocat--format-title title)
           "  "
           (propertize author 'face 'octocat-pr-author)
           (octocat-repo-vui--detail-line
            pr
            (list (and (not (string-empty-p branch))
                       (propertize branch 'face b-face)))
            (list (and has-checks ci))))))
    (octocat-vui-row line
                     (lambda () (octocat-repo-vui--open-pr repo pr))
                     "RET: viewpull request")))

(defun octocat-repo-vui--issue-row (repo issue)
  "Return a row vnode for ISSUE in REPO."
  (let* ((number (format (format "%%%ds" octocat-repo-vui--number-width)
                         (format "#%d" (gethash "number" issue))))
         (title  (or (gethash "title"  issue) ""))
         (author (octocat--author-login issue))
         (line
          (concat
           "  "
           (octocat-repo-vui--state-label (gethash "state" issue))
           " "
           (propertize number 'face 'octocat-pr-number)
           "  "
           (octocat--format-title title)
           "  "
           (propertize author 'face 'octocat-pr-author)
           (octocat-repo-vui--detail-line issue))))
    (octocat-vui-row line
                     (lambda () (octocat-repo-vui--open-issue repo issue))
                     "RET: viewissue")))

(defun octocat-repo-vui--workflow-row (repo workflow)
  "Return a row vnode for WORKFLOW in REPO."
  (let* ((name       (or (gethash "name"  workflow) ""))
         (state      (downcase (or (gethash "state" workflow) "")))
         (state-face (if (equal state "active") 'success 'octocat-dimmed))
         (line
          (concat
           "  "
           (truncate-string-to-width name 40 nil nil "…")
           "  "
           (propertize state 'face state-face))))
    (octocat-vui-row line
                     (lambda () (octocat-repo-vui--open-workflow repo workflow))
                     "RET: viewworkflow")))

(defun octocat-repo-vui--workflow-run-row (repo run current-branch wf-w)
  "Return a row vnode for RUN in REPO.
CURRENT-BRANCH, when non-nil, highlights a matching run branch.
WF-W is the column width to truncate/pad the workflow name to."
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
         (icon       (octocat--workflow-run-icon status conclusion))
         (line
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
           (propertize date 'face 'octocat-dimmed))))
    (octocat-vui-row line
                     (lambda () (octocat-repo-vui--open-workflow-run repo run))
                     "RET: viewworkflow run")))

(defun octocat-repo-vui--commit-row (repo commit head-info)
  "Return a row vnode for COMMIT in REPO.
HEAD-INFO as in `octocat-repo-vui--commits-section'; the local HEAD
commit is highlighted."
  (let* ((head-hash (and head-info (plist-get head-info :hash)))
         (sha       (or (gethash "sha" commit) ""))
         (short     (substring sha 0 (min 11 (length sha))))
         (is-head   (and head-hash
                        (>= (length sha) (length head-hash))
                        (string-prefix-p head-hash sha)))
         (c         (gethash "commit" commit))
         (message   (or (and c (gethash "message" c)) ""))
         (subject   (car (split-string message "\n")))
         (ca        (and c (gethash "author" c)))
         (author    (octocat--commit-author commit))
         (date      (octocat--relative-ts
                     (or (and ca (gethash "date" ca)) "")))
         (line
          (concat
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
           (propertize date 'face 'octocat-dimmed))))
    (octocat-vui-row line
                     (lambda () (octocat-repo-vui--open-commit repo commit))
                     "RET: viewcommit")))


;;;; Sections
;;
;; Each section owns its async fetch (`vui-use-async') and, for the
;; pageable ones, its "load more" limit (`:state').  Compare to
;; `octocat-repo--render-prs' et al. plus `octocat-repo-refresh's fan-in
;; and `octocat-repo-load-more's "find the pageable section at point"
;; walk in the previous magit-section implementation.

(vui-defcomponent octocat-repo-vui--commits-section (repo default-branch current-branch head-info)
  "Commits section for REPO.
The commits are those of the default branch (the API call names no other),
so DEFAULT-BRANCH appears once in the title instead of on every row; it is
highlighted when it is also the local CURRENT-BRANCH.  HEAD-INFO is the
plist from `octocat--head-info', used to highlight the local HEAD commit."
  :state ((limit octocat-section-limit))
  :render
  (let* ((cached (vui-use-memo (repo)
                   (octocat--items-cache-load repo "commits" "default")))
         ;; Only the first page is cached; it shows until the fetch lands.
         (stale  (and (= limit octocat-section-limit) (plist-get cached :items)))
         (sticky (octocat-vui-use-async-sticky (list 'commits repo limit)
                   (lambda (resolve reject)
                     (octocat-repo--list-commits
                      repo limit
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (fresh  (and (eq (plist-get sticky :status) 'ready)
                      (not (plist-get sticky :refreshing))
                      (plist-get sticky :data)))
         (result (octocat-vui-with-stale sticky stale))
         ;; The cached list is labelled with the branch it was fetched for.
         (branch (if (eq result sticky) default-branch (plist-get cached :branch))))
    (vui-use-effect (fresh default-branch)
      (when (and fresh default-branch (= limit octocat-section-limit))
        (octocat--items-cache-save repo "commits" "default" fresh default-branch))
      nil)
    (vui-collapsible
     :title (concat
             (if (and (stringp branch) (not (string-empty-p branch)))
                 (concat "Commits on "
                         (propertize branch 'face
                                     (if (equal branch current-branch)
                                         'octocat-branch-current
                                       'octocat-branch)))
               "Commits")
             (octocat-vui-loading-suffix result))
     :key 'commits :initially-expanded t :indent 0
     (pcase (plist-get result :status)
       ('pending (vui-text "  Loading…\n" :face 'octocat-dimmed))
       ('error   (vui-text (format "  %s\n" (plist-get result :error)) :face 'octocat-dimmed))
       ('ready
        (let ((commits (plist-get result :data)))
          (vui-fragment
           (if (null commits)
               (vui-text "  (no commits)\n" :face 'octocat-dimmed)
             (vui-list commits
                       (lambda (c)
                         (octocat-repo-vui--commit-row repo c head-info))
                       (lambda (c) (gethash "sha" c))))
           (when (and commits
                      (or (>= (length commits) limit)
                          ;; Keep the button in place while a further page
                          ;; loads, but not for the first, cached paint.
                          (and (plist-get result :refreshing)
                               (> limit octocat-section-limit))))
             (octocat-vui-load-more-button
              'load-more-commits octocat-section-limit
              "RET: load more commits"
              (lambda () (vui-set-state :limit (+ limit octocat-section-limit)))
              (plist-get result :refreshing))))))))))

;;;; Root

(defun octocat-repo-vui--nav-buttons (summary)
  "Return a list of buttons opening the issue, PR and workflow pages.
The issue and PR buttons show their open counts, as GitHub's tabs do,
from SUMMARY, the plist from
`octocat-repo--fetch-summary', or an ellipsis while it is still loading."
  (let ((issues (plist-get summary :open-issues))
        (prs    (plist-get summary :open-prs)))
    (list
     (vui-button (format "Issues (%s)" (or issues "…"))
                 :face 'octocat-dimmed
                 :help-echo "RET: list issues"
                 :on-click #'octocat-issues)
     (vui-button (format "Pull requests (%s)" (or prs "…"))
                 :face 'octocat-dimmed
                 :help-echo "RET: list pull requests"
                 :on-click #'octocat-prs)
     (vui-button "Workflows"
                 :face 'octocat-dimmed
                 :help-echo "RET: list workflows and runs"
                 :on-click #'octocat-workflows))))

(vui-defcomponent octocat-repo-vui--root (repo local-dir)
  "Root component for the repo buffer: header, local-head/fork-parent
info, issue/PR summary line, then the commits section.
Everything but the commits comes from a single summary API call."
  :render
  (let* ((head-info      (octocat--head-info))
         (current-branch (plist-get head-info :branch))
         (cached         (vui-use-memo (repo) (octocat-repo--summary-cache-load repo)))
         (summary-result (vui-use-async (list 'summary repo)
                           (lambda (resolve reject)
                             (octocat-repo--fetch-summary
                              repo
                              (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (fresh          (and (eq (plist-get summary-result :status) 'ready)
                              (plist-get summary-result :data)))
         ;; The cached summary shows until the fresh one arrives, so the
         ;; counts and the branch don't pop in.
         (summary        (or fresh cached))
         (default-branch (plist-get summary :default-branch))
         (fork-parent    (plist-get summary :fork-parent)))
    (vui-use-effect (fresh)
      (when fresh (octocat-repo--summary-cache-save repo fresh))
      nil)
    (vui-vstack
     (apply #'vui-hstack :spacing 2
            (vui-text repo :face 'octocat-repo)
            (vui-button "Code"
                        :face 'octocat-dimmed
                        :help-echo "RET: browse file tree"
                        :on-click (lambda () (octocat-tree-open)))
            (octocat-repo-vui--nav-buttons summary))
     (when local-dir
       (vui-text
        (concat (propertize "Local clone:" 'face 'octocat-dimmed)
                "  "
                (propertize local-dir 'face 'octocat-branch))))
     (when fork-parent
       (octocat-vui-row
        (concat "Forked from  " (propertize fork-parent 'face 'octocat-repo) "\n")
        (lambda () (octocat-visit-repo fork-parent))
        "RET: open parent repo view"))
     (vui-newline)
     (vui-component 'octocat-repo-vui--commits-section
                    :repo repo :default-branch default-branch
                    :current-branch current-branch :head-info head-info))))


;;;; Major mode

(defun octocat-repo-browse ()
  "Open the current repository's GitHub page in a browser.
Unlike the shared `octocat-browse' (used by every magit-section-based
view to dispatch on the section at point), this always opens the
whole-repository page: `octocat-repo-mode' has no section at point to
dispatch on, so per-row \"open in browser\" is not implemented yet (see
octocat-repo.el's Commentary)."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (message "Octocat: Opening %s in browser…" octocat-repo--repo)
  (browse-url (format "https://github.com/%s" octocat-repo--repo)))

(defvar octocat-repo-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-repo-mode'.")
(define-key octocat-repo-mode-map (kbd "q") #'quit-window)
(define-key octocat-repo-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-repo-mode-map (kbd "C-c C-t") #'octocat-tree-open)
(define-key octocat-repo-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)
(define-key octocat-repo-mode-map (kbd "C-c C-o") #'octocat-repo-browse)
(define-key octocat-repo-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-repo-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-repo-mode vui-mode "Octocat-Repo"
  "Major mode for browsing a GitHub repository.

\\{octocat-repo-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-repo-refresh))


;;;; Async refresh

(defun octocat-repo-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat-repo buffer.
Mounts the vui.el component tree for `octocat-repo--repo' via
`vui-mount'.  Every section fetches its own data independently (see
the Commentary at the top of this file for what that changes, and what
it gives up, versus the previous magit-section-based implementation)."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (setq octocat-repo--current-branch
        (plist-get (octocat--head-info) :branch))
  (vui-mount (vui-component 'octocat-repo-vui--root
                            :repo octocat-repo--repo
                            :local-dir octocat-repo--local-dir)
             (buffer-name)))

;; NOTE: the `M-x octocat-repo' entry point itself (the `;;;###autoload'
;; command) is defined in `octocat.el', not here -- see CONTRIBUTING.md,
;; "Entry points".  This keeps every `;;;###autoload' command funneled
;; through a single file, so loading any octocat entry point always loads
;; `octocat.el' and its `octocat--evil-init' trigger.  This file supplies
;; everything the command needs: `octocat-repo-mode', `octocat-repo--repo',
;; `octocat-repo--local-dir', `octocat-repo--current-repo', and
;; `octocat-repo-refresh'.

(provide 'octocat-repo)
;;; octocat-repo.el ends here
