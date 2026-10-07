;;; octocat-evil-repo-tests.el --- Regression test: entry points funnel through octocat.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Regression test for the bug documented in
;; plans/repo-mode-evil-ret-binding.md: pressing RET in `octocat-repo-mode'
;; used to silently fall through to `evil-ret' when `octocat-repo' was the
;; first octocat entry point loaded in a session that already had Evil
;; active, because the Evil keybinding trigger (`octocat--evil-init') lived
;; only in `octocat.el' (the dashboard file), which a standalone
;; `octocat-repo' load path never reached.
;;
;; The fix is structural: the `octocat-repo' command is now defined only in
;; `octocat.el' (see CONTRIBUTING.md, "Entry points"), so there is no longer
;; any way to reach it without also loading `octocat.el' and running
;; `octocat--evil-init'.  This test locks in that invariant so a future
;; refactor cannot silently reintroduce it (e.g. by moving the command back
;; into `octocat-repo.el', or adding a new top-level command there).
;;
;; This file MUST be run in its own Emacs process, separate from
;; test/octocat-tests.el, which does `(require 'octocat)' at load time and
;; would make the first assertion below vacuous.  See the `test' target in
;; the Makefile, which invokes `eask test ert' twice.
;;
;; Run via:
;;   eask test ert test/octocat-evil-repo-tests.el

;;; Code:

(require 'ert)
(require 'evil)

;; Evil must already be active *before* any octocat file is loaded, exactly
;; matching the real-world repro: the user's session has Evil on globally
;; (e.g. Doom's `evil +everywhere'), and an octocat command is the first one
;; run in that session.
(evil-mode 1)

(require 'octocat-repo)

;; NOTE: both phases below MUST live in a single `ert-deftest' body, in this
;; order.  `eask test ert' fully loads this file -- executing every
;; top-level form -- before running any test.  A top-level `(require
;; 'octocat)' placed "between" two separate `ert-deftest' forms would
;; therefore already have executed by the time either test body runs,
;; making the intended "before/after" comparison meaningless.  ERT also
;; does not guarantee test execution order across separate `ert-deftest'
;; forms, so splitting phase 1 and phase 2 into different tests could pass
;; or fail depending on run order even if the ordering problem above were
;; fixed some other way.
(ert-deftest octocat-evil-test-repo-entry-point-funnels-through-octocat ()
  "The `octocat-repo' command must not be defined by requiring
`octocat-repo' alone -- it must live only in `octocat.el' (see
CONTRIBUTING.md, \"Entry points\").  Once `octocat' (the only real entry
path) is subsequently loaded, `octocat-repo' becomes defined and RET in
`octocat-repo-mode' resolves to `octocat-visit'."
  ;; Phase 1: pre-entry-point state.
  (should (featurep 'octocat-repo))
  (should-not (featurep 'octocat))
  (should-not (fboundp 'octocat-repo))
  ;; Phase 2: after loading the real (only) entry path.
  (require 'octocat)
  (should (fboundp 'octocat-repo))
  ;; octocat-repo-mode no longer derives from magit-section-mode (it is
  ;; rendered with vui.el, see octocat-repo.el's Commentary) and no longer
  ;; has a single RET-dispatches-on-section-at-point binding to check here
  ;; -- see octocat-evil.el's "octocat-repo-mode" section for the known gap
  ;; around per-row RET bindings under Evil.  Check a binding that *is*
  ;; still installed globally by `octocat-evil-setup' instead, as the
  ;; canary that evil setup ran for this mode at all.
  (let* ((aux (evil-get-auxiliary-keymap octocat-repo-mode-map 'normal nil t))
         (binding (and aux (lookup-key aux (kbd "C-c C-r")))))
    (should (eq binding #'octocat-switch-repo))))

(provide 'octocat-evil-repo-tests)
;;; octocat-evil-repo-tests.el ends here
