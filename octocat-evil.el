;;; octocat-evil.el --- Evil keybindings for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Optional Evil integration for octocat.el.  Loaded automatically by
;; octocat.el when `evil-mode' is active; do not load this file
;; directly.
;;
;; Defines `octocat-evil-setup', which installs normal-state bindings
;; for `octocat-mode-map', `octocat-pr-mode-map', and
;; `octocat-commit-mode-map'.

;;; Code:

(declare-function evil-get-auxiliary-keymap "evil-core" (keymap state &optional create))
(declare-function evil-define-key*          "evil-core" (state keymap &rest bindings))
(declare-function evil-normalize-keymaps    "evil-core" (&optional hook))

(defvar octocat-mode-map)
(defvar octocat-pr-mode-map)
(defvar octocat-commit-mode-map)
(defvar octocat-issue-mode-map)

(declare-function octocat-visit          "octocat"        ())
(declare-function octocat-browse         "octocat"        ())
(declare-function octocat-pr-refresh     "octocat-pr"     (&optional _ignore-auto _noconfirm))
(declare-function octocat-commit-refresh "octocat-commit" (&optional _ignore-auto _noconfirm))
(declare-function octocat-issue-refresh  "octocat-issue"  (&optional _ignore-auto _noconfirm))


;;;###autoload
(defun octocat-evil-setup ()
  "Install Evil normal-state keybindings for all octocat modes."
  ;; ── octocat-mode ──────────────────────────────────────────────────────
  ;; Bind RET in both normal and motion states: evil-ret lives in
  ;; evil-motion-state-map, which normal state inherits.  Auxiliary-keymap
  ;; bindings added via evil-define-key* sit below the built-in state maps
  ;; in the lookup order, so we must shadow evil-ret in motion state as well
  ;; to ensure RET actually dispatches to octocat-visit.
  (evil-define-key* 'normal octocat-mode-map
    (kbd "RET")     #'octocat-visit
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window)
  (evil-define-key* 'motion octocat-mode-map
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

  ;; ── octocat-issue-mode ────────────────────────────────────────────────
  ;; Same auxiliary keymap cleanup as above.
  (let ((aux (evil-get-auxiliary-keymap octocat-issue-mode-map 'normal t)))
    (define-key aux (kbd "g") nil))
  (evil-define-key* 'normal octocat-issue-mode-map
    (kbd "o")       #'octocat-browse
    (kbd "C-c C-o") #'octocat-browse
    (kbd "q")       #'quit-window
    (kbd "gr")      #'octocat-issue-refresh)

  ;; Refresh all octocat keymaps so the new bindings take effect in any
  ;; already-open buffers.
  (evil-normalize-keymaps))

(provide 'octocat-evil)
;;; octocat-evil.el ends here
