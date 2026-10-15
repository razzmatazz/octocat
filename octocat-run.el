;;; octocat-run.el --- Workflow run detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; A GitHub Actions workflow run: `octocat-run-mode', a vui.el page
;; opened from a workflow, the Actions page or a check.  It shows the
;; run's metadata, its jobs (RET opens one, see octocat-job.el), its
;; artifacts and the annotations of all its jobs.
;;
;; Depends on octocat-core.el.  Must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-job)
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))
(declare-function octocat-search-repo "octocat-search" ())


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


;;;; Page

(defun octocat-run--jobs (run)
  "Return the jobs of RUN as a list."
  (let ((v (gethash "jobs" run)))
    (if (vectorp v) (append v nil) nil)))

(defun octocat-run--header (run local-branch)
  "Return the vnodes under the top row: title, status and details of RUN.
LOCAL-BRANCH, the checked-out branch, is highlighted when it is the run's."
  (let* ((status     (downcase (or (gethash "status" run) "")))
         (conclusion (let ((c (octocat--nonempty (gethash "conclusion" run))))
                       (and c (downcase c))))
         (shown      (or conclusion (octocat--nonempty status)))
         (created    (octocat--nonempty (gethash "createdAt" run)))
         (branch     (octocat--nonempty (gethash "headBranch" run)))
         (sha        (octocat--nonempty (gethash "headSha" run))))
    (delq nil
          (list
           (vui-text (concat (octocat--run-icon status conclusion)
                             "  " (or (gethash "displayTitle" run) "")
                             "  " (propertize (format "%s" (or (gethash "databaseId" run) ""))
                                              'face 'octocat-dimmed)))
           (octocat-vui-fields
            (list (cons "Workflow" (octocat--nonempty (gethash "workflowName" run)))
                  (cons "Event"    (octocat--nonempty (gethash "event" run)))
                  (cons "Branch"   (and branch
                                        (propertize branch 'face
                                                    (if (equal branch local-branch)
                                                        'octocat-branch-current
                                                      'octocat-branch))))
                  (cons "SHA"      (and sha (propertize (substring sha 0 (min 7 (length sha)))
                                                        'face 'octocat-pr-number)))
                  (cons "Status"   (and shown (propertize shown 'face (octocat--job-status-face shown))))
                  (cons "Created"  (and created (octocat--format-ts-relative created)))
                  (cons "Duration" (and conclusion
                                        (octocat--run-duration
                                         created (octocat--nonempty (gethash "updatedAt" run)))))))))))

(defun octocat-run--job-row (repo run-id job)
  "Return a RET-able row for JOB of run RUN-ID of REPO."
  (let* ((status     (downcase (or (gethash "status" job) "")))
         (conclusion (let ((c (octocat--nonempty (gethash "conclusion" job))))
                       (and c (downcase c))))
         (duration   (and conclusion
                          (octocat--run-duration
                           (octocat--nonempty (gethash "startedAt" job))
                           (octocat--nonempty (gethash "completedAt" job)))))
         (name       (or (gethash "name" job) "")))
    (octocat-vui-row
     (string-trim-right
      (concat "  " (octocat--run-icon status conclusion) "  "
              (propertize (truncate-string-to-width name 45 nil ?\s "…")
                          'face 'octocat-run-job-name)
              (if duration (propertize (concat "  " duration) 'face 'octocat-dimmed) "")))
     (lambda () (octocat-job-open repo run-id (gethash "databaseId" job) name))
     "RET: open job")))

(defun octocat-run--jobs-section (repo run-id jobs)
  "Return the vnodes of the Jobs section: JOBS of run RUN-ID of REPO."
  (cons (vui-text (propertize (format "Jobs (%d)" (length jobs))
                              'face 'octocat-section-heading))
        (if (null jobs)
            (list (vui-text "  (no jobs)" :face 'octocat-dimmed))
          (mapcar (lambda (job) (octocat-run--job-row repo run-id job)) jobs))))

(defun octocat-run--cached (repo type id key loader)
  "Return the result of LOADER for KEY, cached on disk as TYPE item ID of REPO.
See `octocat-vui-use-cached'.  Must be called during render."
  (octocat-vui-use-cached
   key
   (lambda () (octocat--detail-cache-load repo type id))
   (lambda (data) (octocat--detail-cache-save repo type id data))
   loader))

