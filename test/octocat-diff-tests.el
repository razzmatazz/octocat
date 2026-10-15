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

(ert-deftest octocat-diff-test-comment-markdown ()
  "An inline comment's body is rendered markdown, unless raw."
  (let ((c (json-parse-string
            "{\"user\":{\"login\":\"me\"},\"body\":\"**hi**\",\"created_at\":\"\"}")))
    (should (equal (nth 1 (octocat-diff--comment-lines c nil 80)) "  │ hi"))
    (should (equal (nth 1 (octocat-diff--comment-lines c t 80)) "  │ **hi**"))))

(ert-deftest octocat-diff-test-comments-section ()
  "General comments are boxed; inline ones only counted."
  (let ((text (lambda (data)
                (with-temp-buffer
                  (vui-render (octocat-diff-comments-section
                               "Comments" (list :status 'ready :data data) nil 80))
                  (buffer-substring-no-properties (point-min) (point-max))))))
    (should (string-search "(no comments)" (funcall text nil)))
    (let ((out (funcall text
                        (list (json-parse-string
                               "{\"user\":{\"login\":\"me\"},\"body\":\"hi\",\"created_at\":\"\"}")
                              (json-parse-string
                               "{\"path\":\"a.el\",\"body\":\"x\",\"created_at\":\"\"}")))))
      (should (string-search "Comments (2)" out))
      (should (string-search "(1 inline comment shown in the diff above)" out))
      (should (string-search "┌─ @me" out))
      (should (string-search "│ hi" out)))))

(provide 'octocat-diff-tests)
;;; octocat-diff-tests.el ends here
