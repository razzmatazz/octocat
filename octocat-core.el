;;; octocat-core.el --- Shared infrastructure for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Shared options, faces, and low-level gh-process helpers used by both
;; octocat.el and octocat-pr.el.  Neither of those files should be loaded
;; before this one.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'eldoc)
(require 'octocat-markdown)
(require 'consult)

;; Forward declarations for octocat-repo.el functions called from this file.
;; octocat-repo.el is loaded after octocat-core.el, so we cannot require it.
(declare-function octocat-repo-mode            "octocat-repo" ())
(declare-function octocat-repo--local-dir-for  "octocat-repo" (repo))
(declare-function octocat-repo-refresh         "octocat-repo" (&optional _ignore-auto _noconfirm))
(declare-function octocat-repo--current-repo   "octocat-repo" ())
(declare-function octocat-pr-open              "octocat-pr"   (repo number))
(declare-function octocat-issue-open           "octocat-issue" (repo number))
(declare-function octocat-commit-open          "octocat-commit" (repo sha))

;; Buffer-local variable stubs: defined as defvar-local in their respective
;; files (loaded after octocat-core.el).  The plain defvar here lets the
;; byte-compiler see the symbol and suppresses "reference to free variable"
;; warnings without creating a new binding.
(defvar octocat-repo--repo)
(defvar octocat--pr-repo)
(defvar octocat--pr-number)
(defvar octocat--issue-repo)
(defvar octocat--issue-number)
(defvar octocat--commit-repo)
(defvar octocat--workflow-repo)
(defvar octocat--run-repo)
(defvar octocat--job-repo)
(defvar octocat--checks-repo)
(defvar octocat-tree--repo)


;;;; Options

(defcustom octocat-debug nil
  "When non-nil, dump raw gh JSON output to the *octocat-debug* buffer."
  :type 'boolean
  :group 'octocat)

(defcustom octocat-cache-directory
  (locate-user-emacs-file "octocat/cache-v3/")
  "Directory for storing octocat cache files."
  :type 'directory
  :group 'octocat)

(defcustom octocat-repo-search-cache-ttl 3600
  "Seconds before a cached repo search result expires.
When `octocat-switch-repo' receives a query string it has seen before,
it serves the cached candidate list if the entry is younger than this
value, skipping the `gh search repos' network call entirely.  Set to 0
to disable caching."
  :type 'integer
  :group 'octocat)





;;;; Custom faces

(defface octocat-ci-success
  '((t :inherit success))
  "Face for a passing CI status."
  :group 'octocat)

(defface octocat-ci-failure
  '((t :inherit error))
  "Face for a failing CI status."
  :group 'octocat)

(defface octocat-ci-pending
  '((t :inherit warning))
  "Face for a pending CI status."
  :group 'octocat)

(defface octocat-pr-number
  '((t :inherit font-lock-constant-face))
  "Face for a PR number."
  :group 'octocat)

(defface octocat-pr-author
  '((t :inherit font-lock-string-face))
  "Face for a PR author."
  :group 'octocat)

(defface octocat-repo
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a repository or remote-branch name."
  :group 'octocat)

(defface octocat-branch
  '((((class color) (background dark))  :foreground "#8ec07c")
    (((class color) (background light)) :foreground "#427b58")
    (t :inherit font-lock-function-name-face))
  "Face for a local or remote branch name."
  :group 'octocat)

(defface octocat-branch-current
  '((((class color) (background dark))
     :foreground "#8ec07c" :weight bold :underline t)
    (((class color) (background light))
     :foreground "#427b58" :weight bold :underline t)
    (t :inherit (bold octocat-branch) :underline t))
  "Face for the currently checked-out branch in PR and run lists.
Applied to branch names that match the local HEAD branch, following the
Magit convention of marking the current branch with bold + underline."
  :group 'octocat)

(defconst octocat-branch-max-width 16
  "Maximum display width (in characters) for a branch name column.
Longer names are truncated with a trailing ellipsis (…).")

(defconst octocat-title-width 40
  "Display width (in characters) for title/subject columns.
Used by PR titles, issue titles, workflow-run display titles, and commit
subjects so all list views share a uniform column width.")

(defun octocat--format-title (title)
  "Return TITLE truncated/padded to `octocat-title-width' characters.
Strings shorter than the width are space-padded; longer ones are
truncated with a trailing ellipsis (…)."
  (truncate-string-to-width title octocat-title-width nil ?\s "…"))

(defun octocat--label-foreground (hex)
  "Return \"black\" or \"white\", whichever is more readable on HEX (\"rrggbb\")."
  (let* ((r (string-to-number (substring hex 0 2) 16))
         (g (string-to-number (substring hex 2 4) 16))
         (b (string-to-number (substring hex 4 6) 16)))
    ;; Perceived luminance (ITU-R BT.601), 0-255.
    (if (> (+ (* 0.299 r) (* 0.587 g) (* 0.114 b)) 150) "black" "white")))

(defun octocat--format-label (label)
  "Return a propertized chip string for GitHub LABEL hash-table.
The chip is coloured with the label's own GitHub colour, with a black or
white foreground chosen for contrast.  Without a valid colour it falls
back to the `octocat-branch' face."
  (let* ((name  (or (gethash "name" label) ""))
         (color (let ((c (gethash "color" label)))
                  (and (stringp c) (string-match-p "\\`[0-9a-fA-F]\\{6\\}\\'" c) c))))
    (if color
        (propertize (concat " " name " ")
                    'face `(:background ,(concat "#" color)
                            :foreground ,(octocat--label-foreground color)))
      (propertize name 'face 'octocat-branch))))

(defun octocat--format-labels (labels)
  "Return LABELS (vector of label hash-tables) as space-separated chips.
Returns the empty string when LABELS is nil, `:null' or empty."
  (if (or (null labels) (eq labels :null) (zerop (length labels)))
      ""
    (mapconcat #'octocat--format-label labels " ")))

(defun octocat--format-branch (branch width)
  "Return BRANCH truncated to WIDTH characters and styled with `octocat-branch'.
WIDTH should be at most `octocat-branch-max-width'.  Shorter names are
padded with spaces so columns stay aligned.  The string is decorated
with the `octocat-branch' face."
  (propertize (truncate-string-to-width branch width nil ?\s "…")
              'face 'octocat-branch))

(defun octocat--branch-column-width (runs key)
  "Return the branch column width to use when rendering a workflow list.
KEY names the hash entry holding the branch string (e.g. \"headBranch\"
or \"headRefName\") inside each element of RUNS.  The result is the
minimum of `octocat-branch-max-width' and the longest branch name,
with a floor of 1."
  (min octocat-branch-max-width
       (apply #'max 1
              (mapcar (lambda (r) (length (or (gethash key r) "")))
                      runs))))

(defface octocat-section-heading
  '((t :weight bold :extend t))
  "Face for section headings in octocat buffers."
  :group 'octocat)

(defface octocat-dimmed
  '((t :inherit shadow))
  "Face for secondary / de-emphasised text in octocat buffers."
  :group 'octocat)

(defface octocat-filter-input
  '((t :inherit secondary-selection :extend nil))
  "Face for the search query field of the list pages, drawn like an input box."
  :group 'octocat)

(defface octocat-pr-state-open
  '((t :inherit success))
  "Face for an open PR state badge."
  :group 'octocat)

(defface octocat-pr-state-closed
  '((t :inherit error))
  "Face for a closed PR state badge."
  :group 'octocat)

(defface octocat-pr-state-merged
  '((t :inherit font-lock-builtin-face))
  "Face for a merged PR state badge."
  :group 'octocat)

(defface octocat-run-job-name
  '((t :weight bold))
  "Face for a job name in a workflow-run view."
  :group 'octocat)

(defface octocat-run-step-name
  '((t :inherit shadow))
  "Face for a step name in a workflow-run view."
  :group 'octocat)

(defface octocat-annotation-warning
  '((t :inherit warning))
  "Face for a GitHub Actions warning annotation."
  :group 'octocat)

(defface octocat-annotation-error
  '((t :inherit error))
  "Face for a GitHub Actions error annotation."
  :group 'octocat)

(defface octocat-annotation-notice
  '((t :inherit font-lock-comment-face))
  "Face for a GitHub Actions notice annotation."
  :group 'octocat)


;;;; exec-path augmentation

;; Ensure Homebrew and common user-local paths are in `exec-path' so that
;; `executable-find' can locate `gh' even when Emacs is launched as a GUI app
;; (which does not inherit the shell's PATH).
(dolist (dir '("/opt/homebrew/bin"   ; Apple-silicon Homebrew
               "/usr/local/bin"      ; Intel Homebrew / manual installs
               "/opt/local/bin"))    ; MacPorts
  (add-to-list 'exec-path dir))


;;;; Internal helpers

(defun octocat--current-branch ()
  "Return the name of the currently checked-out local git branch, or nil.
Returns nil when HEAD is detached, the working directory is not a git
repository, or git is not on PATH.  Calls git synchronously — this is
intentional because the result is needed at render time and `git
symbolic-ref' completes in milliseconds."
  (let ((branch (string-trim
                 (shell-command-to-string
                  "git symbolic-ref --short HEAD 2>/dev/null"))))
    (and (not (string-empty-p branch)) branch)))

(defun octocat--head-info ()
  "Return a plist describing the current local HEAD, or nil.
The plist has the keys :branch (string or nil when detached), :hash
\(7-character abbreviated commit hash), and :subject (one-line commit
message).  Returns nil when the working directory is not a git
repository or git is not on PATH.  Uses a single `git log' call so it
is cheap enough to call at render time."
  (let ((raw (string-trim
              (shell-command-to-string
               "git log -1 --abbrev=11 --format=%D%x00%h%x00%s HEAD 2>/dev/null"))))
    (when (not (string-empty-p raw))
      (let* ((parts   (split-string raw "\0"))
             (refs    (nth 0 parts))
             (hash    (nth 1 parts))
             (subject (nth 2 parts))
             ;; Extract the branch name from the refs field (e.g. "HEAD ->
             ;; main, origin/main" → "main").  Falls back to nil for detached
             ;; HEAD where the refs field has no "HEAD ->" component.
             (branch  (when (string-match "HEAD -> \\([^,\n]+\\)" refs)
                        (match-string 1 refs))))
        (list :branch branch :hash hash :subject subject)))))

(defun octocat--author-login (obj)
  "Return \"@LOGIN\" for the GitHub author of OBJ, or \"\" when unavailable.
OBJ is any hash-table that has an \\\"author\\\" key whose value is a GitHub
user object with a \\\"login\\\" field — e.g. a PR, issue, review, or comment
hash-table as returned by the gh CLI.  Returns an empty string when the
author field is absent, null, or carries no login."
  (let* ((author (gethash "author" obj))
         (login  (and author
                      (not (eq author :null))
                      (gethash "login" author))))
    (if (and login (not (string-empty-p login)))
        (concat "@" login)
      "")))

(defun octocat--commit-author (commit)
  "Return a compact author string for COMMIT, for use in list rows.
COMMIT is a hash-table from the GitHub REST commits endpoint.
Prefers the GitHub handle: if the top-level \\\"author\\\" user object has a
\\\"login\\\" field the result is \\\"@LOGIN\\\".  Falls back to the git author
name from the nested \\\"commit\\\" → \\\"author\\\" → \\\"name\\\" field
when the
commit is not associated with a GitHub account.  Returns \"\" when neither
is available.  For detail views where space allows, use
`octocat--commit-author-full' instead."
  (let* ((gh-user (gethash "author" commit))
         (login   (and gh-user
                       (not (eq gh-user :null))
                       (gethash "login" gh-user)))
         (c       (gethash "commit" commit))
         (ca      (and c (gethash "author" c))))
    (cond
     ((and login (not (string-empty-p login)))
      (concat "@" login))
     ((and ca (octocat--nonempty (gethash "name" ca)))
      (gethash "name" ca))
     (t ""))))

(defun octocat--commit-author-full (commit)
  "Return a git-log-style author string for COMMIT, for use in detail views.
COMMIT is a hash-table from the GitHub REST commits endpoint.
Returns \\\"Name  <email>\\\" from the nested git identity fields, including
only the parts that are present and non-empty:

  Saulius Menkevičius  <sauliusmenkevicius@fastmail.com>

The GitHub handle is intentionally excluded; callers that want it should
call `octocat--commit-author-login' separately and render it on its own
line.  For compact list rows where horizontal space is constrained, use
`octocat--commit-author' instead."
  (let* ((c     (gethash "commit" commit))
         (ca    (and c (gethash "author" c)))
         (name  (and ca (octocat--nonempty (gethash "name"  ca))))
         (email (and ca (octocat--nonempty (gethash "email" ca)))))
    (cond
     ((and name email) (format "%s  <%s>" name email))
     (name             name)
     (email            (format "<%s>" email))
     (t                ""))))

(defun octocat--commit-author-login (commit)
  "Return \\\"@login\\\" for the GitHub account linked to COMMIT, or nil.
COMMIT is a hash-table from the GitHub REST commits endpoint.
Returns nil when the commit email is not associated with any GitHub account,
so callers can omit the GitHub line entirely in that case."
  (let* ((gh-user (gethash "author" commit))
         (login   (and gh-user
                       (not (eq gh-user :null))
                       (octocat--nonempty (gethash "login" gh-user)))))
    (and login (concat "@" login))))

(defun octocat--debug-log (label data)
  "When `octocat-debug' is non-nil, append LABEL and DATA to *octocat-debug*."
  (when octocat-debug
    (with-current-buffer (get-buffer-create "*octocat-debug*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] "))
      (insert label "\n")
      (insert data "\n\n"))))

(defun octocat--run-gh (name args parse-fn callback)
  "Run `gh' asynchronously with ARGS and call CALLBACK with the result.
NAME is a short identifier used for the process and temp-buffer names.
ARGS is a list of string arguments passed directly to the `gh' executable.
PARSE-FN is called with the raw output string on success; its return value
is forwarded to CALLBACK.  On a `gh' non-zero exit or a parse failure,
CALLBACK receives a cons cell \\=(error . MESSAGE) where MESSAGE is the
human-readable reason.  Errors raised inside CALLBACK propagate normally
so they appear in the *Backtrace* buffer."
  (let* ((gh-executable (executable-find "gh")))
    (if (not gh-executable)
        (funcall callback '(error . "`gh' executable not found"))
      (let* ((buf     (generate-new-buffer (format " *octocat-gh-%s*" name)))
             (err-buf (generate-new-buffer (format " *octocat-gh-%s-stderr*" name)))
             (cmd     (cons gh-executable args))
             (process-environment (cons "NO_COLOR=1" process-environment)))
        (make-process
         :name (format "octocat-gh-%s" name)
         :buffer buf
         :stderr err-buf
         :command cmd
         :sentinel
         (lambda (proc event)
           (when (string-match-p "\\(finished\\|exited\\)" event)
             ;; Collect output before buffers are killed.
             (let* ((exit-code (process-exit-status proc))
                    (output    (with-current-buffer (process-buffer proc)
                                 (buffer-string)))
                    (stderr    (with-current-buffer err-buf
                                 (buffer-string))))
               (kill-buffer (process-buffer proc))
               (when (buffer-live-p err-buf)
                 ;; The stderr pipe-process attached by `make-process :stderr'
                 ;; may still be live when the sentinel fires, causing Emacs to
                 ;; prompt "has running process; kill it?" interactively.
                 ;; Delete it explicitly first so `kill-buffer' is unconditional.
                 (let ((pipe (get-buffer-process err-buf)))
                   (when pipe (delete-process pipe)))
                 (kill-buffer err-buf))
               (octocat--debug-log
                (format "gh %s exit-code: %d" name exit-code) output)
               (octocat--debug-log
                (format "gh %s stderr" name) stderr)
               ;; Resolve to a parsed value or an (error . msg) cell.
               ;; The condition-case only covers parse-fn; callback runs
               ;; outside it so renderer errors surface as real Lisp errors.
               (let ((result
                      (if (= exit-code 0)
                          (condition-case err
                              (funcall parse-fn output)
                            (error (cons 'error (error-message-string err))))
                        (cons 'error (string-trim
                                      (if (string-empty-p stderr)
                                          (format "gh exited with code %d" exit-code)
                                        stderr))))))
                 (funcall callback result))))))))))

(defun octocat--parse-json-list (json-string)
  "Parse JSON-STRING from gh into a list of hash-tables.
Returns a list of hash-tables, or signals `error' on failure.
An empty or null response is treated as an empty list."
  (let ((trimmed (string-trim json-string)))
    (cond
     ((or (string-empty-p trimmed) (string= trimmed "null"))
      '())
     (t
      (condition-case err
          (let ((parsed (json-parse-string trimmed)))
            (cond
             ((vectorp parsed) (cl-coerce parsed 'list))
             ;; Some gh versions wrap the list in an object with a "data" key.
             ((hash-table-p parsed)
              (let ((inner (gethash "data" parsed)))
                (if (vectorp inner)
                    (cl-coerce inner 'list)
                  (error "Unexpected JSON shape from gh"))))
             (t (error "Unexpected JSON shape from gh"))))
        (json-parse-error
         (error "Failed to parse gh output: %s" (error-message-string err))))))))

(defun octocat--comment-numeric-id (comment)
  "Return the numeric REST comment ID string from COMMENT hash-table.
The ID is parsed from the comment's \\\"url\\\" field, which ends in
\\\"#issuecomment-NNNNN\\\".  Returns nil if the URL is absent or malformed."
  (let ((url (and comment (gethash "url" comment))))
    (when (and url (stringp url)
               (string-match "#issuecomment-\\([0-9]+\\)\\'" url))
      (match-string 1 url))))

(defun octocat--nonempty (value)
  "Return VALUE if it is a non-empty, non-null string, otherwise nil.
Treats the JSON null sentinel `:null' and empty strings as absent values."
  (and value
       (not (eq value :null))
       (stringp value)
       (not (string-empty-p value))
       value))

(defun octocat--run-icon (status conclusion)
  "Return a propertized status icon for STATUS and CONCLUSION strings.
STATUS takes priority over CONCLUSION for in-progress detection."
  (let ((st (downcase (or status "")))
        (co (let ((c (octocat--nonempty conclusion))) (and c (downcase c)))))
    (cond
     ((equal st "in_progress")
      (propertize "●" 'face 'octocat-ci-pending))
     ((equal co "success")
      (propertize "✓" 'face 'octocat-ci-success))
     ((member co '("failure" "timed_out" "startup_failure" "cancelled"))
      (propertize "✗" 'face 'octocat-ci-failure))
     (t
      (propertize "●" 'face 'octocat-ci-pending)))))

(defun octocat--run-duration (started completed)
  "Return a human-readable duration string between STARTED and COMPLETED.
Both are ISO-8601 timestamp strings, or nil/:null.  Returns nil when
either timestamp is unavailable."
  (when (and started
             (not (eq started :null))
             completed
             (not (eq completed :null))
             (not (string-empty-p started))
             (not (string-empty-p completed)))
    (condition-case nil
        (let* ((t1 (float-time (date-to-time started)))
               (t2 (float-time (date-to-time completed)))
               (secs (max 0 (round (- t2 t1)))))
          (cond
           ((< secs 60)   (format "%ds" secs))
           ((< secs 3600) (format "%dm%02ds" (/ secs 60) (% secs 60)))
           (t             (format "%dh%02dm" (/ secs 3600) (/ (% secs 3600) 60)))))
      (error nil))))

(defun octocat--ci-status (pr)
  "Return a one-character CI-status indicator for PR hash-table PR.
Returns \"✓\" (success), \"✗\" (failure), or \"●\" (pending/unknown)."
  (octocat--checks-ci-status (gethash "statusCheckRollup" pr)))

(defun octocat--checks-ci-status (checks)
  "Return a CI-status indicator, as `octocat--ci-status' does.
The status is that of CHECKS, a `statusCheckRollup' sequence, or nil or
:null.  A check's outcome is its conclusion (a check-run) or its state
\(a commit status); one with neither is still running."
  (let ((outcomes
         (and checks (not (eq checks :null))
              (mapcar (lambda (c)
                        (upcase (or (octocat--nonempty (gethash "conclusion" c))
                                    (octocat--nonempty (gethash "state" c))
                                    "PENDING")))
                      checks))))
    (cond
     ((cl-some (lambda (s) (member s '("FAILURE" "ERROR" "TIMED_OUT"))) outcomes)
      (propertize "✗" 'face 'octocat-ci-failure))
     ((cl-every (lambda (s) (member s '("SUCCESS" "NEUTRAL" "SKIPPED"))) outcomes)
      (propertize "✓" 'face 'octocat-ci-success))
     (t
      (propertize "●" 'face 'octocat-ci-pending)))))

(defun octocat--ci-label (pr)
  "Return a short labelled CI-status string for PR hash-table PR.
Combines a dimmed \"CI:\" prefix with the coloured status icon from
`octocat--ci-status', e.g. \"CI: ✓\" or \"CI: ✗\"."
  (concat (propertize "CI:" 'face 'octocat-dimmed)
          " "
          (octocat--ci-status pr)))

;;;; Disk cache

(defun octocat--cache-safe-repo (repo)
  "Return a filesystem-safe version of REPO for use in cache file names.
The owner/repo slash becomes \"--\" so the two components stay visually
distinct; any remaining non-alphanumeric characters become \"-\"."
  (replace-regexp-in-string
   "[^A-Za-z0-9._-]" "-"
   (replace-regexp-in-string "/" "--" repo)))

(defun octocat--cache-file (repo)
  "Return the cache file path for REPO's dashboard data."
  (expand-file-name "dashboard.json"
                    (expand-file-name (octocat--cache-safe-repo repo)
                                      (expand-file-name "repos" octocat-cache-directory))))

(defun octocat--detail-cache-file (repo type number)
  "Return the cache file path for a detail view.
REPO is \"owner/repo\", TYPE is a string such as \"pr\", \"issue\", or
\"commit\", and NUMBER is the item identifier — an integer for PRs and
issues, or a SHA string for commits."
  (expand-file-name (format "%s-%s.json" type number)
                    (expand-file-name (octocat--cache-safe-repo repo)
                                      (expand-file-name "repos" octocat-cache-directory))))

(defun octocat--detail-cache-load (repo type number)
  "Load cached detail data for TYPE item NUMBER in REPO.
NUMBER is an integer for PRs/issues or a SHA string for commits.
Returns the parsed hash-table, or nil when absent or unparseable."
  (let ((file (octocat--detail-cache-file repo type number)))
    (when (file-readable-p file)
      (condition-case nil
          (json-parse-string
           (with-temp-buffer
             (insert-file-contents file)
             (buffer-string)))
        (error nil)))))

(defun octocat--detail-cache-save (repo type number data)
  "Persist DATA (a hash-table) for TYPE item NUMBER in REPO to disk.
NUMBER is an integer for PRs/issues or a SHA string for commits.
Skips silently when DATA is an error cons."
  (unless (eq (car-safe data) 'error)
    (let* ((file (octocat--detail-cache-file repo type number))
           (dir  (file-name-directory file)))
      (make-directory dir t)
      (condition-case nil
          (with-temp-file file
            (set-buffer-multibyte nil)
            (insert (json-serialize data)))
        (error nil)))))

(defun octocat--items-cache-load (repo type id)
  "Load the cached item list of TYPE and ID for REPO.
Returns a plist (:items LIST :branch BRANCH-OR-NIL), or nil when absent.
Used by the list views to paint the last known page while a fresh one is
fetched."
  (when-let* ((data  (octocat--detail-cache-load repo type id))
              (items (cl-coerce (gethash "items" data) 'list)))
    (list :items  items
          :branch (let ((b (gethash "branch" data))) (and (stringp b) b)))))

(defun octocat--query-cache-id (query)
  "Return a cache id for the list search QUERY (nil means the default)."
  (secure-hash 'md5 (string-trim (or query octocat--default-list-query))))

(defun octocat--items-cache-save (repo type id items &optional branch)
  "Persist ITEMS (a list of hash-tables) of TYPE and ID for REPO.
BRANCH, when a string, is stored beside them so a cache made for another
branch can be told apart."
  (let ((data (make-hash-table :test #'equal)))
    (puthash "items" (vconcat items) data)
    (puthash "branch" (or branch :null) data)
    (octocat--detail-cache-save repo type id data)))

(defun octocat--search-cache-file (query)
  "Return the cache file path for repo search results for QUERY."
  (expand-file-name
   (concat (secure-hash 'sha256 query) ".json")
   (expand-file-name "search-repos" octocat-cache-directory)))

(defun octocat--search-cache-load (query)
  "Load cached repo search results for QUERY from disk.
Returns a cons (TIMESTAMP . CANDIDATES) when a valid entry exists, or
nil when the file is absent or cannot be parsed.  The caller is
responsible for checking whether the entry has expired."
  (let ((file (octocat--search-cache-file query)))
    (when (file-readable-p file)
      (condition-case nil
          (let* ((data       (json-parse-string
                              (with-temp-buffer
                                (insert-file-contents file)
                                (buffer-string))))
                 (timestamp  (gethash "timestamp"  data))
                 (candidates (cl-coerce (gethash "candidates" data) 'list)))
            (cons timestamp candidates))
        (error nil)))))

(defun octocat--search-cache-save (query candidates)
  "Persist repo search CANDIDATES for QUERY to disk.
CANDIDATES is a list of \"owner/name\" strings.  Skips silently on
write errors so a full disk never breaks interactive search."
  (let* ((file (octocat--search-cache-file query))
         (dir  (file-name-directory file))
         (obj  (let ((h (make-hash-table :test #'equal)))
                 (puthash "timestamp"  (float-time)        h)
                 (puthash "query"      query               h)
                 (puthash "candidates" (vconcat candidates) h)
                 h)))
    (make-directory dir t)
    (condition-case nil
        (with-temp-file file
          (set-buffer-multibyte nil)
          (insert (json-serialize obj)))
      (error nil))))

(defun octocat--cache-load (repo)
  "Load cached dashboard data for REPO from disk.
Returns a plist with keys :timestamp :prs :issues :workflows
:recent-runs, or nil if the cache file is absent or cannot be
parsed.  :recent-runs is a flat list of run hash-tables (each
containing a workflowName key) representing the last 20 runs
across all workflows."
  (let ((file (octocat--cache-file repo)))
    (when (file-readable-p file)
      (condition-case nil
          (let* ((json   (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string)))
                 (data   (json-parse-string json))
                 (ts      (gethash "timestamp"      data))
                 (prs     (cl-coerce (gethash "prs"          data) 'list))
                 (issues  (cl-coerce (gethash "issues"       data) 'list))
                 (wflows  (cl-coerce (gethash "workflows"    data) 'list))
                 (runs    (cl-coerce (gethash "recent-runs"  data) 'list))
                 (commits (cl-coerce (gethash "commits"      data) 'list))
                 (branch  (gethash "default-branch" data)))
            (list :timestamp ts :prs prs :issues issues
                  :workflows wflows :recent-runs runs
                  :commits commits :default-branch branch))
        (error nil)))))

(defun octocat--cache-save (repo prs issues workflows recent-runs
                            &optional commits default-branch)
  "Write dashboard data for REPO to the disk cache.
PRS, ISSUES, WORKFLOWS are lists of hash-tables.
RECENT-RUNS is a flat list of run hash-tables.  COMMITS is a list of
commit hash-tables from the REST API; when nil an empty vector is stored.
DEFAULT-BRANCH is a string such as \"main\"; when nil it is not stored.
Does nothing if any of the first three arguments is an error cons — only
successful results are persisted."
  (when (and (not (eq (car-safe prs)       'error))
             (not (eq (car-safe issues)    'error))
             (not (eq (car-safe workflows) 'error)))
    (let* ((file (octocat--cache-file repo))
           (dir  (file-name-directory file))
           (obj  (let ((h (make-hash-table :test #'equal)))
                   (puthash "timestamp"    (float-time)               h)
                   (puthash "repo"         repo                        h)
                   (puthash "prs"          (vconcat prs)               h)
                   (puthash "issues"       (vconcat issues)             h)
                   (puthash "workflows"    (vconcat workflows)          h)
                   (puthash "recent-runs"  (if (listp recent-runs)
                                               (vconcat recent-runs)
                                             (vector))
                            h)
                   (puthash "commits"      (if (listp commits)
                                               (vconcat commits)
                                             (vector))
                            h)
                   (when (and default-branch
                              (not (eq (car-safe default-branch) 'error))
                              (stringp default-branch))
                     (puthash "default-branch" default-branch h))
                   h)))
      (make-directory dir t)
      (with-temp-file file
        (set-buffer-multibyte nil)
        (insert (json-serialize obj))))))

;;;; Timestamp formatting

(defun octocat--format-ts (ts)
  "Format an ISO-8601 UTC timestamp TS as \"YYYY-MM-DD HH:MM\" in local time.
Returns an empty string for nil, :null, or an empty string.
Falls back to the raw date prefix if the string cannot be parsed."
  (if (or (null ts) (eq ts :null) (string-empty-p ts))
      ""
    (condition-case nil
        (format-time-string "%Y-%m-%d %H:%M" (date-to-time ts))
      (error (substring ts 0 (min 10 (length ts)))))))

(defun octocat--relative-ts (ts)
  "Return a human-readable relative string for ISO-8601 UTC timestamp TS.
Examples: \"just now\", \"5 minutes ago\", \"3 days ago\", \"2 years ago\".
Returns an empty string for nil, :null, or an empty string.

Implemented in plain Emacs Lisp using `float-time' and `current-time'.
Does not call into any external package."
  (if (or (null ts) (eq ts :null) (string-empty-p ts))
      ""
    (condition-case nil
        (let* ((then  (float-time (date-to-time ts)))
               (now   (float-time (current-time)))
               (secs  (max 0 (round (- now then)))))
          (cond
           ((< secs 60)
            "just now")
           ((< secs 3600)
            (let ((m (round (/ secs 60))))
              (format "%d %s ago" m (if (= m 1) "minute" "minutes"))))
           ((< secs 86400)
            (let ((h (round (/ secs 3600))))
              (format "%d %s ago" h (if (= h 1) "hour" "hours"))))
           ((< secs 604800)
            (let ((d (round (/ secs 86400))))
              (format "%d %s ago" d (if (= d 1) "day" "days"))))
           ((< secs 2592000)
            (let ((w (round (/ secs 604800))))
              (format "%d %s ago" w (if (= w 1) "week" "weeks"))))
           ((< secs 31536000)
            (let ((mo (round (/ secs 2592000))))
              (format "%d %s ago" mo (if (= mo 1) "month" "months"))))
           (t
            (let ((y (round (/ secs 31536000))))
              (format "%d %s ago" y (if (= y 1) "year" "years"))))))
      (error ""))))

(defun octocat--format-ts-relative (ts)
  "Format TS as a relative age carrying the exact time.
The text is `octocat--relative-ts' (\"3 days ago\"); the local date and
time, e.g. \"Mon 2026-06-08 14:23:05 EEST\", is its `help-echo' (shown
on mouse hover) and its `octocat-ts' property (shown by ElDoc when point
rests on it, see `octocat--ts-eldoc-setup').  Returns an empty string
for nil, :null, or an empty string, and the absolute
`octocat--format-ts' when TS cannot be parsed into an age.

Use this wherever a timestamp is shown to the user."
  (let ((rel (octocat--relative-ts ts)))
    (if (string-empty-p rel)
        (octocat--format-ts ts)
      (let ((exact (format-time-string "%a %Y-%m-%d %H:%M:%S %Z"
                                       (date-to-time ts))))
        (propertize rel 'help-echo exact 'octocat-ts exact)))))

(defun octocat--ts-eldoc (&rest _)
  "Return the exact time of the timestamp at point, or nil.
An `eldoc-documentation-functions' member."
  (get-text-property (point) 'octocat-ts))

(defun octocat--ts-eldoc-setup ()
  "Show the exact time of the timestamp at point in the echo area.
Call from a major-mode body.  ElDoc shows it after `eldoc-idle-delay'
when `global-eldoc-mode' is on (the default)."
  (add-hook 'eldoc-documentation-functions #'octocat--ts-eldoc nil t)
  ;; vui motions, so ElDoc reacts to them like to `next-line'.
  (eldoc-add-command-completions "vui-forward" "vui-backward"))


;;;; Markdown rendering

(defconst octocat--quote-prefix (propertize "  │ " 'face 'octocat-dimmed)
  "Line prefix that marks PR/issue bodies and comments as quoted blocks.
The bar is a box-drawing character, which joins vertically with the
bars of neighbouring lines in GUI and terminal frames alike.
The bar sits in column 2, under the first character of the comment
author's handle (and of the \"Body\" heading's text indent), with the
text two columns further right.")

(defvar-local octocat--markdown-raw nil
  "Non-nil means show markdown body text verbatim instead of rendered.
When nil (the default) `octocat--insert-markdown' processes text through
`octocat-markdown-render'.  Toggle with `octocat-toggle-markdown'.")

(defvar-local octocat--refresh-fn nil
  "Buffer-local refresh function called by `octocat-toggle-markdown'.
Each markdown-displaying mode sets this to its own refresh command so the
toggle can re-render the buffer after flipping `octocat--markdown-raw'.")

(defun octocat--markdown-string (text indent raw width)
  "Return TEXT rendered by `octocat-markdown-render', one line per row.
Each line is prefixed with INDENT (a string, nil for \"  \") and ends in a
newline; INDENT is also repeated on the wrapped continuation lines of
long lines.

When RAW is non-nil the text is returned verbatim, without any
rendering.

WIDTH is the columns to fit, as for `octocat-markdown-render'; callers
read it from the window once, with `octocat--markdown-width'."
  (if raw
      (octocat-markdown-render-verbatim text indent)
    (octocat-markdown-render text indent width)))

(defun octocat--markdown-width ()
  "Return the columns rendered markdown should fit in the current buffer.
That is the number of characters that fit a line of the window showing
the buffer (else of the selected window).  Emacs already leaves out the
last column where it is taken by the continuation glyph (a terminal, or
a window without fringes), so a full line does not wrap.

`window-max-chars-per-line' selects the window, which resets the buffer's
point to the window's point; mid-render that scrambles the page, so
point is saved around it."
  (save-excursion
    (window-max-chars-per-line (or (get-buffer-window (current-buffer) t)
                                   (selected-window)))))

(defun octocat--insert-markdown (text &optional indent)
  "Insert TEXT rendered by `octocat--markdown-string' into the current buffer.
Each line is prefixed with INDENT, as for `octocat--markdown-string'.
When `octocat--markdown-raw' is non-nil in the current buffer the text is
inserted verbatim without any font-lock rendering."
  (octocat-markdown--ensure-invisibility)
  (insert (octocat--markdown-string text indent octocat--markdown-raw
                                    (octocat--markdown-width))))

(defun octocat--markdown-open-ref (kind repo id)
  "Open the reference of KIND (`issue' or `commit') ID in REPO.
A nil REPO means the repository of the current buffer.  An issue number
may belong to a pull request, which the GitHub API tells apart, so that
is asked first and the matching view opened."
  (let ((repo (or repo (octocat--search-repo--current-repo)
                  (user-error "Octocat: no repository to look %s up in" id))))
    (pcase kind
      ('commit (octocat-commit-open repo id))
      ('issue
       (message "Octocat: opening %s#%d…" repo id)
       (octocat--run-gh
        "resolve-ref"
        (list "api" (format "repos/%s/issues/%d" repo id) "--jq" ".pull_request != null")
        #'string-trim
        (lambda (result)
          (cond ((eq (car-safe result) 'error)
                 (message "Octocat: cannot open %s#%d: %s" repo id (cdr result)))
                ((equal result "true") (octocat-pr-open repo id))
                (t (octocat-issue-open repo id)))))))))

(setq octocat-markdown-ref-function #'octocat--markdown-open-ref)

(defun octocat-toggle-markdown ()
  "Toggle between rendered and raw markdown display in the current buffer.
When raw mode is active the body text is shown verbatim; when rendered mode
is active (the default) it is processed through `octocat-markdown-render'.
After toggling, the buffer is refreshed via `octocat--refresh-fn'."
  (interactive)
  (setq octocat--markdown-raw (not octocat--markdown-raw))
  (message "Markdown display: %s" (if octocat--markdown-raw "raw" "rendered"))
  (when octocat--refresh-fn
    (funcall octocat--refresh-fn)))

;;;; Repo navigation

(defvar octocat-repo--repo)
(defvar octocat-repo--local-dir)

(defun octocat--async-search-repos ()
  "Return a consult async pipeline stage that queries GitHub for repos.
Fires `gh search repos --limit 30 --json fullName QUERY' for each input
string it receives and forwards results to SINK once the process exits.
Composes with `consult--async-min-input' and `consult--async-throttle'
for debouncing; use those upstream in the pipeline.

The stage speaks the full consult sink protocol: it forwards every
non-string action to SINK unchanged, sends `[indicator running]' when a
process is launched, and sends `flush'/candidates/`[indicator finished]'
from the process sentinel when results arrive."
  (lambda (sink)
    (let (proc proc-buf)
      (lambda (action)
        (pcase action
          ;; New input string — serve from cache if fresh, otherwise fetch.
          ((pred stringp)
           (when (and proc (process-live-p proc))
             (delete-process proc))
           (when (buffer-live-p proc-buf)
             (kill-buffer proc-buf))
           (setq proc nil proc-buf nil)
           (let ((cached (octocat--search-cache-load action)))
             (if (and cached
                      (> octocat-repo-search-cache-ttl 0)
                      (< (- (float-time) (car cached))
                         octocat-repo-search-cache-ttl))
                 ;; Cache hit — deliver results without touching the network.
                 (progn
                   (funcall sink 'flush)
                   (when (cdr cached)
                     (funcall sink (cdr cached)))
                   (funcall sink [indicator finished]))
               ;; Cache miss or expired — launch gh.
               (funcall sink [indicator running])
               (setq proc-buf (generate-new-buffer " *octocat-search-repos*"))
               (setq proc
                     (make-process
                      :name            "octocat-search-repos"
                      :buffer          proc-buf
                      :command         (if (string-prefix-p "@" action)
                                           ;; `gh search' has no users
                                           ;; subcommand; -X GET keeps -f
                                           ;; fields in the query string.
                                           (list "gh" "api" "-X" "GET"
                                                 "search/users"
                                                 "-f" (concat "q=" (substring action 1))
                                                 "-f" "per_page=15"
                                                 "--jq" "[.items[] | {login}]")
                                         (list "gh" "search" "repos"
                                               "--limit" "30"
                                               "--json" "fullName"
                                               action))
                      :connection-type 'pipe
                      :noquery         t
                      :sentinel
                      (lambda (p event)
                        (cond
                         ((string-prefix-p "finished" event)
                          (let ((candidates
                                 (condition-case _
                                     (with-current-buffer (process-buffer p)
                                       (mapcar (lambda (r)
                                                 (if-let* ((login (gethash "login" r)))
                                                     (concat "@" login)
                                                   (gethash "fullName" r)))
                                               (octocat--parse-json-list
                                                (buffer-string))))
                                   (error nil))))
                            (octocat--search-cache-save action candidates)
                            (funcall sink 'flush)
                            (when candidates
                              (funcall sink candidates))
                            (funcall sink [indicator finished])))
                         ((string-prefix-p "killed" event)
                          (funcall sink [indicator killed]))
                         (t
                          (funcall sink [indicator failed])))))))))
          ;; Session ending — clean up the process and forward to sink.
          ((or 'cancel 'destroy)
           (when (and proc (process-live-p proc))
             (delete-process proc))
           (when (buffer-live-p proc-buf)
             (kill-buffer proc-buf))
           (setq proc nil proc-buf nil)
           (funcall sink action))
          ;; All other actions (setup, flush, vectors, …) — pass through.
          (_ (funcall sink action)))))))

(declare-function octocat-user-open "octocat-user" (login))

(defun octocat-switch-repo ()
  "Search GitHub repositories or users interactively with live API queries.
Each keystroke (debounced by `consult-async-input-debounce') calls
`gh search repos' against GitHub's global search index.  Input starting
with \"@\" searches users and organizations instead (the `search/users'
API).
Results update in place as you type — no pre-fetching, no blocking wait.

Uses `consult--read' with a custom async pipeline so Vertico, Embark,
Marginalia, and other consult-aware packages integrate seamlessly.

The selected repository is opened via `octocat-visit-repo', a selected
\"@login\" via `octocat-user-open'."
  (interactive)
  (let ((repo
         (consult--read
          (consult--async-pipeline
           (consult--async-min-input 2)
           (consult--async-throttle)
           (octocat--async-search-repos))
          :prompt   "Search GitHub repos (@ for users): "
          :category 'octocat-repo
          :sort     nil)))          ; preserve server-side ranking
    (when (and repo (not (string-empty-p (string-trim repo))))
      (let ((choice (string-trim repo)))
        (if (string-prefix-p "@" choice)
            (octocat-user-open choice)
          (octocat-visit-repo choice))))))


;;;; Repo tab strip
;;
;; The Code / Issues / Pull requests / Actions strip the repo page and the
;; list pages (tree, issues, PRs, actions) show beside the repo name, as
;; GitHub's tabs do, drawn by `octocat-vui-repo-tabs'.  Detail pages leave
;; it out; their repo name leads back to the repo page.

(declare-function octocat-tree-open  "octocat-tree" (&optional repo))
(declare-function octocat-issues     "octocat"      (&optional repo))
(declare-function octocat-prs        "octocat"      (&optional repo))
(declare-function octocat-actions    "octocat"      (&optional repo))

(defconst octocat--repo-tabs
  '((code    "Code"          "RET: browse file tree"         octocat-tree-open)
    (issues  "Issues"        "RET: list issues"              octocat-issues)
    (pulls   "Pull requests" "RET: list pull requests"       octocat-prs)
    (actions "Actions"       "RET: list workflows and runs"  octocat-actions))
  "The repo tabs: (SYMBOL LABEL HELP-ECHO COMMAND).
COMMAND takes the \"owner/name\" repo to open the tab's page for.")

(defun octocat-visit-repo (repo)
  "Open (or switch to) the *REPO* buffer.
REPO is an \"owner/name\" string.  This is the shared implementation used
by the repo-nav section in every detail view."
  (let* ((buf-name (format "*%s*" repo))
         (buf      (get-buffer-create buf-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-repo-mode)
      (octocat-repo-mode))
    (setq octocat-repo--repo      repo
          octocat-repo--local-dir (octocat-repo--local-dir-for repo))
    (octocat-repo-refresh)))

;;;; Current repo detection
;;
;; Used by the repo-wide search in octocat-search.el and by markdown
;; reference opening.

(defun octocat--search-repo--current-repo ()
  "Return the \"owner/repo\" string for the current octocat buffer context.
Tries each buffer-local repo variable in priority order, then falls
back to parsing the git origin remote via `octocat-repo--current-repo'."
  (or (and (boundp 'octocat-repo--repo)     (ignore-errors octocat-repo--repo))
      (and (boundp 'octocat--pr-repo)       (ignore-errors octocat--pr-repo))
      (and (boundp 'octocat--issue-repo)    (ignore-errors octocat--issue-repo))
      (and (boundp 'octocat--commit-repo)   (ignore-errors octocat--commit-repo))
      (and (boundp 'octocat--workflow-repo) (ignore-errors octocat--workflow-repo))
      (and (boundp 'octocat--run-repo)      (ignore-errors octocat--run-repo))
      (and (boundp 'octocat--job-repo)      (ignore-errors octocat--job-repo))
      (and (boundp 'octocat--checks-repo)   (ignore-errors octocat--checks-repo))
      (and (boundp 'octocat-tree--repo)     (ignore-errors octocat-tree--repo))
      (ignore-errors (octocat-repo--current-repo))))

;;;; List filters
;;
;; The PR and issue list pages are filtered by a GitHub search query
;; string such as \"is:open author:@me label:bug -label:wontfix\".  The
;; state is part of the query (is:open / is:closed / is:merged); a query
;; without a state token matches every state.

(defconst octocat--default-list-query "is:open"
  "Query a PR or issue list starts with.")

(defun octocat--filter-args (query)
  "Return the `gh pr/issue list' flags that apply the search QUERY.
A nil QUERY means `octocat--default-list-query'.  gh's own --state is
always \"all\" so that it cannot contradict a state token in QUERY."
  (let ((query (string-trim (or query octocat--default-list-query))))
    (append (list "--state" "all")
            (unless (string-empty-p query)
              (list "--search" query)))))

(defun octocat--counts-query (kind)
  "Return the GraphQL query counting items of KIND (`issues' or `pulls')."
  (let ((field (if (eq kind 'pulls) "pullRequests" "issues"))
        (states (if (eq kind 'pulls)
                    '(("open" . "OPEN") ("closed" . "CLOSED") ("merged" . "MERGED"))
                  '(("open" . "OPEN") ("closed" . "CLOSED")))))
    (format "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){%s}}"
            (mapconcat (lambda (s)
                         (format "%s:%s(states:%s){totalCount}" (car s) field (cdr s)))
                       states " "))))

(defun octocat--parse-counts (json-string)
  "Parse the GraphQL counts response JSON-STRING into a plist.
Keys: :open, :closed and, for pull requests, :merged."
  (let ((repo (gethash "repository"
                       (gethash "data" (json-parse-string json-string :null-object nil)))))
    (apply #'append
           (mapcar (lambda (key)
                     (let ((entry (gethash (substring (symbol-name key) 1) repo)))
                       (and entry (list key (gethash "totalCount" entry)))))
                   '(:open :closed :merged)))))

(defun octocat--counts-cache-load (repo kind)
  "Load the cached counts plist of KIND (`issues' or `pulls') for REPO, or nil."
  (when-let* ((data (octocat--detail-cache-load repo "counts" (symbol-name kind))))
    (let (plist)
      (dolist (key '(:open :closed :merged))
        (when-let* ((n (gethash (substring (symbol-name key) 1) data)))
          (when (integerp n) (setq plist (append plist (list key n))))))
      plist)))

(defun octocat--counts-cache-save (repo kind counts)
  "Persist the COUNTS plist of KIND (`issues' or `pulls') for REPO."
  (let ((data (make-hash-table :test #'equal)))
    (dolist (key '(:open :closed :merged))
      (when (plist-get counts key)
        (puthash (substring (symbol-name key) 1) (plist-get counts key) data)))
    (octocat--detail-cache-save repo "counts" (symbol-name kind) data)))

(defun octocat--fetch-counts (repo kind callback)
  "Fetch the open/closed(/merged) counts of KIND in REPO asynchronously.
KIND is `issues' or `pulls'.  CALLBACK is called with the plist described
in `octocat--parse-counts', or a cons \\=(error . MSG).  One API call."
  (let ((parts (split-string repo "/")))
    (octocat--run-gh
     "counts"
     (list "api" "graphql"
           "-f" (concat "query=" (octocat--counts-query kind))
           "-F" (concat "owner=" (car parts))
           "-F" (concat "name=" (cadr parts)))
     #'octocat--parse-counts
     callback)))

(defun octocat--list-labels (repo callback)
  "Fetch the label names of REPO asynchronously and call CALLBACK.
CALLBACK is called with a list of strings, or a cons \\=(error . MSG)."
  (octocat--run-gh "labels"
                   (list "label" "list"
                         "--repo" repo
                         "--limit" "200"
                         "--json" "name")
                   (lambda (output)
                     (mapcar (lambda (h) (gethash "name" h))
                             (octocat--parse-json-list output)))
                   callback))

(defun octocat--list-people (repo callback)
  "Fetch the logins that can be assigned in REPO and call CALLBACK.
CALLBACK is called with a list of strings, or a cons \\=(error . MSG)."
  (octocat--run-gh "people"
                   (list "api" (format "repos/%s/assignees?per_page=100" repo)
                         "--jq" ".[].login")
                   (lambda (output) (split-string output "\n" t))
                   callback))

(provide 'octocat-core)
;;; octocat-core.el ends here
