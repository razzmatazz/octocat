;;; octocat-checks-tests.el --- ERT tests for octocat-checks.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-checks-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-checks-test-from-rest ()
  "A REST check-run takes the shape of a statusCheckRollup entry."
  (let ((entry (octocat-checks-from-rest
                (json-parse-string
                 "{\"name\":\"test\",\"status\":\"completed\",\"conclusion\":\"success\",\"started_at\":\"2026-01-01T00:00:00Z\",\"completed_at\":null,\"app\":{\"name\":\"GitHub Actions\"}}"))))
    (should (equal (gethash "name" entry) "test"))
    (should (equal (gethash "workflowName" entry) "GitHub Actions"))
    (should (equal (gethash "status" entry) "COMPLETED"))
    (should (equal (gethash "conclusion" entry) "SUCCESS"))
    (should (equal (gethash "startedAt" entry) "2026-01-01T00:00:00Z"))
    (should-not (gethash "completedAt" entry))))

(ert-deftest octocat-checks-test-check-run-id ()
  "The workflow run ID comes from the details URL, not the check suite."
  (should (equal (octocat--check-run-id
                  (json-parse-string
                   "{\"details_url\":\"https://github.com/o/r/actions/runs/38218268003/job/1\",\"check_suite\":{\"id\":103543467452}}"))
                 38218268003))
  (should-not (octocat--check-run-id
               (json-parse-string "{\"details_url\":\"https://ci.example.com/build/7\"}"))))

(provide 'octocat-checks-tests)
;;; octocat-checks-tests.el ends here
