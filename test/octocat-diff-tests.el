;;; octocat-diff-tests.el --- ERT tests for octocat-diff.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-diff-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-diff-test-line-count ()
  "A file takes its heading line plus its patch lines; no patch, just one."
  (should (= (octocat-diff--line-count
              (vector (json-parse-string "{\"patch\":\"@@ -1 +1 @@\\n-a\\n+b\"}")
                      (json-parse-string "{\"filename\":\"logo.png\"}")))
             5)))

(ert-deftest octocat-diff-test-review-args ()
  "A review passes its flag, and its body only when there is one."
  (should (equal (octocat-pr-diff--review-args "o/r" 7 "--approve" "")
                 '("pr" "review" "7" "--repo" "o/r" "--approve")))
  (should (equal (octocat-pr-diff--review-args "o/r" 7 "--comment" "LGTM")
                 '("pr" "review" "7" "--repo" "o/r" "--comment" "--body" "LGTM"))))

(ert-deftest octocat-diff-test-review-data ()
  "Only an approval may be submitted without text."
  (should (plist-get (octocat-pr-diff--review-data "Approve") :allow-empty))
  (should-not (plist-get (octocat-pr-diff--review-data "Comment") :allow-empty))
  (should (equal (plist-get (octocat-pr-diff--review-data "Request changes") :flag)
                 "--request-changes")))

(provide 'octocat-diff-tests)
;;; octocat-diff-tests.el ends here
