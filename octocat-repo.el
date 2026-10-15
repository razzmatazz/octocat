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
;; counts, with buttons into the list pages in octocat-pr.el, octocat-issue.el, octocat-actions.el) and the
;; recent Commits.  The PR, issue and workflow/run lists live on their own
;; pages; this file still holds their shared row builders and fetchers.
;; The `M-x octocat-repo' entry point is defined in octocat.el (see
;; CONTRIBUTING.md, "Entry points"); this file defines `octocat-repo-mode'
;; and all of its supporting logic.
;;
;; Known regressions / gaps in this first pass (see AGENTS.md's note on
;; this migration for context -- deliberately accepted for now):
;;   - No disk cache / stale-while-revalidate: every `octocat-repo-refresh'
;;     fully remounts the component tree via `vui-mount', so there is no
;;     "render stale cache instantly, then replace with live data" step.
;;   - Because every refresh remounts, collapse state and "load more"
;;     limits reset to their defaults on each *explicit* refresh
;;     (`revert-buffer', reopening via `octocat-visit-repo', etc.).  They
;;     are preserved correctly for interactions *within* one mount
;;     (collapsing a section, clicking "load more", navigating away and
;;     back via `switch-to-buffer') since those go through vui's
;;     reconciliation, not a remount.

;;; Code:

(require 'octocat-core)
(require 'seq)
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
(declare-function octocat-run-open                 "octocat-run"      (repo run-id))
(declare-function octocat-tree-open                "octocat-tree"     ())
(declare-function octocat-tree-find-file           "octocat-tree"     ())
(declare-function octocat-issue-list               "octocat"          ())
(declare-function octocat-pr-list                  "octocat"          ())
(declare-function octocat-actions                  "octocat"          ())


;;;; User options

(defcustom octocat-section-limit 15
  "Default number of items to display per paged section.
Used as the initial page size for workflow runs and user repos.  Each
section starts with this many items and increments by this amount
every time its \"Load more\" button is used."
  :type 'integer
  :group 'octocat)

(defcustom octocat-repo-commits-page-size 25
  "Number of commits the repo buffer shows, and loads, at a time."
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

(defvar-local octocat-repo--branch nil
  "Branch the page shows, or nil for the default branch.
Chosen with `octocat-repo-switch-branch'; kept by `g', cleared when the
page is opened anew.  The Code tab browses it too.")

(defvar-local octocat-repo--default-branch nil
  "The repository's default branch, once its summary is known.")


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


;;;; Unpushed commits

(defun octocat-repo--git-lines (dir &rest args)
  "Return the output lines of git ARGS run in DIR, or nil when it fails."
  (let ((default-directory dir))
    (with-temp-buffer
      (and (eq 0 (apply #'process-file "git" nil '(t nil) nil args))
           (split-string (buffer-string) "\n" t)))))

(defun octocat-repo--parse-unpushed (lines)
  "Parse LINES of \"SHA NUL SUBJECT\" into plists."
  (mapcar (lambda (l)
            (pcase-let ((`(,sha ,subject) (split-string l "\0")))
              (list :sha sha :subject subject)))
          lines))

(defun octocat-repo--unpushed (dir)
  "Return the local commits in DIR not yet on GitHub, or nil when none.
The result is a plist: :commits from `octocat-repo--parse-unpushed',
newest first, :upstream the remote-tracking branch they are counted
against (nil for a branch never pushed, counted against every origin
branch), and :behind how many upstream commits HEAD lacks, as of the
last fetch; non-zero means the branches diverged.  Reads git synchronously."
  (let* ((upstream (car (octocat-repo--git-lines
                         dir "rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{u}")))
         (log      (append '("log" "--format=%H%x00%s")
                           (if upstream
                               '("@{u}..HEAD")
                             '("HEAD" "--not" "--remotes=origin"))))
         (commits  (octocat-repo--parse-unpushed
                    (apply #'octocat-repo--git-lines dir log))))
    (when commits
      (list :commits commits
            :upstream upstream
            :behind (if upstream
                        (string-to-number
                         (or (car (octocat-repo--git-lines
                                   dir "rev-list" "--count" "HEAD..@{u}"))
                             "0"))
                      0)))))


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
rather than rejecting, so the section shows \"(no pull requests)\"."
  (cond
   ((not (eq (car-safe result) 'error)) (funcall resolve result))
   ((octocat-repo--disabled-feature-p result) (funcall resolve nil))
   (t (funcall reject (cdr result)))))


(defun octocat-repo-vui-use-cached (type repo number fetch &optional as-list)
  "Return the `vui-use-async' result of FETCH for item NUMBER of REPO.
NUMBER is what identifies the item, such as a PR number or a commit SHA.
TYPE is the disk-cache type (see `octocat--detail-cache-file').  The last
saved data shows at once with :refreshing t (see `octocat-vui-with-stale')
while FETCH, called with REPO, NUMBER and a callback, runs on every open
of the page; fresh data replaces it in place and is saved.  AS-LIST says
the data is a list, which the cache stores as a vector.
Must be called during render, like any hook."
  (let* ((cached (vui-use-memo (repo number)
                   (let ((raw (octocat--detail-cache-load repo type number)))
                     (and raw (if as-list (cl-coerce raw 'list) raw)))))
         (async  (vui-use-async (list type repo number)
                   (lambda (resolve reject)
                     (funcall fetch repo number
                              (lambda (r)
                                (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (fresh  (and (eq (plist-get async :status) 'ready)
                      (plist-get async :data))))
    (vui-use-effect (fresh)
      (when fresh
        (octocat--detail-cache-save repo type number
                                    (if as-list (vconcat fresh) fresh)))
      nil)
    (octocat-vui-with-stale async cached)))
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

(defconst octocat-repo--history-query
  "query($owner:String!,$name:String!,$ref:String!,$limit:Int!,$after:String){repository(owner:$owner,name:$name){object(expression:$ref){...on Commit{history(first:$limit,after:$after){edges{cursor node{oid messageHeadline authoredDate author{name email user{login}}}}}}}}}"
  "GraphQL query behind `octocat-repo--list-commits'.
Only what a row shows: the REST commits endpoint sends ~15 times as much.")

(defun octocat-repo--list-commits (repo ref callback &optional after)
  "Fetch a page of the commits of REPO, from REF back.
REF is a branch or SHA; nil means the head of the default branch.
AFTER, a commit's \"cursor\", fetches the page after that commit.  A
page holds `octocat-repo-commits-page-size' commits.  Calls CALLBACK with
a list of commits from `octocat-repo--parse-history', or a cons
\\=(error . MSG)."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "commits"
     (append (list "api" "graphql"
                   "-f" (concat "query=" octocat-repo--history-query)
                   "-f" (concat "owner=" (car parts))
                   "-f" (concat "name=" (cadr parts))
                   "-f" (concat "ref=" (or ref "HEAD"))
                   "-F" (format "limit=%d" octocat-repo-commits-page-size))
             (and after (list "-f" (concat "after=" after))))
     #'octocat-repo--parse-history
     callback)))

(defun octocat-repo--parse-history (json-string)
  "Parse the commit history response JSON-STRING into a list of commits.
Each is shaped as the REST commits endpoint has it, which is what the
rows read: \"sha\"; \"commit\", with the \"message\" (its headline only)
and the git \"author\" (name, email, date); and \"author\", the GitHub
user or :null.  It also has its \"cursor\", for the page after it."
  (let* ((repo (gethash "repository" (gethash "data" (json-parse-string json-string))))
         (obj  (and (hash-table-p repo) (gethash "object" repo))))
    (unless (hash-table-p obj)
      (error "No such branch or commit"))
    (mapcar (lambda (edge)
              (let* ((node   (gethash "node" edge))
                     (a      (gethash "author" node))
                     (user   (and (hash-table-p a) (gethash "user" a)))
                     (git    (make-hash-table :test #'equal))
                     (c      (make-hash-table :test #'equal))
                     (commit (make-hash-table :test #'equal)))
                (when (hash-table-p a)
                  (puthash "name" (gethash "name" a) git)
                  (puthash "email" (gethash "email" a) git))
                (puthash "date" (gethash "authoredDate" node) git)
                (puthash "message" (gethash "messageHeadline" node) c)
                (puthash "author" git c)
                (puthash "sha" (gethash "oid" node) commit)
                (puthash "commit" c commit)
                (puthash "author" (if (hash-table-p user) user :null) commit)
                (puthash "cursor" (gethash "cursor" edge) commit)
                commit))
            (gethash "edges" (gethash "history" obj)))))

(defun octocat-repo--commits-merge (base &rest others)
  "Return the longest of BASE and OTHERS with the head commit of BASE.
Each is a commit list from the top of a history.  A history is fixed by
its head SHA, so lists with the same head are prefixes of one another
and the longest knows the most; one with another head is out of date."
  (let ((head (and base (gethash "sha" (car base)))))
    (seq-reduce (lambda (best l)
                  (if (and l (equal (gethash "sha" (car l)) head)
                           (> (length l) (length best)))
                      l
                    best))
                others base)))

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
;; Each of these opens (or switches to) the corresponding detail buffer,
;; from a row's RET handler.

(defun octocat-repo-vui--open-pr (repo pr)
  "Open the PR detail buffer for PR (a hash-table) in REPO."
  (octocat-pr-open repo (gethash "number" pr)))

(defun octocat-repo-vui--open-issue (repo issue)
  "Open the issue detail buffer for ISSUE (a hash-table) in REPO."
  (octocat-issue-open repo (gethash "number" issue)))

(defun octocat-repo-vui--open-commit (repo commit)
  "Open the commit detail buffer for COMMIT (a hash-table) in REPO."
  (octocat-commit-open repo (or (gethash "sha" commit) (gethash "oid" commit) "")))

(defun octocat-repo-vui--open-workflow (repo workflow)
  "Open the workflow detail buffer for WORKFLOW (a hash-table) in REPO."
  (octocat-workflow-open repo (gethash "id" workflow)
                         (or (gethash "name" workflow) "")
                         (gethash "path" workflow)))

(defun octocat-repo-vui--open-workflow-run (repo run)
  "Open the workflow-run detail buffer for RUN (a hash-table) in REPO."
  (octocat-run-open repo (gethash "databaseId" run)))


;;;; Row builders

(defconst octocat-repo-vui--state-width 6
  "Display width of the state column (\"closed\", \"merged\") in PR and issue rows.")

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

;; PR and issue rows are two lines, each cut to the window width: the
;; title with who opened it and when, then the labels and a dimmed line
;; about where the item lives.  The title gives way to the author and age.
;;
;;   open  Another dummy PR  @me · 3 days ago
;;         duplicate enhancement  owner/repo#5 · some-pr · CI: ●

(defun octocat-repo-vui--cells (item current-branch repo)
  "Return the display cells of the PR or issue ITEM of REPO as a plist.
The keys are :title, :chips (label chips), :branch, :ci, :author, :prs
\(the PRs that close an issue), :comments, :date and :ref (\"owner/repo#N\");
a cell that ITEM does not have is nil or empty.  CURRENT-BRANCH, when
non-nil, is the local HEAD branch name; a matching PR branch is
highlighted with `octocat-branch-current'."
  (let* ((branch   (octocat--nonempty (gethash "headRefName" item)))
         (checks   (gethash "statusCheckRollup" item))
         (closers  (gethash "closedByPullRequestsReferences" item))
         ;; A list row's item has the count; a page's, the comments.
         (comments (or (gethash "commentCount" item)
                       (let ((c (gethash "comments" item)))
                         (if (vectorp c) (length c) 0)))))
    (list :title  (or (gethash "title" item) "")
          :ref    (propertize (format "%s#%d" repo (gethash "number" item))
                              'face 'octocat-dimmed)
          :date   (propertize (octocat--format-ts-relative
                               (or (gethash "createdAt" item) ""))
                              'face 'octocat-dimmed)
          :prs    (and (vectorp closers) (> (length closers) 0)
                       (propertize
                        (mapconcat (lambda (pr) (format "#%d" (gethash "number" pr)))
                                   closers " ")
                        'face 'octocat-pr-number))
          :comments (and (> comments 0)
                         (propertize (format "✉ %d" comments)
                                     'face 'octocat-dimmed))
          :chips  (octocat--format-labels (gethash "labels" item))
          :branch (and branch
                       (propertize branch 'face
                                   (if (equal branch current-branch)
                                       'octocat-branch-current
                                     'octocat-branch)))
          :ci     (and (or (octocat--nonempty (gethash "ciState" item))
                           (and checks (not (eq checks :null)) (> (length checks) 0)))
                       (octocat--ci-label item))
          :author (propertize (octocat--author-login item)
                              'face 'octocat-pr-author))))

(defun octocat-repo-vui--item-lines (state cells keys &optional width)
  "Return the two lines of an item with STATE text, as a list of strings.
The first is the state, title, author and date; the second the label
chips and then the cells under KEYS.  CELLS are as made by
`octocat-repo-vui--cells'.  WIDTH, when non-nil, cuts each line to fit,
shortening the title first.  Shared by the list rows and the page
headers so the two read alike."
  (let* ((cap   (and width (max 10 (1- width))))
         (dot   (propertize " · " 'face 'octocat-dimmed))
         (join  (lambda (keys)
                  (mapconcat #'identity
                             (seq-remove (lambda (s) (or (null s) (string-empty-p s)))
                                         (mapcar (lambda (key) (plist-get cells key)) keys))
                             dot)))
         (who   (funcall join '(:author :date)))
         (title (plist-get cells :title))
         (chips (or (plist-get cells :chips) ""))
         (cut   (lambda (s) (if cap (truncate-string-to-width s cap nil nil "…") s))))
    (list
     (funcall cut
              (concat state "  "
                      (if cap
                          (truncate-string-to-width
                           title
                           (max 10 (- cap (string-width state) 2 (+ 2 (string-width who))))
                           nil nil "…")
                        title)
                      "  " who))
     (funcall cut
              (concat (make-string (+ octocat-repo-vui--state-width 2) ?\s)
                      (if (string-empty-p chips) "" (concat chips "  "))
                      (funcall join keys))))))

(defun octocat-repo-vui--item-row (state cells width on-visit help)
  "Return the row vnode for an item with STATE text.
CELLS are as made by `octocat-repo-vui--cells'; each line is cut to
WIDTH.  ON-VISIT and HELP are as for `octocat-vui-row'."
  (octocat-vui-row
   (mapconcat #'identity
              (octocat-repo-vui--item-lines
               state cells '(:ref :branch :ci :prs :comments) width)
              "\n")
   on-visit help))

(defun octocat-repo-vui--pr-row (repo pr current-branch width)
  "Return a row vnode for PR in REPO, cut to WIDTH.
CURRENT-BRANCH is as for `octocat-repo-vui--cells'."
  (octocat-repo-vui--item-row
   (octocat-repo-vui--state-label (gethash "state" pr) (gethash "isDraft" pr))
   (octocat-repo-vui--cells pr current-branch repo)
   width
   (lambda () (octocat-repo-vui--open-pr repo pr))
   "RET: view pull request"))

(defun octocat-repo-vui--issue-row (repo issue width)
  "Return a row vnode for ISSUE in REPO, cut to WIDTH."
  (octocat-repo-vui--item-row
   (octocat-repo-vui--state-label (gethash "state" issue))
   (octocat-repo-vui--cells issue nil repo)
   width
   (lambda () (octocat-repo-vui--open-issue repo issue))
   "RET: view issue"))

;; The header of an issue or PR page is drawn like a regular list row (see
;; above), so the page continues the list it was opened from: the state
;; before the title with the labels after it, then a dimmed line with where
;; it lives and who opened it.

(defun octocat-repo-vui--detail-header (repo item state on-edit-title
                                            &optional branch omit)
  "Return the header vnodes of the issue or PR ITEM of REPO.
STATE is its coloured state text (see `octocat-repo-vui--state-label').
The first row is the repo and number, as in every other view; RET on it
opens the repo view.  Below it are the item's two list lines (see
`octocat-repo-vui--item-lines'), uncut and less the repo reference
above; the first is the `title' target of the page's edit command, and
RET on either calls ON-EDIT-TITLE.  BRANCH, when non-nil, replaces the
branch cell.  OMIT is a list of cell keys (see `octocat-repo-vui--cells')
to leave out."
  (let* ((cells (octocat-repo-vui--cells item nil repo))
         (cells (if branch (plist-put cells :branch branch) cells))
         (lines (octocat-repo-vui--item-lines
                 state cells (seq-difference '(:branch :ci :prs :comments) omit))))
    (list
     (octocat-vui-row
      (concat (propertize repo 'face 'octocat-repo)
              (propertize (format "#%d" (gethash "number" item))
                          'face 'octocat-pr-number))
      (lambda () (octocat-visit-repo repo))
      "RET: open repo view")
     (octocat-vui-row
      (propertize (car lines) 'octocat-timeline-target 'title)
      on-edit-title
      "RET: edit title")
     (octocat-vui-row (cadr lines) on-edit-title "RET: edit title"))))

(defun octocat-repo-vui--detail-fields (fields)
  "Return a vnode listing FIELDS under the title, or nil when none has a value.
FIELDS is a list of (LABEL . VALUE); a nil or empty VALUE is skipped.  The
line is dimmed and lined up with the title column."
  (let ((parts (delq nil
                     (mapcar (lambda (f)
                               (and (cdr f) (not (equal (cdr f) ""))
                                    (concat (propertize (car f) 'face 'octocat-dimmed)
                                            " " (cdr f))))
                             fields))))
    (and parts
         (vui-text (concat (make-string (+ octocat-repo-vui--state-width 2) ?\s)
                           (mapconcat #'identity parts
                                      (propertize " · " 'face 'octocat-dimmed)))))))

(defun octocat-repo-vui--logins (users)
  "Return the \"@login\" names of USERS (a vector of user objects) joined, or nil."
  (and (vectorp users) (> (length users) 0)
       (mapconcat (lambda (u)
                    (propertize (concat "@" (or (gethash "login" u) (gethash "name" u) ""))
                                'face 'octocat-pr-author))
                  users ", ")))

(defun octocat-repo-vui--numbers (refs)
  "Return the \"#N\" numbers of REFS (a vector of issue/PR objects) joined, or nil."
  (and (vectorp refs) (> (length refs) 0)
       (propertize (mapconcat (lambda (r) (format "#%d" (gethash "number" r))) refs " ")
                   'face 'octocat-pr-number)))

(defun octocat-repo-vui--milestone (item)
  "Return the milestone title of ITEM, or nil."
  (let ((m (gethash "milestone" item)))
    (and (hash-table-p m) (octocat--nonempty (gethash "title" m)))))

(defun octocat-repo-vui--workflow-row (repo workflow)
  "Return a row vnode for WORKFLOW in REPO."
  (let* ((name       (or (gethash "name"  workflow) ""))
         (state      (downcase (or (gethash "state" workflow) "")))
         (state-face (if (equal state "active") 'success 'octocat-dimmed))
         (line
          (concat
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
         (date       (octocat--format-ts-relative created))
         (icon       (octocat--workflow-run-icon status conclusion))
         (line
          (concat
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

(defconst octocat-repo-vui--author-max-width 30
  "Widest author column of the commit list; longer names are truncated.")

(defun octocat-repo-vui--author-width (commits)
  "Return the width of the author column for COMMITS: the longest name.
It is no wider than `octocat-repo-vui--author-max-width', so the dates
line up with no more padding than the different names require."
  (min octocat-repo-vui--author-max-width
       (apply #'max 0 (mapcar (lambda (c) (string-width (octocat--commit-author c)))
                              commits))))

(defun octocat-repo-vui--commit-row (repo commit head-info author-w)
  "Return a row vnode for COMMIT in REPO.
HEAD-INFO as in `octocat-repo-vui--commits-section'; the local HEAD
commit is highlighted.  AUTHOR-W is the width of the author column, see
`octocat-repo-vui--author-width'."
  (let* ((head-hash (and head-info (plist-get head-info :hash)))
         (sha       (or (gethash "sha" commit) ""))
         (short     (substring sha 0 (min 7 (length sha))))
         (is-head   (and head-hash
                        (>= (length sha) (length head-hash))
                        (string-prefix-p head-hash sha)))
         (c         (gethash "commit" commit))
         (message   (or (and c (gethash "message" c)) ""))
         (subject   (car (split-string message "\n")))
         (ca        (and c (gethash "author" c)))
         (author    (octocat--commit-author commit))
         (date      (octocat--format-ts-relative
                     (or (and ca (gethash "date" ca)) "")))
         (line
          (concat
           (propertize (format "%-7s" short)
                       'face (if is-head 'octocat-branch-current 'octocat-commit-sha))
           "  "
           (if is-head
               (let* ((text (truncate-string-to-width subject octocat-title-width nil nil "…"))
                      (pad  (make-string (- octocat-title-width (string-width text)) ?\s)))
                 (concat (propertize text 'face 'octocat-branch-current) pad))
             (octocat--format-title subject))
           "  "
           (propertize (truncate-string-to-width author author-w nil ?\s "…")
                       'face 'octocat-pr-author)
           "  "
           (propertize date 'face 'octocat-dimmed))))
    (octocat-vui-row line
                     (lambda () (octocat-repo-vui--open-commit repo commit))
                     "RET: viewcommit")))


(defun octocat-repo-vui--unpushed-row (commit)
  "Return a line for COMMIT, a plist from `octocat-repo--parse-unpushed'.
Not RET-able: the commit page reads from GitHub, which lacks it."
  (let ((sha (plist-get commit :sha)))
    (vui-text
     (concat
      (propertize (substring sha 0 (min 7 (length sha))) 'face 'octocat-commit-sha)
      " "
      (plist-get commit :subject)))))


;;;; Sections
;;
;; Each section owns its async fetch (`vui-use-async') and, for the
;; pageable ones, its "load more" limit (`:state').

(defun octocat-repo-vui--unpushed-section (unpushed)
  "Return the section listing UNPUSHED, from `octocat-repo--unpushed'.
It is apart from the commits section: the local branch need not be the
default branch, nor sit on top of it."
  (let ((commits (plist-get unpushed :commits))
        (behind  (plist-get unpushed :behind)))
    (vui-vstack
     (vui-text
      (concat (propertize "Local commits not on " 'face 'octocat-section-heading)
              (octocat--branch-glyph)
              (propertize (or (plist-get unpushed :upstream) "origin") 'face 'octocat-branch)
              (propertize (format " (%d)" (length commits)) 'face 'octocat-section-heading)
              (when (> behind 0)
                (propertize (format "  diverged, %d behind" behind) 'face 'octocat-dimmed))))
     (apply #'vui-vstack (mapcar #'octocat-repo-vui--unpushed-row commits))
     (vui-newline))))

(defun octocat-repo-vui--commits-heading (label current-branch reset default)
  "Return the Commits heading for the branch named LABEL.
LABEL is a picker button, as GitHub's branch dropdown, highlighted when
it is the local CURRENT-BRANCH.  RESET non-nil adds a button back to
the DEFAULT branch.  Without LABEL the heading is plain \"Commits\"."
  (if (and (stringp label) (not (string-empty-p label)))
      (apply #'vui-hstack :spacing 1
             (vui-text "Commits" :face 'octocat-section-heading)
             (vui-hstack :spacing 0
               (vui-text (octocat--branch-glyph))
               (vui-button (format "[%s ▾]" label)
                           :no-decoration t
                           :face (if (equal label current-branch)
                                     'octocat-branch-current
                                   'octocat-branch)
                           :help-echo "RET: show another branch (C-c C-b)"
                           :on-click #'octocat-repo-switch-branch))
             (when reset
               (list (vui-button (if default (format "[reset to %s]" default) "[reset]")
                                 :no-decoration t
                                 :face 'octocat-dimmed
                                 :help-echo "RET: show the default branch"
                                 :on-click #'octocat-repo-reset-branch))))
    (vui-text "Commits" :face 'octocat-section-heading)))

(defun octocat-repo--commits-cache-id (branch)
  "Return the cache id of BRANCH's commits; nil means the default branch."
  (if branch (concat "branch-" (octocat--cache-safe-repo branch)) "default"))

(vui-defcomponent octocat-repo-vui--commits-section
    (repo branch default-branch current-branch head-info)
  "Commits section for REPO.
The commits are those of BRANCH, or of the default branch when nil;
the branch appears once in the title instead of on every row, with
a button back to DEFAULT-BRANCH when it is another.  It is highlighted
when it is also the local CURRENT-BRANCH.  HEAD-INFO is the
plist from `octocat--head-info', used to highlight the local HEAD commit.
Every commit loaded is cached on disk under its branch head, so while the
head stays put, reopening and \"load more\" reuse them; only commits
beyond the cache are fetched, a page at a time, pinned to that head."
  ;; MORE is (:items LIST :done BOOL): the commits after the last load
  ;; more, DONE when that page came back short (end of history).
  :state ((limit octocat-repo-commits-page-size) (more nil) (fetching nil))
  :render
  (let* ((size   octocat-repo-commits-page-size)
         (cache-id (octocat-repo--commits-cache-id branch))
         ;; "history", not the REST-era "commits", whose entries lack
         ;; the cursors that load more pages after.
         (cached (vui-use-memo (repo cache-id)
                   (octocat--items-cache-load repo "history" cache-id)))
         (first  (vui-use-async (list 'commits repo branch)
                   (lambda (resolve reject)
                     (octocat-repo--list-commits
                      repo branch
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (fresh  (and (eq (plist-get first :status) 'ready)
                      (plist-get first :data)))
         (more-items (plist-get more :items))
         (commits (if fresh
                      (octocat-repo--commits-merge fresh (plist-get cached :items) more-items)
                    (octocat-repo--commits-merge (plist-get cached :items) more-items)))
         (result (octocat-vui-with-stale first commits))
         (done   (or (and (plist-get more :done) (eq commits more-items))
                     (/= 0 (% (length commits) size))))
         (loading (and (or (plist-get result :refreshing) fetching) t))
         ;; The cached default-branch list is labelled with the branch it
         ;; was fetched for.
         (label  (or branch (if fresh default-branch (plist-get cached :branch)))))
    (octocat-vui-use-mode-line-loading loading)
    (vui-use-effect (fresh commits label)
      (when (and fresh label)
        (octocat--items-cache-save repo "history" cache-id commits label))
      nil)
    (vui-vstack
     (octocat-repo-vui--commits-heading label current-branch (and branch t) default-branch)
     (pcase (plist-get result :status)
       ('pending (vui-text (octocat-vui-line-skeleton)))
       ('error   (vui-text (format "%s" (plist-get result :error)) :face 'octocat-dimmed))
       ('ready
        (let ((shown (seq-take commits limit)))
          (vui-fragment
           (if (null shown)
               (vui-text "(no commits)" :face 'octocat-dimmed)
             (let ((author-w (octocat-repo-vui--author-width shown)))
               (octocat-vui-reveal-list
                shown
                (lambda (c)
                  (octocat-repo-vui--commit-row repo c head-info author-w))
                (lambda (c) (gethash "sha" c)))))
           (when (and shown (or (> (length commits) limit) (not done)))
             (octocat-vui-load-more-button
              'load-more-commits size
              "RET: load more commits"
              (lambda ()
                (octocat-repo-vui--load-more-commits repo commits (+ limit size)))
              fetching 0 (octocat-vui-line-skeleton))))))))))

(defun octocat-repo-vui--load-more-commits (repo commits limit)
  "Show LIMIT of COMMITS of REPO, fetching the next page when short.
Called from the load-more button of `octocat-repo-vui--commits-section'.
The page is fetched at the head of COMMITS, after the last of them, so
the history it pages through cannot shift under it."
  (vui-set-state :limit limit)
  (when (< (length commits) limit)
    (let ((on-page
           (vui-async-callback (r)
             (vui-set-state :fetching nil)
             (if (eq (car-safe r) 'error)
                 (message "octocat: %s" (cdr r))
               (vui-set-state
                :more (list :items (append commits r)
                            :done (< (length r) octocat-repo-commits-page-size)))))))
      (vui-set-state :fetching t)
      (octocat-repo--list-commits repo (gethash "sha" (car commits)) on-page
                                  (gethash "cursor" (car (last commits)))))))

;;;; Root

(defun octocat-repo-vui--nav-buttons (repo summary)
  "Return the tab strip of REPO's pages, as GitHub's tabs.
The issue and PR tabs show their open counts from SUMMARY, the plist
from `octocat-repo--fetch-summary', or an ellipsis while it loads."
  (octocat-vui-repo-tabs repo nil
                         (or (plist-get summary :open-issues) "…")
                         (or (plist-get summary :open-prs) "…")))

(vui-defcomponent octocat-repo-vui--root (repo branch local-dir unpushed)
  "Root component for the repo buffer: header, local-head/fork-parent
info, issue/PR summary line, then the UNPUSHED and the commits sections.
BRANCH is the branch whose commits to show, nil for the default.
Everything but the commits comes from a single summary API call."
  :render
  (let* ((buf            (current-buffer))
         (head-info      (octocat--head-info))
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
         (fork-parent    (plist-get summary :fork-parent))
         (loading        (eq (plist-get summary-result :status) 'pending)))
    (vui-use-effect (fresh)
      (when fresh (octocat-repo--summary-cache-save repo fresh))
      nil)
    (vui-use-effect (default-branch)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq octocat-repo--default-branch default-branch)))
      nil)
    (octocat-vui-use-mode-line-loading loading)
    (vui-vstack
     (apply #'vui-hstack :spacing 2
            (vui-text repo :face 'octocat-repo)
            (octocat-repo-vui--nav-buttons repo summary))
     (when local-dir
       (vui-text
        (concat (propertize "Local clone:" 'face 'octocat-dimmed)
                "  "
                (propertize local-dir 'face 'octocat-branch)
                (cond (current-branch
                       (concat "  " (octocat--branch-glyph)
                               (propertize current-branch 'face 'octocat-branch-current)))
                      ((plist-get head-info :hash)
                       (concat "  detached at "
                               (propertize (plist-get head-info :hash)
                                           'face 'octocat-commit-sha)))))))
     (when fork-parent
       (octocat-vui-row
        (concat "Forked from  " (propertize fork-parent 'face 'octocat-repo) "\n")
        (lambda () (octocat-visit-repo fork-parent))
        "RET: open parent repo view"))
     (vui-newline)
     (when unpushed
       (octocat-repo-vui--unpushed-section unpushed))
     (vui-component 'octocat-repo-vui--commits-section
                    :key (or branch 'default)
                    :repo repo :branch branch :default-branch default-branch
                    :current-branch current-branch :head-info head-info))))


;;;; Major mode

(defun octocat-repo-browse ()
  "Open the current repository's GitHub page in a browser."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (message "Octocat: Opening %s in browser…" octocat-repo--repo)
  (browse-url (format "https://github.com/%s" octocat-repo--repo)))

(defun octocat-repo-switch-branch ()
  "Show the commits of another branch, picked from the repository's."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let* ((default octocat-repo--default-branch)
         (picked  (octocat--read-branch
                   octocat-repo--repo default (plist-get (octocat--head-info) :branch)
                   (or octocat-repo--branch default))))
    (setq octocat-repo--branch (unless (equal picked default) picked))
    (or (octocat-vui-update-page :branch octocat-repo--branch)
        (octocat-repo-refresh))))

(defun octocat-repo-reset-branch ()
  "Show the commits of the default branch again."
  (interactive)
  (setq octocat-repo--branch nil)
  (or (octocat-vui-update-page :branch nil)
      (octocat-repo-refresh)))

(defvar octocat-repo-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-repo-mode'.")
(define-key octocat-repo-mode-map (kbd "q") #'quit-window)
(define-key octocat-repo-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-repo-mode-map (kbd "C-c C-t") #'octocat-tree-open)
(define-key octocat-repo-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)
(define-key octocat-repo-mode-map (kbd "C-c C-b") #'octocat-repo-switch-branch)
(define-key octocat-repo-mode-map (kbd "C-c C-o") #'octocat-repo-browse)
(define-key octocat-repo-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-repo-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-repo-mode vui-mode "Octocat-Repo"
  "Major mode for browsing a GitHub repository.

\\{octocat-repo-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-repo-refresh)
  (octocat--ts-eldoc-setup))


;;;; Async refresh

(defun octocat-repo-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat-repo buffer.
Mounts the vui.el component tree for `octocat-repo--repo' via
`vui-mount'.  Every section fetches its own data independently (see
the Commentary at the top of this file)."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-repo-vui--root
                              :repo octocat-repo--repo
                              :branch octocat-repo--branch
                              :local-dir octocat-repo--local-dir
                              :unpushed (and octocat-repo--local-dir
                                             (octocat-repo--unpushed
                                              octocat-repo--local-dir)))
               (buffer-name))))

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
