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

(ert-deftest octocat-pr-test-merge-refusal ()
  "Drafts and conflicts cannot be merged; a blocked PR is left to GitHub."
  (should (octocat-pr--merge-refusal (octocat-pr-test--pr "{\"isDraft\":true}")))
  (should (octocat-pr--merge-refusal
           (octocat-pr-test--pr "{\"mergeable\":\"CONFLICTING\"}")))
  (should-not (octocat-pr--merge-refusal
               (octocat-pr-test--pr "{\"mergeStateStatus\":\"BLOCKED\"}"))))

(ert-deftest octocat-pr-test-merge-rows ()
  "The merge box rows read as GitHub's."
  (should (equal (octocat-pr--merge-rows
                  (octocat-pr-test--pr
                   "{\"reviewDecision\":\"APPROVED\",
                     \"latestReviews\":[{\"state\":\"APPROVED\"}],
                     \"statusCheckRollup\":[{\"conclusion\":\"SUCCESS\"},
                                            {\"conclusion\":\"SKIPPED\"},
                                            {\"status\":\"IN_PROGRESS\"}],
                     \"mergeable\":\"MERGEABLE\"}"))
                 '((ok "Changes approved" "1 approving review")
                   (wait "Some checks haven't completed yet"
                         "1 in progress, 1 skipped, 1 successful checks" t)
                   (ok "No conflicts with base branch")))))

(provide 'octocat-pr-tests)
;;; octocat-pr-tests.el ends here
