;;; octocat-workflow-tests.el --- ERT tests for octocat-workflow.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-workflow-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-workflow-test-url ()
  "A workflow's page is named by its file, as on GitHub; by ID when unknown."
  (should (equal (octocat-workflow--url "o/r" 7 ".github/workflows/ci.yml")
                 "https://github.com/o/r/actions/workflows/ci.yml"))
  (should (equal (octocat-workflow--url "o/r" 7 nil)
                 "https://github.com/o/r/actions/workflows/7")))

(provide 'octocat-workflow-tests)
;;; octocat-workflow-tests.el ends here
