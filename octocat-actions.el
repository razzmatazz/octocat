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


(vui-defcomponent octocat-actions--runs-section (repo current-branch on-loading)
  "Workflow Runs section for REPO.
ON-LOADING is called with whether the runs are refreshing, for the page's
loading indicator."
  :state ((limit octocat-section-limit))
  :render
  (let* ((result  (octocat-vui-use-async-sticky (list 'recent-runs repo limit)
                    (lambda (resolve reject)
                      (octocat-repo--list-recent-runs
                       repo limit
                       (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (loading (and (plist-get result :refreshing) t)))
    (vui-use-effect (loading)
      (funcall on-loading loading)
      nil)
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

(vui-defcomponent octocat-actions--workflows-section (repo)
  "Workflows section for REPO (no pagination: run history lives in
`octocat-actions--runs-section' instead)."
  :render
  (let ((result (vui-use-async (list 'workflows repo)
                  (lambda (resolve reject)
                    (octocat-repo--list-workflows
                     repo
                     (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject)))))))
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

(vui-defcomponent octocat-actions--page (repo current-branch)
  "The Actions page of REPO: its workflows and recent runs."
  :state ((loading nil))
  :render
  (vui-vstack
   (vui-component 'octocat-vui-list-header
                  :repo repo :tab 'actions :loading loading)
   (vui-component 'octocat-actions--workflows-section :repo repo)
   (vui-newline)
   (vui-component 'octocat-actions--runs-section
                  :repo repo :current-branch current-branch
                  :on-loading (vui-async-callback (v)
                                (vui-set-state :loading v)))))

(defun octocat-actions-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current Actions page buffer."
  (interactive)
  (unless octocat-vui-list--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-actions--page
                              :repo octocat-vui-list--repo
                              :current-branch (plist-get (octocat--head-info) :branch))
               (buffer-name))))

(define-derived-mode octocat-actions-mode octocat-vui-list-mode "Octocat-Actions"
  "Major mode for the Actions page of a repository.

\\{octocat-actions-mode-map}"
  :group 'octocat
  (setq-local revert-buffer-function #'octocat-actions-refresh))

(provide 'octocat-actions)
;;; octocat-actions.el ends here
