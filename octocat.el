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
(require 'octocat-issue)
(require 'octocat-workflow)
(require 'octocat-run)
(require 'octocat-job)

(defvar octocat--pr-repo)        ; defined as buffer-local in octocat-pr.el
(defvar octocat--pr-number)      ; defined as buffer-local in octocat-pr.el
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
Retrieves the 3 most recent entries and calls CALLBACK with a list of
run hash-tables, or a cons \\=(error . MSG) on failure."
  (octocat--run-gh
   (format "workflow-runs-%d" workflow-id)
   (list "run" "list"
         "--repo"     repo
         "--workflow" (number-to-string workflow-id)
         "--limit"    "3"
         "--json"     "databaseId,displayTitle,status,conclusion,createdAt,headBranch")
   #'octocat--parse-json-list
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

(defun octocat--render-prs (prs)
  "Insert the collapsible Pull Requests section for PRS.
PRS may be a list of pull-request hash-tables or a cons (error . MSG)."
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
      (dolist (pr prs)
        (let* ((number (format "#%-4d" (gethash "number" pr)))
               (title  (or (gethash "title"  pr) ""))
               (author (or (gethash "login"
                                    (gethash "author" pr)) ""))
               (state  (downcase (or (gethash "state" pr) "open")))
               (state-face (cond ((equal state "merged") 'octocat-pr-state-merged)
                                 ((equal state "closed") 'octocat-pr-state-closed)
                                 (t                      'octocat-pr-state-open)))
               (ci     (octocat--ci-label pr)))
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
               "\n")))))))))

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
               "\n")))))))))

