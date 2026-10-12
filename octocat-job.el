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
(require 'vui-components) ; vui-collapsible

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

(defun octocat-job--log-line (entry indent)
  "Return log ENTRY, a plist from `octocat--job-parse-log-line', as a line.
INDENT starts it.  Commands are dimmed."
  (let ((ts   (plist-get entry :ts))
        (text (or (plist-get entry :text) "")))
    (concat indent
            (if ts (propertize (concat ts " ") 'face 'octocat-dimmed) "")
            (if (eq (plist-get entry :kind) 'command)
                (propertize text 'face 'octocat-dimmed)
              text))))

(defun octocat-job--log-blocks (entries indent)
  "Return log ENTRIES as a list of blocks, lines starting with INDENT.
A block is (text STRING), a run of lines, or (group NAME STRING), the
lines of a ##[group], indented two more.  An unclosed group ends at the
next group or the end."
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
                 (push (octocat-job--log-line entry (concat indent "  ")) group)
               (push (octocat-job--log-line entry indent) run)))))
      (flush-run)
      (flush-group))
    (nreverse blocks)))

(defun octocat-job--block (block index)
  "Return the vnode of log BLOCK, from `octocat-job--log-blocks'.
INDEX, its position in the step, keys a group's fold."
  (pcase block
    (`(text ,text) (vui-text text))
    (`(group ,name ,text)
     (vui-collapsible
      :title (propertize name 'face 'octocat-dimmed)
      :key (intern (format "log-group-%d" index))
      :collapsed-indicator (propertize "      ▸" 'face 'octocat-dimmed)
      :expanded-indicator (propertize "      ▾" 'face 'octocat-dimmed)
      :indent 0
      (if (string-empty-p text) (vui-text "        (empty)" :face 'octocat-dimmed) (vui-text text))))))


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

(vui-defcomponent octocat-job--step (step lines)
  "STEP of a job, a REST hash-table, folded; unfolding shows its log LINES.
The log is laid out only once the step is unfolded: a log can be long."
  :state ((open nil))
  :render
  (let ((title  (octocat-job--step-title step))
        (blocks (vui-use-memo (open lines)
                  (and open (octocat-job--log-blocks lines "      ")))))
    (if (null lines)
        (vui-text (concat "    " title))
      (apply #'vui-collapsible
             :title title
             :key (intern (format "step-%s" (gethash "number" step)))
             :expanded open
             :on-toggle (vui-async-callback (v) (vui-set-state :open v))
             :collapsed-indicator "  ▸"
             :expanded-indicator "  ▾"
             :indent 0
             (cl-loop for block in blocks
                      for i from 0
                      collect (octocat-job--block block i))))))

(defun octocat-job--steps (job log)
  "Return the vnodes of the Steps section of JOB.
LOG is the parsed log, as from `octocat--job-parse-log', or \\=(error . MSG)."
  (let ((steps (let ((v (gethash "steps" job)))
                 (if (vectorp v) (append v nil) nil)))
        (failed (eq (car-safe log) 'error)))
    (append
     (list (vui-text (propertize (format "Steps (%d)" (length steps))
                                 'face 'octocat-section-heading)))
     (if (null steps)
         (list (vui-text "  (no steps)" :face 'octocat-dimmed))
       (mapcar (lambda (step)
                 (vui-component 'octocat-job--step
                                :key (gethash "number" step)
                                :step step
                                :lines (unless failed
                                         (cdr (assoc (or (gethash "name" step) "") log)))))
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

(vui-defcomponent octocat-job--page (repo run-id job-id name)
  "Job JOB-ID of run RUN-ID of REPO; NAME shows while it loads."
  :state ((spin 0))
  :render
  (let* ((result  (vui-use-async (list 'job repo job-id)
                    (lambda (resolve reject)
                      (octocat--fetch-job
                       repo run-id job-id
                       (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (loading (eq (plist-get result :status) 'pending)))
    (octocat-vui-use-spinner loading)
    (apply #'vui-vstack
           (octocat-vui-actions-top-row
            repo (and loading (octocat-vui-loading-suffix '(:refreshing t) spin)))
           (pcase (plist-get result :status)
             ('pending (list (vui-text name :face 'octocat-run-job-name)))
             ('error   (list (vui-text (format "  Error: %s" (plist-get result :error))
                                       :face 'error)))
             (_ (pcase-let ((`(,job ,log ,annotations ,artifacts) (plist-get result :data)))
                  (append (octocat-job--header job)
                          (list (vui-newline))
                          (octocat-job--steps job log)
                          (when-let* ((arts (octocat-job-artifacts repo run-id artifacts)))
                            (cons (vui-newline) arts))
                          (when-let* ((anns (octocat-job-annotations
                                             (mapcar (lambda (a) (cons nil a)) annotations))))
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
Mounts the vui.el page, which fetches the job and its log."
  (interactive)
  (unless (and octocat--job-repo octocat--job-id)
    (user-error "Octocat: Buffer is not associated with a job"))
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-job--page
                              :repo octocat--job-repo
                              :run-id octocat--job-run-id
                              :job-id octocat--job-id
                              :name (or octocat--job-name ""))
               (buffer-name))))

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
