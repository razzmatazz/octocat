;;; octocat-evil.el --- Evil keybindings for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Optional Evil integration for octocat.el.  Loaded automatically by
;; octocat.el when `evil-mode' is active; do not load this file
;; directly.
;;
;; Defines `octocat-evil-setup', which installs normal-state bindings
;; for `octocat-mode-map' (dashboard), `octocat-repo-mode-map' (repo
;; view), `octocat-pr-mode-map', `octocat-commit-mode-map', and others.

;;; Code:

(declare-function evil-get-auxiliary-keymap "evil-core" (keymap state &optional create ignore-parent))
(declare-function evil-define-key*          "evil-core" (state keymap &rest bindings))
(declare-function evil-normalize-keymaps    "evil-core" (&optional hook))

(defvar octocat-mode-map)
(defvar octocat-repo-mode-map)
(defvar octocat-pr-mode-map)
(defvar octocat-commit-mode-map)
(defvar octocat-pr-diff-mode-map)
(defvar octocat-issue-mode-map)
(defvar octocat-workflow-mode-map)
(defvar octocat-run-mode-map)
(defvar octocat-job-mode-map)
(defvar octocat-tree-mode-map)
(defvar octocat-file-mode-map)

(declare-function octocat-visit              "octocat"           ())
(declare-function octocat-browse             "octocat"           ())
(declare-function octocat-tree-open          "octocat-tree"      ())
(declare-function octocat-tree-visit         "octocat-tree"      ())
(declare-function octocat-tree-browse        "octocat-tree"      ())
(declare-function octocat-tree-expand        "octocat-tree"      ())
(declare-function octocat-tree-refresh       "octocat-tree"      (&optional _ignore-auto _noconfirm))
(declare-function octocat-file-refresh       "octocat-tree"      (&optional _ignore-auto _noconfirm))
(declare-function octocat-file-browse        "octocat-tree"      ())
(declare-function octocat-toggle-markdown    "octocat-core"      ())
(declare-function octocat-pr-refresh         "octocat-pr"        (&optional _ignore-auto _noconfirm))
(declare-function octocat-pr-add-comment     "octocat-pr"        ())
(declare-function octocat-pr-edit-body       "octocat-pr"        ())
(declare-function octocat-pr-edit            "octocat-pr"        ())
(declare-function octocat-commit-refresh     "octocat-commit"    (&optional _ignore-auto _noconfirm))
(declare-function octocat-pr-diff-refresh   "octocat-pr-diff"   (&optional _ignore-auto _noconfirm))
(declare-function octocat-issue-refresh      "octocat-issue"     (&optional _ignore-auto _noconfirm))
(declare-function octocat-issue-add-comment  "octocat-issue"     ())
(declare-function octocat-issue-edit-body    "octocat-issue"     ())
(declare-function octocat-issue-edit         "octocat-issue"     ())
(declare-function octocat-feed-load-more     "octocat"           ())
(declare-function octocat-repo-load-more     "octocat-repo"      ())
(declare-function octocat-workflow-load-more "octocat-workflow"  ())
(declare-function octocat-workflow-refresh   "octocat-workflow"  (&optional _ignore-auto _noconfirm))
(declare-function octocat-workflow-visit     "octocat-workflow"  ())
(declare-function octocat-run-refresh             "octocat-run" (&optional _ignore-auto _noconfirm))
(declare-function octocat-run-visit               "octocat-run" ())
(declare-function octocat-run-visit-or-download   "octocat-run" ())
(declare-function octocat-job-refresh             "octocat-job" (&optional _ignore-auto _noconfirm))
(declare-function octocat-job-download-artifact   "octocat-job" ())


