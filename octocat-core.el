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


;;;; Options

(defcustom octocat-debug nil
  "When non-nil, dump raw gh JSON output to the *octocat-debug* buffer."
  :type 'boolean
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
  '((t :inherit magit-hash))
  "Face for a PR number."
  :group 'octocat)

(defface octocat-pr-author
  '((t :inherit magit-log-author))
  "Face for a PR author."
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

(provide 'octocat-core)
;;; octocat-core.el ends here
