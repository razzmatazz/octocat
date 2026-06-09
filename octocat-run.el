;;; octocat-run.el --- Workflow run detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Workflow-run data fetching, detail rendering, and the octocat-run-mode
;; major mode.  Depends on octocat-core.el for shared infrastructure; must
;; not depend on octocat.el to avoid a circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-job)

;; These commands are defined in octocat.el which loads this file, so we
;; cannot require it here.  Declare them to silence the byte-compiler.
(declare-function octocat-browse "octocat" ())


;;;; Buffer-local declarations

(defvar-local octocat--run-repo nil
  "The \"owner/repo\" this run buffer belongs to.")

(defvar-local octocat--run-id nil
  "The numeric database ID of the run this buffer is displaying.")


;;;; Data fetching

(defun octocat--fetch-run (repo run-id callback)
  "Fetch detail for run RUN-ID in REPO asynchronously.
Calls CALLBACK with a hash-table of run data (including a \\='jobs\\=' key
whose value is a vector of job hash-tables), or a cons \\=(error . MSG)."
  (octocat--run-gh
   "run-view"
   (list "run" "view"
         (number-to-string run-id)
         "--repo" repo
         "--json" (concat "databaseId,displayTitle,status,conclusion,"
                          "createdAt,updatedAt,headBranch,headSha,"
                          "event,workflowName,jobs"))
   (lambda (output) (json-parse-string (string-trim output)))
   callback))


;;;; Rendering helpers