(defun octocat--render-workflows (workflows &optional runs-by-id)
  "Insert the collapsible Workflows section for WORKFLOWS.
WORKFLOWS may be a list of workflow hash-tables or a cons (error . MSG).
RUNS-BY-ID is an optional alist of (workflow-id . runs-list) used to
render recent run rows beneath each workflow heading."
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
      (let ((branch-w (min 25 (apply #'max 1
                                     (mapcar (lambda (r)
                                               (length (or (gethash "headBranch" r) "")))
                                             (apply #'append
                                                    (mapcar (lambda (wf)
                                                              (cdr (assoc (gethash "id" wf)
                                                                          runs-by-id)))
                                                            workflows)))))))
        (dolist (workflow workflows)
          (let* ((name       (or (gethash "name"  workflow) ""))
                 (wf-id      (gethash "id" workflow))
                 (state      (downcase (or (gethash "state" workflow) "")))
                 (state-face (if (equal state "active") 'success 'octocat-dimmed))
                 (runs       (cdr (assoc wf-id runs-by-id))))
            (magit-insert-section (workflow workflow)
              (magit-insert-heading
                (concat
                 "  "
                 (truncate-string-to-width name 40 nil nil "…")
                 "  "
                 (propertize state 'face state-face)
                 "\n"))
              (dolist (run runs)
                (let* ((run-id     (or (gethash "databaseId"   run) 0))
                       (title      (or (gethash "displayTitle" run) ""))
                       (status     (downcase (or (gethash "status" run) "")))
                       (conclusion (let ((c (gethash "conclusion" run)))
                                     (and (octocat--nonempty c) (downcase c))))
                       (branch     (or (gethash "headBranch" run) ""))
                       (created    (or (gethash "createdAt"  run) ""))
                       (date       (octocat--format-ts created))
                       (icon       (octocat--workflow-run-icon status conclusion)))
                  (magit-insert-section (workflow-run run)
                    (magit-insert-heading
                      (concat
                       "    "
                       icon
                       "  "
                       (propertize (format "%-10s" (number-to-string run-id))
                                   'face 'octocat-pr-number)
                       "  "
                       (propertize (truncate-string-to-width branch branch-w nil ?\s "…")
                                   'face 'octocat-branch)
                       "  "
                       (truncate-string-to-width title 30 nil ?\s "…")
                       "  "
                       (propertize date 'face 'octocat-dimmed)
                       "\n")))))))))))))

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
      (octocat--hide-if-saved 'pull-requests
        (magit-insert-section (pull-requests)
          (magit-insert-heading
            (propertize "Pull Requests" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (octocat--hide-if-saved 'issues
        (magit-insert-section (issues)
          (magit-insert-heading
            (propertize "Issues" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))
      (octocat--hide-if-saved 'workflows
        (magit-insert-section (workflows)
          (magit-insert-heading
            (propertize "Workflows" 'face 'octocat-section-heading))
          (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))))))

(defun octocat--render (prs issues workflows repo &optional runs-by-id)
  "Erase the current buffer and render PRS, ISSUES, and WORKFLOWS for REPO.
Each argument may be a list of hash-tables or a cons (error . MSG) when the
corresponding feature is disabled or unavailable for the repo.
RUNS-BY-ID is an optional alist of (workflow-id . runs-list).
Renders collapsible sections; delegates to the individual render helpers."
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
      (octocat--hide-if-saved 'pull-requests (octocat--render-prs prs))
      (octocat--hide-if-saved 'issues        (octocat--render-issues issues))
      (octocat--hide-if-saved 'workflows     (octocat--render-workflows workflows runs-by-id)))))


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
fetches fresh data in the background and re-renders when it arrives."
  (interactive)
  (unless octocat--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (let* ((buf         (current-buffer))
         (repo        octocat--repo)
         (cache       (octocat--cache-load repo))
         ;; Capture point position before any render so both the cache
         ;; render and the live render can restore it afterwards.
         (saved-point (octocat--save-point)))
    ;; Render cache immediately if available; otherwise show loading skeleton.
    (if cache
        (progn
          (octocat--render (plist-get cache :prs)
                           (plist-get cache :issues)
                           (plist-get cache :workflows)
                           repo
                           (plist-get cache :workflow-runs))
          (octocat--restore-point saved-point))
      (octocat--render-loading repo))
    ;; Always fetch fresh data in the background.
    ;; Phase 1: fetch PRs, issues, workflows in parallel.
    ;; Phase 2: once workflows arrive, fetch runs for each workflow, then render.
    (setq mode-line-process " [refreshing…]")
    (let ((pr-result       'pending)
          (issue-result    'pending)
          (workflow-result 'pending)
          (runs-by-id      nil)
          (runs-pending    0)
          (phase2-started  nil))
      (cl-labels
          ((maybe-render ()
             ;; Fire only when PRs, issues, workflows, and all run fetches are done.
             (unless (or (eq pr-result       'pending)
                         (eq issue-result    'pending)
                         (eq workflow-result 'pending)
                         (> runs-pending 0))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq mode-line-process nil)
                   (octocat--cache-save repo pr-result issue-result
                                        workflow-result runs-by-id)
                   (octocat--render pr-result issue-result workflow-result
                                    repo runs-by-id)
                   (octocat--restore-point saved-point)))))
           (start-phase2 ()
             ;; Called once workflow-result is known.  Fire one run-list fetch
             ;; per workflow; if there are no workflows, go straight to render.
             (setq phase2-started t)
             (let ((wfs (if (or (eq (car-safe workflow-result) 'error)
                                (null workflow-result))
                            '()
                          workflow-result)))
               (if (null wfs)
                   (maybe-render)
                 (setq runs-pending (length wfs))
                 (dolist (wf wfs)
                   (let ((wf-id (gethash "id" wf)))
                     (octocat--list-workflow-runs
                      repo wf-id
                      (lambda (result)
                        (when (buffer-live-p buf)
                          (with-current-buffer buf
                            (unless (eq (car-safe result) 'error)
                              (push (cons wf-id result) runs-by-id))
                            (cl-decf runs-pending)
                            (maybe-render)))))))))))
        (octocat--list-prs repo
                           (lambda (result)
                             (setq pr-result result)
                             (when phase2-started (maybe-render))))
        (octocat--list-issues repo
                              (lambda (result)
                                (setq issue-result result)
                                (when phase2-started (maybe-render))))
        (octocat--list-workflows repo
                                 (lambda (result)
                                   (setq workflow-result result)
                                   (start-phase2)))))))


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
