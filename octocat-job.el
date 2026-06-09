;;; octocat-job.el --- Job detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Job data fetching, detail rendering, and the octocat-job-mode major mode
;; for displaying the full detail and log output of a single GitHub Actions
;; job.  Depends on octocat-core.el for shared infrastructure; must not
;; depend on octocat.el or octocat-run.el to avoid circular requires.
;;
;; Layout of the view:
;;
;;   REPO  job  JOB-NAME  ✓  success
;;
;;   Info ──────────────────────────────
;;     Status     success
;;     Duration   5s
;;     Started    2026-06-08 05:47:21
;;     Completed  2026-06-08 05:47:26
;;     Runner     GitHub Actions …
;;     Labels     ubuntu-latest
;;
;;   ▸ [✓] Set up job          success  1s
;;         line1
;;         line2
;;   ▸ [✓] Run action          success  3s
;;         line1
;;   ▸ [✓] Complete job        success  0s
;;         line1
;;
;; Job metadata is fetched from the REST API:
;;   gh api repos/OWNER/REPO/actions/jobs/JOB-ID
;;
;; Log output is fetched with:
;;   gh run view --log --job JOB-ID --repo OWNER/REPO
;;
;; The two requests run in parallel.  A log-fetch failure is non-fatal:
;; step sections are shown with their metadata but without log lines, and
;; a note is appended at the bottom.

;;; Code:

