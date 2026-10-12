;;; octocat-job-tests.el --- ERT tests for octocat-job.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-job-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-job-test-log-line-bom ()
  "A byte-order mark before the timestamp does not hide a group start."
  (let ((entry (octocat--job-parse-log-line
                "\uFEFF2026-10-12T07:32:34.8448215Z ##[group]Run make compile")))
    (should (eq (plist-get entry :kind) 'group-start))
    (should (equal (plist-get entry :text) "Run make compile"))
    (should (plist-get entry :ts))))

(ert-deftest octocat-job-test-log-blocks ()
  "Log lines are grouped by ##[group], unindented, so they copy out as-is."
  (let ((blocks (octocat-job--log-blocks
                 (mapcar #'octocat--job-parse-log-line
                         '("2026-10-12T07:32:34Z before"
                           "2026-10-12T07:32:35Z ##[group]Run make"
                           "2026-10-12T07:32:36Z inside"
                           "2026-10-12T07:32:37Z ##[endgroup]"
                           "after")))))
    (should (equal (mapcar #'car blocks) '(text group text)))
    (should (string-suffix-p " before" (substring-no-properties (nth 1 (nth 0 blocks)))))
    (should (equal (nth 1 (nth 1 blocks)) "Run make"))
    (should (string-suffix-p " inside" (substring-no-properties (nth 2 (nth 1 blocks)))))
    (should (equal (substring-no-properties (nth 1 (nth 2 blocks))) "after"))))

(ert-deftest octocat-job-test-log-colors ()
  "Color codes go, whether escape characters or spelled out as ^[."
  (should (equal (plist-get (octocat--job-parse-log-line
                             "2026-10-12T07:32:34Z ^[[36;1mmake compile^[[0m \e[32mok\e[0m")
                            :text)
                 "make compile ok")))

(provide 'octocat-job-tests)
;;; octocat-job-tests.el ends here
