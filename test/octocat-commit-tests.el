;;; octocat-commit-tests.el --- ERT tests for octocat-commit.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-commit-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-commit-test-skeleton ()
  "The commit skeleton keeps its grey bars within WIDTH."
  (let ((text (octocat-commit--skeleton 30)))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 29)))))

(provide 'octocat-commit-tests)
;;; octocat-commit-tests.el ends here
