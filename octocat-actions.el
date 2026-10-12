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

;; The Actions page, as GitHub's Actions tab: a repository's workflows
;; and its recent runs across all workflows.  Opened by `M-x
;; octocat-actions' (octocat.el).  See "UI frameworks" in CONTRIBUTING.md.

;;; Code:

(require 'octocat-core)
(require 'octocat-vui)
(require 'vui)
(require 'vui-components) ; vui-collapsible, vui-list, etc.
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
  "Workflow Runs section for REPO.
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
    (vui-collapsible
     :title "Workflow Runs"
     :key 'workflow-runs :initially-expanded t :indent 0
     (pcase (plist-get result :status)
       ('pending (vui-text "(loading…)\n" :face 'octocat-dimmed))
       ('error   (vui-text (format "%s\n" (plist-get result :error)) :face 'octocat-dimmed))
       ('ready
        (let* ((runs (plist-get result :data))
               (wf-w (if runs
                         (min 25 (apply #'max 1
                                        (mapcar (lambda (r) (length (or (gethash "workflowName" r) "")))
                                                runs)))
                       1)))
          (vui-fragment
           (if (null runs)
               (vui-text "(no workflow runs)\n" :face 'octocat-dimmed)
             (octocat-vui-reveal-list
              runs
              (lambda (r) (octocat-repo-vui--workflow-run-row repo r current-branch wf-w))
              (lambda (r) (gethash "databaseId" r))))
           (when (and runs (or (plist-get result :refreshing)
                               (>= (length runs) limit)))
             (octocat-vui-load-more-button
              'load-more-runs octocat-section-limit
              "RET: load more runs"
              (lambda () (vui-set-state :limit (+ limit octocat-section-limit)))
              (plist-get result :refreshing) 0)))))))))

(vui-defcomponent octocat-actions--workflows-section (repo tick)
  "Workflows section for REPO (no pagination: run history lives in
`octocat-actions--runs-section' instead).
TICK is as for `octocat-actions--runs-section'."
  :render
  (let* ((result  (octocat-actions--use-cached
                   repo "workflows" (list 'workflows repo tick)
                   (lambda (callback) (octocat-repo--list-workflows repo callback))))
         (loading (octocat-actions--loading-p result)))
    (octocat-vui-use-mode-line-loading loading)
    (vui-collapsible
     :title "Workflows" :key 'workflows :initially-expanded t :indent 0
     (pcase (plist-get result :status)
       ('pending (vui-text "(loading…)\n" :face 'octocat-dimmed))
       ('error   (vui-text (format "%s\n" (plist-get result :error)) :face 'octocat-dimmed))
       ('ready
        (let ((workflows (plist-get result :data)))
          (if (null workflows)
              (vui-text "(no workflows)\n" :face 'octocat-dimmed)
            (vui-list workflows
                      (lambda (wf) (octocat-repo-vui--workflow-row repo wf))
                      (lambda (wf) (gethash "id" wf))))))))))

(vui-defcomponent octocat-actions--page (repo current-branch tick)
  "The Actions page of REPO: its workflows and recent runs.
A new TICK refetches both, keeping what is shown until the fresh data
replaces it."
  :render
  (vui-vstack
   (vui-component 'octocat-vui-list-header :repo repo :tab 'actions)
   (vui-component 'octocat-actions--workflows-section :repo repo :tick tick)
   (vui-newline)
   (vui-component 'octocat-actions--runs-section
                  :repo repo :current-branch current-branch :tick tick)))

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
