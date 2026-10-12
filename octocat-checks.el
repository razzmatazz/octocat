;;; octocat-checks.el --- Check-run detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Fetches and displays all GitHub check-runs for a commit SHA, and provides
;; `octocat-checks-mode' for browsing them.  Each check-run row is a
;; RET-able magit section; pressing RET on a check that has an associated
;; GitHub Actions run opens the `octocat-run-mode' detail buffer for it.
;;
;; Data is retrieved from the GitHub Checks REST API:
;;   GET /repos/{owner}/{repo}/commits/{ref}/check-runs?per_page=100
;;
;; Also the vui.el Checks section the PR and commit pages share,
;; `octocat-checks-block'.
;;
;; Depends on octocat-core.el (shared infrastructure) and octocat-run.el
;; (to open the run detail view).  Must not depend on octocat.el to avoid
;; a circular require.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'octocat-core)
(require 'octocat-timeline)
(require 'octocat-vui)
(require 'vui)

;; octocat-run.el is loaded before this file in the package load order, but
;; declare the functions anyway to silence the byte-compiler.
(declare-function octocat-run-refresh "octocat-run" (&optional _ignore-auto _noconfirm))
(declare-function octocat-browse      "octocat"     ())

;; Buffer-locals set by the mode that are referenced in rendering functions
;; defined in this file but that live in octocat-run.el buffers.  Declare
;; them so the byte-compiler won't warn about free variables.
(defvar octocat--run-repo)
(defvar octocat--run-id)


;;;; Buffer-local declarations

(defvar-local octocat--checks-repo nil
  "The \"owner/repo\" this checks buffer is displaying.")

(defvar-local octocat--checks-sha nil
  "The full commit SHA whose check-runs this buffer shows.")

(defvar-local octocat--checks-ref nil
  "A human-readable ref label shown in the buffer header (branch name or PR head).
May be nil when only a SHA is available.")


;;;; Data fetching

(defun octocat--fetch-checks (repo sha callback)
  "Fetch all check-runs for SHA in REPO asynchronously.
Calls CALLBACK with a list of check-run hash-tables (snake_case keys from
the GitHub Checks REST API), or a cons \\=(error . MSG) on failure.
Requests up to 100 check-runs; pagination is not yet supported."
  (octocat--run-gh
   "checks"
   (list "api"
         (format "repos/%s/commits/%s/check-runs?per_page=100" repo sha))
   (lambda (output)
     (let* ((parsed (json-parse-string (string-trim output)))
            (runs   (and (hash-table-p parsed)
                         (gethash "check_runs" parsed))))
       (cond
        ((null runs)    '())
        ((vectorp runs) (cl-coerce runs 'list))
        (t              '()))))
   callback))


;;;; Rendering helpers

(defun octocat--checks-status-face (status conclusion)
  "Return the appropriate face for STATUS and CONCLUSION strings."
  (let ((st (or status ""))
        (co (octocat--nonempty conclusion)))
    (cond
     ((equal st "in_progress")                                   'octocat-ci-pending)
     ((equal co "success")                                       'octocat-ci-success)
     ((member co '("failure" "timed_out" "startup_failure"))     'octocat-ci-failure)
     (t                                                          'octocat-ci-pending))))

(defun octocat--check-run-id (check)
  "Return the GitHub Actions run database ID for CHECK, or nil.
CHECK is a check-run hash-table.  The run ID is stored in the nested
\\='check_suite\\=' → \\='app\\=' → GitHub Actions app, but is most reliably
reached via the \\='app.slug\\=' field (\\='github-actions\\=') combined with
\\='check_suite.id\\='.  When available we return the suite ID so the caller
can open the matching `octocat-run-mode' buffer.
Returns nil when the check was not created by GitHub Actions."
  (let* ((app       (gethash "app" check))
         (slug      (and app (gethash "slug" app)))
         (suite     (gethash "check_suite" check))
         (suite-id  (and suite (gethash "id" suite))))
    (when (and (equal slug "github-actions") suite-id)
      suite-id)))


;;;; Checks section (vui)
;;
;; Shared by the PR and commit pages.

