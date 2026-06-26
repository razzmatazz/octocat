;;; octocat-job.el --- Job detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6

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

(defun octocat--fetch-job (repo run-id job-id callback)
  "Fetch job detail, log, annotations, and artifacts for JOB-ID in REPO.
RUN-ID is the numeric workflow run ID (used for the artifacts request).
Calls CALLBACK asynchronously with a list (JOB LOG-SECTIONS ANNOTATIONS
ARTIFACTS) where:
- JOB is a hash-table from the GitHub REST API.
- LOG-SECTIONS is either an alist of (STEP-NAME . LINES) pairs in source
  order, or a cons \\=(error . MSG) when log output is unavailable.
- ANNOTATIONS is a vector of annotation hash-tables from the Checks API
  (GET /check-runs/JOB-ID/annotations), or \\=[] when unavailable.
- ARTIFACTS is a vector of artifact hash-tables from the Actions API
  (GET /actions/runs/RUN-ID/artifacts), or \\=[] when unavailable.
A job-metadata failure is fatal and CALLBACK receives \\=(error . MSG)."
  (let ((job-result 'pending)
        (log-result 'pending)
        (ann-result 'pending)
        (art-result 'pending))
    (cl-labels
        ((maybe-done ()
           (unless (or (eq job-result 'pending)
                       (eq log-result 'pending)
                       (eq ann-result 'pending)
                       (eq art-result 'pending))
             ;; Metadata failure aborts the whole view; log/annotation/
             ;; artifact failures are passed through and rendered gracefully.
             (if (eq (car-safe job-result) 'error)
                 (funcall callback job-result)
               (funcall callback
                        (list job-result log-result ann-result art-result))))))
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
       (lambda (result) (setq log-result result) (maybe-done)))
      (octocat--run-gh
       "job-annotations"
       (list "api"
             (format "repos/%s/check-runs/%s/annotations?per_page=100"
                     repo (number-to-string job-id)))
       (lambda (output)
         (condition-case nil
             (let ((parsed (json-parse-string (string-trim output))))
               (if (vectorp parsed) parsed []))
           (error [])))
       (lambda (result)
         (setq ann-result (if (eq (car-safe result) 'error) [] result))
         (maybe-done)))
      (if (not run-id)
          (progn (setq art-result []) (maybe-done))
        (octocat--run-gh
         "job-artifacts"
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
           (setq art-result (if (eq (car-safe result) 'error) [] result))
           (maybe-done)))))))


;;;; Log parsing

(defun octocat--job-parse-log-line (rest)
  "Parse one raw log REST field (TIMESTAMP MESSAGE) into a tagged entry.
Returns a plist:
  (:ts FORMATTED-TIME :kind KIND :text CONTENT)
where KIND is one of `normal', `group-start', `group-end', or `command',
and CONTENT is the ANSI-stripped message text.
For `group-start' lines CONTENT is the group name.
For `group-end' lines CONTENT is nil."
  (let* ((ts-raw  nil)
         (content nil))
    ;; Third field starts with an ISO-8601 timestamp.
    (if (string-match "^\\([0-9T:.Z-]+\\) \\(.*\\)$" rest)
        (let* ((ts  (match-string 1 rest))
               (msg (match-string 2 rest)))
          (setq ts-raw  ts
                content (ansi-color-filter-apply msg)))
      (setq content (ansi-color-filter-apply rest)))
    (let* ((fmt (when ts-raw
                  (condition-case nil
                      (format-time-string "%H:%M:%S" (date-to-time ts-raw))
                    (error (if (>= (length ts-raw) 19)
                               (substring ts-raw 11 19)
                             ts-raw)))))
           (kind (cond
                  ((string-match "^##\\[group\\]\\(.*\\)$" (or content ""))
                   'group-start)
                  ((string-match "^##\\[endgroup\\]" (or content ""))
                   'group-end)
                  ((string-match "^\\[command\\]" (or content ""))
                   'command)
                  (t 'normal)))
           (text (pcase kind
                   ('group-start (match-string 1 content))
                   ('group-end   nil)
                   (_            content))))
      (list :ts fmt :kind kind :text text))))

(defun octocat--job-parse-log (raw)
  "Parse RAW log text from `gh run view --log' into an alist.
Returns an alist of (STEP-NAME . ENTRIES) in source order.
Each entry is a plist (:ts TS :kind KIND :text TEXT) where KIND is one of
`normal', `group-start', `group-end', or `command'.
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
          (let* ((step  (string-trim (nth 1 parts)))
                 (entry (octocat--job-parse-log-line (nth 2 parts))))
            (unless (equal step current-step)
              (when current-step
                (push (cons current-step (nreverse current-lines)) sections))
              (setq current-step  step
                    current-lines '()))
            (push entry current-lines)))))
    (when current-step
      (push (cons current-step (nreverse current-lines)) sections))
    (nreverse sections)))


;;;; Rendering helpers

(defun octocat--render-log-line (entry indent)
  "Insert one log ENTRY plist at INDENT into the current buffer.
ENTRY has keys :ts :kind :text.  Returns non-nil for normal/command lines
and nil for group-start/group-end lines (the caller handles those)."
  (let ((ts   (plist-get entry :ts))
        (kind (plist-get entry :kind))
        (text (plist-get entry :text)))
    (pcase kind
      ('normal
       (insert indent
               (if ts (propertize (concat ts " ") 'face 'octocat-dimmed) "")
               (or text "")
               "\n"))
      ('command
       (insert indent
               (if ts (propertize (concat ts " ") 'face 'octocat-dimmed) "")
               (propertize (or text "") 'face 'octocat-dimmed)
               "\n")))))

(defun octocat--render-log-lines (entries indent)
  "Insert log ENTRIES at INDENT, collapsing ##[group] blocks as sections."
  (let ((group-entries nil)
        (group-name    nil))
    (dolist (entry entries)
      (let ((kind (plist-get entry :kind)))
        (cond
         ;; Start a new group — collect subsequent lines.
         ((eq kind 'group-start)
          ;; If we were already in a group (malformed log), flush it first.
          (when group-name
            (octocat--render-log-group group-name (nreverse group-entries) indent))
          (setq group-name    (plist-get entry :text)
                group-entries nil))
         ;; End of group — emit the collected section.
         ((eq kind 'group-end)
          (when group-name
            (octocat--render-log-group group-name (nreverse group-entries) indent))
          (setq group-name nil group-entries nil))
         ;; Any other line: buffer it if inside a group, otherwise emit directly.
         (t
          (if group-name
              (push entry group-entries)
            (octocat--render-log-line entry indent))))))
    ;; Flush an unclosed group at end of step.
    (when group-name
      (octocat--render-log-group group-name (nreverse group-entries) indent))))

(defun octocat--render-log-group (name entries indent)
  "Insert a collapsible magit section for a log group named NAME.
ENTRIES are the lines collected inside the group; INDENT is the outer prefix."
  (magit-section-hide
   (magit-insert-section (job-log-group name)
     (magit-insert-heading
       (concat indent
               (propertize (concat "▸ " (or name "")) 'face 'octocat-dimmed)))
     (dolist (entry entries)
       (octocat--render-log-line entry (concat indent "  "))))))

(defun octocat--job-step-icon (status conclusion)
  "Return a propertized checkbox icon for a step with STATUS and CONCLUSION.
Uses bracket-checkbox glyphs to distinguish steps from job-level icons."
  (let ((s (or (and (equal status "in_progress") status)
               (octocat--nonempty conclusion)
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

(defun octocat--annotation-face (level)
  "Return the face for an annotation LEVEL string."
  (cond
   ((equal level "failure") 'octocat-annotation-error)
   ((equal level "warning") 'octocat-annotation-warning)
   (t                       'octocat-annotation-notice)))

(defun octocat--annotation-icon (level)
  "Return a propertized icon for an annotation LEVEL string."
  (cond
   ((equal level "failure") (propertize "✗" 'face 'octocat-annotation-error))
   ((equal level "warning") (propertize "⚠" 'face 'octocat-annotation-warning))
   (t                       (propertize "ℹ" 'face 'octocat-annotation-notice))))

(defun octocat--format-artifact-size (bytes)
  "Format BYTES as a human-readable size string."
  (cond
   ((null bytes)         "")
   ((< bytes 1024)       (format "%d B" bytes))
   ((< bytes 1048576)    (format "%.1f KB" (/ (float bytes) 1024)))
   (t                    (format "%.1f MB" (/ (float bytes) 1048576)))))

(defun octocat--render-artifacts (artifacts)
  "Insert an Artifacts section for the ARTIFACTS vector into the current buffer.
Each entry is a hash-table from the Actions API
\(GET /actions/runs/RUN/artifacts).  Does nothing when ARTIFACTS is nil or empty."
  (let ((arts (or artifacts [])))
    (unless (zerop (length arts))
      (magit-insert-section (job-artifacts)
        (magit-insert-heading
          (propertize (format "Artifacts (%d)" (length arts))
                      'face 'octocat-section-heading))
        (cl-loop for art across arts do
                 (let* ((name  (or (gethash "name" art) ""))
                        (size  (gethash "size_in_bytes" art))
                        (label (concat "  \U0001f4e6 "
                                       (propertize name 'face 'octocat-run-job-name)
                                       "  "
                                       (propertize
                                        (octocat--format-artifact-size size)
                                        'face 'octocat-dimmed))))
                   (insert (propertize (concat label "\n")
                                       'octocat-artifact art
                                       'mouse-face 'magit-section-highlight
                                       'help-echo "RET: download artifact"))))))))



(defun octocat--render-annotations (annotations &optional job-name)
  "Insert an Annotations section for ANNOTATIONS vector into the current buffer.
Each entry is a hash-table from the Checks API.  When JOB-NAME is non-nil
it is shown as a prefix on each line (used in the run buffer view).
Does nothing when ANNOTATIONS is empty or nil."
  (let ((anns (or annotations [])))
    (unless (zerop (length anns))
      (magit-insert-section (job-annotations)
        (magit-insert-heading
          (propertize (format "Annotations (%d)" (length anns))
                      'face 'octocat-section-heading))
        (cl-loop for ann across anns do
                 (let* ((level (downcase
                                (or (gethash "annotation_level" ann) "notice")))
                        (msg   (or (gethash "message" ann) ""))
                        (icon  (octocat--annotation-icon level))
                        (face  (octocat--annotation-face level))
                        ;; Collapse multi-line messages to a single line.
                        (text  (replace-regexp-in-string "\n" " " msg)))
                                    (insert (concat "  "
                                                   icon
                                                   " "
                                                   (when job-name
                                                     (concat (propertize job-name
                                                                         'face 'octocat-run-job-name)
                                                             "  "))
                                                   (propertize text 'face face)
                                                   "\n")))))
      (insert "\n"))))


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
        (let ((hint (list 'mouse-face 'magit-section-highlight
                          'help-echo  "RET: open repo view")))
          (magit-insert-section (repo-nav octocat--job-repo)
            (magit-insert-heading
              (concat (apply #'propertize "  Repo      " hint)
                      (apply #'propertize (or octocat--job-repo "")
                             'face 'octocat-repo hint)
                      (apply #'propertize "\n" hint)))))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (job-steps)
        (magit-insert-heading (propertize "Steps" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-job (job log-sections &optional annotations artifacts)
  "Erase the current buffer and render job detail.
JOB is a hash-table from the GitHub REST API (snake_case keys).
LOG-SECTIONS is either an alist of (STEP-NAME . LINES) or a cons
\\=(error . MSG) when log fetching failed.
ANNOTATIONS is a vector of annotation hash-tables from the Checks API,
or nil/[] when unavailable.
ARTIFACTS is a vector of artifact hash-tables from the Actions API,
or nil/[] when unavailable."
  (let* ((job-name   (or (gethash "name" job) ""))
         (status     (downcase (or (gethash "status" job) "")))
         (conc-raw   (gethash "conclusion" job))
         (conclusion (and (octocat--nonempty conc-raw) (downcase conc-raw)))
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
        (let ((hint (list 'mouse-face 'magit-section-highlight
                          'help-echo  "RET: open repo view")))
          (magit-insert-section (repo-nav octocat--job-repo)
            (magit-insert-heading
              (concat (apply #'propertize "  Repo      " hint)
                      (apply #'propertize (or octocat--job-repo "")
                             'face 'octocat-repo hint)
                      (apply #'propertize "\n" hint)))))
        (unless (string-empty-p display-status)
          (insert (format "  Status     %s\n"
                          (propertize display-status
                                      'face (octocat--job-status-face
                                             display-status)))))
        (when duration
          (insert (format "  Duration   %s\n" duration)))
        (when started
          (insert (format "  Started    %s\n" (octocat--format-ts-full started))))
        (when completed
          (insert (format "  Completed  %s\n" (octocat--format-ts-full completed))))
        (when runner
          (insert (format "  Runner     %s\n"
                          (propertize runner 'face 'octocat-dimmed))))
        (when labels
          (insert (format "  Labels     %s\n"
                          (propertize labels 'face 'octocat-branch)))))
      (insert "\n")
      ;; ── Steps ────────────────────────────────────────────────────────────
      (magit-insert-section (job-steps)
        (magit-insert-heading (propertize "Steps" 'face 'octocat-section-heading))
        (if (zerop (length steps))
            (insert (propertize "  (no steps)\n" 'face 'octocat-dimmed))
          (cl-loop for step across steps do
                   (let* ((sname    (or (gethash "name" step) ""))
                          (sstat    (downcase (or (gethash "status" step) "")))
                          (sconc-r  (gethash "conclusion" step))
                          (sconc    (and (octocat--nonempty sconc-r) (downcase sconc-r)))
                          (sstart   (octocat--nonempty (gethash "started_at" step)))
                          (scomp    (octocat--nonempty (gethash "completed_at" step)))
                          (sdur     (and sconc (octocat--run-duration sstart scomp)))
                          (sicon    (octocat--job-step-icon sstat sconc))
                          (sstatus  (or sconc sstat))
                          (lines    (unless (eq (car-safe log-sections) 'error)
                                      (cdr (assoc sname log-sections)))))
                     (magit-section-hide
                      (magit-insert-section (job-step sname)
                        (magit-insert-heading
                          (concat "  "
                                  sicon
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
                        (octocat--render-log-lines lines "    ")))))
          (when (eq (car-safe log-sections) 'error)
            (insert (propertize (format "  (log unavailable: %s)\n"
                                        (cdr log-sections))
                                'face 'octocat-dimmed)))))
      (insert "\n")
      ;; ── Artifacts (from Actions API) ────────────────────────────────────
      (octocat--render-artifacts artifacts)
      (when (and artifacts (not (zerop (length artifacts))))
        (insert "\n"))
      ;; ── Annotations (from Checks API) — placed last, can be lengthy ─────
      (octocat--render-annotations annotations))))


;;;; Download

(defun octocat--do-download-artifact (repo run-id art)
  "Download artifact ART (a hash-table) from RUN-ID in REPO.
Prompts for a destination directory and runs `gh run download' asynchronously."
  (let* ((name (or (gethash "name" art) ""))
         (dir  (read-directory-name
                (format "Download \"%s\" to: " name)
                default-directory)))
    (message "Octocat: Downloading \"%s\"…" name)
    (octocat--run-gh
     "artifact-download"
     (list "run" "download"
           (number-to-string run-id)
           "--repo" repo
           "--name" name
           "--dir"  (expand-file-name dir))
     #'identity
     (lambda (result)
       (if (eq (car-safe result) 'error)
           (message "Octocat: Download failed: %s" (cdr result))
         (message "Octocat: Downloaded \"%s\" to %s" name dir))))))

(defun octocat-job-download-artifact ()
  "Download the artifact at point to a directory chosen by the user."
  (interactive)
  (let ((art  (get-text-property (point) 'octocat-artifact))
        ;; Work in both job buffers (octocat--job-*) and run buffers
        ;; (octocat--run-*) — whichever locals are bound wins.
        (repo   (or (and (boundp 'octocat--job-repo)    octocat--job-repo)
                    (and (boundp 'octocat--run-repo)    octocat--run-repo)))
        (run-id (or (and (boundp 'octocat--job-run-id)  octocat--job-run-id)
                    (and (boundp 'octocat--run-id)       octocat--run-id))))
    (unless art
      (user-error "Octocat: No artifact at point"))
    (unless (and repo run-id)
      (user-error "Octocat: Buffer is not associated with a run"))
    (octocat--do-download-artifact repo run-id art)))


;;;; Major mode

(defvar octocat-job-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-r") #'octocat-switch-repo)
    (define-key map (kbd "RET")     #'octocat-job-download-artifact)
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-job-refresh)
    map)
  "Keymap for `octocat-job-mode'.")

(define-derived-mode octocat-job-mode magit-section-mode "Octocat-Job"
  "Major mode for viewing a GitHub Actions job.

\\{octocat-job-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-job-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-job-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current job buffer asynchronously."
  (interactive)
  (unless (and octocat--job-repo octocat--job-id)
    (user-error "Octocat: Buffer is not associated with a job"))
  (let* ((buf         (current-buffer))
         (repo        octocat--job-repo)
         (run-id      octocat--job-run-id)
         (job-id      octocat--job-id)
         (job-name    octocat--job-name)
         (saved-point (octocat--save-point)))
    (when (zerop (buffer-size))
      (octocat--render-job-loading job-name))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-job
     repo run-id job-id
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq mode-line-process nil)
           (if (eq (car-safe result) 'error)
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (propertize (format "  Error: %s\n" (cdr result))
                                     'face 'error)))
             (octocat--render-job (car result) (cadr result)
                                  (caddr result) (cadddr result))
             (octocat--restore-point saved-point))))))))

(provide 'octocat-job)
;;; octocat-job.el ends here
