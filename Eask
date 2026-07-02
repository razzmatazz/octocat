;; -*- mode: eask; lexical-binding: t -*-

(package "octocat"
         "0.1.0"
         "GitHub Client powered by the gh CLI")

(website-url "https://github.com/octocat.el/octocat.el")
(keywords "tools" "vc" "github")

(package-file "octocat.el")

(source "gnu")
(source "melpa")

(depends-on "emacs"         "29.1")
(depends-on "magit-section" "3.0")
(depends-on "markdown-mode" "2.0")
(depends-on "consult"       "1.0")

;; evil is an optional runtime integration (see octocat-evil.el) and is
;; therefore NOT listed in octocat.el's Package-Requires header.  It is
;; needed here only so `test/octocat-evil-repo-tests.el' can exercise the
;; real Evil keymap machinery in CI.
(development
 (depends-on "evil"))
