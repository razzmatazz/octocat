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
(declare-function octocat-user-open                "octocat-user"     (login))


;;;; User options

(defcustom octocat-section-limit 15
  "Default number of items to display per paged section.
Used as the initial page size for workflow runs and user repos.  Each
section starts with this many items and increments by this amount
every time its \"Load more\" button is used."
  :type 'integer
  :group 'octocat)

(defcustom octocat-repo-commits-page-size 10
  "Number of commits the repo buffer shows, and loads, at a time."
  :type 'integer
  :group 'octocat)

(defcustom octocat-repo-doc-lines 20
  "Lines of the repo buffer's README shown before the rest is folded away.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
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


(defun octocat-repo-vui-use-cached (type repo number fetch &optional as-list tick)
  "Return the `vui-use-async' result of FETCH for item NUMBER of REPO.
NUMBER is what identifies the item, such as a PR number or a commit SHA.
TYPE is the disk-cache type (see `octocat--detail-cache-file').  The last
saved data shows at once with :refreshing t while FETCH, called with
REPO, NUMBER and a callback, runs; fresh data replaces it in place and
is saved.  A new TICK, the page's (see `octocat-vui-refresh-page'),
fetches again.  AS-LIST says the data is a list, which the cache stores
as a vector.  Must be called during render, like any hook."
  (octocat-vui-use-cached
   (list type repo number tick)
   (lambda ()
     (let ((raw (octocat--detail-cache-load repo type number)))
       (and raw (if as-list (cl-coerce raw 'list) raw))))
   (lambda (data)
     (octocat--detail-cache-save repo type number (if as-list (vconcat data) data)))
   (lambda (resolve reject)
     (funcall fetch repo number
              (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
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

(defun octocat-repo--list-recent-runs (repo limit callback &optional args)
  "Fetch the LIMIT most recent workflow run entries across all workflows in REPO.
ARGS are more `gh run list' options, filtering the runs, such as
\\=(\"--branch\" \"main\").  Call CALLBACK with a list of run hash-tables
\(each including a \\='workflowName\\=' key), or a cons \\=(error . MSG) on
failure."
  (octocat--run-gh
   "recent-runs"
   (append
    (list "run" "list"
          "--repo"  repo
          "--limit" (number-to-string limit)
          "--json"  "databaseId,displayTitle,status,conclusion,createdAt,headBranch,workflowName")
    args)
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

(defconst octocat-repo--root-query
  "query($owner:String!,$name:String!,$expr:String!){repository(owner:$owner,name:$name){object(expression:$expr){...on Tree{entries{name type oid}}}}}"
  "GraphQL query behind `octocat-repo--list-root'.")

(defun octocat-repo--list-root (repo ref callback)
  "Fetch the files at the root of REPO at REF (nil for the default branch).
Calls CALLBACK with a list of hash-tables with \"name\" and \"oid\", or
a cons \\=(error . MSG)."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "repo-root"
     (list "api" "graphql"
           "-f" (concat "query=" octocat-repo--root-query)
           "-f" (concat "owner=" (car parts))
           "-f" (concat "name=" (cadr parts))
           "-f" (concat "expr=" (or ref "HEAD") ":"))
     (lambda (json)
       (let* ((r   (gethash "repository"
                            (gethash "data" (json-parse-string json :null-object nil))))
              (obj (and r (gethash "object" r))))
         (seq-filter (lambda (e) (equal (gethash "type" e) "blob"))
                     (and obj (gethash "entries" obj)))))
     callback)))

(defun octocat-repo--load-root (repo sha callback)
  "Call CALLBACK with the root files of REPO at commit SHA, or (error . MSG).
They are as from `octocat-repo--list-root'.  A commit's files never
change, so they are served from the disk cache when there, at once;
else fetched and cached."
  (if-let* ((cached (octocat--detail-cache-load repo "root-at" sha)))
      (funcall callback (cl-coerce cached 'list))
    (octocat-repo--list-root
     repo sha
     (lambda (result)
       (unless (eq (car-safe result) 'error)
         (octocat--detail-cache-save repo "root-at" sha (vconcat result)))
       (funcall callback result)))))

(defconst octocat-repo--doc-kinds
  '((readme   "README"          "readme")
    (coc      "Code of conduct" "code[-_]of[-_]conduct")
    (contrib  "Contributing"    "contributing")
    (license  "License"         "\\(?:licen[cs]e\\|copying\\)")
    (security "Security"        "security"))
  "The documents GitHub offers below a repository's files, in its order.
Each is (KIND LABEL STEM): a root file is one when its name, ignoring
case, is STEM, a regexp, with or without an extension.")

(defun octocat-repo--markdown-file-p (name)
  "Return non-nil when file NAME is markdown, by its extension."
  (string-match-p "\\.\\(?:md\\|markdown\\|mdown\\|mkdn?\\)\\'" (downcase name)))

(defun octocat-repo--docs (entries)
  "Return the documents among ENTRIES, root files from `octocat-repo--list-root'.
Each is (KIND LABEL ENTRY), in the order of `octocat-repo--doc-kinds'.
Of several files of a kind a markdown one wins, then the shortest name,
so README.md beats README.txt and README."
  (delq nil
        (mapcar
         (pcase-lambda (`(,kind ,label ,stem))
           (let* ((re (concat "\\`" stem "\\(?:\\.[^.]+\\)?\\'"))
                  (hits (seq-filter (lambda (e)
                                      (let ((case-fold-search t))
                                        (string-match-p re (gethash "name" e))))
                                    entries))
                  (rank (lambda (e)
                          (let ((n (gethash "name" e)))
                            (+ (if (octocat-repo--markdown-file-p n) 0 1000)
                               (length n))))))
             (when hits
               (list kind label
                     (car (sort hits (lambda (a b) (< (funcall rank a)
                                                      (funcall rank b)))))))))
         octocat-repo--doc-kinds)))

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

;; PR and issue rows are two lines, each cut to the window width, as
;; GitHub's: the title and its labels, then its number, who opened it
;; and when, and a dimmed line about its review, checks and comments.
;; The title gives way to the labels.  The branch is left to the page.
;;
;;   open  Another dummy PR  duplicate enhancement
;;         owner/repo#5 by @me · 3 days ago · Review required · ✓ 4/5

(defun octocat-repo-vui--cells (repo item bg)
  "Return the display cells of the PR or issue ITEM of REPO as a plist.
The keys are :title, :chips (label chips), :review, :ci, :author, :prs
\(the PRs that close an issue), :comments, :date and :number
\(\"owner/repo#N\");
a cell that ITEM does not have is nil or empty.  BG is as for
`octocat--label-face'."
  (let* ((checks   (gethash "statusCheckRollup" item))
         (closers  (gethash "closedByPullRequestsReferences" item))
         ;; A list row's item has the count; a page's, the comments.
         (comments (or (gethash "commentCount" item)
                       (let ((c (gethash "comments" item)))
                         (if (vectorp c) (length c) 0)))))
    (list :title  (or (gethash "title" item) "")
          :number (concat (propertize repo 'face 'octocat-repo)
                          (propertize (format "#%d" (gethash "number" item))
                                      'face 'octocat-pr-number))
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
          :chips  (octocat--format-labels (gethash "labels" item) bg)
          ;; As GitHub's list, only while open: a draft says so instead.
          :review (and (equal (upcase (or (gethash "state" item) "")) "OPEN")
                       (not (eq (gethash "isDraft" item) t))
                       (when-let* ((text (pcase (gethash "reviewDecision" item)
                                           ("REVIEW_REQUIRED"   "Review required")
                                           ("APPROVED"          "Approved")
                                           ("CHANGES_REQUESTED" "Changes requested"))))
                         (propertize text 'face 'octocat-dimmed)))
          :ci     (and (or (octocat--nonempty (gethash "ciState" item))
                           (and checks (not (eq checks :null)) (> (length checks) 0)))
                       (octocat--ci-count-label item))
          :author (propertize (octocat--author-login item)
                              'face 'octocat-pr-author))))

(defun octocat-repo-vui--join-cells (cells keys)
  "Return the non-empty CELLS under KEYS, joined by a dimmed dot."
  (mapconcat #'identity
             (seq-remove (lambda (s) (or (null s) (string-empty-p s)))
                         (mapcar (lambda (key) (plist-get cells key)) keys))
             (propertize " · " 'face 'octocat-dimmed)))

(defun octocat-repo-vui--item-lines (state cells keys &optional width)
  "Return the two lines of an item with STATE text, as a list of strings.
The first is the state, title and label chips; the second the number,
author and date, then the cells under KEYS.  CELLS are as made by
`octocat-repo-vui--cells'.  WIDTH, when non-nil, cuts each line to fit,
shortening the title to make room for the chips.  Shared by the list
rows and the page headers so the two read alike."
  (let* ((cap   (and width (max 10 (1- width))))
         (dot   (propertize " · " 'face 'octocat-dimmed))
         (join  (lambda (keys) (octocat-repo-vui--join-cells cells keys)))
         (who   (concat (plist-get cells :number)
                        (propertize " by " 'face 'octocat-dimmed)
                        (funcall join '(:author :date))))
         (title (plist-get cells :title))
         (chips (let ((c (or (plist-get cells :chips) "")))
                  (if (string-empty-p c) "" (concat "  " c))))
         (rest  (funcall join keys))
         (cut   (lambda (s) (if cap (truncate-string-to-width s cap nil nil "…") s))))
    (list
     (funcall cut
              (concat state "  "
                      (if cap
                          (truncate-string-to-width
                           title
                           (max 10 (- cap (string-width state) 2 (string-width chips)))
                           nil nil "…")
                        title)
                      chips))
     (funcall cut
              (concat (make-string (+ octocat-repo-vui--state-width 2) ?\s)
                      who
                      (if (string-empty-p rest) "" (concat dot rest)))))))

(defun octocat-repo-vui--compact-line (state number cells &optional width)
  "Return the one line of an item in a compact list.
That is STATE text, NUMBER (\"#N\"), the title and its label chips, then
the author; CELLS are as made by `octocat-repo-vui--cells'.  The repo is
the page's and the age is left out, to make room for the title.
WIDTH, when non-nil, cuts the line to fit, shortening the title first."
  (let* ((cap   (and width (max 10 (1- width))))
         (chips (let ((c (or (plist-get cells :chips) "")))
                  (if (string-empty-p c) "" (concat "  " c))))
         (tail  (concat (propertize " · " 'face 'octocat-dimmed)
                        (plist-get cells :author)))
         (head  (concat state "  " number "  "))
         (title (plist-get cells :title))
         (line  (concat head
                        (if cap
                            (truncate-string-to-width
                             title
                             (max 10 (- cap (string-width head) (string-width chips)
                                        (string-width tail)))
                             nil nil "…")
                          title)
                        chips tail)))
    (if cap (truncate-string-to-width line cap nil nil "…") line)))

(defun octocat-repo-vui--item-row (state cells width on-visit help
                                         &optional compact number)
  "Return the row vnode for an item with STATE text.
CELLS are as made by `octocat-repo-vui--cells'; each line is cut to
WIDTH.  ON-VISIT and HELP are as for `octocat-vui-row'.  COMPACT draws
the one line of `octocat-repo-vui--compact-line', with NUMBER."
  (octocat-vui-row
   (if compact
       (octocat-repo-vui--compact-line state number cells width)
     (mapconcat #'identity
                (octocat-repo-vui--item-lines
                 state cells '(:review :ci :prs :comments) width)
                "\n"))
   on-visit help))

(defun octocat-repo-vui--number (item)
  "Return the \"#N\" of the issue or PR ITEM."
  (propertize (format "#%d" (gethash "number" item)) 'face 'octocat-pr-number))

(defun octocat-repo-vui--pr-row (repo pr width bg &optional compact)
  "Return a row vnode for PR in REPO, cut to WIDTH.
BG is as for `octocat-repo-vui--cells'; COMPACT draws it on one line."
  (octocat-repo-vui--item-row
   (octocat-repo-vui--state-label (gethash "state" pr) (gethash "isDraft" pr))
   (octocat-repo-vui--cells repo pr bg)
   width
   (lambda () (octocat-repo-vui--open-pr repo pr))
   "RET: view pull request"
   compact (octocat-repo-vui--number pr)))

(defun octocat-repo-vui--issue-row (repo issue width bg &optional compact)
  "Return a row vnode for ISSUE in REPO, cut to WIDTH.
BG is as for `octocat-repo-vui--cells'; COMPACT draws it on one line."
  (octocat-repo-vui--item-row
   (octocat-repo-vui--state-label (gethash "state" issue))
   (octocat-repo-vui--cells repo issue bg)
   width
   (lambda () (octocat-repo-vui--open-issue repo issue))
   "RET: view issue"
   compact (octocat-repo-vui--number issue)))

;; The header of an issue or PR page is drawn like a regular list row (see
;; above), so the page continues the list it was opened from: the state
;; before the title with the labels after it, then who opened it and when
;; with its review and branch.

(defun octocat-repo-vui--detail-header (repo item state on-edit-title bg
                                            &optional branch omit)
  "Return the header vnodes of the issue or PR ITEM of REPO.
STATE is its coloured state text (see `octocat-repo-vui--state-label').
The rows are the item's two list lines (see
`octocat-repo-vui--item-lines'), uncut; the first is the `title' target
of the page's edit command, and RET on either calls ON-EDIT-TITLE.  BG
is as for `octocat-repo-vui--cells'.  BRANCH, when non-nil, is shown
after the review.  OMIT is a list of cell keys (see
`octocat-repo-vui--cells') to leave out."
  (let* ((cells (octocat-repo-vui--cells repo item bg))
         (cells (if branch (plist-put cells :branch branch) cells))
         (lines (octocat-repo-vui--item-lines
                 state cells (seq-difference '(:review :branch :ci :prs :comments) omit))))
    (list
     (octocat-vui-row
      (propertize (car lines) 'octocat-timeline-target 'title)
      on-edit-title
      "RET: edit title")
     (octocat-repo-vui--detail-who cells omit on-edit-title))))

(defun octocat-repo-vui--detail-who (cells omit on-edit-title)
  "Return the header row under the title: number, author, date and cells.
As the second of `octocat-repo-vui--item-lines', but the author is a
TAB-able link.  CELLS, OMIT and ON-EDIT-TITLE are as for
`octocat-repo-vui--detail-header'."
  (let* ((author (plist-get cells :author))
         (rest   (octocat-repo-vui--join-cells
                  cells (cons :date (seq-difference '(:review :branch :ci :prs :comments)
                                                    omit)))))
    (octocat-vui-row
     (list (make-string (+ octocat-repo-vui--state-width 2) ?\s)
           (plist-get cells :number)
           (propertize " by " 'face 'octocat-dimmed)
           (if (string-empty-p author)
               ""
             (octocat-repo-vui--login-link (substring author 1)))
           (if (or (string-empty-p author) (string-empty-p rest))
               rest
             (concat (propertize " · " 'face 'octocat-dimmed) rest)))
     on-edit-title
     "RET: edit title")))

(defun octocat-repo-vui--detail-fields (fields)
  "Return a vnode listing FIELDS under the title, or nil when none has a value.
FIELDS is a list of (LABEL . VALUE), VALUE a string or a list of vnodes;
a nil or empty VALUE is skipped, and a nil LABEL shows VALUE alone.  The
line is lined up with the title column."
  (let ((parts (delq nil
                     (mapcar (lambda (f)
                               (and (cdr f) (not (equal (cdr f) ""))
                                    (append
                                     (and (car f)
                                          (list (vui-text (concat (car f) " ")
                                                          :face 'octocat-dimmed)))
                                     (if (stringp (cdr f))
                                         (list (vui-text (cdr f)))
                                       (cdr f)))))
                             fields))))
    (and parts
         (vui-hstack :spacing 0
           (vui-text (make-string (+ octocat-repo-vui--state-width 2) ?\s))
           (octocat-repo-vui--separate parts (propertize " · " 'face 'octocat-dimmed))))))

(defun octocat-repo-vui--separate (items sep)
  "Return ITEMS (vnodes or lists of them) with a `vui-text' of SEP between."
  (cdr (mapcan (lambda (item) (list (vui-text sep) item)) items)))

(defun octocat-repo-vui--link (label face action &optional help)
  "Return an unbracketed `vui-button' showing LABEL in FACE: a TAB stop.
ACTION is called on RET or a click; HELP is its hover text, by default
\"RET: open LABEL\"."
  (vui-button label
    :no-decoration t
    :face face
    :help-echo (or help (concat "RET: open " label))
    :on-click action))

(defun octocat-repo-vui--login-link (login)
  "Return \"@LOGIN\" as a link to the page of the user LOGIN."
  (octocat-repo-vui--link (concat "@" login) 'octocat-pr-author
                          (lambda () (octocat-user-open login))))

(defun octocat-repo-vui--logins (users)
  "Return the \"@login\" names of USERS (a vector of user objects), or nil.
A list of vnodes, comma-separated; each opens the page of its user."
  (and (vectorp users) (> (length users) 0)
       (octocat-repo-vui--separate
        (mapcar (lambda (u)
                  (let ((login (gethash "login" u)))
                    (if (octocat--nonempty login)
                        (octocat-repo-vui--login-link login)
                      (vui-text (concat "@" (or (gethash "name" u) ""))
                                :face 'octocat-pr-author))))
                users)
        ", ")))

(defun octocat-repo-vui--numbers (repo refs open)
  "Return the \"#N\" numbers of REFS (a vector of issue/PR objects), or nil.
A list of vnodes, space-separated; each calls OPEN with its repository,
REPO unless it names another, and number."
  (and (vectorp refs) (> (length refs) 0)
       (octocat-repo-vui--separate
        (mapcar (lambda (r)
                  (let* ((n     (gethash "number" r))
                         (other (gethash "repository" r))
                         (owner (and (hash-table-p other) (gethash "owner" other)))
                         (where (if (and (hash-table-p owner) (gethash "login" owner))
                                    (format "%s/%s" (gethash "login" owner)
                                            (gethash "name" other))
                                  repo)))
                    (octocat-repo-vui--link
                     (if (equal where repo) (format "#%d" n) (format "%s#%d" where n))
                     'octocat-pr-number (lambda () (funcall open where n)))))
                refs)
        " ")))

(defun octocat-repo-vui--milestone (item)
  "Return the milestone title of ITEM, or nil."
  (let ((m (gethash "milestone" item)))
    (and (hash-table-p m) (octocat--nonempty (gethash "title" m)))))

(defun octocat-repo-vui--workflow-state (workflow)
  "Return the state of WORKFLOW as shown on its row, such as \"active\"."
  (downcase (or (gethash "state" workflow) "")))

(defun octocat-repo-vui--workflow-file (workflow)
  "Return the file name of WORKFLOW, such as \"test.yml\"."
  (file-name-nondirectory (or (gethash "path" workflow) "")))

(defun octocat-repo-vui--workflow-name-width (workflows width state-w)
  "Return the width of the name column of WORKFLOWS: the longest name.
It is at most what WIDTH columns leave beside the STATE-W wide state and
the longest file name, but cuts no name shorter than 10."
  (let ((longest (lambda (f) (apply #'max 0 (mapcar (lambda (wf) (string-width (funcall f wf)))
                                                    workflows)))))
    (min (funcall longest (lambda (wf) (or (gethash "name" wf) "")))
         (max 10 (- width 1 state-w 2 2
                    (funcall longest #'octocat-repo-vui--workflow-file))))))

(defun octocat-repo-vui--workflow-row (repo workflow &optional state-w name-w)
  "Return a row vnode for WORKFLOW in REPO: its state, name and file name.
The state is padded to STATE-W columns and the name to NAME-W, cut to
it when longer (40 by default), so the columns line up."
  (let* ((name       (or (gethash "name"  workflow) ""))
         (state      (octocat-repo-vui--workflow-state workflow))
         (state-face (if (equal state "active") 'success 'octocat-dimmed))
         (line
          (concat
           (propertize (string-pad state (max (or state-w 0) (string-width state)))
                       'face state-face)
           "  "
           (truncate-string-to-width name (or name-w 40) nil ?\s "…")
           "  "
           (propertize (octocat-repo-vui--workflow-file workflow) 'face 'octocat-dimmed))))
    (octocat-vui-row line
                     (lambda () (octocat-repo-vui--open-workflow repo workflow))
                     "RET: viewworkflow")))

(defun octocat-repo-vui--run-title-width (runs width wf-w &optional branch-w)
  "Return the title column's width, that of the longest title.
The titles are those of RUNS.  It is at least
`octocat-repo-vui--subject-min-width', and at most what WIDTH columns
leave beside the other columns of `octocat-repo-vui--workflow-run-row',
the workflow name WF-W wide and the branch BRANCH-W."
  (let ((rest (+ (or branch-w octocat-branch-max-width) 2 11 2 wf-w 2 1 2 2 1
                 (apply #'max 0 (mapcar (lambda (r)
                                          (string-width (octocat--format-ts-relative
                                                         (or (gethash "createdAt" r) ""))))
                                        runs)))))
    (max octocat-repo-vui--subject-min-width
         (min (- width rest)
              (apply #'max 0 (mapcar (lambda (r) (string-width (or (gethash "displayTitle" r) "")))
                                     runs))))))

(defun octocat-repo-vui--workflow-run-row (repo run current-branch wf-w
                                                &optional title-w branch-w)
  "Return a row vnode for RUN in REPO.
CURRENT-BRANCH, when non-nil, highlights a matching run branch.
WF-W is the column width to truncate/pad the workflow name to, TITLE-W
that of the title, `octocat-title-width' by default, and BRANCH-W that
of the branch, `octocat-branch-max-width' by default."
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
           (let* ((branch-w (or branch-w octocat-branch-max-width))
                  (name (truncate-string-to-width branch branch-w nil nil "…"))
                  (pad  (make-string (- branch-w (string-width name)) ?\s)))
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
           (octocat--format-title title title-w)
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

(defun octocat-repo-vui--subject (commit)
  "Return the first line of COMMIT's message."
  (let ((c (gethash "commit" commit)))
    (car (split-string (or (and c (gethash "message" c)) "") "\n"))))

(defconst octocat-repo-vui--subject-min-width 24
  "Narrowest subject column, so short subjects still leave a gap before the author.")

(defun octocat-repo-vui--date (commit)
  "Return the relative author date of COMMIT, as on its row."
  (let* ((c  (gethash "commit" commit))
         (ca (and c (gethash "author" c))))
    (octocat--format-ts-relative (or (and ca (gethash "date" ca)) ""))))

(defun octocat-repo-vui--subject-width (commits width author-w)
  "Return the width of the subject column for COMMITS: the longest subject.
It is at least `octocat-repo-vui--subject-min-width', and at most what
WIDTH columns leave beside the SHA, the AUTHOR-W wide author and the
date, so the rows fill the page but do not wrap."
  (let ((rest (+ 7 2 2 author-w 2
                 (apply #'max 0 (mapcar (lambda (c) (string-width (octocat-repo-vui--date c)))
                                        commits)))))
    (max octocat-repo-vui--subject-min-width
         (min (- width rest)
              (apply #'max 0 (mapcar (lambda (c) (string-width (octocat-repo-vui--subject c)))
                                     commits))))))

(defun octocat-repo-vui--commit-row (repo commit head-info author-w &optional subject-w)
  "Return a row vnode for COMMIT in REPO.
HEAD-INFO as in `octocat-repo-vui--commits-section'; the local HEAD
commit is highlighted.  AUTHOR-W is the width of the author column, see
`octocat-repo-vui--author-width'; SUBJECT-W that of the subject column,
`octocat-title-width' by default."
  (let* ((subject-w (or subject-w octocat-title-width))
         (head-hash (and head-info (plist-get head-info :hash)))
         (sha       (or (gethash "sha" commit) ""))
         (short     (substring sha 0 (min 7 (length sha))))
         (is-head   (and head-hash
                        (>= (length sha) (length head-hash))
                        (string-prefix-p head-hash sha)))
         (subject   (octocat-repo-vui--subject commit))
         (author    (octocat--commit-author commit))
         (date      (octocat-repo-vui--date commit))
         (line
          (concat
           (propertize (format "%-7s" short)
                       'face (if is-head 'octocat-branch-current 'octocat-commit-sha))
           "  "
           (if is-head
               (let* ((text (truncate-string-to-width subject subject-w nil nil "…"))
                      (pad  (make-string (- subject-w (string-width text)) ?\s)))
                 (concat (propertize text 'face 'octocat-branch-current) pad))
             (octocat--format-title subject subject-w))
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
    (repo branch default-branch current-branch head-info on-head tick)
  "Commits section for REPO.
The commits are those of BRANCH, or of the default branch when nil;
the branch appears once in the title instead of on every row, with
a button back to DEFAULT-BRANCH when it is another.  It is highlighted
when it is also the local CURRENT-BRANCH.  HEAD-INFO is the
plist from `octocat--head-info', used to highlight the local HEAD commit.
Every commit loaded is cached on disk under its branch head, so while the
head stays put, reopening and \"load more\" reuse them; only commits
beyond the cache are fetched, a page at a time, pinned to that head.
ON-HEAD is called with the SHA of the head shown, cached or fresh,
whenever it changes, or with nil when there are no commits to show."
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
         (first  (octocat-vui-use-async-sticky (list 'commits repo branch tick)
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
    (let ((head (pcase (plist-get result :status)
                  ('ready (if commits (gethash "sha" (car commits)) 'none))
                  ('error 'none))))
      (vui-use-effect (head)
        (when head (funcall on-head (and (stringp head) head)))
        nil))
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
             ;; Columns from all loaded commits, so they hold as more show.
             (let* ((author-w  (octocat-repo-vui--author-width commits))
                    (subject-w (octocat-repo-vui--subject-width
                                commits (octocat-vui-window-width) author-w)))
               (octocat-vui-reveal-list
                shown
                (lambda (c)
                  (octocat-repo-vui--commit-row repo c head-info author-w subject-w))
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

;;;; Docs

(defun octocat-repo-vui--doc-tabs (docs shown width)
  "Return the selector of DOCS, from `octocat-repo--docs', as GitHub's.
SHOWN is the kind of the one shown.  See `octocat-vui-tab-row' for WIDTH."
  (octocat-vui-tab-row
   (mapcar (pcase-lambda (`(,kind ,label ,entry))
             (list label (format "RET: show %s" (gethash "name" entry))
                   (unless (eq kind shown)
                     (lambda () (vui-set-state :kind kind)))))
           docs)
   width))

(defun octocat-repo--doc-text (name content raw width)
  "Return the rows of file NAME's CONTENT, rendered when it is markdown.
RAW and WIDTH are as for `octocat--markdown-string'.  Not indented, so
it copies as from the file."
  (let ((text (decode-coding-string content 'utf-8)))
    (string-remove-suffix
     "\n" (if (octocat-repo--markdown-file-p name)
              (octocat--markdown-string text "" raw width)
            (octocat-markdown-render-verbatim text "")))))

(vui-defcomponent octocat-repo-vui--docs-section (repo head waiting raw)
  "The README of REPO at commit HEAD, and a selector of its other documents.
They are those of `octocat-repo--doc-kinds' at the root of HEAD, the
head of the branch shown.  WAITING is non-nil until the commits section
knows it; till then, and while the listing loads, grey bars stand in
for the section.  RAW shows markdown verbatim.  A long document is folded after
`octocat-repo-doc-lines'.  The listing is cached under HEAD and a file
under its blob SHA, so while the branch stays put no request is made."
  :state ((kind nil))
  :render
  (let* ((root  (vui-use-async (list 'root repo head)
                  (lambda (resolve reject)
                    (if (null head)
                        (funcall resolve nil)
                      (octocat-repo--load-root
                       repo head
                       (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject)))))))
         (docs  (and (eq (plist-get root :status) 'ready)
                     (octocat-repo--docs (plist-get root :data))))
         (doc   (or (assq kind docs) (car docs)))
         (entry (nth 2 doc))
         (oid   (and entry (gethash "oid" entry)))
         (blob  (vui-use-async (list 'doc repo oid)
                  (lambda (resolve reject)
                    (if (null oid)
                        (funcall resolve nil)
                      (octocat-tree--load-blob
                       repo oid
                       (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject)))))))
         (width (octocat--markdown-width))
         (text  (vui-use-memo ((plist-get blob :data) raw width)
                  (and entry (plist-get blob :data)
                       (octocat-repo--doc-text (gethash "name" entry)
                                               (plist-get blob :data) raw width)))))
    (octocat-vui-use-mode-line-loading
     (and (or (eq (plist-get root :status) 'pending)
              (eq (plist-get blob :status) 'pending))
          t))
    (cond
     (docs
      (vui-vstack
       (vui-newline)
       (octocat-repo-vui--doc-tabs docs (car doc) width)
       (pcase (plist-get blob :status)
         ('pending (vui-text (octocat-vui-line-skeleton)))
         ('error   (vui-text (format "%s" (plist-get blob :error)) :face 'octocat-dimmed))
         (_        (let ((text (or text "")))
                     (octocat-vui-fold-lines
                      text (octocat-vui-line-ends text) octocat-repo-doc-lines
                      ;; One per document, so switching starts folded.
                      (intern (format "doc-fold-%s" (car doc))) ""))))))
     ((or waiting (eq (plist-get root :status) 'pending))
      (vui-vstack
       (vui-newline)
       (vui-text (concat (octocat-vui-skeleton '((6 "  " 12 "  " 7)))
                         "\n" (octocat-vui-line-skeleton))))))))

;;;; Root

(defun octocat-repo-vui--nav-buttons (repo summary)
  "Return the tab strip of REPO's pages, as GitHub's tabs.
The issue and PR tabs show their open counts from SUMMARY, the plist
from `octocat-repo--fetch-summary', or an ellipsis while it loads."
  (octocat-vui-repo-tabs repo 'code
                         (or (plist-get summary :open-issues) "…")
                         (or (plist-get summary :open-prs) "…")))

(vui-defcomponent octocat-repo-vui--root (repo branch local-dir unpushed raw tick)
  "Root component for the repo buffer: header, local-head/fork-parent
info, issue/PR summary line, then the UNPUSHED, the commits and the
docs sections.  BRANCH is the branch whose commits and docs to show, nil
for the default.  RAW shows markdown verbatim.
Everything but the commits comes from a single summary API call."
  ;; HEAD is (BRANCH . SHA), the head the commits section shows (nil SHA
  ;; when none), for the docs at that commit; BRANCH tells a switched-from
  ;; branch's apart.
  :state ((head nil))
  :render
  (let* ((buf            (current-buffer))
         (head-info      (octocat--head-info))
         (current-branch (plist-get head-info :branch))
         (cached         (vui-use-memo (repo) (octocat-repo--summary-cache-load repo)))
         (summary-result (octocat-vui-use-async-sticky (list 'summary repo tick)
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
         (loading        (or (eq (plist-get summary-result :status) 'pending)
                             (plist-get summary-result :refreshing))))
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
                    :current-branch current-branch :head-info head-info :tick tick
                    :on-head (vui-async-callback (sha)
                               (vui-set-state :head (cons branch sha))))
     (let ((known (and head (equal (car head) branch))))
       (vui-component 'octocat-repo-vui--docs-section
                      :key (or branch 'default)
                      :repo repo :raw raw
                      :head (and known (cdr head)) :waiting (not known))))))


;;;; Major mode

(defun octocat-repo-browse ()
  "Open the current repository's GitHub page in a browser."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (message "Octocat: Opening %s in browser…" octocat-repo--repo)
  (octocat-browse-external (format "https://github.com/%s" octocat-repo--repo)))

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
(define-key octocat-repo-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-repo-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-repo-mode-map (kbd "C-c C-t") #'octocat-tree-open)
(define-key octocat-repo-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)
(define-key octocat-repo-mode-map (kbd "C-c C-b") #'octocat-repo-switch-branch)
(define-key octocat-repo-mode-map (kbd "C-c C-o") #'octocat-repo-browse)
(define-key octocat-repo-mode-map (kbd "C-c C-v") #'octocat-toggle-markdown)
(define-key octocat-repo-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-repo-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-repo-mode vui-mode "Octocat-Repo"
  "Major mode for browsing a GitHub repository.

\\{octocat-repo-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-repo-refresh)
  (setq-local octocat--refresh-fn #'octocat-repo-refresh)
  (octocat-markdown--ensure-invisibility)
  (octocat--ts-eldoc-setup)
  (octocat--max-width-setup))


;;;; Async refresh

(defun octocat-repo-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat-repo buffer, in place.
Every section fetches its own data independently (see the Commentary at
the top of this file)."
  (interactive)
  (unless octocat-repo--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-repo-vui--root octocat-repo--repo
                            (list :repo octocat-repo--repo
                                  :branch octocat-repo--branch
                                  :local-dir octocat-repo--local-dir
                                  :raw octocat--markdown-raw
                                  :unpushed (and octocat-repo--local-dir
                                                 (octocat-repo--unpushed
                                                  octocat-repo--local-dir)))))

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
