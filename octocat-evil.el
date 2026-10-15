;;; octocat-evil.el --- Evil keybindings for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Optional Evil integration for octocat.el.  Loaded automatically by
;; octocat.el when `evil-mode' is active; do not load this file
;; directly.
;;
;; Defines `octocat-evil-setup', which installs normal-state bindings
;; for `octocat-mode-map' (dashboard), `octocat-repo-mode-map' (repo
;; view), `octocat-pr-mode-map', `octocat-commit-mode-map', and others.

;;; Code:

(declare-function evil-define-key*          "evil-core" (state keymap &rest bindings))
(declare-function evil-normalize-keymaps    "evil-core" (&optional hook))
(declare-function evil-insert-state         "evil-states" (&optional arg))
(declare-function evil-normal-state         "evil-states" (&optional arg))
(declare-function evil-local-set-key        "evil-core" (state key def))
(declare-function evil-ret                  "evil-commands" (&optional count))
(declare-function evil-backward-char        "evil-commands" (&optional count crosslines noerror))
(declare-function evil-forward-char         "evil-commands" (&optional count crosslines noerror))

(defvar octocat-mode-map)
(defvar octocat-repo-mode-map)
(defvar octocat-user-mode-map)
(declare-function octocat-user-browse "octocat-user" ())
(defvar octocat-pr-list-mode-map)
(defvar octocat-issue-list-mode-map)
(defvar octocat-actions-mode-map)
(defvar octocat-pr-mode-map)
(defvar octocat-commit-mode-map)
(defvar octocat-checks-mode-map)
(defvar octocat-pr-diff-mode-map)
(defvar octocat-issue-mode-map)
(defvar octocat-workflow-mode-map)
(defvar octocat-run-mode-map)
(defvar octocat-job-mode-map)
(defvar octocat-tree-mode-map)
(defvar octocat-file-mode-map)
(defvar octocat-file-log-mode-map)

(declare-function octocat-tree-open          "octocat-tree"      ())
(declare-function octocat-tree-find-file     "octocat-tree"      ())
(declare-function octocat-tree-switch-branch "octocat-tree"      ())
(declare-function octocat-tree-collapse-or-up "octocat-tree"    ())
(declare-function octocat-tree--entry-at-point-p "octocat-tree" ())
(declare-function octocat-tree-visit         "octocat-tree"      ())
(declare-function octocat-tree-browse        "octocat-tree"      ())
(declare-function octocat-tree-refresh       "octocat-tree"      (&optional _ignore-auto _noconfirm))
(declare-function octocat-file-refresh       "octocat-tree"      (&optional _ignore-auto _noconfirm))
(declare-function octocat-file-browse        "octocat-tree"      ())
(declare-function octocat-file-log-open      "octocat-tree"      ())
(declare-function octocat-file-log-refresh   "octocat-tree"      (&optional _ignore-auto _noconfirm))
(declare-function octocat-file-log-visit     "octocat-tree"      ())
(declare-function octocat-file-log-browse    "octocat-tree"      ())
(declare-function octocat-switch-repo        "octocat-core"      ())
(declare-function octocat-toggle-markdown    "octocat-core"      ())
(declare-function octocat-pr-refresh         "octocat-pr"        (&optional _ignore-auto _noconfirm))
(declare-function octocat-pr-add-comment     "octocat-pr"        ())
(declare-function octocat-pr-edit-body       "octocat-pr"        ())
(declare-function octocat-pr-edit            "octocat-pr"        ())
(declare-function octocat-pr-merge           "octocat-pr"        ())
(declare-function octocat-commit-refresh     "octocat-commit"    (&optional _ignore-auto _noconfirm))
(declare-function octocat-pr-diff-browse    "octocat-pr-diff"   ())
(declare-function octocat-pr-diff-review    "octocat-pr-diff"   ())
(declare-function octocat-commit-browse     "octocat-commit"    ())
(declare-function octocat-checks-browse     "octocat-checks"    ())
(declare-function octocat-checks-refresh    "octocat-checks"    (&optional _ignore-auto _noconfirm))
(declare-function octocat-issue-refresh      "octocat-issue"     (&optional _ignore-auto _noconfirm))
(declare-function octocat-issue-add-comment  "octocat-issue"     ())
(declare-function octocat-issue-edit-body    "octocat-issue"     ())
(declare-function octocat-issue-browse       "octocat-issue"     ())
(declare-function octocat-pr-browse          "octocat-pr"        ())
(declare-function octocat-issue-edit         "octocat-issue"     ())
(declare-function octocat-feed-load-more     "octocat"           ())
(declare-function octocat-dashboard-browse   "octocat"           ())
(declare-function octocat-repo-browse        "octocat-repo"      ())
(declare-function octocat-repo-switch-branch "octocat-repo"      ())
(declare-function octocat-vui-list-browse    "octocat-vui"       ())
(declare-function octocat-vui-list-filter    "octocat-vui"       ())
(declare-function octocat-vui-list-edit-query "octocat-vui"      ())
(defvar octocat-vui-list-query-submit-hook)
(defvar octocat-vui-list-mode-hook)
(defvar evil-local-mode)
(declare-function octocat-vui-list--query-widget "octocat-vui" ())

