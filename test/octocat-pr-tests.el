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

(ert-deftest octocat-pr-test-commit-days ()
  "Commits are grouped by day, oldest first, and read as REST commits."
  (let* ((pr (octocat-pr-test--pr
              "{\"commits\":[
                 {\"oid\":\"aaa\",\"messageHeadline\":\"a\",
                  \"committedDate\":\"2026-10-03T12:00:00Z\",
                  \"authors\":[{\"login\":\"me\",\"name\":\"Me\"}]},
                 {\"oid\":\"bbb\",\"messageHeadline\":\"b\",
                  \"committedDate\":\"2026-10-03T12:30:00Z\",
                  \"authors\":[{\"login\":\"\",\"name\":\"Anon\"}]},
                 {\"oid\":\"ccc\",\"messageHeadline\":\"c\",
                  \"committedDate\":\"2026-10-05T12:00:00Z\"}]}"))
         (days (octocat-pr--commit-days pr)))
    (should (equal (mapcar (lambda (d) (cons (car d) (mapcar (lambda (c) (gethash "sha" c))
                                                         (cdr d))))
                           days)
                   '(("Commits on Oct 3, 2026" "aaa" "bbb")
                     ("Commits on Oct 5, 2026" "ccc"))))
    (should (equal (mapcar #'octocat--commit-author (cdar days)) '("@me" "Anon")))
    ;; Short subjects get the minimum column; long ones what the page leaves.
    (let ((commits (apply #'append (mapcar #'cdr days))))
      (should (= (octocat-repo-vui--subject-width commits 112 3)
                 octocat-repo-vui--subject-min-width))
      (puthash "message" (make-string 200 ?x) (gethash "commit" (car commits)))
      (should (= (+ (octocat-repo-vui--subject-width commits 112 3) 7 2 2 3 2
                    (apply #'max (mapcar (lambda (c) (string-width (octocat-repo-vui--date c)))
                                         commits)))
                 112)))))

(ert-deftest octocat-pr-test-merge-allowed ()
  "Only the methods the repo allows are offered, in GitHub's order."
  (should (equal (octocat-pr--merge-allowed
                  (json-parse-string "{\"mergeCommitAllowed\":false,
                                       \"squashMergeAllowed\":true,
                                       \"rebaseMergeAllowed\":true}"))
                 '("Squash" "Rebase"))))

(ert-deftest octocat-pr-test-merge-initial-method ()
  "The last method is kept while allowed; a lone method is always picked."
  (should (equal (octocat-pr--merge-initial-method '("Merge" "Squash") "Squash") "Squash"))
  (should-not (octocat-pr--merge-initial-method '("Merge" "Squash") "Rebase"))
  (should-not (octocat-pr--merge-initial-method '("Merge" "Squash") nil))
  (should (equal (octocat-pr--merge-initial-method '("Rebase") "Squash") "Rebase")))

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
                         "1 in progress, 1 skipped, 1 successful checks" checks)
                   (ok "No conflicts with base branch")))))

(ert-deftest octocat-pr-test-merge-rows-awaiting ()
  "Workflow runs awaiting approval get a row of their own after the checks."
  (let ((pr (octocat-pr-test--pr "{\"mergeable\":\"MERGEABLE\"}"))
        (run (octocat-pr-test--pr "{\"id\":1}")))
    (should (equal (octocat-pr--merge-rows pr (list run))
                   '((wait "1 workflow awaiting approval"
                           "This workflow requires approval from a maintainer." approval)
                     (ok "No conflicts with base branch"))))
    (should (equal (cadr (car (octocat-pr--merge-rows pr (list run run))))
                   "2 workflows awaiting approval"))))

(provide 'octocat-pr-tests)
;;; octocat-pr-tests.el ends here
