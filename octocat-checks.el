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

;; The check-runs of a commit: `octocat-checks-mode', a vui.el page
;; opened from the PR and commit pages.  RET on a GitHub Actions check
;; opens its workflow run; on any other, its page in the browser.
;;
;; Also the Checks section the PR and commit pages share,
;; `octocat-checks-block'.
;;
;; Data is retrieved from the GitHub Checks REST API:
;;   GET /repos/{owner}/{repo}/commits/{ref}/check-runs?per_page=100
;;
;; Depends on octocat-core.el.  Must not depend on octocat.el to avoid a
;; circular require.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'octocat-core)
(require 'octocat-vui)
(require 'vui)

(declare-function octocat-run-open "octocat-run" (repo run-id))
(declare-function octocat-repo-vui-use-cached "octocat-repo"
                  (type repo number fetch &optional as-list tick))
(declare-function octocat-search-repo "octocat-search" ())


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

(defun octocat--check-run-id (check)
  "Return the GitHub Actions workflow run ID of the REST check-run CHECK, or nil.
It is read from the check's details URL, `.../actions/runs/ID/job/...';
a check not created by GitHub Actions has none."
  (let ((url (or (octocat--nonempty (gethash "details_url" check))
                 (octocat--nonempty (gethash "html_url" check)))))
    (and url (string-match "/actions/runs/\\([0-9]+\\)" url)
         (string-to-number (match-string 1 url)))))


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
                     ("workflowName" . ,(octocat--get check "app" "name"))
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
  (let ((started (octocat--get check "startedAt")))
    (list (or (gethash "name" check) "")
          (or (gethash "workflowName" check) "")
          (or (octocat--run-duration started (octocat--get check "completedAt")) "")
          (octocat--format-ts-relative started))))

(defun octocat-checks--widths (checks)
  "Return the width of each column: its widest field over all entries.
The entries are CHECKS.  The name and workflow columns stop at
`octocat-checks--column-max'."
  (let ((widths (list 0 0 0 0)))
    (seq-doseq (check checks)
      (setq widths (cl-mapcar (lambda (w field) (max w (string-width field)))
                              widths (octocat-checks--fields check))))
    (cl-mapcar (lambda (w cap) (if cap (min w cap) w))
               widths (append octocat-checks--column-max '(nil nil)))))

(defun octocat-checks--row (check widths on-visit &optional help-echo indent)
  "Return a RET-able vnode for the status CHECK (a hash-table).
WIDTHS are the column widths, as from `octocat-checks--widths'.  A
column no check has anything in takes no space.  ON-VISIT is called by
RET, described by HELP-ECHO.  INDENT starts the row, two spaces if nil."
  (let ((cells (cl-mapcar
                (lambda (field width face)
                  (and (> width 0)
                       (propertize (truncate-string-to-width field width nil ?\s "…")
                                   'face face)))
                (octocat-checks--fields check) widths
                '(nil octocat-dimmed octocat-dimmed octocat-dimmed))))
    (octocat-vui-row
     (string-trim-right
      (concat (or indent "  ")
              (octocat--run-icon (or (gethash "status" check) "")
                                 (octocat--get check "conclusion"))
              " "
              (mapconcat #'identity (delq nil cells) "  ")))
     on-visit
     (or help-echo "RET: view checks for this commit"))))

(define-obsolete-variable-alias 'octocat-pr-checks-shown 'octocat-checks-shown "0.1.0")
(defcustom octocat-checks-shown 5
  "Number of checks shown on a PR or commit page before the rest folds away.
The rest expands on RET.  Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)

(defun octocat-checks-rows (rollup on-visit &optional indent)
  "Return a vnode listing ROLLUP; all but a few fold away.
ROLLUP is a `statusCheckRollup' vector, as a PR has (see
`octocat-checks-from-rest' for a commit's check-runs).  ON-VISIT is
called by RET on a check.  INDENT starts each row, two spaces if nil."
  (let ((widths (octocat-checks--widths rollup))) ; Of all, so unfolding shifts no column.
    (vui-component
     'octocat-vui-fold-rest
     :total (length rollup)
     :limit octocat-checks-shown
     :noun "checks"
     :key 'checks-fold
     :prefix (or indent "  ")
     :render (lambda (shown)
               (apply #'vui-vstack
                      (cl-loop for check across rollup
                               repeat shown
                               collect (octocat-checks--row check widths on-visit
                                                            nil indent)))))))

(defun octocat-checks-block (checks on-visit)
  "Return the vnodes of the CI section, with a CI summary.
CHECKS and ON-VISIT are as for `octocat-checks-rows'."
  (list
   (vui-text (concat (propertize (format "Checks (%d)" (length checks))
                                 'face 'octocat-section-heading)
                     (unless (zerop (length checks))
                       (concat "  " (propertize "CI:" 'face 'octocat-dimmed)
                               " " (octocat--checks-ci-status checks)))))
   (if (zerop (length checks))
       (vui-text (propertize "  (no checks)" 'face 'octocat-dimmed))
     (octocat-checks-rows checks on-visit))))

;;;; Page

(defun octocat-checks--visit (repo check)
  "Open the workflow run of the REST check-run CHECK of REPO.
A check not created by GitHub Actions opens in the browser instead."
  (let ((run-id (octocat--check-run-id check)))
    (if run-id
        (octocat-run-open repo run-id)
      (when-let* ((url (octocat--nonempty (gethash "html_url" check))))
        (browse-url url)))))

(defun octocat-checks--list (repo checks)
  "Return the vnodes of the section of the CI results of REPO, one per row.
CHECKS is a list of REST check-runs."
  (let* ((entries (mapcar #'octocat-checks-from-rest checks))
         (widths  (octocat-checks--widths entries)))
    (cons
     (vui-text (concat (propertize (format "Check runs (%d)" (length checks))
                                   'face 'octocat-section-heading)
                       (when checks
                         (concat "  " (propertize "CI:" 'face 'octocat-dimmed)
                                 " " (octocat--checks-ci-status entries)))))
     (if (null checks)
         (list (vui-text "  (no checks)" :face 'octocat-dimmed))
       (cl-mapcar (lambda (check entry)
                    (octocat-checks--row
                     entry widths
                     (lambda () (octocat-checks--visit repo check))
                     (if (octocat--check-run-id check)
                         "RET: open workflow run"
                       "RET: open in browser")))
                  checks entries)))))

(vui-defcomponent octocat-checks--page (repo sha ref tick)
  "The check-runs of commit SHA of REPO; REF is its branch, or nil.
A new TICK fetches them again."
  :render
  (let* ((checks  (octocat-repo-vui-use-cached
                   "checks" repo sha #'octocat--fetch-checks t tick))
         (loading (and (or (eq (plist-get checks :status) 'pending)
                           (plist-get checks :refreshing))
                       t)))
    (octocat-vui-use-mode-line-loading loading)
    (apply #'vui-vstack
           (octocat-vui-commit-top-row repo sha)
           (vui-text (concat "Checks"
                             (when ref (concat "  " (propertize ref 'face 'octocat-branch)))))
           (vui-newline)
           (pcase (plist-get checks :status)
             ('pending (list (vui-text (octocat-vui-line-skeleton "  "))))
             ('error   (list (vui-text (format "  Error: %s" (plist-get checks :error))
                                       :face 'error)))
             (_ (octocat-checks--list repo (plist-get checks :data)))))))


;;;; Major mode

(defun octocat-checks-browse ()
  "Open the CI results of this commit in a browser."
  (interactive)
  (unless (and octocat--checks-repo octocat--checks-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (message "Octocat: Opening checks in browser…")
  (octocat-browse-external (format "https://github.com/%s/commit/%s/checks"
                                   octocat--checks-repo octocat--checks-sha)))

(defvar octocat-checks-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-checks-mode'.")
(define-key octocat-checks-mode-map (kbd "q") #'octocat-quit-window)
(define-key octocat-checks-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-checks-mode-map (kbd "C-c C-o") #'octocat-checks-browse)
(define-key octocat-checks-mode-map (kbd "C-c C-j") #'octocat-switch-repo)
(define-key octocat-checks-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-checks-mode vui-mode "Octocat-Checks"
  "Major mode for viewing the GitHub check-runs of a commit.

\\{octocat-checks-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-checks-refresh)
  (octocat--ts-eldoc-setup))


;;;; Refresh

(defun octocat-checks-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current check-runs buffer.
The page paints the disk cache at once and fetches the check-runs in
the background, in place."
  (interactive)
  (unless (and octocat--checks-repo octocat--checks-sha)
    (user-error "Octocat: Buffer is not associated with a commit"))
  (octocat-vui-refresh-page 'octocat-checks--page
                            (cons octocat--checks-repo octocat--checks-sha)
                            (list :repo octocat--checks-repo
                                  :sha octocat--checks-sha
                                  :ref (octocat--nonempty octocat--checks-ref))))

(defun octocat-checks-open (repo sha ref)
  "Show the CI results of commit SHA of REPO in their own buffer.
REF is the branch the commit is the head of, or nil."
  (let ((buf (get-buffer-create
              (format "*%s checks %s*" repo
                      (substring sha 0 (min 7 (length sha)))))))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-checks-mode)
      (octocat-checks-mode))
    (setq octocat--checks-repo repo
          octocat--checks-sha  sha
          octocat--checks-ref  ref)
    (octocat-checks-refresh)))

(provide 'octocat-checks)
;;; octocat-checks.el ends here