(defun octocat-evil-list-edit-query ()
  "Move into the query field of the current list, in insert state."
  (interactive)
  (octocat-vui-list-edit-query)
  (evil-insert-state))

(defun octocat-evil-list-ret ()
  "Start editing the query field when on it, else `evil-ret'.
`evil-ret' would treat the field as a button without an action and
insert a newline into it."
  (interactive)
  (let ((widget (octocat-vui-list--query-widget)))
    (if (and widget (eq (widget-field-at (point)) widget))
        (octocat-evil-list-edit-query)
      (call-interactively #'evil-ret))))

(defconst octocat-evil--list-bindings
  '(("RET"     . octocat-evil-list-ret)
    ("C-c C-o" . octocat-vui-list-browse)
    ("C-c C-r" . octocat-switch-repo)
    ("C-c C-s" . octocat-search-repo)
    ("gs"      . octocat-search-repo)
    ("gr"      . revert-buffer)
    ("F"       . octocat-vui-list-filter)
    ("q"       . quit-window))
  "Normal-state bindings of the PR, issue and Actions list pages.")

(defun octocat-evil--list-setup ()
  "Bind `octocat-evil--list-bindings' in the current list buffer.
Buffer-local, as the query field's keymap replaces the mode's keymap,
and with it the mode's Evil bindings: after ESC in the field, `q'
would start recording a macro."
  (pcase-dolist (`(,key . ,def) octocat-evil--list-bindings)
    (evil-local-set-key 'normal (kbd key) def)))

(defun octocat-evil--list-query-submitted ()
  "Leave insert state once the query field is submitted."
  (when evil-local-mode
    (evil-normal-state)))

(declare-function octocat-workflow-browse    "octocat-workflow"  ())
(declare-function octocat-workflow-refresh   "octocat-workflow"  (&optional _ignore-auto _noconfirm))
(declare-function octocat-run-browse         "octocat-run"       ())
(declare-function octocat-run-refresh        "octocat-run"       (&optional _ignore-auto _noconfirm))
(declare-function octocat-job-browse         "octocat-job"       ())
(declare-function octocat-job-refresh        "octocat-job"       (&optional _ignore-auto _noconfirm))

(defun octocat-evil-tree-l ()
  "Open the file or toggle the directory at point, as in treemacs-evil.
Off an entry, such as on the header, move right."
  (interactive)
  (if (octocat-tree--entry-at-point-p)
      (octocat-tree-visit)
    (call-interactively #'evil-forward-char)))

(defun octocat-evil-tree-h ()
  "Collapse the directory at point, or move to its parent, as in treemacs-evil.
Off an entry, such as on the header, move left."
  (interactive)
  (if (octocat-tree--entry-at-point-p)
      (octocat-tree-collapse-or-up)
    (call-interactively #'evil-backward-char)))


;;;###autoload
(defun octocat-evil-setup ()
  "Install Evil normal-state keybindings for all octocat modes."
  ;; ── octocat-mode (dashboard) ──────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode below: each row binds its own
  ;; RET via a `keymap' text property, so only the global bindings go here.
  (evil-define-key* 'normal octocat-mode-map
    (kbd "+")       #'octocat-feed-load-more
    (kbd "C-c C-o") #'octocat-dashboard-browse
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'revert-buffer
    (kbd "q")       #'quit-window)

  ;; ── octocat-repo-mode ─────────────────────────────────────────────────
  ;; Each row binds its own RET via a `keymap' text property, so only the
  ;; global bindings go here.
  (evil-define-key* 'normal octocat-repo-mode-map
    (kbd "C-c C-o") #'octocat-repo-browse
    (kbd "C-c C-f") #'octocat-tree-find-file
    (kbd "C-c C-b") #'octocat-repo-switch-branch
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'revert-buffer
    (kbd "q")       #'quit-window)

  ;; ── octocat-user-mode ─────────────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode: rows bind their own RET.
  (evil-define-key* 'normal octocat-user-mode-map
    (kbd "C-c C-o") #'octocat-user-browse
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "gr")      #'revert-buffer
    (kbd "q")       #'quit-window)

  ;; ── PR / issue list pages and the Actions page ──────────────────────────────────
  ;; Normal state is bound per buffer by `octocat-evil--list-setup'.
  ;; Motion state on each derived mode's own map: Evil's auxiliary keymaps
  ;; are not reliably found through the parent `octocat-vui-list-mode-map'.
  (dolist (map (list octocat-pr-list-mode-map
                     octocat-issue-list-mode-map
                     octocat-actions-mode-map))
    (evil-define-key* 'motion map
      (kbd "F")       #'octocat-vui-list-filter))
  (add-hook 'octocat-vui-list-mode-hook #'octocat-evil--list-setup)
  (add-hook 'octocat-vui-list-query-submit-hook #'octocat-evil--list-query-submitted)

  ;; ── octocat-pr-mode ───────────────────────────────────────────────────
  ;; vui.el-rendered like octocat-issue-mode: row RET actions come from
  ;; per-row keymaps, so only the global commands are bound here.
  (evil-define-key* 'normal octocat-pr-mode-map
    (kbd "C-c C-o") #'octocat-pr-browse
    (kbd "C-c C-a") #'octocat-pr-add-comment
    (kbd "C-c C-e") #'octocat-pr-edit
    (kbd "C-c C-m") #'octocat-pr-merge
    (kbd "C-c C-v") #'octocat-toggle-markdown
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-pr-refresh
    (kbd "q")       #'quit-window)

  ;; ── octocat-commit-mode ───────────────────────────────────────────────
  ;; vui.el-rendered like octocat-pr-diff-mode: row RET actions come from
  ;; per-row keymaps, so only the global commands are bound here.
  (evil-define-key* 'normal octocat-commit-mode-map
    (kbd "C-c C-o") #'octocat-commit-browse
    (kbd "C-c C-v") #'octocat-toggle-markdown
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-commit-refresh
    (kbd "q")       #'quit-window)

  ;; ── octocat-checks-mode ───────────────────────────────────────────────
  (evil-define-key* 'normal octocat-checks-mode-map
    (kbd "C-c C-o") #'octocat-checks-browse
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-checks-refresh
    (kbd "q")       #'quit-window)

  ;; ── octocat-pr-diff-mode ──────────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode, so only the global commands
  ;; are bound here.
  (evil-define-key* 'normal octocat-pr-diff-mode-map
    (kbd "C-c C-a") #'octocat-pr-diff-review
    (kbd "C-c C-o") #'octocat-pr-diff-browse
    (kbd "C-c C-v") #'octocat-toggle-markdown
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'revert-buffer
    (kbd "q")       #'quit-window)

  ;; ── octocat-issue-mode ────────────────────────────────────────────────
  ;; vui.el-rendered like octocat-repo-mode: row RET actions come from
  ;; per-row keymaps, so only the global commands are bound here.
  (evil-define-key* 'normal octocat-issue-mode-map
    (kbd "C-c C-o") #'octocat-issue-browse
    (kbd "C-c C-a") #'octocat-issue-add-comment
    (kbd "C-c C-e") #'octocat-issue-edit
    (kbd "C-c C-v") #'octocat-toggle-markdown
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-issue-refresh
    (kbd "q")       #'quit-window)

  ;; ── octocat-workflow-mode ─────────────────────────────────────────────
  (evil-define-key* 'normal octocat-workflow-mode-map
    (kbd "C-c C-o") #'octocat-workflow-browse
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-workflow-refresh
    (kbd "q")       #'quit-window)

  ;; ── octocat-run-mode ──────────────────────────────────────────────────
  (evil-define-key* 'normal octocat-run-mode-map
    (kbd "C-c C-o") #'octocat-run-browse
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-run-refresh
    (kbd "q")       #'quit-window)

  ;; ── octocat-job-mode ──────────────────────────────────────────────────
  (evil-define-key* 'normal octocat-job-mode-map
    (kbd "C-c C-o") #'octocat-job-browse
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "gr")      #'octocat-job-refresh
    (kbd "q")       #'quit-window)

  ;; ── octocat-tree-mode ─────────────────────────────────────────────────
  ;; TAB is left to the buttons' own keymaps: it walks them, which
  ;; `octocat-tree-toggle-or-forward' does in normal state.
  (evil-define-key* 'normal octocat-tree-mode-map
    (kbd "RET")     #'octocat-tree-visit
    (kbd "l")       #'octocat-evil-tree-l
    (kbd "h")       #'octocat-evil-tree-h
    (kbd "C-c C-f") #'octocat-tree-find-file
    (kbd "C-c C-b") #'octocat-tree-switch-branch
    (kbd "C-c C-o") #'octocat-tree-browse
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "o")       #'octocat-tree-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-tree-refresh)
  (evil-define-key* 'motion octocat-tree-mode-map
    (kbd "RET")     #'octocat-tree-visit)

  ;; ── octocat-file-mode ─────────────────────────────────────────────────
  (evil-define-key* 'normal octocat-file-mode-map
    (kbd "C-c C-o") #'octocat-file-browse
    (kbd "o")       #'octocat-file-browse
    (kbd "C-c C-f") #'octocat-tree-find-file
    (kbd "C-c C-l") #'octocat-file-log-open
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-file-refresh)
  (evil-define-key* 'motion octocat-file-mode-map
    (kbd "gr")      #'octocat-file-refresh)

  ;; ── octocat-file-log-mode ─────────────────────────────────────────────
  (evil-define-key* 'normal octocat-file-log-mode-map
    (kbd "RET")     #'octocat-file-log-visit
    (kbd "C-c C-o") #'octocat-file-log-browse
    (kbd "o")       #'octocat-file-log-browse
    (kbd "C-c C-r") #'octocat-switch-repo
    (kbd "C-c C-s") #'octocat-search-repo
    (kbd "gs")      #'octocat-search-repo
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-file-log-refresh)
  (evil-define-key* 'motion octocat-file-log-mode-map
    (kbd "RET")     #'octocat-file-log-visit)

  ;; Refresh all octocat keymaps so the new bindings take effect in any
  ;; already-open buffers.
  (evil-normalize-keymaps))

(provide 'octocat-evil)
;;; octocat-evil.el ends here