(defun octocat-checks-from-rest (check)
  "Return the REST check-run CHECK in the shape of a `statusCheckRollup' entry.
The REST API's snake_case, lowercase fields become the camelCase,
uppercase ones `gh pr view' gives; the app name stands in for the
workflow name, which the REST check-run does not carry."
  (let ((entry (make-hash-table :test #'equal)))
    (dolist (field `(("name"         . ,(gethash "name" check))
                     ("workflowName" . ,(octocat-timeline--get check "app" "name"))
                     ("status"       . ,(octocat--nonempty (gethash "status" check)))
                     ("conclusion"   . ,(octocat--nonempty (gethash "conclusion" check)))
                     ("startedAt"    . ,(octocat--nonempty (gethash "started_at" check)))
                     ("completedAt"  . ,(octocat--nonempty (gethash "completed_at" check)))))
      (when (cdr field)
        (puthash (car field)
                 (if (member (car field) '("status" "conclusion"))
                     (upcase (cdr field))
                   (cdr field))
                 entry)))
    entry))

(defconst octocat-checks--column-max '(50 30)
  "Widest the name and workflow columns of the checks list grow.")

(defun octocat-checks--fields (check)
  "Return the text columns of status CHECK (a hash-table).
That is a list (NAME WORKFLOW DURATION STARTED); STARTED is the age,
with the exact time on hover (see `octocat--format-ts-relative')."
  (let ((started (octocat-timeline--get check "startedAt")))
    (list (or (gethash "name" check) "")
          (or (gethash "workflowName" check) "")
          (or (octocat--run-duration started (octocat-timeline--get check "completedAt")) "")
          (octocat--format-ts-relative started))))

(defun octocat-checks--widths (checks)
  "Return the width of each column: the widest field of any of CHECKS.
The name and workflow columns stop at `octocat-checks--column-max'."
  (let ((widths (list 0 0 0 0)))
    (seq-doseq (check checks)
      (setq widths (cl-mapcar (lambda (w field) (max w (string-width field)))
                              widths (octocat-checks--fields check))))
    (cl-mapcar (lambda (w cap) (if cap (min w cap) w))
               widths (append octocat-checks--column-max '(nil nil)))))

(defun octocat-checks--row (check widths on-visit)
  "Return a RET-able vnode for the status CHECK (a hash-table).
WIDTHS are the column widths, as from `octocat-checks--widths'.  A
column no check has anything in takes no space.  ON-VISIT is called by
RET."
  (let ((cells (cl-mapcar
                (lambda (field width face)
                  (and (> width 0)
                       (propertize (truncate-string-to-width field width nil ?\s "…")
                                   'face face)))
                (octocat-checks--fields check) widths
                '(nil octocat-dimmed octocat-dimmed octocat-dimmed))))
    (octocat-vui-row
     (string-trim-right
      (concat "  "
              (octocat--run-icon (or (gethash "status" check) "")
                                 (octocat-timeline--get check "conclusion"))
              " "
              (mapconcat #'identity (delq nil cells) "  ")))
     on-visit
     "RET: view checks for this commit")))

(define-obsolete-variable-alias 'octocat-pr-checks-shown 'octocat-checks-shown "0.1.0")
(defcustom octocat-checks-shown 5
  "Number of checks shown on a PR or commit page before the rest folds away.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)

(defun octocat-checks-block (checks on-visit)
  "Return the vnodes of a section listing CI runs, with a CI summary.
The runs are CHECKS, a `statusCheckRollup' vector, as a PR has (see
`octocat-checks-from-rest' for a commit's check-runs).  ON-VISIT is
called by RET on a check."
  (let* (;; From all checks, so unfolding the rest shifts no column.
         (widths (octocat-checks--widths checks)))
    (cons
     (vui-text (concat (propertize (format "Checks (%d)" (length checks))
                                   'face 'octocat-section-heading)
                       (unless (zerop (length checks))
                         (concat "  " (propertize "CI:" 'face 'octocat-dimmed)
                                 " " (octocat--checks-ci-status checks)))))
     (if (zerop (length checks))
         (list (vui-text (propertize "  (no checks)" 'face 'octocat-dimmed)))
       (list (vui-component
              'octocat-timeline-fold
              :total (length checks)
              :limit octocat-checks-shown
              :noun "checks"
              :key 'checks-fold
              :prefix "  "
              :render (lambda (shown)
                        (apply #'vui-vstack
                               (cl-loop for check across checks
                                        repeat shown
                                        collect (octocat-checks--row check widths on-visit))))))))))

;;;; Rendering

(defun octocat--checks-title-line (ref)
  "Return the row below the checks page's top line, naming the page.
REF, when non-nil, is the branch or tag the commit was opened from."
  (concat "Checks"
          (when ref (concat "  " (propertize ref 'face 'octocat-branch)))
          "\n"))

(defun octocat--render-checks-loading (sha)
  "Render a loading skeleton for the check-runs view of commit SHA."
  (let* ((short (substring sha 0 (min 7 (length sha))))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-checks-root)
      (magit-insert-heading
        (concat (propertize (or octocat--checks-repo "") 'face 'octocat-repo)
                (propertize (concat "@" short) 'face 'octocat-commit-sha)
                "  "
                (octocat--repo-tabs-string octocat--checks-repo 'code)))
      (insert (octocat--checks-title-line
               (and (octocat--nonempty octocat--checks-ref) octocat--checks-ref)))
      (let ((hint (list 'mouse-face 'magit-section-highlight
                        'help-echo  "RET: open repo view")))
        (magit-insert-section (repo-nav octocat--checks-repo)
          (magit-insert-heading
            (concat (apply #'propertize "  Repo     " hint)
                    (apply #'propertize (or octocat--checks-repo "")
                           'face 'octocat-repo hint)
                    (apply #'propertize "\n" hint)))))
      (insert "\n")
      (magit-insert-section (checks-list)
        (magit-insert-heading
          (propertize "Check Runs" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-checks (checks-list)
  "Erase the current buffer and render a list of check-run CHECKS-LIST.
CHECKS-LIST is a list of check-run hash-tables from the GitHub Checks API."
  (let* ((sha   (or octocat--checks-sha ""))
         (short (substring sha 0 (min 7 (length sha))))
         (ref   (and (octocat--nonempty octocat--checks-ref) octocat--checks-ref))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-checks-root)
      ;; ── Header ──────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--checks-repo "") 'face 'octocat-repo)
                (propertize (concat "@" short) 'face 'octocat-commit-sha)
                "  "
                (octocat--repo-tabs-string octocat--checks-repo 'code)))
      (insert (octocat--checks-title-line ref))
      ;; ── Repo breadcrumb ─────────────────────────────────────────────────
      (let ((hint (list 'mouse-face 'magit-section-highlight
                        'help-echo  "RET: open repo view")))
        (magit-insert-section (repo-nav octocat--checks-repo)
          (magit-insert-heading
            (concat (apply #'propertize "  Repo     " hint)
                    (apply #'propertize (or octocat--checks-repo "")
                           'face 'octocat-repo hint)
                    (apply #'propertize "\n" hint)))))
      (insert "\n")
      ;; ── Check Runs list ─────────────────────────────────────────────────
      (magit-insert-section (checks-list)
        (magit-insert-heading
          (propertize (format "Check Runs (%d)" (length checks-list))
                      'face 'octocat-section-heading))
        (if (null checks-list)
            (insert (propertize "  (no checks)\n" 'face 'octocat-dimmed))
          (dolist (check checks-list)
            (let* ((name       (or (gethash "name"       check) ""))
                   (status     (downcase (or (gethash "status"  check) "")))
                   (conc-raw   (gethash "conclusion" check))
                   (conclusion (and (octocat--nonempty conc-raw) (downcase conc-raw)))
                   (started    (octocat--nonempty (gethash "started_at"  check)))
                   (completed  (octocat--nonempty (gethash "completed_at" check)))
                   (duration   (octocat--run-duration started completed))
                   (app        (gethash "app" check))
                   (app-name   (or (and app (octocat--nonempty (gethash "name" app))) ""))
                   (icon       (octocat--run-icon status conclusion))
                   (run-id     (octocat--check-run-id check))
                   (navigable  (not (null run-id)))
                   (hint       (when navigable
                                 (list 'mouse-face 'magit-section-highlight
                                       'help-echo  "RET: open workflow run"))))
              (magit-insert-section (check-run check)
                (magit-insert-heading
                  (apply #'concat
                         (append
                          (list "  "
                                icon
                                "  "
                                (if navigable
                                    (apply #'propertize
                                           (truncate-string-to-width
                                            (format "%-40s" name) 40 nil ?\s "…")
                                           hint)
                                  (truncate-string-to-width
                                   (format "%-40s" name) 40 nil ?\s "…"))
                                "  "
                                (propertize (truncate-string-to-width
                                             (format "%-20s" app-name) 20 nil ?\s "…")
                                            'face 'octocat-dimmed))
                          (when duration
                            (list "  "
                                  (propertize duration 'face 'octocat-dimmed)))
                          (list "\n"))))))))))))


;;;; Visitor

(defun octocat-checks-visit ()
  "Open the workflow-run detail view for the check-run at point.
If the check-run was created by GitHub Actions and its suite ID is
available, opens an `octocat-run-mode' buffer for that run.  Otherwise
falls back to opening the check in the browser via `octocat-browse'."
  (interactive)
  (let* ((section (magit-current-section))
         (type    (and section (oref section type))))
    (when (eq type 'check-run)
      (let* ((check   (oref section value))
             (run-id  (octocat--check-run-id check))
             (repo    octocat--checks-repo))
        (if run-id
            (let* ((buf-name (format "*octocat-run: %s#%d*" repo run-id))
                   (buf      (get-buffer-create buf-name)))
              (pop-to-buffer buf)
              (unless (derived-mode-p 'octocat-run-mode)
                ;; Avoid a circular require by loading octocat-run lazily.
                (require 'octocat-run)
                (octocat-run-mode))
              (setq octocat--run-repo repo
                    octocat--run-id   run-id)
              (octocat--render-run-loading run-id)
              (octocat-run-refresh))
          (octocat-browse))))))

;; Forward-declare rendering helpers from octocat-run.el so the byte-compiler
;; doesn't warn about them being called in `octocat-checks-visit'.
(declare-function octocat-run-mode          "octocat-run" ())
(declare-function octocat--render-run-loading "octocat-run" (run-id))


;;;; Major mode

(defvar octocat-checks-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "RET")     #'octocat-checks-visit)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-r") #'octocat-switch-repo)
    (define-key map (kbd "C-c C-s") #'octocat-search-repo)
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-checks-refresh)
    map)
  "Keymap for `octocat-checks-mode'.")

(define-derived-mode octocat-checks-mode magit-section-mode "Octocat-Checks"
  "Major mode for viewing GitHub check-runs for a commit.

Each row represents one check-run.  Press RET on a GitHub Actions check
to open the workflow-run detail in `octocat-run-mode'.  Press \\[octocat-browse]
to open the check in the browser.

\\{octocat-checks-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-checks-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-checks-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current check-runs buffer asynchronously.
Render a disk cache immediately (stale-while-revalidate) when available,
then always fetch fresh data in the background."
  (interactive)
  (unless (and octocat--checks-repo octocat--checks-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (let* ((buf         (current-buffer))
         (repo        octocat--checks-repo)
         (sha         octocat--checks-sha)
         (saved-point (octocat--save-point))
         (cache       (octocat--detail-cache-load repo "checks" sha)))
    (when cache
      ;; The cache stores a vector (JSON array); convert to list for rendering.
      (let ((cached-list (if (vectorp cache)
                             (cl-coerce cache 'list)
                           (list cache))))
        (octocat--render-checks cached-list)
        (octocat--restore-point saved-point)))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-checks
     repo sha
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
             ;; Persist as a JSON array so cache loading can use the
             ;; standard detail-cache machinery.
             (let ((vec (vconcat result)))
               (octocat--detail-cache-save repo "checks" sha vec))
             (octocat--render-checks result)
             (octocat--restore-point saved-point))))))))

(defun octocat-checks-open (repo sha ref)
  "Show the checks of commit SHA of REPO in their own buffer.
REF is the branch the commit is the head of, or nil."
  (let ((buf (get-buffer-create
              (format "*octocat-checks: %s@%s*" repo
                      (substring sha 0 (min 7 (length sha)))))))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-checks-mode)
      (octocat-checks-mode))
    (setq octocat--checks-repo repo
          octocat--checks-sha  sha
          octocat--checks-ref  ref)
    (octocat--render-checks-loading sha)
    (octocat-checks-refresh)))

(provide 'octocat-checks)
;;; octocat-checks.el ends here
