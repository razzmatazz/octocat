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

;; A GitHub Actions job: `octocat-job-mode', a vui.el page opened from
;; its run (octocat-run.el).  It shows the job's metadata, its steps,
;; folded, with their log output, then the run's artifacts and the job's
;; annotations.  Also the Artifacts and Annotations sections the run page
;; shares.
;;
;; Job metadata is fetched from the REST API:
;;   gh api repos/OWNER/REPO/actions/jobs/JOB-ID
;;
;; Log output is fetched with:
;;   gh run view --log --job JOB-ID --repo OWNER/REPO
;;
;; The requests run in parallel.  A log-fetch failure is non-fatal: the
;; steps are shown without log lines, with a note below them.
;;
;; Depends on octocat-core.el.  Must not depend on octocat.el or
;; octocat-run.el to avoid circular requires.

;;; Code:

(require 'ansi-color)
(require 'octocat-core)
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))
(declare-function octocat-run-open "octocat-run" (repo run-id))
(declare-function octocat-search-repo "octocat-search" ())


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
Calls CALLBACK asynchronously with a hash-table, which the disk cache
can store as JSON, of:
- \"job\", a hash-table from the GitHub REST API.
- \"log\", the raw `gh run view --log' text (see `octocat--job-parse-log'),
  or \"log_error\", the message when the log is unavailable.
- \"annotations\", a vector of annotation hash-tables from the Checks API
  (GET /check-runs/JOB-ID/annotations), \\=[] when unavailable.
- \"artifacts\", a vector of artifact hash-tables from the Actions API
  (GET /actions/runs/RUN-ID/artifacts), \\=[] when unavailable.
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
               (let ((h (make-hash-table :test #'equal)))
                 (puthash "job" job-result h)
                 (if (eq (car-safe log-result) 'error)
                     (puthash "log_error" (cdr log-result) h)
                   (puthash "log" log-result h))
                 (puthash "annotations" ann-result h)
                 (puthash "artifacts" art-result h)
                 (funcall callback h))))))
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
       #'identity
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

(defun octocat-job--strip-colors (text)
  "Return TEXT without its ANSI color codes.
The log carries some as escape characters and some spelled out in caret
notation, \"^[[36;1m\"."
  (replace-regexp-in-string "\\^\\[\\[[0-9;]*m" "" (ansi-color-filter-apply text)))

