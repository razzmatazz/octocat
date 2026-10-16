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


(defun octocat-actions--use-cached (repo type key loader &optional save-p)
  "Return the result of LOADER for KEY, a list cached as TYPE of REPO.
SAVE-P, when given, says whether to save a fresh result.  See
`octocat-vui-use-cached'.  Must be called during render."
  (octocat-vui-use-cached
   key
   (lambda () (plist-get (octocat--items-cache-load repo type "all") :items))
   (lambda (items)
     (when (or (null save-p) (funcall save-p))
       (octocat--items-cache-save repo type "all" items)))
   (lambda (resolve reject)
     (funcall loader (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))

(defun octocat-actions--loading-p (result)
  "Return whether RESULT is loading or showing data about to be replaced."
  (and (or (eq (plist-get result :status) 'pending)
           (plist-get result :refreshing))
       t))

(vui-defcomponent octocat-actions--runs-section (repo current-branch tick)
  "The Runs tab of REPO's Actions page: its recent runs.
TICK is the page's refresh tick."
  :state ((limit octocat-section-limit))
  :render
  (let* ((result  (octocat-actions--use-cached
                   ;; Only the first page is cached: a longer list would shrink back.
                   repo "recent-runs" (list 'recent-runs repo limit tick)
                   (lambda (callback) (octocat-repo--list-recent-runs repo limit callback))
                   (lambda () (= limit octocat-section-limit))))
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
           (if (null runs)
               (vui-text "(no workflow runs)\n" :face 'octocat-dimmed)
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

(vui-defcomponent octocat-actions--page (repo current-branch tick)
  "The Actions page of REPO: a Runs and a Workflows tab, Runs first.
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
         (vui-component 'octocat-actions--runs-section
                        :repo repo :current-branch current-branch :tick tick)
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
                                  :current-branch (plist-get (octocat--head-info) :branch))))

(define-derived-mode octocat-actions-mode octocat-vui-list-mode "Octocat-Actions"
  "Major mode for the Actions page of a repository.

\\{octocat-actions-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-actions-refresh))

(provide 'octocat-actions)
;;; octocat-actions.el ends here
