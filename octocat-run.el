;;; octocat-run.el --- Workflow run detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

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

;; Workflow-run data fetching, detail rendering, and the octocat-run-mode
;; major mode.  Depends on octocat-core.el for shared infrastructure; must
;; not depend on octocat.el to avoid a circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-job)

;; These commands are defined in octocat.el which loads this file, so we
;; cannot require it here.  Declare them to silence the byte-compiler.
(declare-function octocat-browse                 "octocat"     ())
(declare-function octocat-job-download-artifact  "octocat-job" ())


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


;;;; Annotations fetching

(defun octocat--fetch-run-annotations (repo jobs callback)
  "Fetch check-run annotations for every job in the JOBS vector from REPO.
Fires one async request per job in parallel.  Calls CALLBACK with an alist
of (JOB-ID . ANNOTATIONS-VECTOR) entries, or nil when JOBS is empty.
Individual job annotation failures are silently treated as empty vectors."
  (let* ((job-list (cl-coerce jobs 'list))
         (pending  (length job-list))
         (results  nil))
    (if (zerop pending)
        (funcall callback nil)
      (dolist (job job-list)
        (let* ((job-id   (gethash "databaseId" job))
               (job-name (or (gethash "name" job) "")))
          (octocat--run-gh
           "run-annotations"
           (list "api"
                 (format "repos/%s/check-runs/%s/annotations?per_page=100"
                         repo (number-to-string job-id)))
           (lambda (output)
             (condition-case nil
                 (let ((parsed (json-parse-string (string-trim output))))
                   (if (vectorp parsed) parsed []))
               (error [])))
           (lambda (ann-result)
             (let ((anns (if (eq (car-safe ann-result) 'error) [] ann-result)))
               (push (list job-id job-name anns) results))
             (cl-decf pending)
             (when (zerop pending)
               (funcall callback (nreverse results))))))))))


;;;; Artifacts fetching

(defun octocat--fetch-run-artifacts (repo run-id callback)
  "Fetch artifacts for run RUN-ID in REPO asynchronously.
Calls CALLBACK with a vector of artifact hash-tables, or \\=[] on failure."
  (octocat--run-gh
   "run-artifacts"
   (list "api"
         (format "repos/%s/actions/runs/%s/artifacts?per_page=100"
                 repo (number-to-string run-id)))
   (lambda (output)
     (condition-case nil
         (let ((parsed (json-parse-string (string-trim output))))
           (or (and (hash-table-p parsed)
                    (gethash "artifacts" parsed))
               []))
       (error [])))
   (lambda (result)
     (funcall callback (if (eq (car-safe result) 'error) [] result)))))


;;;; Rendering helpers

(defun octocat--run-step-icon (status conclusion)
  "Return a propertized step-level checkbox icon for STATUS and CONCLUSION strings.
Steps use a bracketed checkbox style to visually distinguish them from jobs,
which use the plain filled-glyph icons from `octocat--run-icon'.
STATUS takes priority over CONCLUSION for in-progress detection."
  (let ((st (or status ""))
        (co (octocat--nonempty conclusion)))
    (cond
     ((equal st "in_progress")
      (propertize "[●]" 'face 'octocat-ci-pending))
     ((equal co "success")
      (propertize "[✓]" 'face 'octocat-ci-success))
     ((member co '("failure" "timed_out" "startup_failure" "cancelled"))
      (propertize "[✗]" 'face 'octocat-ci-failure))
     ((equal co "skipped")
      (propertize "[-]" 'face 'octocat-dimmed))
     ((equal st "completed")
      ;; completed but unrecognised conclusion — treat as failure
      (propertize "[✗]" 'face 'octocat-ci-failure))
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
      (insert "\n")
      (magit-insert-section (run-jobs)
        (magit-insert-heading (propertize "Jobs" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-run (run &optional annotations-entries artifacts)
  "Erase the current buffer and render workflow-run detail from hash-table RUN.
ANNOTATIONS-ENTRIES is an optional alist of (JOB-ID JOB-NAME ANNOTATIONS-VECTOR)
triples returned by `octocat--fetch-run-annotations'.
ARTIFACTS is an optional vector of artifact hash-tables from the Actions API."
  (let* ((run-id     (or (gethash "databaseId"   run) 0))
         (title      (or (gethash "displayTitle"  run) ""))
         (status     (downcase (or (gethash "status"       run) "")))
         (conclusion (let ((c (gethash "conclusion" run)))
                       (and (octocat--nonempty c) (downcase c))))
         (created    (or (gethash "createdAt"    run) ""))
         (updated    (or (gethash "updatedAt"    run) ""))
         (branch     (or (gethash "headBranch"   run) ""))
         (local-branch (octocat--current-branch))
         (branch-face  (if (and local-branch (string= branch local-branch))
                           'octocat-branch-current
                         'octocat-branch))
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
                          (propertize branch 'face branch-face))))
        (unless (string-empty-p sha)
          (insert (format "  SHA        %s\n"
                          (propertize (substring sha 0 (min 7 (length sha)))
                                      'face 'octocat-pr-number))))
        (let* ((display-status (or conclusion
                                   (and (not (string-empty-p status)) status)))
               (status-face    (cond
                                ((equal display-status "success")   'octocat-ci-success)
                                ((member display-status '("failure" "timed_out"
                                                          "startup_failure" "cancelled"))
                                 'octocat-ci-failure)
                                (t 'octocat-ci-pending))))
          (when display-status
            (insert (format "  Status     %s\n"
                            (propertize display-status 'face status-face)))))
        (unless (string-empty-p created)
          (insert (format "  Created    %s\n" (octocat--format-ts-full created))))
        (when conclusion
          (let ((duration (octocat--run-duration
                           (and (not (string-empty-p created)) created)
                           (and (not (string-empty-p updated)) updated))))
            (when duration
              (insert (format "  Duration   %s\n"
                              (propertize duration 'face 'octocat-dimmed)))))))
      ;; ── Jobs ────────────────────────────────────────────────────────────
      (insert "\n")
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
                          (jconc      (and (octocat--nonempty jconc-raw) (downcase jconc-raw)))
                          (jstarted   (gethash "startedAt"   job))
                          (jcompleted (gethash "completedAt" job))
                          (duration   (and jconc
                                          (octocat--run-duration
                                           (octocat--nonempty jstarted)
                                           (octocat--nonempty jcompleted))))
                          (jicon      (octocat--run-icon jstatus jconc)))
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
                          "\n"))))))
      (insert "\n")
      ;; ── Artifacts ───────────────────────────────────────────────────────
      (octocat--render-artifacts artifacts)
      ;; ── Annotations (aggregated across all jobs) — placed last ──────────
      (let ((all-anns
             (when annotations-entries
               (cl-loop for (_jid jname anns) in annotations-entries
                        append (cl-loop for ann across anns
                                        collect (cons jname ann))))))
        (when all-anns
          (insert "\n")
          (magit-insert-section (run-annotations)
            (magit-insert-heading
              (propertize (format "Annotations (%d)" (length all-anns))
                          'face 'octocat-section-heading))
            (dolist (entry all-anns)
              (let* ((jname (car entry))
                     (ann   (cdr entry))
                     (level (downcase
                             (or (gethash "annotation_level" ann) "notice")))
                     (msg   (or (gethash "message" ann) ""))
                     (text  (replace-regexp-in-string "\n" " " msg)))
                (insert "  "
                        (octocat--annotation-icon level)
                        "  "
                        (propertize jname 'face 'octocat-run-job-name)
                        "  "
                        (propertize text
                                    'face (octocat--annotation-face level))
                          "\n"))))))))))


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

(defun octocat-run-visit-or-download ()
  "Visit the job at point, or download the artifact at point.
On a `run-job' section heading calls `octocat-run-visit'.
On an artifact row (carrying the `octocat-artifact' text property)
calls `octocat-job-download-artifact'."
  (interactive)
  (let ((section (magit-current-section)))
    (cond
     ((and section (eq (oref section type) 'run-job))
      (octocat-run-visit))
     ((get-text-property (point) 'octocat-artifact)
      (octocat-job-download-artifact)))))

(defvar octocat-run-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "RET")     #'octocat-run-visit-or-download)
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
  "Refresh the current run detail buffer asynchronously.
Renders a disk cache immediately (stale-while-revalidate) when available,
then always fetches fresh data in the background."
  (interactive)
  (unless (and octocat--run-repo octocat--run-id)
    (user-error "Octocat: Buffer is not associated with a workflow run"))
  (let* ((buf         (current-buffer))
         (repo        octocat--run-repo)
         (id          octocat--run-id)
         (saved-point (octocat--save-point))
         (cache       (octocat--detail-cache-load repo "run" id)))
    (when cache
      (octocat--render-run cache)
      (octocat--restore-point saved-point))
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
             (octocat--detail-cache-save repo "run" id result)
             ;; Render immediately without annotations (fast path).
             (octocat--render-run result nil)
             (octocat--restore-point saved-point)
             ;; Fetch annotations and artifacts in parallel, re-render once
             ;; both are ready.
             (let* ((jobs (let ((v (gethash "jobs" result)))
                            (if (or (null v) (eq v :null)) [] v)))
                    (ann-result 'pending)
                    (art-result 'pending))
               (cl-labels
                   ((maybe-done ()
                      (unless (or (eq ann-result 'pending)
                                  (eq art-result 'pending))
                        (when (buffer-live-p buf)
                          (with-current-buffer buf
                            (octocat--render-run result ann-result art-result)
                            (octocat--restore-point saved-point))))))
                 (octocat--fetch-run-annotations
                  repo jobs
                  (lambda (entries)
                    (setq ann-result entries)
                    (maybe-done)))
                 (octocat--fetch-run-artifacts
                  repo id
                  (lambda (arts)
                    (setq art-result arts)
                    (maybe-done))))))))))))

(provide 'octocat-run)
;;; octocat-run.el ends here
