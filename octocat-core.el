;;; octocat-core.el --- Shared infrastructure for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Shared options, faces, and low-level gh-process helpers used by both
;; octocat.el and octocat-pr.el.  Neither of those files should be loaded
;; before this one.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'json)
(require 'markdown-mode)


;;;; Options

(defcustom octocat-debug nil
  "When non-nil, dump raw gh JSON output to the *octocat-debug* buffer."
  :type 'boolean
  :group 'octocat)

(defcustom octocat-cache-directory
  (locate-user-emacs-file "octocat/cache-v2/")
  "Directory for storing octocat cache files."
  :type 'directory
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

(defun octocat--format-branch (branch width)
  "Return BRANCH truncated to WIDTH characters and styled with `octocat-branch'.
WIDTH should be at most `octocat-branch-max-width'.  Shorter names are
padded with spaces so columns stay aligned.  The string is decorated
with the `octocat-branch' face."
  (propertize (truncate-string-to-width branch width nil ?\s "…")
              'face 'octocat-branch))

(defun octocat--branch-column-width (runs key)
  "Return the branch column width for a list of RUNS hash-tables.
KEY names the hash entry holding the branch string (e.g. \"headBranch\"
or \"headRefName\").  The result is the minimum of
`octocat-branch-max-width' and the longest branch name in RUNS,
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
name from the nested \\\"commit\\\" → \\\"author\\\" → \\\"name\\\" field when the
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
  (let ((st (or status ""))
        (co (octocat--nonempty conclusion)))
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
  (let* ((checks (gethash "statusCheckRollup" pr))
         (conclusions
          (when (and checks (not (eq checks :null)))
            (mapcar (lambda (c) (gethash "conclusion" c)) checks)))
         (states
          (when (and checks (not (eq checks :null)))
            (mapcar (lambda (c) (gethash "state" c)) checks))))
    (cond
     ((cl-some (lambda (s) (member s '("FAILURE" "ERROR" "TIMED_OUT")))
               (append conclusions states))
      (propertize "✗" 'face 'octocat-ci-failure))
     ((cl-every (lambda (s) (equal s "SUCCESS"))
                (append conclusions states))
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
  "Return the cache file path for REPO."
  (expand-file-name (concat (octocat--cache-safe-repo repo) ".json")
                    octocat-cache-directory))

(defun octocat--detail-cache-file (repo type number)
  "Return the cache file path for a detail view.
REPO is \"owner/repo\", TYPE is a string such as \"pr\", \"issue\", or
\"commit\", and NUMBER is the item identifier — an integer for PRs and
issues, or a SHA string for commits."
  (expand-file-name (format "%s-%s-%s.json"
                            (octocat--cache-safe-repo repo) type number)
                    octocat-cache-directory))

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

(defun octocat--format-ts-full (ts)
  "Format TS as \"YYYY-MM-DD HH:MM (relative)\" for detail-view info sections.
Returns an empty string for nil, :null, or an empty string.
Example output: \"2026-06-08 14:23 (3 days ago)\".

Use this in info sections where horizontal space is ample.
Use `octocat--format-ts' for compact list rows."
  (let ((abs (octocat--format-ts ts))
        (rel (octocat--relative-ts ts)))
    (if (string-empty-p abs)
        ""
      (if (string-empty-p rel)
          abs
        (format "%s (%s)" abs rel)))))

;;;; Section identity

;; magit-section uses `magit-section-ident-value' to derive a stable identity
;; key from each section's `:value' slot.  The default implementation returns
;; the value as-is, which means two hash-table objects representing the same
;; GitHub entity are never `equal' across re-renders.  We override the generic
;; for every value type octocat uses, returning a simple scalar key so that
;; `magit-get-section' can locate the matching section in a freshly-built tree.

(cl-defmethod magit-section-ident-value ((ht hash-table))
  "Return a stable scalar key for a GitHub entity hash-table HT.
Checks for the most specific numeric identifier first (databaseId,
number), then a string identifier (oid, name), falling back to nil."
  (or (gethash "databaseId" ht)
      (gethash "number"     ht)
      (gethash "oid"        ht)
      (gethash "id"         ht)
      (gethash "name"       ht)))


;;;; Point preservation across refreshes

(defun octocat--save-point ()
  "Capture point position relative to the current magit section.
Returns a plist (:section SECTION :line LINE :char CHAR) describing
point's location within its enclosing section, or nil when there is
no live section tree (e.g. during initial buffer setup).
Pass the returned plist to `octocat--restore-point' after re-rendering."
  (when (and (boundp 'magit-root-section) magit-root-section)
    (let ((section (magit-current-section)))
      (when section
        (let ((pos (magit-section-get-relative-position section)))
          (list :section section
                :line    (car pos)
                :char    (cadr pos)))))))

(defun octocat--restore-point (saved)
  "Restore point to the section described by SAVED, if possible.
SAVED must be a plist as returned by `octocat--save-point', or nil.
Uses `magit-section-goto-successor' so that if the exact section no
longer exists the cursor lands on the nearest related sibling or parent."
  (when saved
    (let ((section (plist-get saved :section))
          (line    (plist-get saved :line))
          (char    (plist-get saved :char)))
      (when section
        (ignore-errors
          (magit-section-goto-successor section line char))))))


;;;; Comment rendering

(defun octocat--render-comments (comments)
  "Insert COMMENTS as individual magit sections with full markdown bodies.
COMMENTS is a vector of comment hash-tables as returned by the gh CLI.
Each comment gets a collapsible section whose heading shows the author
and date, with the full body rendered via `octocat--insert-markdown'
below it.  An empty vector renders a dimmed \"(no comments)\" placeholder."
  (if (zerop (length comments))
      (insert (propertize "  (no comments)\n" 'face 'octocat-dimmed))
    (cl-loop for comment across comments do
             (let* ((author  (octocat--author-login comment))
                    (body    (or (gethash "body" comment) ""))
                    (created (or (gethash "createdAt" comment) ""))
                    (date    (octocat--format-ts created)))
               (magit-insert-section (comment comment)
                 (magit-insert-heading
                   (concat "  "
                           (propertize author 'face 'octocat-pr-author)
                           "  "
                           (propertize date 'face 'octocat-dimmed)
                           "\n"))
                 (if (string-empty-p (string-trim body))
                     (insert (propertize "  (empty)\n" 'face 'octocat-dimmed))
                   (octocat--insert-markdown body))
                 (insert "\n"))))))

;;;; Markdown rendering

(defun octocat--insert-markdown (text &optional indent)
  "Insert TEXT rendered via `gfm-view-mode' font-lock into the current buffer.
Each line is prefixed with INDENT (a string, default \"  \").
Windows-style CR characters are stripped before rendering.
Markup delimiters are hidden and syntax is highlighted using the
faces from `markdown-mode', which is a declared dependency."
  (let* ((indent (or indent "  "))
         (text (replace-regexp-in-string "\r" "" text))
         (rendered
          (condition-case _err
              (with-temp-buffer
                (insert text)
                (gfm-view-mode)
                (font-lock-ensure)
                (buffer-string))
            ;; gfm-mode can crash on malformed input (e.g. unterminated
            ;; code fences).  Fall back to the raw text so the caller
            ;; always gets something sensible.
            (error text))))
    (dolist (line (split-string rendered "\n"))
      (insert indent line "\n"))))

(provide 'octocat-core)
;;; octocat-core.el ends here
