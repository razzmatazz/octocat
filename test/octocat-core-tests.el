;;; octocat-core-tests.el --- ERT tests for octocat-core.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-core-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-core-test-format-label-colour ()
  (let* ((label (make-hash-table :test 'equal)))
    (puthash "name" "bug" label)
    (puthash "color" "d73a4a" label)
    (let* ((s (octocat--format-label label))
           (face (get-text-property 1 'face s)))
      (should (equal s " bug "))
      (should (equal (plist-get face :background) "#d73a4a"))
      (should (equal (plist-get face :foreground) "white")))
    (puthash "color" "fef2c0" label)
    (should (equal (plist-get (get-text-property 1 'face (octocat--format-label label))
                              :foreground)
                   "black"))))

(ert-deftest octocat-core-test-format-label-fallback ()
  (let ((label (make-hash-table :test 'equal)))
    (puthash "name" "x" label)
    (should (eq (get-text-property 0 'face (octocat--format-label label))
                'octocat-branch))
    (should (equal (octocat--format-labels nil) ""))
    (should (equal (octocat--format-labels :null) ""))
    (should (equal (octocat--format-labels []) ""))))

(ert-deftest octocat-core-test-search-query ()
  "The query is scoped to the repo and kind; nil means open items."
  (should (equal (octocat--search-query "o/r" 'pulls nil)
                 "( is:open ) repo:o/r type:pr"))
  (should (equal (octocat--search-query "o/r" 'issues "is:closed OR label:x")
                 "( is:closed OR label:x ) repo:o/r type:issue"))
  (should (equal (octocat--search-query "o/r" 'issues "  ")
                 "repo:o/r type:issue")))

(ert-deftest octocat-core-test-parse-list-items ()
  "Connections flatten to what the rows read; the cursor ends with the pages."
  (let* ((json "{\"data\":{\"search\":{\"nodes\":[{\"number\":5,\"labels\":{\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]},\"comments\":{\"totalCount\":3},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{\"state\":\"FAILURE\"}}}]}},{\"number\":6,\"labels\":{\"nodes\":[]},\"comments\":{\"totalCount\":0},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":null}}]}}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"Y3I\"}}}}")
         (page  (octocat--parse-list-items json))
         (pr    (car (plist-get page :items)))
         (bare  (cadr (plist-get page :items))))
    (should (equal (plist-get page :cursor) "Y3I"))
    (should (equal (gethash "name" (aref (gethash "labels" pr) 0)) "bug"))
    (should (= (gethash "commentCount" pr) 3))
    (should (equal (gethash "ciState" pr) "FAILURE"))
    (should (equal (substring-no-properties (octocat--ci-status pr)) "✗"))
    (should-not (gethash "ciState" bare))
    (should-not (gethash "commits" bare)))
  (should-not (plist-get (octocat--parse-list-items
                          "{\"data\":{\"search\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}")
                         :cursor)))

(defmacro octocat-core-tests--with-cache-dir (&rest body)
  "Evaluate BODY with `octocat-cache-directory' pointing at a temp directory."
  (declare (indent 0))
  `(let ((octocat-cache-directory (make-temp-file "octocat-cache" t)))
     (unwind-protect (progn ,@body)
       (delete-directory octocat-cache-directory t))))

(ert-deftest octocat-core-test-items-cache-roundtrip ()
  "A saved item list loads back with its branch; a missing one is nil."
  (octocat-core-tests--with-cache-dir
    (should-not (octocat--items-cache-load "o/r" "commits" "default"))
    (let ((item (make-hash-table :test #'equal)))
      (puthash "sha" "abc" item)
      (octocat--items-cache-save "o/r" "commits" "default" (list item) "main"))
    (let ((loaded (octocat--items-cache-load "o/r" "commits" "default")))
      (should (equal (plist-get loaded :branch) "main"))
      (should (equal (gethash "sha" (car (plist-get loaded :items))) "abc")))
    ;; Branch is optional.
    (octocat--items-cache-save "o/r" "prs" "id" nil)
    (should-not (octocat--items-cache-load "o/r" "prs" "id"))))

(ert-deftest octocat-core-test-counts-and-summary-cache-roundtrip ()
  "Counts and the repo summary survive a save/load, nils included."
  (octocat-core-tests--with-cache-dir
    (octocat--counts-cache-save "o/r" 'pulls '(:open 1 :closed 0 :merged 9))
    (should (equal (octocat--counts-cache-load "o/r" 'pulls)
                   '(:open 1 :closed 0 :merged 9)))
    (octocat--counts-cache-save "o/r" 'issues '(:open 3 :closed 4))
    (should (equal (octocat--counts-cache-load "o/r" 'issues) '(:open 3 :closed 4)))
    (octocat-repo--summary-cache-save
     "o/r" '(:default-branch "main" :fork-parent nil :open-issues 2 :open-prs 1))
    (should (equal (octocat-repo--summary-cache-load "o/r")
                   '(:default-branch "main" :fork-parent nil :open-issues 2 :open-prs 1)))))

(ert-deftest octocat-core-test-checks-ci-status ()
  "A check's outcome is its conclusion or state, in any case."
  (cl-flet ((status (&rest checks)
              (substring-no-properties
               (octocat--checks-ci-status
                (mapcar (lambda (fields)
                          (let ((h (make-hash-table :test #'equal)))
                            (while fields (puthash (pop fields) (pop fields) h))
                            h))
                        checks)))))
    (should (equal (status '("conclusion" "SUCCESS")) "✓"))
    (should (equal (status '("conclusion" "success") '("state" "SUCCESS")) "✓"))
    (should (equal (status '("conclusion" "SUCCESS") '("conclusion" "FAILURE")) "✗"))
    (should (equal (status '("conclusion" "SUCCESS") '("status" "IN_PROGRESS")) "●"))))

(ert-deftest octocat-core-test-counts-query-and-parse ()
  "Pull requests also count merged; the response parses to a plist."
  (should (string-match-p "merged:pullRequests(states:MERGED)"
                          (octocat--counts-query 'pulls)))
  (should-not (string-match-p "merged" (octocat--counts-query 'issues)))
  (should (equal (octocat--parse-counts
                  "{\"data\":{\"repository\":{\"open\":{\"totalCount\":2},\"closed\":{\"totalCount\":5}}}}")
                 '(:open 2 :closed 5))))


(ert-deftest octocat-core-test-centered-margins ()
  "Margins centre MAX columns in a wider window, and vanish otherwise."
  (should (equal (octocat--centered-margins 120 nil) '(0 . 0)))
  (should (equal (octocat--centered-margins 80 100) '(0 . 0)))
  (should (equal (octocat--centered-margins 140 100) '(20 . 20)))
  (should (equal (octocat--centered-margins 141 100) '(20 . 21))))

(provide 'octocat-core-tests)
;;; octocat-core-tests.el ends here