(defun octocat--run-step-icon (status conclusion)
  "Return a propertized step-level checkbox icon for STATUS and CONCLUSION strings.
Steps use a bracketed checkbox style to visually distinguish them from jobs,
which use the plain filled-glyph icons from `octocat--run-icon'."
  (let ((s (or (and conclusion (not (eq conclusion :null)) conclusion)
               status
               "")))
    (cond
     ((equal s "success")
      (propertize "[✓]" 'face 'octocat-ci-success))
     ((member s '("failure" "timed_out" "startup_failure" "cancelled"))
      (propertize "[✗]" 'face 'octocat-ci-failure))
     ((equal s "in_progress")
      (propertize "[●]" 'face 'octocat-ci-pending))
     ((equal s "skipped")
      (propertize "[-]" 'face 'octocat-dimmed))
     (t
      (propertize "[ ]" 'face 'octocat-dimmed)))))


;;;; Rendering

(defun octocat--render-run-loading (run-id)
  "Render a loading skeleton for run RUN-ID."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-run-root)
      (magit-insert-heading
        (concat (propertize (or octocat--run-repo "") 'face 'octocat-repo)
                "  "
                (propertize "run" 'face 'octocat-dimmed)
                " "
                (propertize (number-to-string run-id) 'face 'octocat-pr-number)))
      (magit-insert-section (run-info)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (run-jobs)
        (magit-insert-heading (propertize "Jobs" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-run (run)
  "Erase the current buffer and render workflow-run detail from hash-table RUN."
  (let* ((run-id     (or (gethash "databaseId"   run) 0))
         (title      (or (gethash "displayTitle"  run) ""))
         (status     (downcase (or (gethash "status"       run) "")))
         (conclusion (let ((c (gethash "conclusion" run)))
                       (when (and c (not (eq c :null)))
                         (downcase c))))
         (created    (or (gethash "createdAt"    run) ""))
         (updated    (or (gethash "updatedAt"    run) ""))
         (branch     (or (gethash "headBranch"   run) ""))
         (sha        (or (gethash "headSha"      run) ""))
         (event      (or (gethash "event"        run) ""))
         (wf-name    (or (gethash "workflowName" run) ""))
         (jobs       (let ((v (gethash "jobs" run)))
                       (if (or (null v) (eq v :null)) [] v)))
         (icon       (octocat--run-icon status conclusion))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-run-root)
      ;; ── Header ──────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--run-repo "") 'face 'octocat-repo)
                "  "
                (propertize "run" 'face 'octocat-dimmed)
                " "
                (propertize (number-to-string run-id) 'face 'octocat-pr-number)
                "  "
                icon
                "  "
                title))
      ;; ── Info ────────────────────────────────────────────────────────────
      (magit-insert-section (run-info)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (unless (string-empty-p wf-name)
          (insert (format "  Workflow   %s\n"
                          (propertize wf-name 'face 'octocat-section-heading))))
        (unless (string-empty-p event)
          (insert (format "  Event      %s\n" event)))
        (unless (string-empty-p branch)
          (insert (format "  Branch     %s\n"
                          (propertize branch 'face 'octocat-branch))))
        (unless (string-empty-p sha)
          (insert (format "  SHA        %s\n"
                          (propertize (substring sha 0 (min 7 (length sha)))
                                      'face 'octocat-pr-number))))
        (let ((display-status (or conclusion status)))
          (unless (string-empty-p display-status)
            (insert (format "  Status     %s\n"
                            (propertize display-status
                                        'face (cond
                                               ((equal display-status "success")
                                                'octocat-ci-success)
                                               ((member display-status
                                                        '("failure" "timed_out"
                                                          "startup_failure" "cancelled"))
                                                'octocat-ci-failure)
                                               (t 'octocat-ci-pending)))))))
        (unless (string-empty-p created)
          (insert (format "  Created    %s\n"
                          (substring created 0 (min 19 (length created))))))
        (unless (string-empty-p updated)
          (insert (format "  Updated    %s\n"
                          (substring updated 0 (min 19 (length updated)))))))
      ;; ── Jobs ────────────────────────────────────────────────────────────
      (magit-insert-section (run-jobs)
        (magit-insert-heading
          (propertize (format "Jobs (%d)" (length jobs))
                      'face 'octocat-section-heading))
        (if (zerop (length jobs))
            (insert (propertize "  (no jobs)\n" 'face 'octocat-dimmed))
          (cl-loop for job across jobs do
                   (let* ((job-name   (or (gethash "name"       job) ""))
                          (jstatus    (downcase (or (gethash "status"     job) "")))
                          (jconc-raw  (gethash "conclusion" job))
                          (jconc      (when (and jconc-raw (not (eq jconc-raw :null)))
                                        (downcase jconc-raw)))
                          (jstarted   (gethash "startedAt"   job))
                          (jcompleted (gethash "completedAt" job))
                          (duration   (octocat--run-duration
                                       (when (and jstarted   (not (eq jstarted :null)))
                                         jstarted)
                                       (when (and jcompleted (not (eq jcompleted :null)))
                                         jcompleted)))
                          (jicon      (octocat--run-icon jstatus jconc))
                          (steps      (let ((v (gethash "steps" job)))
                                        (if (or (null v) (eq v :null)) [] v))))
                     (magit-insert-section (run-job job)
                       (magit-insert-heading
                         (concat
                          "  "
                          jicon
                          "  "
                          (propertize
                           (truncate-string-to-width (format "%-45s" job-name) 45 nil ?\s "…")
                           'face 'octocat-run-job-name)
                          (if duration
                              (propertize (format "  %s" duration) 'face 'octocat-dimmed)
                            "")
                          "\n"))
                       (when (> (length steps) 0)
                         (cl-loop for step across steps do
                                  (let* ((sname   (or (gethash "name"       step) ""))
                                         (sstatus (downcase (or (gethash "status"     step) "")))
                                         (sconc-r (gethash "conclusion" step))
                                         (sconc   (when (and sconc-r (not (eq sconc-r :null)))
                                                    (downcase sconc-r)))
                                         (sstart  (gethash "startedAt"   step))
                                         (scomp   (gethash "completedAt" step))
                                         (sdur    (octocat--run-duration
                                                   (when (and sstart (not (eq sstart :null)))
                                                     sstart)
                                                   (when (and scomp  (not (eq scomp  :null)))
                                                     scomp)))
                                         (sicon   (octocat--run-step-icon sstatus sconc)))
                                    (insert
                                     (concat
                                      "      "
                                      sicon
                                      " "
                                      (propertize
                                       (truncate-string-to-width
                                        (format "%-43s" sname) 43 nil ?\s "…")
                                       'face 'octocat-run-step-name)
                                      (if sdur
                                          (propertize (format "  %s" sdur) 'face 'octocat-dimmed)
                                        "")
                                      "\n")))))))))))
    (goto-char (point-min))))


;;;; Visitor

(defun octocat-run-visit ()
  "Open the detail view for the job at point.
Handles \\='run-job\\=' sections, opening an `octocat-job-mode' buffer
for the selected job."
  (interactive)
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'run-job))
      (let* ((job      (oref section value))
             (job-id   (gethash "databaseId" job))
             (job-name (or (gethash "name" job) ""))
             (repo     octocat--run-repo)
             (run-id   octocat--run-id)
             (buf-name (format "*octocat-job: %s#%d*" repo job-id))
             (buf      (get-buffer-create buf-name)))
        (pop-to-buffer buf)
        (unless (derived-mode-p 'octocat-job-mode)
          (octocat-job-mode))
        (setq octocat--job-repo   repo
              octocat--job-run-id run-id
              octocat--job-id     job-id
              octocat--job-name   job-name)
        (octocat-job-refresh)))))


;;;; Major mode

(defvar octocat-run-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "RET")     #'octocat-run-visit)
    (define-key map (kbd "o")       #'octocat-browse)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-run-refresh)
    map)
  "Keymap for `octocat-run-mode'.")

(define-derived-mode octocat-run-mode magit-section-mode "Octocat-Run"
  "Major mode for viewing a GitHub Actions workflow run.

\\{octocat-run-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-run-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-run-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current run detail buffer asynchronously."
  (interactive)
  (unless (and octocat--run-repo octocat--run-id)
    (user-error "Octocat: Buffer is not associated with a workflow run"))
  (let ((buf  (current-buffer))
        (repo octocat--run-repo)
        (id   octocat--run-id))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-run
     repo id
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq mode-line-process nil)
           (if (eq (car-safe result) 'error)
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (propertize
                          (format "  Error: %s\n" (cdr result))
                          'face 'error)))
             (octocat--render-run result))))))))

(provide 'octocat-run)
;;; octocat-run.el ends here
