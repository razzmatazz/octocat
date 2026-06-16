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

(declare-function evil-get-auxiliary-keymap "evil-core" (keymap state &optional create))
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

(declare-function octocat-visit              "octocat"           ())
(declare-function octocat-browse             "octocat"           ())
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
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window)
  (evil-define-key* 'motion octocat-mode-map
    (kbd "RET")     #'octocat-visit)

  ;; ── octocat-repo-mode ─────────────────────────────────────────────────
  (evil-define-key* 'normal octocat-repo-mode-map
    (kbd "RET")     #'octocat-visit
    (kbd "+")       #'octocat-repo-load-more
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window)
  (evil-define-key* 'motion octocat-repo-mode-map
    (kbd "RET")     #'octocat-visit)

  ;; ── octocat-pr-mode ───────────────────────────────────────────────────
  ;; Clear any stale "g" binding from evil's auxiliary keymap so "gr" can
  ;; be registered as a two-key sequence without conflict.
  (let ((aux (evil-get-auxiliary-keymap octocat-pr-mode-map 'normal t)))
    (define-key aux (kbd "g") nil))
  (evil-define-key* 'normal octocat-pr-mode-map
    (kbd "RET")     #'octocat-visit
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "c")       #'octocat-pr-add-comment
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-pr-refresh)
  (evil-define-key* 'motion octocat-pr-mode-map
    (kbd "RET")     #'octocat-visit)

  ;; ── octocat-commit-mode ───────────────────────────────────────────────
  ;; Same auxiliary keymap cleanup as above.
  (let ((aux (evil-get-auxiliary-keymap octocat-commit-mode-map 'normal t)))
    (define-key aux (kbd "g") nil))
  (evil-define-key* 'normal octocat-commit-mode-map
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-commit-refresh)

  ;; ── octocat-pr-diff-mode ──────────────────────────────────────────────
  (let ((aux (evil-get-auxiliary-keymap octocat-pr-diff-mode-map 'normal t)))
    (define-key aux (kbd "g") nil))
  (evil-define-key* 'normal octocat-pr-diff-mode-map
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-pr-diff-refresh)

  ;; ── octocat-issue-mode ────────────────────────────────────────────────
  ;; Same auxiliary keymap cleanup as above.
  (let ((aux (evil-get-auxiliary-keymap octocat-issue-mode-map 'normal t)))
    (define-key aux (kbd "g") nil))
  (evil-define-key* 'normal octocat-issue-mode-map
    (kbd "RET")     #'octocat-visit
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "c")       #'octocat-issue-add-comment
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-issue-refresh)
  (evil-define-key* 'motion octocat-issue-mode-map
    (kbd "RET")     #'octocat-visit)

  ;; ── octocat-workflow-mode ─────────────────────────────────────────────
  ;; Same auxiliary keymap cleanup as above.
  (let ((aux (evil-get-auxiliary-keymap octocat-workflow-mode-map 'normal t)))
    (define-key aux (kbd "g") nil))
  (evil-define-key* 'normal octocat-workflow-mode-map
    (kbd "RET")     #'octocat-workflow-visit
    (kbd "+")       #'octocat-workflow-load-more
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-workflow-refresh)
  (evil-define-key* 'motion octocat-workflow-mode-map
    (kbd "RET")     #'octocat-workflow-visit)

  ;; ── octocat-run-mode ──────────────────────────────────────────────────
  ;; Same auxiliary keymap cleanup as above.
  (let ((aux (evil-get-auxiliary-keymap octocat-run-mode-map 'normal t)))
    (define-key aux (kbd "g") nil))
  (evil-define-key* 'normal octocat-run-mode-map
    (kbd "RET")     #'octocat-run-visit-or-download
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-run-refresh)
  (evil-define-key* 'motion octocat-run-mode-map
    (kbd "RET")     #'octocat-run-visit-or-download)

  ;; ── octocat-job-mode ──────────────────────────────────────────────────
  (let ((aux (evil-get-auxiliary-keymap octocat-job-mode-map 'normal t)))
    (define-key aux (kbd "g") nil))
  (evil-define-key* 'normal octocat-job-mode-map
    (kbd "RET")     #'octocat-job-download-artifact
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-job-refresh)
  (evil-define-key* 'motion octocat-job-mode-map
    (kbd "RET")     #'octocat-job-download-artifact)

  ;; Refresh all octocat keymaps so the new bindings take effect in any
  ;; already-open buffers.
  (evil-normalize-keymaps))

(provide 'octocat-evil)
;;; octocat-evil.el ends here