(require 'ansi-color)
(require 'octocat-core)

;; Defined in octocat.el which loads this file; avoid circular require.
(declare-function octocat-browse "octocat" ())


;;;; Buffer-local state

(defvar-local octocat--job-repo nil
  "The \"owner/repo\" this job buffer belongs to.")

(defvar-local octocat--job-run-id nil
  "The numeric run ID this job belongs to.")

(defvar-local octocat--job-id nil
  "The numeric database ID of the job this buffer is displaying.")

(defvar-local octocat--job-name nil
  "The display name of the job this buffer is displaying.")


;;;; Data fetching

(defun octocat--fetch-job (repo job-id callback)
  "Fetch job detail and log for JOB-ID in REPO asynchronously.
CALLBACK receives a cons (JOB . LOG-SECTIONS) where JOB is a hash-table
from the GitHub REST API and LOG-SECTIONS is either an alist of
\(STEP-NAME . LINES) pairs in source order, or a cons \\=(error . MSG)
when log output is unavailable (e.g. the job is still running).
A job-metadata failure is fatal and CALLBACK receives \\=(error . MSG)."
  (let ((job-result 'pending)
        (log-result 'pending))
    (cl-labels
        ((maybe-done ()
           (unless (or (eq job-result 'pending)
                       (eq log-result 'pending))
             ;; Metadata failure aborts the whole view; log failure is
             ;; passed through as-is and rendered gracefully.
             (if (eq (car-safe job-result) 'error)
                 (funcall callback job-result)
               (funcall callback (cons job-result log-result))))))
      (octocat--run-gh
       "job-detail"
       (list "api" (format "repos/%s/actions/jobs/%s" repo
                           (number-to-string job-id)))
       (lambda (output) (json-parse-string (string-trim output)))
       (lambda (result) (setq job-result result) (maybe-done)))
      (octocat--run-gh
       "job-log"
       (list "run" "view"
             "--log"
             "--job" (number-to-string job-id)
             "--repo" repo)
       #'octocat--job-parse-log
       (lambda (result) (setq log-result result) (maybe-done))))))


;;;; Log parsing

(defun octocat--job-parse-log (raw)
  "Parse RAW log text from `gh run view --log' into an alist.
Returns an alist of (STEP-NAME . (LINE ...)) in source order.
Each line has its leading timestamp formatted as HH:MM:SS local time.
ANSI codes are removed.  Lines that don't match the expected
tab-delimited format are ignored."
  (let ((sections '())
        (current-step nil)
        (current-lines '()))
    (dolist (line (split-string (string-trim raw) "\n"))
      ;; Format: JOB_NAME<TAB>STEP_NAME<TAB>TIMESTAMP MESSAGE
      ;; Some lines begin with a UTF-8 BOM (#xFEFF); discard it.
      (let* ((clean (if (and (> (length line) 0)
                             (= (aref line 0) #xFEFF))
                        (substring line 1)
                      line))
             (parts (split-string clean "\t" nil)))
        (when (>= (length parts) 3)
          (let* ((step    (string-trim (nth 1 parts)))
                 (rest    (nth 2 parts))
                 ;; Third field starts with an ISO-8601 timestamp; format it.
                 (msg     (if (string-match "^\\([0-9T:.Z]+\\) \\(.*\\)$" rest)
                              (let* ((ts      (match-string 1 rest))
                                     (content (match-string 2 rest))
                                     (fmt     (condition-case nil
                                                  (format-time-string
                                                   "%H:%M:%S" (date-to-time ts))
                                                (error
                                                 (if (>= (length ts) 19)
                                                     (substring ts 11 19)
                                                   ts)))))
                                (concat fmt " " content))
                            rest))
                 (content (ansi-color-filter-apply msg)))
            (unless (equal step current-step)
              (when current-step
                (push (cons current-step (nreverse current-lines)) sections))
              (setq current-step  step
                    current-lines '()))
            (push content current-lines)))))
    (when current-step
      (push (cons current-step (nreverse current-lines)) sections))
    (nreverse sections)))


;;;; Rendering helpers

(defun octocat--job-step-icon (status conclusion)
  "Return a propertized checkbox icon for a step with STATUS and CONCLUSION.
Uses bracket-checkbox glyphs to distinguish steps from job-level icons."
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

(defun octocat--job-status-face (status)
  "Return the face for a job STATUS string."
  (cond
   ((equal status "success")
    'octocat-ci-success)
   ((member status '("failure" "timed_out" "startup_failure" "cancelled"))
    'octocat-ci-failure)
   (t 'octocat-ci-pending)))


;;;; Rendering

(defun octocat--render-job-loading (job-name)
  "Render a loading skeleton for the job named JOB-NAME."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-job-root)
      (magit-insert-heading
        (concat (propertize (or octocat--job-repo "") 'face 'octocat-repo)
                "  "
                (propertize "job" 'face 'octocat-dimmed)
                "  "
                (propertize (or job-name "") 'face 'octocat-run-job-name)))
      (magit-insert-section (job-info)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (job-steps)
        (magit-insert-heading (propertize "Steps" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (job-log)
        (magit-insert-heading (propertize "Log" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-job (job log-sections)
  "Erase the current buffer and render job detail.
JOB is a hash-table from the GitHub REST API (snake_case keys).
LOG-SECTIONS is either an alist of (STEP-NAME . LINES) or a cons
\\=(error . MSG) when log fetching failed."
  (let* ((job-name   (or (gethash "name" job) ""))
         (status     (downcase (or (gethash "status" job) "")))
         (conc-raw   (gethash "conclusion" job))
         (conclusion (when (and conc-raw (not (eq conc-raw :null)))
                       (downcase conc-raw)))
         (started    (let ((v (gethash "started_at" job)))
                       (when (and v (not (eq v :null)) (not (string-empty-p v))) v)))
         (completed  (let ((v (gethash "completed_at" job)))
                       (when (and v (not (eq v :null)) (not (string-empty-p v))) v)))
         (duration   (octocat--run-duration started completed))
         (runner     (let ((v (gethash "runner_name" job)))
                       (when (and v (not (eq v :null)) (not (string-empty-p v))) v)))
         (labels     (let ((v (gethash "labels" job)))
                       (when (and v (not (eq v :null)) (> (length v) 0))
                         (mapconcat #'identity (cl-coerce v 'list) ", "))))
         (steps      (let ((v (gethash "steps" job)))
                       (if (or (null v) (eq v :null)) [] v)))
         (display-status (or conclusion status))
         (icon       (octocat--run-icon status conclusion))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-job-root)
      ;; ── Header ──────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--job-repo "") 'face 'octocat-repo)
                "  "
                (propertize "job" 'face 'octocat-dimmed)
                "  "
                (propertize job-name 'face 'octocat-run-job-name)
                "  "
                icon
                (unless (string-empty-p display-status)
                  (concat "  "
                          (propertize display-status
                                      'face (octocat--job-status-face
                                             display-status))))))
      ;; ── Info ────────────────────────────────────────────────────────────
      (magit-insert-section (job-info)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (unless (string-empty-p display-status)
          (insert (format "  Status     %s\n"
                          (propertize display-status
                                      'face (octocat--job-status-face
                                             display-status)))))
        (when duration
          (insert (format "  Duration   %s\n" duration)))
        (when started
          (insert (format "  Started    %s\n" (octocat--format-ts started))))
        (when completed
          (insert (format "  Completed  %s\n" (octocat--format-ts completed))))
        (when runner
          (insert (format "  Runner     %s\n"
                          (propertize runner 'face 'octocat-dimmed))))
        (when labels
          (insert (format "  Labels     %s\n"
                          (propertize labels 'face 'octocat-branch)))))
      (insert "\n")
      ;; ── Per-step sections (icon + name + status + duration + log lines) ──
      (if (zerop (length steps))
          (insert (propertize "  (no steps)\n" 'face 'octocat-dimmed))
        (cl-loop for step across steps do
                 (let* ((sname    (or (gethash "name" step) ""))
                        (sstat    (downcase (or (gethash "status" step) "")))
                        (sconc-r  (gethash "conclusion" step))
                        (sconc    (when (and sconc-r (not (eq sconc-r :null)))
                                    (downcase sconc-r)))
                        (sstart   (let ((v (gethash "started_at" step)))
                                    (when (and v (not (eq v :null))) v)))
                        (scomp    (let ((v (gethash "completed_at" step)))
                                    (when (and v (not (eq v :null))) v)))
                        (sdur     (octocat--run-duration sstart scomp))
                        (sicon    (octocat--job-step-icon sstat sconc))
                        (sstatus  (or sconc sstat))
                        (lines    (unless (eq (car-safe log-sections) 'error)
                                    (cdr (assoc sname log-sections)))))
                   (magit-section-hide
                    (magit-insert-section (job-step sname)
                      (magit-insert-heading
                        (concat sicon
                                " "
                                (propertize
                                 (truncate-string-to-width
                                  (format "%-40s" sname) 40 nil ?\s "…")
                                 'face 'octocat-run-step-name)
                                (unless (string-empty-p sstatus)
                                  (concat "  "
                                          (propertize sstatus
                                                      'face (octocat--job-status-face
                                                             sstatus))))
                                (when sdur
                                  (propertize (format "  %s" sdur)
                                              'face 'octocat-dimmed))))
                      (dolist (line lines)
                        (insert "  " line "\n")))))))
      (when (eq (car-safe log-sections) 'error)
        (insert (propertize (format "  (log unavailable: %s)\n" (cdr log-sections))
                            'face 'octocat-dimmed))))
    (goto-char (point-min))))


;;;; Major mode

(defvar octocat-job-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "o")       #'octocat-browse)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-job-refresh)
    map)
  "Keymap for `octocat-job-mode'.")

(define-derived-mode octocat-job-mode magit-section-mode "Octocat-Job"
  "Major mode for viewing a GitHub Actions job.

\\{octocat-job-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-job-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-job-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current job buffer asynchronously."
  (interactive)
  (unless (and octocat--job-repo octocat--job-id)
    (user-error "Octocat: Buffer is not associated with a job"))
  (let ((buf      (current-buffer))
        (repo     octocat--job-repo)
        (job-id   octocat--job-id)
        (job-name octocat--job-name))
    (when (zerop (buffer-size))
      (octocat--render-job-loading job-name))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-job
     repo job-id
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq mode-line-process nil)
           (if (eq (car-safe result) 'error)
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (propertize (format "  Error: %s\n" (cdr result))
                                     'face 'error)))
             (octocat--render-job (car result) (cdr result)))))))))

(provide 'octocat-job)
;;; octocat-job.el ends here