(defun octocat-run--annotation-entries (results)
  "Return the RESULTS of `octocat--fetch-run-annotations' as a vector.
Each entry is a hash-table of \"job\", its name, and \"annotations\", a
vector: a shape the disk cache can store as JSON."
  (vconcat
   (mapcar (lambda (r)
             (let ((h (make-hash-table :test #'equal)))
               (puthash "job" (nth 1 r) h)
               (puthash "annotations" (nth 2 r) h)
               h))
           results)))

(vui-defcomponent octocat-run--page (repo run-id tick)
  "Workflow run RUN-ID of REPO.
A new TICK refetches everything, keeping what is shown until the fresh
data replaces it."
  :render
  (let* ((local-branch (vui-use-memo () (octocat--current-branch)))
         (run   (octocat-run--cached
                 repo "run" run-id (list 'run repo run-id tick)
                 (lambda (resolve reject)
                   (octocat--fetch-run
                    repo run-id
                    (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (data  (and (eq (plist-get run :status) 'ready) (plist-get run :data)))
         (jobs  (and data (octocat-run--jobs data)))
         ;; Keyed by the jobs too: they are only known once the run is.
         (anns  (octocat-run--cached
                 repo "run-annotations" run-id
                 (list 'run-annotations repo run-id tick
                       (mapcar (lambda (j) (gethash "databaseId" j)) jobs))
                 (lambda (resolve _reject)
                   (if jobs
                       (octocat--fetch-run-annotations
                        repo (vconcat jobs)
                        (lambda (r) (funcall resolve (octocat-run--annotation-entries r))))
                     (funcall resolve nil)))))
         (arts  (octocat-run--cached
                 repo "run-artifacts" run-id (list 'run-artifacts repo run-id tick)
                 (lambda (resolve _reject)
                   (octocat--fetch-run-artifacts repo run-id resolve))))
         (loading (and (cl-some (lambda (r) (or (eq (plist-get r :status) 'pending)
                                                (plist-get r :refreshing)))
                                (list run anns arts))
                       t)))
    (octocat-vui-use-mode-line-loading loading)
    (apply #'vui-vstack
           (octocat-vui-actions-top-row repo)
           (pcase (plist-get run :status)
             ('pending (list (vui-text (format "run %s" run-id) :face 'octocat-dimmed)
                             (vui-newline)
                             (vui-text (octocat-vui-line-skeleton "  "))))
             ('error   (list (vui-text (format "  Error: %s" (plist-get run :error))
                                       :face 'error)))
             (_ (append (octocat-run--header data local-branch)
                        (list (vui-newline))
                        (octocat-run--jobs-section repo run-id jobs)
                        (when-let* ((section (octocat-job-artifacts
                                              repo run-id (or (plist-get arts :data) []))))
                          (cons (vui-newline) section))
                        (when-let* ((section (octocat-job-annotations
                                              (cl-loop for entry across (or (plist-get anns :data) [])
                                                       append (cl-loop for ann across (gethash "annotations" entry)
                                                                       collect (cons (gethash "job" entry) ann))))))
                          (cons (vui-newline) section))))))))


;;;; Major mode

(defun octocat-run-browse ()
  "Open this workflow run in a browser."
  (interactive)
  (unless (and octocat--run-repo octocat--run-id)
    (user-error "Octocat: Buffer is not associated with a workflow run"))
  (message "Octocat: Opening run #%s in browser…" octocat--run-id)
  (octocat-browse-external (format "https://github.com/%s/actions/runs/%s"
                                   octocat--run-repo octocat--run-id)))

(defvar octocat-run-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-run-mode'.")
(define-key octocat-run-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-run-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-run-mode-map (kbd "C-c C-o") #'octocat-run-browse)
(define-key octocat-run-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-run-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-run-mode vui-mode "Octocat-Run"
  "Major mode for viewing a GitHub Actions workflow run.

\\{octocat-run-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-run-refresh)
  (octocat--ts-eldoc-setup))


;;;; Refresh

(defun octocat-run-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current run buffer.
The page paints the disk cache at once and fetches the run, its
annotations and artifacts in the background.  A refresh keeps the old
content up until the fresh data arrives, for following a running job."
  (interactive)
  (unless (and octocat--run-repo octocat--run-id)
    (user-error "Octocat: Buffer is not associated with a workflow run"))
  (octocat-vui-refresh-page 'octocat-run--page octocat--run-id
                            (list :repo octocat--run-repo :run-id octocat--run-id)))

(defun octocat-run-open (repo run-id)
  "Show workflow run RUN-ID of REPO in its own buffer."
  (let ((buf (get-buffer-create (format "*%s run %d*" repo run-id))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-run-mode)
      (octocat-run-mode))
    (setq octocat--run-repo repo
          octocat--run-id   run-id)
    (octocat-run-refresh)))

(provide 'octocat-run)
;;; octocat-run.el ends here
