;;; octocat-actions.el --- Actions page for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-opus-5-5

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

;; The Actions page, as GitHub's Actions tab: a repository's recent runs
;; across all workflows, and on a second tab its workflows.  Opened by `M-x
;; octocat-actions' (octocat.el).  See "UI frameworks" in CONTRIBUTING.md.

;;; Code:

(require 'octocat-core)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-list, etc.
(require 'octocat-repo) ; row builders and fetchers


(defun octocat-actions--use-cached (repo type key loader &optional save-p id)
  "Return the result of LOADER for KEY, a list cached as TYPE of REPO.
SAVE-P, when given, says whether to save a fresh result.  ID names the
cache entry, \"all\" by default.  See `octocat-vui-use-cached'.  Must
be called during render."
  (octocat-vui-use-cached
   key
   (lambda () (plist-get (octocat--items-cache-load repo type (or id "all")) :items))
   (lambda (items)
     (when (or (null save-p) (funcall save-p))
       (octocat--items-cache-save repo type (or id "all") items)))
   (lambda (resolve reject)
     (funcall loader (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))

(defun octocat-actions--loading-p (result)
  "Return whether RESULT is loading or showing data about to be replaced."
  (and (or (eq (plist-get result :status) 'pending)
           (plist-get result :refreshing))
       t))

;;;; Run filters
;;
;; The runs are filtered by a query of qualifiers, edited as a PR list's
;; (see "List filters" in octocat-vui.el).  `gh run list' takes no search
;; query, only one option per qualifier, so each becomes its option; a
;; repeated qualifier keeps its last value, as gh would.

(defconst octocat-actions--run-qualifiers
  '(("branch:"   . "--branch")
    ("status:"   . "--status")
    ("workflow:" . "--workflow")
    ("actor:"    . "--user")
    ("event:"    . "--event")
    ("commit:"   . "--commit"))
  "Run query qualifiers and the `gh run list' option each becomes.")

(defconst octocat-actions--run-statuses
  '("success" "failure" "in_progress" "queued" "completed" "cancelled"
    "skipped" "timed_out" "action_required" "waiting" "pending"
    "requested" "neutral" "stale" "startup_failure")
  "Values `gh run list --status' takes, the common ones first.")

(defun octocat-actions--run-args (query)
  "Return the `gh run list' options of QUERY, and its other tokens.
That is (ARGS . IGNORED): ARGS a list of options and values, IGNORED the
tokens of QUERY that are no qualifier of `octocat-actions--run-qualifiers'."
  (let (opts ignored)
    (dolist (token (octocat-vui-list--tokenize (or query "")))
      (if-let* ((q (seq-find (lambda (q) (string-prefix-p (car q) token))
                             octocat-actions--run-qualifiers))
                (value (string-replace "\"" "" (substring token (length (car q)))))
                ((not (string-empty-p value))))
          (setf (alist-get (cdr q) opts nil nil #'equal) value)
        (push token ignored)))
    (cons (mapcan (lambda (o) (list (car o) (cdr o))) (nreverse opts))
          (nreverse ignored))))

(defun octocat-actions--static-candidates (values)
  "Return a fetch function of `octocat-vui-list--edit-facet' giving VALUES."
  (lambda (_repo callback) (funcall callback values)))

(defun octocat-actions--workflow-names (repo callback)
  "Call CALLBACK with the workflow names of REPO, or (error . MSG)."
  (octocat-repo--list-workflows
   repo (lambda (r)
          (funcall callback
                   (if (eq (car-safe r) 'error)
                       r
                     (mapcar (lambda (wf) (gethash "name" wf)) r))))))

(defun octocat-actions-filter-branch ()
  "Filter by the branch of a run."
  (interactive)
  (octocat-vui-list--edit-facet "branch:" "Branch" nil #'octocat--list-branches nil))

(defun octocat-actions-filter-status ()
  "Filter by the status or conclusion of a run."
  (interactive)
  (octocat-vui-list--edit-facet
   "status:" "Status" nil
   (octocat-actions--static-candidates octocat-actions--run-statuses) nil))

(defun octocat-actions-filter-workflow ()
  "Filter by the workflow of a run."
  (interactive)
  (octocat-vui-list--edit-facet "workflow:" "Workflow" nil
                                #'octocat-actions--workflow-names nil))

(defun octocat-actions-filter-actor ()
  "Filter by who triggered a run."
  (interactive)
  (octocat-vui-list--edit-facet "actor:" "Actor" nil #'octocat--list-people nil))

(defun octocat-actions--filter-setup ()
  "Give the current list buffer the filter of the Actions page."
  (setq-local octocat-vui-list--states octocat-actions--run-statuses
              octocat-vui-list--default-query ""
              octocat-vui-list--qualifiers
              (append (mapcar #'car octocat-actions--run-qualifiers)
                      (mapcar (lambda (s) (concat "status:" s))
                              octocat-actions--run-statuses)
                      '("event:push" "event:pull_request" "event:schedule"
                        "event:workflow_dispatch"))
              octocat-vui-list--facets
              '(("Branch"   . octocat-actions-filter-branch)
                ("Status"   . octocat-actions-filter-status)
                ("Workflow" . octocat-actions-filter-workflow)
                ("Actor"    . octocat-actions-filter-actor))))

;;;; Page

(vui-defcomponent octocat-actions--runs-section (repo current-branch tick query)
  "The Runs tab of REPO's Actions page: its recent runs matching QUERY.
See `octocat-actions--run-args' for QUERY.  TICK is the page's refresh
tick.  Each query's first page is cached."
  :state ((limit octocat-section-limit))
  :render
  (let* ((parsed  (octocat-actions--run-args query))
         (result  (octocat-actions--use-cached
                   ;; Only the first page is cached: a longer list would shrink back.
                   repo "recent-runs" (list 'recent-runs repo limit tick query)
                   (lambda (callback)
                     (octocat-repo--list-recent-runs repo limit callback (car parsed)))
                   (lambda () (= limit octocat-section-limit))
                   (if (car parsed) (secure-hash 'md5 (format "%S" (car parsed))) "all")))
         (loading (octocat-actions--loading-p result)))
    (octocat-vui-use-mode-line-loading loading)
    (pcase (plist-get result :status)
       ('pending (vui-text (octocat-vui-line-skeleton)))
       ('error   (vui-text (format "%s\n" (plist-get result :error)) :face 'octocat-dimmed))
       ('ready
        (let* ((runs (plist-get result :data))
               (wf-w (if runs
                         (min 25 (apply #'max 1
                                        (mapcar (lambda (r) (length (or (gethash "workflowName" r) "")))
                                                runs)))
                       1))
               (branch-w (octocat--branch-column-width runs "headBranch"))
               (title-w (octocat-repo-vui--run-title-width
                         runs (octocat-vui-window-width) wf-w branch-w)))
          (vui-fragment
           (when (cdr parsed)
             (vui-text (format "Ignored, not a run filter: %s\n"
                               (string-join (cdr parsed) " "))
                       :face 'octocat-dimmed))
           (if (null runs)
               (vui-text (if (car parsed)
                             "(no workflow runs match the filters)\n"
                           "(no workflow runs)\n")
                         :face 'octocat-dimmed)
             (octocat-vui-reveal-list
              runs
              (lambda (r)
                (octocat-repo-vui--workflow-run-row
                 repo r current-branch wf-w title-w branch-w))
              (lambda (r) (gethash "databaseId" r))))
           (when (and runs (or (plist-get result :refreshing)
                               (>= (length runs) limit)))
             (octocat-vui-load-more-button
              'load-more-runs octocat-section-limit
              "RET: load more runs"
              (lambda () (vui-set-state :limit (+ limit octocat-section-limit)))
              (and (plist-get result :refreshing) (< (length runs) limit)) 0
              (octocat-vui-line-skeleton)))))))))

(defun octocat-actions--workflows (repo result)
  "Return the Workflows tab of REPO's Actions page, from RESULT.
RESULT is the page's `octocat-actions--use-cached' result of the
workflows (no pagination: run history lives on the Runs tab)."
  (pcase (plist-get result :status)
    ('pending (vui-text (octocat-vui-line-skeleton)))
    ('error   (vui-text (format "%s\n" (plist-get result :error)) :face 'octocat-dimmed))
    ('ready
     (let ((workflows (plist-get result :data)))
       (if (null workflows)
           (vui-text "(no workflows)\n" :face 'octocat-dimmed)
         (let* ((state-w (apply #'max (mapcar (lambda (wf)
                                                (string-width
                                                 (octocat-repo-vui--workflow-state wf)))
                                              workflows)))
                (name-w  (octocat-repo-vui--workflow-name-width
                          workflows (octocat-vui-window-width) state-w)))
           (vui-list workflows
                     (lambda (wf) (octocat-repo-vui--workflow-row repo wf state-w name-w))
                     (lambda (wf) (gethash "id" wf)))))))))

(vui-defcomponent octocat-actions--page (repo current-branch tick query)
  "The Actions page of REPO: a Runs and a Workflows tab, Runs first.
The runs are those matching QUERY, filtered above them.
The workflows are fetched whichever tab shows, for the count on their
tab; cached, it shows at once.  A new TICK refetches, keeping what is
shown up until the fresh data replaces it."
  :state ((tab 'runs))
  :render
  (let* ((workflows (octocat-actions--use-cached
                     repo "workflows" (list 'workflows repo tick)
                     (lambda (callback) (octocat-repo--list-workflows repo callback))))
         (count     (and (eq (plist-get workflows :status) 'ready)
                         (length (plist-get workflows :data))))
         (tab-of    (lambda (sym label help)
                      (list label help
                            (unless (eq tab sym) (lambda () (vui-set-state :tab sym)))))))
    (octocat-vui-use-mode-line-loading
     (and (eq tab 'workflows) (octocat-actions--loading-p workflows)))
    (vui-vstack
     (vui-component 'octocat-vui-list-header :repo repo :tab 'actions)
     (octocat-vui-tab-row
      (list (funcall tab-of 'runs "Runs" "RET: show the recent runs")
            (funcall tab-of 'workflows
                     (if count (format "Workflows (%d)" count) "Workflows")
                     "RET: show the workflows"))
      (octocat-vui-window-width))
     (if (eq tab 'runs)
         (vui-vstack
          (octocat-vui-list-filter-bar query)
          (vui-component 'octocat-actions--runs-section
                         :key query
                         :repo repo :current-branch current-branch :tick tick
                         :query query))
       (octocat-actions--workflows repo workflows)))))

(defun octocat-actions-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current Actions page buffer.
The page paints the disk cache at once and fetches the workflows and runs
in the background; a refresh keeps the old content up meanwhile."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-actions--page octocat-vui-list--repo
                            (list :repo octocat-vui-list--repo
                                  :current-branch (plist-get (octocat--head-info) :branch)
                                  :query (octocat-vui-list-query))))

(define-derived-mode octocat-actions-mode octocat-vui-list-mode "Octocat-Actions"
  "Major mode for the Actions page of a repository.

\\{octocat-actions-mode-map}"
  :group 'octocat
  (octocat-actions--filter-setup)
  (setq-local revert-buffer-function #'octocat-actions-refresh))

(provide 'octocat-actions)
;;; octocat-actions.el ends here
