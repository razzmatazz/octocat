;;; octocat-workflow.el --- Workflow detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Workflow data fetching, detail rendering, and the octocat-workflow-mode
;; major mode.  Depends on octocat-core.el for shared infrastructure; must
;; not depend on octocat.el to avoid a circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-run)

;; These commands are defined in octocat.el which loads this file, so we
;; cannot require it here.  Declare them to silence the byte-compiler.
(declare-function octocat-browse "octocat" ())


;;;; Buffer-local declarations

(defvar-local octocat--workflow-repo nil
  "The \"owner/repo\" this workflow buffer belongs to.")

(defvar-local octocat--workflow-id nil
  "The numeric workflow ID this buffer is displaying.")

(defvar-local octocat--workflow-name nil
  "The display name of the workflow this buffer is displaying.")


;;;; Data fetching

(defun octocat--fetch-workflow (repo id callback)
  "Fetch detail for workflow ID in REPO asynchronously.
Calls CALLBACK with a cons (WORKFLOW . RUNS) where WORKFLOW is a
hash-table of metadata and RUNS is a list of run hash-tables, or a
cons \\=(error . MSG) on failure."
  (let ((workflow-result 'pending)
        (runs-result 'pending))
    (cl-labels
        ((maybe-done ()
           (unless (or (eq workflow-result 'pending)
                       (eq runs-result 'pending))
             (cond
              ((eq (car-safe workflow-result) 'error)
               (funcall callback workflow-result))
              ((eq (car-safe runs-result) 'error)
               (funcall callback runs-result))
              (t
               (funcall callback (cons workflow-result runs-result)))))))
      (octocat--run-gh
       "workflow-detail"
       (list "api" (format "repos/%s/actions/workflows/%s" repo id))
       (lambda (output) (json-parse-string (string-trim output)))
       (lambda (result) (setq workflow-result result) (maybe-done)))
      (octocat--run-gh
       "workflow-runs"
       (list "run" "list"
             "--repo"     repo
             "--workflow" (number-to-string id)
             "--limit"    "20"
             "--json"     "databaseId,displayTitle,status,conclusion,createdAt,headBranch")
       #'octocat--parse-json-list
       (lambda (result) (setq runs-result result) (maybe-done))))))


;;;; Rendering helpers

(defun octocat--workflow-run-icon (status conclusion)
  "Return a propertized status icon for a run with STATUS and CONCLUSION."
  (let ((s (or conclusion status "")))
    (cond
     ((equal s "success")
      (propertize "✓" 'face 'octocat-ci-success))
     ((member s '("failure" "timed_out" "startup_failure"))
      (propertize "✗" 'face 'octocat-ci-failure))
     (t
      (propertize "●" 'face 'octocat-ci-pending)))))

(defun octocat--workflow-state-face (state)
  "Return the face for workflow STATE string."
  (if (equal state "active") 'success 'octocat-dimmed))


;;;; Rendering

(defun octocat--render-workflow-loading (name)
  "Render a loading skeleton for the workflow named NAME."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-workflow-root)
      (magit-insert-heading
        (concat (propertize (or octocat--workflow-repo "") 'face 'octocat-repo)
                "  "
                (propertize "workflow" 'face 'octocat-dimmed)
                "  "
                name))
      (magit-insert-section (workflow-info)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (workflow-runs)
        (magit-insert-heading (propertize "Runs" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-workflow (workflow runs)
  "Erase the current buffer and render workflow detail.
WORKFLOW is a hash-table of workflow metadata; RUNS is a list of run
hash-tables."
  (let* ((name    (or (gethash "name"       workflow) ""))
         (state   (downcase (or (gethash "state"      workflow) "")))
         (path    (or (gethash "path"       workflow) ""))
         (created (or (gethash "created_at" workflow) ""))
         (updated (or (gethash "updated_at" workflow) ""))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-workflow-root)
      ;; ── Header ──────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--workflow-repo "") 'face 'octocat-repo)
                "  "
                (propertize "workflow" 'face 'octocat-dimmed)
                "  "
                name
                "  "
                (propertize state 'face (octocat--workflow-state-face state))))
      ;; ── Info ────────────────────────────────────────────────────────────
      (magit-insert-section (workflow-info)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (format "  State    %s\n"
                        (propertize state 'face (octocat--workflow-state-face state))))
        (insert (format "  Path     %s\n"
                        (propertize path 'face 'octocat-branch)))
        (unless (string-empty-p created)
          (insert (format "  Created  %s\n" (octocat--format-ts created))))
        (unless (string-empty-p updated)
          (insert (format "  Updated  %s\n" (octocat--format-ts updated)))))
      ;; ── Runs ────────────────────────────────────────────────────────────
      (magit-insert-section (workflow-runs)
        (magit-insert-heading
          (propertize (format "Runs (%d)" (length runs))
                      'face 'octocat-section-heading))
        (if (null runs)
            (insert (propertize "  (no runs)\n" 'face 'octocat-dimmed))
          (dolist (run runs)
            (let* ((id         (or (gethash "databaseId"   run) 0))
                   (title      (or (gethash "displayTitle" run) ""))
                   (status     (downcase (or (gethash "status" run) "")))
                   (conclusion (let ((c (gethash "conclusion" run)))
                                 (when (and c (not (eq c :null)))
                                   (downcase c))))
                   (branch     (or (gethash "headBranch" run) ""))
                   (created    (or (gethash "createdAt"  run) ""))
                   (date       (octocat--format-ts created))
                   (icon       (octocat--workflow-run-icon status conclusion)))
              (magit-insert-section (workflow-run run)
                (magit-insert-heading
                  (concat
                   "  "
                   icon
                   "  "
                   (propertize (format "%-10s" (number-to-string id))
                               'face 'octocat-pr-number)
                   "  "
                   (truncate-string-to-width (format "%-50s" title) 50 nil ?\s "…")
                   "  "
                   (propertize (format "%-30s" branch) 'face 'octocat-branch)
                   "  "
                   (propertize date 'face 'octocat-dimmed)
                   "\n"))))))))
    (goto-char (point-min))))


;;;; Visitor

(defun octocat-workflow-visit ()
  "Open the detail view for the item at point.
Currently handles \\='workflow-run\\=' sections, opening an
`octocat-run-mode' buffer for the selected run."
  (interactive)
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'workflow-run))
      (let* ((run      (oref section value))
             (run-id   (gethash "databaseId" run))
             (title    (or (gethash "displayTitle" run) ""))
             (repo     octocat--workflow-repo)
             (buf-name (format "*octocat-run: %s#%d*" repo run-id))
             (buf      (get-buffer-create buf-name)))
        (pop-to-buffer buf)
        (unless (derived-mode-p 'octocat-run-mode)
          (octocat-run-mode))
        (setq octocat--run-repo repo
              octocat--run-id   run-id)
        (octocat--render-run-loading run-id)
        (octocat-run-refresh)
        (ignore title)))))


;;;; Major mode

(defvar octocat-workflow-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "RET")     #'octocat-workflow-visit)
    (define-key map (kbd "o")       #'octocat-browse)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-workflow-refresh)
    map)
  "Keymap for `octocat-workflow-mode'.")

(define-derived-mode octocat-workflow-mode magit-section-mode "Octocat-Workflow"
  "Major mode for viewing a GitHub Actions Workflow.

\\{octocat-workflow-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-workflow-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-workflow-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current workflow detail buffer asynchronously."
  (interactive)
  (unless (and octocat--workflow-repo octocat--workflow-id)
    (user-error "Octocat: Buffer is not associated with a workflow"))
  (let ((buf  (current-buffer))
        (repo octocat--workflow-repo)
        (id   octocat--workflow-id))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-workflow
     repo id
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq mode-line-process nil)
           (if (eq (car-safe result) 'error)
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (propertize (format "  Error: %s\n" (cdr result))
                                     'face 'error)))
             (octocat--render-workflow (car result) (cdr result)))))))))

(provide 'octocat-workflow)
;;; octocat-workflow.el ends here
