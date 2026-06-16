;;; octocat-checks.el --- Check-run detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Fetches and displays all GitHub check-runs for a commit SHA, and provides
;; `octocat-checks-mode' for browsing them.  Each check-run row is a
;; RET-able magit section; pressing RET on a check that has an associated
;; GitHub Actions run opens the `octocat-run-mode' detail buffer for it.
;;
;; Data is retrieved from the GitHub Checks REST API:
;;   GET /repos/{owner}/{repo}/commits/{ref}/check-runs?per_page=100
;;
;; Depends on octocat-core.el (shared infrastructure) and octocat-run.el
;; (to open the run detail view).  Must not depend on octocat.el to avoid
;; a circular require.

;;; Code:

(require 'octocat-core)

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


;;;; Rendering

(defun octocat--render-checks-loading (sha)
  "Render a loading skeleton for the check-runs view of commit SHA."
  (let* ((short (substring sha 0 (min 7 (length sha))))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-checks-root)
      (magit-insert-heading
        (concat (propertize (or octocat--checks-repo "") 'face 'octocat-repo)
                "  "
                (propertize "checks" 'face 'octocat-dimmed)
                "  "
                (propertize short 'face 'octocat-commit-sha)
                (when (and octocat--checks-ref
                           (not (string-empty-p (or octocat--checks-ref ""))))
                  (concat "  " (propertize octocat--checks-ref
                                           'face 'octocat-branch)))))
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
                "  "
                (propertize "checks" 'face 'octocat-dimmed)
                "  "
                (propertize short 'face 'octocat-commit-sha)
                (when ref
                  (concat "  " (propertize ref 'face 'octocat-branch)))))
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
    (define-key map (kbd "o")       #'octocat-browse)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
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

(provide 'octocat-checks)
;;; octocat-checks.el ends here
