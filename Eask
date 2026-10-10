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
(depends-on "consult"       "1.0")

;; octocat-repo.el renders its buffer with vui.el instead of magit-section
;; (see octocat-repo.el's Commentary).  vui.el is not yet on MELPA/GNU ELPA,
;; so it is pulled straight from its GitHub repo; :files pulls in every
;; top-level .el (vui.el, vui-components.el, vui-layout.el) as one package.
(depends-on "vui" :repo "d12frosted/vui.el" :fetcher 'github
            :files '("*.el"))

;; evil is an optional runtime integration (see octocat-evil.el) and is
;; therefore NOT listed in octocat.el's Package-Requires header.  It is
;; needed here only so `test/octocat-evil-repo-tests.el' can exercise the
;; real Evil keymap machinery in CI.
(development
 (depends-on "evil"))
