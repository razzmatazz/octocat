;;; octocat-tests.el --- ERT tests for octocat.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Basic test suite for octocat.el.  Run via:
;;   eask test ert test/octocat-tests.el

;;; Code:

(require 'ert)
(require 'octocat)


;;; octocat--current-repo

(defmacro octocat-tests--with-remote (url &rest body)
  "Evaluate BODY with `shell-command-to-string' mocked to return URL."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'shell-command-to-string) (lambda (_) ,url)))
     ,@body))

(ert-deftest octocat-test-repo-ssh ()
  "Parse SSH remote URL."
  (octocat-tests--with-remote "git@github.com:owner/repo.git"
    (should (equal (octocat--current-repo) "owner/repo"))))

(ert-deftest octocat-test-repo-ssh-no-suffix ()
  "Parse SSH remote URL without .git suffix."
  (octocat-tests--with-remote "git@github.com:owner/repo"
    (should (equal (octocat--current-repo) "owner/repo"))))

(ert-deftest octocat-test-repo-https ()
  "Parse HTTPS remote URL."
  (octocat-tests--with-remote "https://github.com/owner/repo.git"
    (should (equal (octocat--current-repo) "owner/repo"))))

(ert-deftest octocat-test-repo-https-no-suffix ()
  "Parse HTTPS remote URL without .git suffix."
  (octocat-tests--with-remote "https://github.com/owner/repo"
    (should (equal (octocat--current-repo) "owner/repo"))))

(ert-deftest octocat-test-repo-no-remote ()
  "Signal user-error when no origin remote is found."
  (octocat-tests--with-remote ""
    (should-error (octocat--current-repo) :type 'user-error)))

(provide 'octocat-tests)
;;; octocat-tests.el ends here
