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

(require 'octocat-core)
(require 'octocat-pr)
(require 'octocat-commit)
(require 'octocat-issue)
(require 'octocat-workflow)
(require 'octocat-run)

(defvar octocat--pr-repo)        ; defined as buffer-local in octocat-pr.el
(defvar octocat--pr-number)      ; defined as buffer-local in octocat-pr.el
(defvar octocat--issue-repo)     ; defined as buffer-local in octocat-issue.el
(defvar octocat--issue-number)   ; defined as buffer-local in octocat-issue.el
(defvar octocat--workflow-repo)  ; defined as buffer-local in octocat-workflow.el
(defvar octocat--workflow-id)    ; defined as buffer-local in octocat-workflow.el
(defvar octocat--workflow-name)  ; defined as buffer-local in octocat-workflow.el
(defvar octocat--run-repo)       ; defined as buffer-local in octocat-run.el
(defvar octocat--run-id)         ; defined as buffer-local in octocat-run.el

;; Evil integration is optional; declare its entry point to silence the
;; byte-compiler when `octocat-evil' has not been loaded yet.
(declare-function octocat-evil-setup "octocat-evil" ())


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

(defun octocat--list-issues (repo callback)
  "Fetch issues for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of issue hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "issues"
                   (list "issue" "list"
                         "--repo" repo
                         "--state" "all"
                         "--json" "number,title,author,state")
                   #'octocat--parse-json-list
                   callback))

(defun octocat--list-workflows (repo callback)
  "Fetch workflows for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of workflow hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "workflows"
                   (list "workflow" "list"
                         "--repo" repo
                         "--json" "id,name,state,path")
                   #'octocat--parse-json-list
                   callback))


;;;; Buffer rendering

(defun octocat--render-prs (prs)
  "Insert the collapsible Pull Requests section for PRS."
  (magit-insert-section (pull-requests)
    (magit-insert-heading
      (propertize "Pull Requests" 'face 'octocat-section-heading))
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
      (propertize "Issues" 'face 'octocat-section-heading))
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

(defun octocat--render-workflows (workflows)
  "Insert the collapsible Workflows section for WORKFLOWS."
  (magit-insert-section (workflows)
    (magit-insert-heading
      (propertize "Workflows" 'face 'octocat-section-heading))
    (if (null workflows)
        (insert "  (no workflows)\n")
      (dolist (workflow workflows)
        (let* ((name  (or (gethash "name"  workflow) ""))
               (state (downcase (or (gethash "state" workflow) "")))
               (state-face (if (equal state "active")
                               'success
                             'octocat-dimmed)))
          (magit-insert-section (workflow workflow)
            (magit-insert-heading
              (concat
               "  "
               (truncate-string-to-width (format "%-40s" name) 40 nil ?\s "…")
               "  "
               (propertize state 'face state-face)
               "\n"))))))))

(defun octocat--render-loading (repo)
  "Render a skeleton front view for REPO while data is still loading.
Shows the repo header and collapsed section expanders for Pull Requests,
Issues, and Workflows, each with a dimmed \\='Loading…\\=' placeholder."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (propertize repo 'face 'octocat-repo))
      (magit-insert-section (pull-requests)
        (magit-insert-heading
          (propertize "Pull Requests" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (issues)
        (magit-insert-heading
          (propertize "Issues" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (workflows)
        (magit-insert-heading
          (propertize "Workflows" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render (prs issues workflows repo)
  "Erase the current buffer and render PRS, ISSUES, and WORKFLOWS for REPO.
Renders collapsible sections; delegates to the individual render helpers."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-root)
      (magit-insert-heading
        (concat (propertize repo 'face 'octocat-repo)
                (propertize (format "  %d PR(s)  %d issue(s)  %d workflow(s)"
                                    (length prs) (length issues) (length workflows))
                            'face 'octocat-dimmed)))
      (octocat--render-prs prs)
      (octocat--render-issues issues)
      (octocat--render-workflows workflows))))


;;;; Major mode

(defvar octocat-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `octocat-mode'.")
(define-key octocat-mode-map (kbd "q")       #'quit-window)
(define-key octocat-mode-map (kbd "RET")     #'octocat-visit)
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

(defun octocat-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat buffer asynchronously.
Fetches pull requests, issues, and workflows in parallel; renders once all
arrive."
  (interactive)
  (unless octocat--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let ((buf (current-buffer))
        (repo octocat--repo)
        (pr-result 'pending)
        (issue-result 'pending)
        (workflow-result 'pending))
    (octocat--render-loading repo)
    (cl-labels ((maybe-render ()
                (unless (or (eq pr-result 'pending)
                            (eq issue-result 'pending)
                            (eq workflow-result 'pending))
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (let ((failed (seq-find (lambda (r) (eq (car-safe r) 'error))
                                              (list pr-result issue-result workflow-result))))
                        (if failed
                          (let ((inhibit-read-only t))
                            (erase-buffer)
                            (insert (propertize
                                     (format "  Error: %s\n\
  Make sure `gh' is installed and you are authenticated (`gh auth login').\n"
                                             (cdr failed))
                                     'face 'error)))
                        (octocat--render pr-result issue-result workflow-result repo))))))))
      (octocat--list-prs repo
                         (lambda (result)
                           (setq pr-result result)
                           (maybe-render)))
      (octocat--list-issues repo
                            (lambda (result)
                              (setq issue-result result)
                              (maybe-render)))
      (octocat--list-workflows repo
                               (lambda (result)
                                 (setq workflow-result result)
                                 (maybe-render))))))


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
              (oid      (or (gethash "oid" commit) ""))
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
      (_ nil))))


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