;;;###autoload
(defun octocat-evil-setup ()
  "Install Evil normal-state keybindings for all octocat modes."
  ;; ── octocat-mode (dashboard) ──────────────────────────────────────────
  ;; Bind RET in both normal and motion states: evil-ret lives in
  ;; evil-motion-state-map, which normal state inherits.  Auxiliary-keymap
  ;; bindings added via evil-define-key* sit below the built-in state maps
  ;; in the lookup order, so we must shadow evil-ret in motion state as well
  ;; to ensure RET actually dispatches to octocat-visit.
  (evil-define-key* 'normal octocat-mode-map
    (kbd "RET")     #'octocat-visit
    (kbd "+")       #'octocat-feed-load-more
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window)
  (evil-define-key* 'motion octocat-mode-map
    (kbd "RET")     #'octocat-visit)

  ;; ── octocat-repo-mode ─────────────────────────────────────────────────
  (evil-define-key* 'normal octocat-repo-mode-map
    (kbd "RET")     #'octocat-visit
    (kbd "+")       #'octocat-repo-load-more
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window)
  (evil-define-key* 'motion octocat-repo-mode-map
    (kbd "RET")     #'octocat-visit)

  ;; ── octocat-pr-mode ───────────────────────────────────────────────────
  ;; Use define-key directly so all bindings (including RET) land in the
  ;; same aux keymap slot.  See AGENTS.md "evil-define-key* aux-keymap slot
  ;; divergence" for why evil-define-key* is not used here.
  ;; The fourth argument t (IGNORE-PARENT) is critical: without it,
  ;; evil-get-auxiliary-keymap returns the *parent* (magit-section-mode-map)
  ;; aux keymap because child mode maps inherit the parent's normal-state slot.
  ;; All define-key calls would then mutate the shared parent keymap, bleeding
  ;; octocat bindings into every magit buffer.
  (let ((aux   (evil-get-auxiliary-keymap octocat-pr-mode-map 'normal t t))
        (aux-m (evil-get-auxiliary-keymap octocat-pr-mode-map 'motion t t)))
    (define-key aux   (kbd "g")     nil)
    (define-key aux   (kbd "RET")   #'octocat-visit)
    (define-key aux   (kbd "C-c C-o") #'octocat-browse)
    (define-key aux   (kbd "C-c C-a") #'octocat-pr-add-comment)
    (define-key aux   (kbd "C-c C-e") #'octocat-pr-edit)
    (define-key aux   (kbd "C-c C-v") #'octocat-toggle-markdown)
    (define-key aux   (kbd "q")     #'quit-window)
    (define-key aux   (kbd "gr")    #'octocat-pr-refresh)
    (define-key aux-m (kbd "RET")   #'octocat-visit))

  ;; ── octocat-commit-mode ───────────────────────────────────────────────
  ;; Use define-key directly on the aux keymap retrieved by
  ;; evil-get-auxiliary-keymap for every binding, not evil-define-key*.
  ;; See AGENTS.md "evil-define-key* aux-keymap slot divergence" for why.
  (let ((aux   (evil-get-auxiliary-keymap octocat-commit-mode-map 'normal t t))
        (aux-m (evil-get-auxiliary-keymap octocat-commit-mode-map 'motion t t)))
    (define-key aux   (kbd "g")     nil)
    (define-key aux   (kbd "RET")   #'octocat-visit)
    (define-key aux   (kbd "C-c C-o") #'octocat-browse)
    (define-key aux   (kbd "C-c C-v") #'octocat-toggle-markdown)
    (define-key aux   (kbd "q")     #'quit-window)
    (define-key aux   (kbd "gr")    #'octocat-commit-refresh)
    (define-key aux-m (kbd "RET")   #'octocat-visit))

  ;; ── octocat-pr-diff-mode ──────────────────────────────────────────────
  (let ((aux (evil-get-auxiliary-keymap octocat-pr-diff-mode-map 'normal t t)))
    (define-key aux (kbd "g")       nil)
    (define-key aux (kbd "C-c C-o") #'octocat-browse)
    (define-key aux (kbd "q")       #'quit-window)
    (define-key aux (kbd "gr")      #'octocat-pr-diff-refresh))

  ;; ── octocat-issue-mode ────────────────────────────────────────────────
  (let ((aux   (evil-get-auxiliary-keymap octocat-issue-mode-map 'normal t t))
        (aux-m (evil-get-auxiliary-keymap octocat-issue-mode-map 'motion t t)))
    (define-key aux   (kbd "g")     nil)
    (define-key aux   (kbd "RET")   #'octocat-visit)
    (define-key aux   (kbd "C-c C-o") #'octocat-browse)
    (define-key aux   (kbd "C-c C-a") #'octocat-issue-add-comment)
    (define-key aux   (kbd "C-c C-e") #'octocat-issue-edit)
    (define-key aux   (kbd "C-c C-v") #'octocat-toggle-markdown)
    (define-key aux   (kbd "q")     #'quit-window)
    (define-key aux   (kbd "gr")    #'octocat-issue-refresh)
    (define-key aux-m (kbd "RET")   #'octocat-visit))

  ;; ── octocat-workflow-mode ─────────────────────────────────────────────
  (let ((aux   (evil-get-auxiliary-keymap octocat-workflow-mode-map 'normal t t))
        (aux-m (evil-get-auxiliary-keymap octocat-workflow-mode-map 'motion t t)))
    (define-key aux   (kbd "g")     nil)
    (define-key aux   (kbd "RET")   #'octocat-workflow-visit)
    (define-key aux   (kbd "+")     #'octocat-workflow-load-more)
    (define-key aux   (kbd "C-c C-o") #'octocat-browse)
    (define-key aux   (kbd "q")     #'quit-window)
    (define-key aux   (kbd "gr")    #'octocat-workflow-refresh)
    (define-key aux-m (kbd "RET")   #'octocat-workflow-visit))

  ;; ── octocat-run-mode ──────────────────────────────────────────────────
  (let ((aux   (evil-get-auxiliary-keymap octocat-run-mode-map 'normal t t))
        (aux-m (evil-get-auxiliary-keymap octocat-run-mode-map 'motion t t)))
    (define-key aux   (kbd "g")     nil)
    (define-key aux   (kbd "RET")   #'octocat-run-visit-or-download)
    (define-key aux   (kbd "C-c C-o") #'octocat-browse)
    (define-key aux   (kbd "q")     #'quit-window)
    (define-key aux   (kbd "gr")    #'octocat-run-refresh)
    (define-key aux-m (kbd "RET")   #'octocat-run-visit-or-download))

  ;; ── octocat-job-mode ──────────────────────────────────────────────────
  (let ((aux   (evil-get-auxiliary-keymap octocat-job-mode-map 'normal t t))
        (aux-m (evil-get-auxiliary-keymap octocat-job-mode-map 'motion t t)))
    (define-key aux   (kbd "g")     nil)
    (define-key aux   (kbd "RET")   #'octocat-job-download-artifact)
    (define-key aux   (kbd "C-c C-o") #'octocat-browse)
    (define-key aux   (kbd "q")     #'quit-window)
    (define-key aux   (kbd "gr")    #'octocat-job-refresh)
    (define-key aux-m (kbd "RET")   #'octocat-job-download-artifact))

  ;; ── octocat-tree-mode ─────────────────────────────────────────────────
  ;; Derives from special-mode (not magit-section-mode): evil-define-key* is safe.
  (evil-define-key* 'normal octocat-tree-mode-map
    (kbd "RET")     #'octocat-tree-visit
    (kbd "TAB")     #'octocat-tree-expand
    [tab]           #'octocat-tree-expand
    (kbd "C-c C-o") #'octocat-tree-browse
    (kbd "o")       #'octocat-tree-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-tree-refresh)
  (evil-define-key* 'motion octocat-tree-mode-map
    (kbd "RET")     #'octocat-tree-visit
    (kbd "TAB")     #'octocat-tree-expand
    [tab]           #'octocat-tree-expand)

  ;; ── octocat-file-mode ─────────────────────────────────────────────────
  ;; Derives from special-mode (not magit-section-mode): evil-define-key* is safe.
  (evil-define-key* 'normal octocat-file-mode-map
    (kbd "C-c C-o") #'octocat-file-browse
    (kbd "o")       #'octocat-file-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-file-refresh)
  (evil-define-key* 'motion octocat-file-mode-map
    (kbd "gr")      #'octocat-file-refresh)

  ;; Refresh all octocat keymaps so the new bindings take effect in any
  ;; already-open buffers.
  (evil-normalize-keymaps))

(provide 'octocat-evil)
;;; octocat-evil.el ends here
