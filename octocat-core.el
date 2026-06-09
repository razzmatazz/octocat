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
  '((t :inherit font-lock-function-name-face))
  "Face for a local or remote branch name."
  :group 'octocat)

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


;;;; exec-path augmentation

;; Ensure Homebrew and common user-local paths are in `exec-path' so that
;; `executable-find' can locate `gh' even when Emacs is launched as a GUI app
;; (which does not inherit the shell's PATH).
(dolist (dir '("/opt/homebrew/bin"   ; Apple-silicon Homebrew
               "/usr/local/bin"      ; Intel Homebrew / manual installs
               "/opt/local/bin"))    ; MacPorts
  (add-to-list 'exec-path dir))


;;;; Internal helpers

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
               (when (buffer-live-p err-buf) (kill-buffer err-buf))
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

(defun octocat--run-icon (status conclusion)
  "Return a propertized status icon for STATUS and CONCLUSION strings."
  (let ((s (or (and conclusion (not (eq conclusion :null)) conclusion)
               status
               "")))
    (cond
     ((equal s "success")
      (propertize "✓" 'face 'octocat-ci-success))
     ((member s '("failure" "timed_out" "startup_failure" "cancelled"))
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
REPO is \"owner/repo\", TYPE is a string such as \"pr\" or \"issue\",
and NUMBER is the integer item number."
  (expand-file-name (format "%s-%s-%d.json"
                            (octocat--cache-safe-repo repo) type number)
                    octocat-cache-directory))

(defun octocat--detail-cache-load (repo type number)
  "Load cached detail data for TYPE item NUMBER in REPO.
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
Skips silently when DATA is an error cons."
  (unless (eq (car-safe data) 'error)
    (let* ((file (octocat--detail-cache-file repo type number))
           (dir  (file-name-directory file)))
      (make-directory dir t)
      (condition-case nil
          (with-temp-file file
            (insert (json-serialize data))
            (json-pretty-print-buffer))
        (error nil)))))

(defun octocat--cache-load (repo)
  "Load cached dashboard data for REPO from disk.
Returns a plist with keys :timestamp :prs :issues :workflows, or nil if the
cache file is absent or cannot be parsed."
  (let ((file (octocat--cache-file repo)))
    (when (file-readable-p file)
      (condition-case nil
          (let* ((json   (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string)))
                 (data   (json-parse-string json))
                 (ts     (gethash "timestamp" data))
                 (prs    (cl-coerce (gethash "prs"       data) 'list))
                 (issues (cl-coerce (gethash "issues"    data) 'list))
                 (wflows (cl-coerce (gethash "workflows" data) 'list)))
            (list :timestamp ts :prs prs :issues issues :workflows wflows))
        (error nil)))))

(defun octocat--cache-save (repo prs issues workflows)
  "Write PRS, ISSUES and WORKFLOWS for REPO to the disk cache as JSON.
Does nothing if any argument is an error cons — only successful results are
persisted."
  (when (and (not (eq (car-safe prs)       'error))
             (not (eq (car-safe issues)    'error))
             (not (eq (car-safe workflows) 'error)))
    (let* ((file (octocat--cache-file repo))
           (dir  (file-name-directory file))
           (obj  (let ((h (make-hash-table :test #'equal)))
                   (puthash "timestamp" (float-time)      h)
                   (puthash "repo"      repo              h)
                   (puthash "prs"       (vconcat prs)     h)
                   (puthash "issues"    (vconcat issues)  h)
                   (puthash "workflows" (vconcat workflows) h)
                   h)))
      (make-directory dir t)
      (with-temp-file file
        (insert (json-serialize obj))
        (json-pretty-print-buffer)))))

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
             (let* ((login   (or (gethash "login" (gethash "author" comment)) ""))
                    (body    (or (gethash "body" comment) ""))
                    (created (or (gethash "createdAt" comment) ""))
                    (date    (octocat--format-ts created)))
               (magit-insert-section (comment comment)
                 (magit-insert-heading
                   (concat "  "
                           (propertize (concat "@" login) 'face 'octocat-pr-author)
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
          (with-temp-buffer
            (insert text)
            (gfm-view-mode)
            (font-lock-ensure)
            (buffer-string))))
    (dolist (line (split-string rendered "\n"))
      (insert indent line "\n"))))

(provide 'octocat-core)
;;; octocat-core.el ends here
