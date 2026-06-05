;;; octocat.el --- GitHub Client powered by the gh CLI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; Author: octocat.el contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "3.0") (transient "0.4"))
;; Keywords: tools, vc, github
;; URL: https://github.com/octocat.el/octocat.el

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Emacs client for GitHub, powered by the gh CLI.

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

;; Ensure Homebrew and common user-local paths are in `exec-path' so that
;; `executable-find' can locate `gh' even when Emacs is launched as a GUI app
;; (which does not inherit the shell's PATH).
(dolist (dir '("/opt/homebrew/bin"   ; Apple-silicon Homebrew
               "/usr/local/bin"      ; Intel Homebrew / manual installs
               "/opt/local/bin"))    ; MacPorts
  (add-to-list 'exec-path dir))

(defun octocat--ci-status (pr)
  "Return a one-character CI-status indicator for PR alist PR.
Returns \"✓\" (success), \"✗\" (failure), or \"●\" (pending/unknown)."
  (let* ((checks (gethash "statusCheckRollup" pr))
         ;; gh returns an array of check objects; derive overall conclusion.
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

(defun octocat--debug-log (label data)
  "When `octocat-debug' is non-nil, append LABEL and DATA to *octocat-debug*."
  (when octocat-debug
    (with-current-buffer (get-buffer-create "*octocat-debug*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] "))
      (insert label "\n")
      (insert data "\n\n"))))

(defun octocat--parse-prs (json-string)
  "Parse JSON-STRING returned by `gh pr list' into a list of hash-tables.
Returns a list of hash-tables, or signals `error' on failure.
An empty or null response (zero open PRs) is treated as an empty list."
  (let ((trimmed (string-trim json-string)))
    (cond
     ;; gh returns an empty string or literal "null" when there are no PRs.
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

(defun octocat--list-prs (repo callback)
  "Fetch open PRs for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a single argument: a list of PR hash-tables,
or the symbol `error' when the gh process fails."
  (let* ((gh-executable (executable-find "gh"))
         (buf     (generate-new-buffer " *octocat-gh*"))
         (err-buf (generate-new-buffer " *octocat-gh-stderr*"))
         (cmd (when gh-executable
                (list gh-executable "pr" "list"
                      "--repo" repo
                      "--state" "all"
                      "--json" "number,title,author,state,statusCheckRollup"))))
    (if (not gh-executable)
        (progn
          (kill-buffer buf)
          (kill-buffer err-buf)
          (funcall callback 'error))
      (let ((process-environment
             (cons "NO_COLOR=1" process-environment)))
        (make-process
         :name "octocat-gh"
         :buffer buf
         :stderr err-buf
         :command cmd
         :sentinel
         (lambda (proc event)
           (when (string-match-p "\\(finished\\|exited\\)" event)
             (condition-case err
                 (let* ((exit-code (process-exit-status proc))
                        (output (with-current-buffer (process-buffer proc)
                                  (buffer-string)))
                        (stderr (with-current-buffer err-buf
                                  (buffer-string))))
                   (kill-buffer (process-buffer proc))
                   (when (buffer-live-p err-buf) (kill-buffer err-buf))
                   (octocat--debug-log (format "gh exit-code: %d" exit-code) output)
                   (octocat--debug-log "gh stderr" stderr)
                   (if (= exit-code 0)
                       (funcall callback (octocat--parse-prs output))
                     (funcall callback 'error)))
               (error
                (when (buffer-live-p err-buf) (kill-buffer err-buf))
                (message "Octocat sentinel error: %s" (error-message-string err))
                (funcall callback 'error))))))))))

(defun octocat--list-issues (repo callback)
  "Fetch issues for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a single argument: a list of issue hash-tables,
or the symbol `error' when the gh process fails."
  (let* ((gh-executable (executable-find "gh"))
         (buf     (generate-new-buffer " *octocat-gh-issues*"))
         (err-buf (generate-new-buffer " *octocat-gh-issues-stderr*"))
         (cmd (when gh-executable
                (list gh-executable "issue" "list"
                      "--repo" repo
                      "--state" "all"
                      "--json" "number,title,author,state"))))
    (if (not gh-executable)
        (progn
          (kill-buffer buf)
          (kill-buffer err-buf)
          (funcall callback 'error))
      (let ((process-environment
             (cons "NO_COLOR=1" process-environment)))
        (make-process
         :name "octocat-gh-issues"
         :buffer buf
         :stderr err-buf
         :command cmd
         :sentinel
         (lambda (proc event)
           (when (string-match-p "\\(finished\\|exited\\)" event)
             (condition-case err
                 (let* ((exit-code (process-exit-status proc))
                        (output (with-current-buffer (process-buffer proc)
                                  (buffer-string)))
                        (stderr (with-current-buffer err-buf
                                  (buffer-string))))
                   (kill-buffer (process-buffer proc))
                   (when (buffer-live-p err-buf) (kill-buffer err-buf))
                   (octocat--debug-log (format "gh issues exit-code: %d" exit-code) output)
                   (octocat--debug-log "gh issues stderr" stderr)
                   (if (= exit-code 0)
                       (funcall callback (octocat--parse-prs output))
                     (funcall callback 'error)))
               (error
                (when (buffer-live-p err-buf) (kill-buffer err-buf))
                (message "Octocat sentinel error: %s" (error-message-string err))
                (funcall callback 'error))))))))))

;;;; Buffer rendering

(defun octocat--render-prs (prs)
  "Insert the collapsible Pull Requests section for PRS."
  (magit-insert-section (pull-requests)
    (magit-insert-heading
      (propertize "Pull Requests" 'face 'magit-section-heading))
    (if (null prs)
        (insert "  (no pull requests)\n")
      (dolist (pr prs)
        (let* ((number (format "#%-4d" (gethash "number" pr)))
               (title  (or (gethash "title"  pr) ""))
               (author (or (gethash "login"
                                    (gethash "author" pr)) ""))
               (state  (downcase (or (gethash "state" pr) "open")))
               (state-face (cond ((equal state "merged") 'octocat-pr-state-merged)
                                 ((equal state "closed") 'octocat-pr-state-closed)
                                 (t                      'octocat-pr-state-open)))
               (ci     (octocat--ci-status pr)))
          (magit-insert-section (pr pr)
            (magit-insert-heading
              (concat
               "  "
               (propertize number 'face 'octocat-pr-number)
               "  "
               (truncate-string-to-width (format "%-40s" title) 40 nil ?\s "…")
               "  "
               (propertize (format "@%-15s" author) 'face 'octocat-pr-author)
               "  "
               (propertize (format "%-6s" state) 'face state-face)
               "  "
               ci
               "\n"))))))))

(defun octocat--render-issues (issues)
  "Insert the collapsible Issues section for ISSUES."
  (magit-insert-section (issues)
    (magit-insert-heading
      (propertize "Issues" 'face 'magit-section-heading))
    (if (null issues)
        (insert "  (no issues)\n")
      (dolist (issue issues)
        (let* ((number (format "#%-4d" (gethash "number" issue)))
               (title  (or (gethash "title"  issue) ""))
               (author (or (gethash "login"
                                    (gethash "author" issue)) ""))
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
               (truncate-string-to-width (format "%-40s" title) 40 nil ?\s "…")
               "  "
               (propertize (format "@%-15s" author) 'face 'octocat-pr-author)
               "  "
               (propertize (format "%-6s" state) 'face state-face)
               "\n"))))))))

(defun octocat--render (prs issues repo)
  "Erase the current buffer and render PRS and ISSUES for REPO.
Uses the `magit-section' package for collapsible sections."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (concat (propertize repo 'face 'magit-branch-remote)
                (propertize (format "  %d PR(s)  %d issue(s)"
                                    (length prs) (length issues))
                            'face 'magit-dimmed)))
      (octocat--render-prs prs)
      (octocat--render-issues issues))))


;;;; Major mode

(defvar octocat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "RET") #'octocat-visit-pr)
    map)
  "Keymap for `octocat-mode'.")

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

(defun octocat-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat buffer asynchronously.
Fetches pull requests and issues in parallel; renders once both arrive."
  (interactive)
  (unless octocat--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let ((buf (current-buffer))
        (repo octocat--repo)
        (pr-result 'pending)
        (issue-result 'pending))
    ;; Show loading placeholder immediately.
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "  Loading…\n" 'face 'magit-dimmed)))
    ;; Render once both fetches have completed.
    (cl-flet ((maybe-render ()
                (unless (or (eq pr-result 'pending) (eq issue-result 'pending))
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (if (or (eq pr-result 'error) (eq issue-result 'error))
                          (progn
                            (let ((inhibit-read-only t))
                              (erase-buffer)
                              (insert (propertize
                                       "  Error: could not fetch data.\n\
  Make sure `gh' is installed and you are authenticated (`gh auth login').\n"
                                       'face 'error)))
                            (message "Octocat: Failed to fetch data"))
                        (octocat--render pr-result issue-result repo)
                        (message "Octocat: Loaded %d PR(s), %d issue(s)"
                                 (length pr-result) (length issue-result))))))))
      (octocat--list-prs repo
                         (lambda (result)
                           (setq pr-result result)
                           (maybe-render)))
      (octocat--list-issues repo
                            (lambda (result)
                              (setq issue-result result)
                              (maybe-render))))))


;;;; PR visitor (stub)

(defun octocat-visit-pr ()
  "Open the detail view for the PR at point (not yet implemented)."
  (interactive)
  (let ((section (magit-current-section)))
    (if (and section (eq (oref section type) 'pr))
        (message "Octocat: PR detail view coming soon!  (PR %s)"
                 (gethash "number" (oref section value)))
      (message "Octocat: No PR at point"))))


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

(provide 'octocat)
;;; octocat.el ends here
