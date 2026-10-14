;;; octocat-pr-tests.el --- ERT tests for octocat-pr.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-pr-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defun octocat-pr-test--pr (json)
  "Return the PR hash-table parsed from JSON."
  (json-parse-string json))

(ert-deftest octocat-pr-test-merge-args ()
  "Merge and squash pass the message split into subject and body; rebase none."
  (should (equal (octocat-pr--merge-args "o/r" 7 "Squash" "Fix (#7)\n\n* a\n* b" t)
                 '("pr" "merge" "7" "--repo" "o/r" "--squash"
                   "--subject" "Fix (#7)" "--body" "* a\n* b" "--delete-branch")))
  (should (equal (octocat-pr--merge-args "o/r" 7 "Merge" "Merge it" nil)
                 '("pr" "merge" "7" "--repo" "o/r" "--merge"
                   "--subject" "Merge it" "--body" "")))
  (should (equal (octocat-pr--merge-args "o/r" 7 "Rebase" "ignored" nil)
                 '("pr" "merge" "7" "--repo" "o/r" "--rebase"))))

(ert-deftest octocat-pr-test-merge-message ()
  "Default messages follow GitHub's."
  (let ((pr (octocat-pr-test--pr
             "{\"number\":7,\"title\":\"Fix\",\"headRefName\":\"fix\",
               \"headRepositoryOwner\":{\"login\":\"me\"},
               \"commits\":[{\"messageHeadline\":\"a\"},{\"messageHeadline\":\"b\"}]}")))
    (should (equal (octocat-pr--merge-message "Merge" pr)
                   "Merge pull request #7 from me/fix\n\nFix"))
    (should (equal (octocat-pr--merge-message "Squash" pr) "Fix (#7)\n\n* a\n* b"))
    (should (equal (octocat-pr--merge-message "Rebase" pr) ""))))

(ert-deftest octocat-pr-test-merge-allowed ()
  "Only the methods the repo allows are offered, in GitHub's order."
  (should (equal (octocat-pr--merge-allowed
                  (json-parse-string "{\"mergeCommitAllowed\":false,
                                       \"squashMergeAllowed\":true,
                                       \"rebaseMergeAllowed\":true}"))
                 '("Squash" "Rebase"))))

(ert-deftest octocat-pr-test-merge-status ()
  "Drafts and conflicts cannot be merged; a blocked PR still offers it."
  (should-not (nth 2 (octocat-pr--merge-status
                      (octocat-pr-test--pr "{\"isDraft\":true}"))))
  (should-not (nth 2 (octocat-pr--merge-status
                      (octocat-pr-test--pr "{\"mergeable\":\"CONFLICTING\"}"))))
  (should (equal (octocat-pr--merge-status
                  (octocat-pr-test--pr "{\"mergeStateStatus\":\"CLEAN\",
                                         \"reviewDecision\":\"APPROVED\"}"))
                 '("✓ Ready to merge · Approved" octocat-ci-success t)))
  (should (nth 2 (octocat-pr--merge-status
                  (octocat-pr-test--pr "{\"mergeStateStatus\":\"BLOCKED\"}")))))

(provide 'octocat-pr-tests)
;;; octocat-pr-tests.el ends here