(defun octocat--job-parse-log-line (rest)
  "Parse one raw log REST field (TIMESTAMP MESSAGE) into a tagged entry.
Returns a plist:
  (:ts FORMATTED-TIME :kind KIND :text CONTENT)
where KIND is one of `normal', `group-start', `group-end', or `command',
and CONTENT is the ANSI-stripped message text.
For `group-start' lines CONTENT is the group name.
For `group-end' lines CONTENT is nil."
  (let* ((rest    (if (string-prefix-p "\uFEFF" rest) ; a step's first line has one
                      (substring rest 1)
                    rest))
         (ts-raw  nil)
         (content nil))
    ;; Third field starts with an ISO-8601 timestamp.
    (if (string-match "^\\([0-9T:.Z-]+\\) \\(.*\\)$" rest)
        (let* ((ts  (match-string 1 rest))
               (msg (match-string 2 rest)))
          (setq ts-raw  ts
                content (octocat-job--strip-colors msg)))
      (setq content (octocat-job--strip-colors rest)))
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

;;;; Log

(defun octocat-job--log-line (entry)
  "Return log ENTRY, a plist from `octocat--job-parse-log-line', as a line.
It is not indented, so the log copies out as it is.  Commands are dimmed."
  (let ((ts   (plist-get entry :ts))
        (text (or (plist-get entry :text) "")))
    (concat (if ts (propertize (concat ts " ") 'face 'octocat-dimmed) "")
            (if (eq (plist-get entry :kind) 'command)
                (propertize text 'face 'octocat-dimmed)
              text))))

(defun octocat-job--log-blocks (entries)
  "Return log ENTRIES as a list of blocks.
A block is (text STRING), a run of lines, or (group NAME STRING), the
lines of a ##[group].  An unclosed group ends at the next group or the
end."
  (let (blocks run group-name group)
    (cl-flet ((flush-run ()
                (when run
                  (push (list 'text (string-join (nreverse run) "\n")) blocks)
                  (setq run nil)))
              (flush-group ()
                (when group-name
                  (push (list 'group group-name (string-join (nreverse group) "\n")) blocks)
                  (setq group-name nil group nil))))
      (dolist (entry entries)
        (pcase (plist-get entry :kind)
          ('group-start (flush-run)
                        (flush-group)
                        (setq group-name (or (plist-get entry :text) "")))
          ('group-end   (flush-group))
          (_ (if group-name
                 (push (octocat-job--log-line entry) group)
               (push (octocat-job--log-line entry) run)))))
      (flush-run)
      (flush-group))
    (nreverse blocks)))

(defun octocat-job--log-group (name text index bulk)
  "Return a ##[group] of a step's log: NAME, folded over its TEXT.
INDEX, its position in the step, keys it.  BULK is as for `octocat-vui-fold'."
  (vui-component
   'octocat-vui-fold
   :key index
   :bulk bulk
   :header (lambda (open toggle)
             (octocat-vui-fold-header "      " open toggle
                                      (propertize name 'face 'octocat-dimmed)
                                      '("RET: unfold" . "RET: fold")))
   :deps text
   :prepare (lambda ()
              (octocat-vui-text-body
               (if (string-empty-p text)
                   (propertize "(empty)" 'face 'octocat-dimmed)
                 text)))))

(defun octocat-job--step-body (lines bulk)
  "Return the log LINES of a step as the (TOTAL . RENDER) body of a fold.
A group counts as one line, its header; it unfolds on its own, or with
the others by BULK (see `octocat-vui-fold')."
  (let* ((blocks (mapcar (lambda (block)
                           (pcase block
                             (`(text ,text) (list 'text text (octocat-vui-line-ends text)))
                             (_ block)))
                         (octocat-job--log-blocks lines)))
         (total  (apply #'+ (mapcar (lambda (b) (if (eq (car b) 'text) (1+ (length (nth 2 b))) 1))
                                    blocks))))
    (cons total
          (lambda (n)
            (cl-loop for block in blocks
                     for i from 0
                     while (> n 0)
                     collect (pcase block
                               (`(text ,text ,ends)
                                (prog1 (vui-text (octocat-vui-take-lines text ends n))
                                  (cl-decf n (1+ (length ends)))))
                               (`(group ,name ,text)
                                (cl-decf n)
                                (octocat-job--log-group name text i bulk))))))))


;;;; Steps

(defun octocat-job--step-title (step)
  "Return the heading of STEP, a REST hash-table: icon, name, status, duration."
  (let* ((status     (downcase (or (gethash "status" step) "")))
         (conclusion (let ((c (octocat--nonempty (gethash "conclusion" step))))
                       (and c (downcase c))))
         (duration   (and conclusion
                          (octocat--run-duration
                           (octocat--nonempty (gethash "started_at" step))
                           (octocat--nonempty (gethash "completed_at" step)))))
         (shown      (or conclusion status)))
    (concat (octocat--job-step-icon status conclusion)
            " "
            (propertize (truncate-string-to-width (or (gethash "name" step) "") 40 nil ?\s "…")
                        'face 'octocat-run-step-name)
            (unless (string-empty-p shown)
              (concat "  " (propertize shown 'face (octocat--job-status-face shown))))
            (when duration
              (propertize (concat "  " duration) 'face 'octocat-dimmed)))))

(defun octocat-job--step (step lines bulk)
  "Return STEP of a job, a REST hash-table, folded over its log LINES.
The log is laid out only once the step is unfolded: a log can be long.
BULK is as for `octocat-vui-fold'."
  (let ((title (octocat-job--step-title step)))
    (if (null lines)
        (vui-text (concat "    " title))
      ;; `octocat-vui-fold', not `vui-collapsible': its toggle button would
      ;; draw the whole title in the `link' face, losing the icon and
      ;; status faces.
      (vui-component
       'octocat-vui-fold
       :key (gethash "number" step)
       :bulk bulk
       :header (lambda (open toggle)
                 (octocat-vui-fold-header "  " open toggle title
                                          '("RET: show log" . "RET: hide log")))
       ;; BULK too, for the log groups it unfolds.
       :deps (cons lines bulk)
       :prepare (lambda () (octocat-job--step-body lines bulk))))))

(defun octocat-job--steps (job log bulk on-bulk)
  "Return the vnodes of the section listing each step of JOB.
LOG is the parsed log, as from `octocat--job-parse-log', or \\=(error . MSG).
The heading carries an \"Expand all\" button for the steps and their log
groups: BULK and ON-BULK are as for `octocat-vui-expand-all-button'."
  (let ((steps (let ((v (gethash "steps" job)))
                 (if (vectorp v) (append v nil) nil)))
        (failed (eq (car-safe log) 'error)))
    (append
     (list (if (and steps (not failed))
               (vui-hstack :spacing 2
                           (vui-text (propertize (format "Steps (%d)" (length steps))
                                                 'face 'octocat-section-heading))
                           (octocat-vui-expand-all-button bulk on-bulk))
             (vui-text (propertize (format "Steps (%d)" (length steps))
                                   'face 'octocat-section-heading))))
     (if (null steps)
         (list (vui-text "  (no steps)" :face 'octocat-dimmed))
       (mapcar (lambda (step)
                 (octocat-job--step step
                                    (unless failed
                                      (cdr (assoc (or (gethash "name" step) "") log)))
                                    bulk))
               steps))
     (when failed
       (list (vui-text (format "  (log unavailable: %s)" (cdr log)) :face 'octocat-dimmed))))))


;;;; Artifacts and annotations
;;
;; Shared with the run page.

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

(defun octocat-job-artifacts (repo run-id artifacts)
  "Return the vnodes of the Artifacts section, or nil when there are none.
ARTIFACTS is a vector from the Actions API of run RUN-ID of REPO; RET on
one downloads it."
  (unless (zerop (length artifacts))
    (cons (vui-text (propertize (format "Artifacts (%d)" (length artifacts))
                                'face 'octocat-section-heading))
          (cl-loop for art across artifacts
                   collect (octocat-vui-row
                            (concat "  \U0001f4e6 "
                                    (propertize (or (gethash "name" art) "")
                                                'face 'octocat-run-job-name)
                                    "  "
                                    (propertize (octocat--format-artifact-size
                                                 (gethash "size_in_bytes" art))
                                                'face 'octocat-dimmed))
                            (lambda () (octocat--do-download-artifact repo run-id art))
                            "RET: download artifact")))))

(defun octocat-job-annotations (entries)
  "Return the vnodes of the Annotations section, or nil when there are none.
ENTRIES is a list of (JOB-NAME . ANNOTATION), the annotation a Checks API
hash-table; a nil JOB-NAME is not shown."
  (when entries
    (cons (vui-text (propertize (format "Annotations (%d)" (length entries))
                                'face 'octocat-section-heading))
          (mapcar (lambda (entry)
                    (let ((level (downcase (or (gethash "annotation_level" (cdr entry))
                                               "notice"))))
                      (vui-text
                       (concat "  " (octocat--annotation-icon level) "  "
                               (when (car entry)
                                 (concat (propertize (car entry) 'face 'octocat-run-job-name)
                                         "  "))
                               (propertize (replace-regexp-in-string
                                            "\n" " " (or (gethash "message" (cdr entry)) ""))
                                           'face (octocat--annotation-face level))))))
                  entries))))


;;;; Page

(defun octocat-job--header (job)
  "Return the vnodes under the top row: name, status and details of JOB."
  (let* ((status     (downcase (or (gethash "status" job) "")))
         (conclusion (let ((c (octocat--nonempty (gethash "conclusion" job))))
                       (and c (downcase c))))
         (shown      (or conclusion status))
         (started    (octocat--nonempty (gethash "started_at" job)))
         (completed  (octocat--nonempty (gethash "completed_at" job)))
         (labels     (let ((v (gethash "labels" job)))
                       (and (vectorp v) (> (length v) 0)
                            (mapconcat #'identity v ", ")))))
    (delq nil
          (list
           (vui-text (concat (octocat--run-icon status conclusion)
                             "  " (propertize (or (gethash "name" job) "")
                                              'face 'octocat-run-job-name)
                             (unless (string-empty-p shown)
                               (concat "  " (propertize shown 'face (octocat--job-status-face shown))))))
           (octocat-vui-fields
            (list (cons "Duration"  (octocat--run-duration started completed))
                  (cons "Started"   (and started (octocat--format-ts-relative started)))
                  (cons "Completed" (and completed (octocat--format-ts-relative completed)))
                  (cons "Runner"    (octocat--nonempty (gethash "runner_name" job)))
                  (cons "Labels"    (and labels (propertize labels 'face 'octocat-branch)))))))))

(vui-defcomponent octocat-job--page (repo run-id job-id name tick)
  "Job JOB-ID of run RUN-ID of REPO; NAME shows while it loads.
A new TICK refetches the job, keeping what is shown, and which steps are
unfolded, until the fresh data replaces it."
  :state ((bulk nil))
  :render
  (let* ((result  (octocat-vui-use-cached
                    (list 'job repo job-id tick)
                    (lambda () (octocat--detail-cache-load repo "job" job-id))
                    (lambda (data) (octocat--detail-cache-save repo "job" job-id data))
                    (lambda (resolve reject)
                      (octocat--fetch-job
                       repo run-id job-id
                       (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (data    (and (eq (plist-get result :status) 'ready) (plist-get result :data)))
         (raw     (and data (gethash "log" data)))
         (log     (vui-use-memo (raw)
                    (if raw
                        (octocat--job-parse-log raw)
                      (cons 'error (or (and data (gethash "log_error" data)) "")))))
         (loading (and (or (eq (plist-get result :status) 'pending)
                           (plist-get result :refreshing))
                       t)))
    (octocat-vui-use-mode-line-loading loading)
    (apply #'vui-vstack
           (octocat-vui-actions-top-row repo)
           (pcase (plist-get result :status)
             ('pending (list (vui-text name :face 'octocat-run-job-name)))
             ('error   (list (vui-text (format "  Error: %s" (plist-get result :error))
                                       :face 'error)))
             (_ (let ((job (gethash "job" data)))
                  (append (octocat-job--header job)
                          (list (vui-newline))
                          (octocat-job--steps job log bulk
                                              (vui-async-callback (v) (vui-set-state :bulk v)))
                          (when-let* ((arts (octocat-job-artifacts
                                             repo run-id (gethash "artifacts" data))))
                            (cons (vui-newline) arts))
                          (when-let* ((anns (octocat-job-annotations
                                             (mapcar (lambda (a) (cons nil a))
                                                     (gethash "annotations" data)))))
                            (cons (vui-newline) anns)))))))))


;;;; Major mode

(defun octocat-job-browse ()
  "Open this job in a browser."
  (interactive)
  (unless (and octocat--job-repo octocat--job-run-id octocat--job-id)
    (user-error "Octocat: Buffer is not associated with a job"))
  (message "Octocat: Opening job in browser…")
  (browse-url (format "https://github.com/%s/actions/runs/%s/job/%s"
                      octocat--job-repo octocat--job-run-id octocat--job-id)))

(defvar octocat-job-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-job-mode'.")
(define-key octocat-job-mode-map (kbd "q") #'quit-window)
(define-key octocat-job-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-job-mode-map (kbd "C-c C-o") #'octocat-job-browse)
(define-key octocat-job-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-job-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-job-mode vui-mode "Octocat-Job"
  "Major mode for viewing a GitHub Actions job.

\\{octocat-job-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-job-refresh)
  (octocat--ts-eldoc-setup))


;;;; Refresh

(defun octocat-job-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current job buffer.
The page paints the disk cache at once and fetches the job and its log
in the background.  A refresh keeps the steps unfolded and the old
content up until the fresh data arrives, for following a running job."
  (interactive)
  (unless (and octocat--job-repo octocat--job-id)
    (user-error "Octocat: Buffer is not associated with a job"))
  (octocat-vui-refresh-page 'octocat-job--page octocat--job-id
                            (list :repo octocat--job-repo
                                  :run-id octocat--job-run-id
                                  :job-id octocat--job-id
                                  :name (or octocat--job-name ""))))

(defun octocat-job-open (repo run-id job-id name)
  "Show job JOB-ID of run RUN-ID of REPO in its own buffer; NAME is its name."
  (let ((buf (get-buffer-create (format "*octocat-job: %s#%d*" repo job-id))))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-job-mode)
      (octocat-job-mode))
    (setq octocat--job-repo   repo
          octocat--job-run-id run-id
          octocat--job-id     job-id
          octocat--job-name   name)
    (octocat-job-refresh)))

(provide 'octocat-job)
;;; octocat-job.el ends here
