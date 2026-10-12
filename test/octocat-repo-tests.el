;;; octocat-repo-tests.el --- ERT tests for octocat-repo.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-repo-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defmacro octocat-repo-tests--with-remote (url &rest body)
  "Evaluate BODY with `shell-command-to-string' mocked to return URL."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'shell-command-to-string) (lambda (_) ,url)))
     ,@body))

(ert-deftest octocat-repo-test-ssh ()
  "Parse SSH remote URL."
  (octocat-repo-tests--with-remote "git@github.com:owner/repo.git"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-ssh-no-suffix ()
  "Parse SSH remote URL without .git suffix."
  (octocat-repo-tests--with-remote "git@github.com:owner/repo"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-https ()
  "Parse HTTPS remote URL."
  (octocat-repo-tests--with-remote "https://github.com/owner/repo.git"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-https-no-suffix ()
  "Parse HTTPS remote URL without .git suffix."
  (octocat-repo-tests--with-remote "https://github.com/owner/repo"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-no-remote ()
  "Signal user-error when no origin remote is found."
  (octocat-repo-tests--with-remote ""
    (should-error (octocat-repo--current-repo) :type 'user-error)))

(ert-deftest octocat-repo-test-parse-summary-fork ()
  "A fork's summary carries its parent, default branch and counts."
  (should (equal (octocat-repo--parse-summary
                  "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\"},\"parent\":{\"nameWithOwner\":\"up/stream\"},\"issues\":{\"totalCount\":3},\"pullRequests\":{\"totalCount\":2}}}}")
                 '(:default-branch "main" :fork-parent "up/stream"
                   :open-issues 3 :open-prs 2))))

(ert-deftest octocat-repo-test-parse-summary-empty-repo ()
  "A non-fork with no default branch yields nils, not errors."
  (should (equal (octocat-repo--parse-summary
                  "{\"data\":{\"repository\":{\"defaultBranchRef\":null,\"parent\":null,\"issues\":{\"totalCount\":0},\"pullRequests\":{\"totalCount\":0}}}}")
                 '(:default-branch nil :fork-parent nil
                   :open-issues 0 :open-prs 0))))

(ert-deftest octocat-repo-test-state-label ()
  "State labels are fixed-width words; only open PRs can be drafts."
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN")) "open  "))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "CLOSED")) "closed"))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "MERGED" t)) "merged"))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN" t)) "draft "))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN" :false)) "open  ")))

(provide 'octocat-repo-tests)
;;; octocat-repo-tests.el ends here
