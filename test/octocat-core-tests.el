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
    (let* ((s (octocat--format-label label nil))
           (face (get-text-property 1 'face s)))
      (should (equal s " bug "))
      (should (equal (plist-get face :background) "#d73a4a"))
      (should (equal (plist-get face :foreground) "white")))
    (puthash "color" "fef2c0" label)
    (should (equal (plist-get (get-text-property 1 'face (octocat--format-label label nil))
                              :foreground)
                   "black"))))

(ert-deftest octocat-core-test-format-label-dark ()
  "On a dark background a label is a tint with lightened text, as on GitHub."
  (let ((label (make-hash-table :test 'equal)))
    (puthash "name" "bug" label)
    (puthash "color" "d73a4a" label)
    (let ((face (octocat--label-face label "#000000")))
      ;; 18% of the colour over black.
      (should (equal (plist-get face :background) "#270a0d"))
      ;; Lightness 0.535 raised by 0.6 - 0.363.
      (should (equal (plist-get face :foreground) "#eb9fa6"))
      (should (equal (plist-get (plist-get face :box) :color) "#473032")))
    ;; Light enough already: the text keeps the label's colour.
    (puthash "color" "fef2c0" label)
    (should (equal (plist-get (octocat--label-face label "#000000") :foreground)
                   "#fef2c0"))))

(ert-deftest octocat-core-test-format-label-fallback ()
  (let ((label (make-hash-table :test 'equal)))
    (puthash "name" "x" label)
    (should (eq (get-text-property 0 'face (octocat--format-label label nil))
                'octocat-branch))
    (should (equal (octocat--format-labels nil nil) ""))
    (should (equal (octocat--format-labels :null nil) ""))
    (should (equal (octocat--format-labels [] nil) ""))))

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
  (let* ((json "{\"data\":{\"search\":{\"nodes\":[{\"number\":5,\"labels\":{\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]},\"comments\":{\"totalCount\":3},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{\"state\":\"FAILURE\",\"contexts\":{\"checkRunCountsByState\":[{\"state\":\"SUCCESS\",\"count\":3},{\"state\":\"FAILURE\",\"count\":1}],\"statusContextCountsByState\":[{\"state\":\"SUCCESS\",\"count\":1}]}}}}]}},{\"number\":6,\"labels\":{\"nodes\":[]},\"comments\":{\"totalCount\":0},\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":null}}]}}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"Y3I\"}}}}")
         (page  (octocat--parse-list-items json))
         (pr    (car (plist-get page :items)))
         (bare  (cadr (plist-get page :items))))
    (should (equal (plist-get page :cursor) "Y3I"))
    (should (equal (gethash "name" (aref (gethash "labels" pr) 0)) "bug"))
    (should (= (gethash "commentCount" pr) 3))
    (should (equal (gethash "ciState" pr) "FAILURE"))
    (should (equal (substring-no-properties (octocat--ci-status pr)) "✗"))
    (should (equal (substring-no-properties (octocat--ci-count-label pr)) "✗ 4/5"))
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


(ert-deftest octocat-core-test-cap-width ()
  "Only a capped page keeps to `octocat-max-width'."
  (with-temp-buffer
    (let ((octocat-max-width 100))
      (should (= (octocat--cap-width 140) 140))
      (octocat--max-width-setup)
      (should (= (octocat--cap-width 140) 100))
      (should (= (octocat--cap-width 80) 80))
      (let ((octocat-max-width nil))
        (should (= (octocat--cap-width 140) 140))))))

(ert-deftest octocat-search-test-state-face ()
  "`gh search' gives lower-case states: open is green, closed is red."
  (cl-flet ((face (fn state)
              (let ((c (funcall fn (json-parse-string
                                    (format "{\"number\":1,\"title\":\"t\",\"state\":\"%s\"}"
                                            state))
                                "o/r")))
                (get-text-property (string-search "(" c) 'face c))))
    (should (eq (face #'octocat--search-make-pr-candidate "closed") 'octocat-pr-state-closed))
    (should (eq (face #'octocat--search-make-pr-candidate "open") 'octocat-pr-state-open))
    (should (eq (face #'octocat--search-make-issue-candidate "open") 'octocat-pr-state-open))
    (should (eq (face #'octocat--search-make-issue-candidate "closed") 'octocat-pr-state-closed))))

;;; github.com links

(ert-deftest octocat-core-test-github-url-target ()
  "A github.com URL maps to the octocat view showing it, or nil for none."
  (dolist (case '(("https://github.com/octocat"                    (user "octocat"))
                  ("https://github.com/octo/cat"                   (repo "octo/cat"))
                  ("http://www.github.com/octo/cat.git/"           (repo "octo/cat"))
                  ("https://github.com/octo/cat?tab=readme-ov-file" (repo "octo/cat"))
                  ("https://github.com/octo/cat/pull/12"           (pr "octo/cat" 12))
                  ("https://github.com/octo/cat/pull/12#issuecomment-1" (pr "octo/cat" 12))
                  ("https://github.com/octo/cat/pull/12/files"     (pr-diff "octo/cat" 12))
                  ("https://github.com/octo/cat/pull/12/commits"   (pr-commits "octo/cat" 12))
                  ("https://github.com/octo/cat/pull/12/commits/abc1234"
                   (commit "octo/cat" "abc1234"))
                  ("https://github.com/octo/cat/issues/7"          (issue "octo/cat" 7))
                  ("https://github.com/octo/cat/commit/deadbeef1"  (commit "octo/cat" "deadbeef1"))
                  ("https://github.com/octo/cat/pulls"             (pr-list "octo/cat"))
                  ("https://github.com/octo/cat/issues"            (issue-list "octo/cat"))
                  ("https://github.com/octo/cat/actions"           (actions "octo/cat"))
                  ("https://github.com/octo/cat/tree/main"         (tree "octo/cat"))
                  ("https://github.com/octo/cat/actions/runs/42"   (run "octo/cat" 42))
                  ("https://github.com/octo/cat/actions/runs/42/attempts/2" (run "octo/cat" 42))
                  ("https://github.com/octo/cat/actions/runs/42/job/99" (job "octo/cat" 42 99))
                  ("https://github.com/octo/cat/actions/workflows/ci.yml" (workflow "octo/cat" "ci.yml"))
                  ;; Another owner's repository is opened as readily.
                  ("https://github.com/torvalds/linux/commit/0123abc4567"
                   (commit "torvalds/linux" "0123abc4567"))
                  ("https://github.com/torvalds/linux/actions/runs/5" (run "torvalds/linux" 5))
                  ;; No octocat view: left to the browser.
                  ("https://github.com/octo/cat/blob/main/x.el"    nil)
                  ("https://github.com/octo/cat/wiki"              nil)
                  ("https://github.com/octo/cat/pull/abc"          nil)
                  ("https://github.com/orgs/octo/teams/t"          nil)
                  ("https://github.com/settings"                   nil)
                  ("https://github.com"                            nil)
                  ("https://gitlab.com/octo/cat"                   nil)
                  ("https://example.com/github.com/octo/cat"       nil)))
    (should (equal (list (car case) (octocat--github-url-target (car case)))
                   case))))

(ert-deftest octocat-core-test-browse-url-opens-views ()
  "`octocat-browse-url' opens the view of each kind of link."
  (let (opened)
    (cl-letf (((symbol-function 'octocat-user-open)     (lambda (&rest a) (push (cons 'user a) opened)))
              ((symbol-function 'octocat-visit-repo)    (lambda (&rest a) (push (cons 'repo a) opened)))
              ((symbol-function 'octocat-pr-open)       (lambda (&rest a) (push (cons 'pr a) opened)))
              ((symbol-function 'octocat-pr-diff-open)  (lambda (&rest a) (push (cons 'pr-diff a) opened)))
              ((symbol-function 'octocat-pr-commits-open) (lambda (&rest a) (push (cons 'pr-commits a) opened)))
              ((symbol-function 'octocat--markdown-open-ref) (lambda (&rest a) (push (cons 'ref a) opened)))
              ((symbol-function 'octocat-commit-open)   (lambda (&rest a) (push (cons 'commit a) opened)))
              ((symbol-function 'octocat-run-open)      (lambda (&rest a) (push (cons 'run a) opened)))
              ((symbol-function 'octocat-job-open)      (lambda (&rest a) (push (cons 'job a) opened)))
              ((symbol-function 'octocat-workflow-open) (lambda (&rest a) (push (cons 'workflow a) opened)))
              ((symbol-function 'octocat-pr-list)       (lambda (&rest a) (push (cons 'pr-list a) opened)))
              ((symbol-function 'octocat-issue-list)    (lambda (&rest a) (push (cons 'issue-list a) opened)))
              ((symbol-function 'octocat-actions)       (lambda (&rest a) (push (cons 'actions a) opened)))
              ((symbol-function 'octocat-tree-open)     (lambda (&rest a) (push (cons 'tree a) opened))))
      (dolist (path '("octocat" "o/r" "o/r/pull/1" "o/r/pull/1/files" "o/r/pull/1/commits" "o/r/issues/2"
                      "o/r/commit/abc1234" "o/r/actions/runs/3" "o/r/actions/runs/3/job/4"
                      "o/r/actions/workflows/ci.yml"
                      "o/r/pulls" "o/r/issues" "o/r/actions" "o/r/tree/main"))
        (octocat-browse-url (concat "https://github.com/" path))))
    (should (equal (nreverse opened)
                   '((user "octocat") (repo "o/r") (pr "o/r" 1) (pr-diff "o/r" 1) (pr-commits "o/r" 1)
                     (ref issue "o/r" 2) (commit "o/r" "abc1234") (run "o/r" 3)
                     (job "o/r" 3 4 nil)
                     (workflow "o/r" "ci.yml" "ci.yml" ".github/workflows/ci.yml")
                     (pr-list "o/r") (issue-list "o/r")
                     (actions "o/r") (tree "o/r"))))))

(ert-deftest octocat-core-test-browse-url-handler ()
  "`browse-url' sends the github.com links octocat can show to it.
Other links, and an explicit request for an external browser, skip it;
`octocat-open-github-urls' turns it off."
  (should (eq (browse-url-select-handler "https://github.com/o/r/pull/1")
              #'octocat-browse-url))
  (should-not (eq (browse-url-select-handler "https://github.com/o/r/blob/main/x")
                  #'octocat-browse-url))
  (should-not (eq (browse-url-select-handler "https://github.com/o/r/pull/1" 'external)
                  #'octocat-browse-url))
  (unwind-protect
      (progn
        (customize-set-variable 'octocat-open-github-urls nil)
        (should-not (eq (browse-url-select-handler "https://github.com/o/r/pull/1")
                        #'octocat-browse-url)))
    (customize-set-variable 'octocat-open-github-urls t))
  (should (= 1 (cl-count #'octocat-browse-url browse-url-handlers :key #'cdr))))

(ert-deftest octocat-core-test-markdown-links-open-views ()
  "RET on a github.com link in markdown opens its view, in the repo it names;
#123 and commit references still open in the buffer's own repository."
  (let ((out (octocat-markdown-render
              "https://github.com/torvalds/linux/commit/0123abc4567 and #7 and abc1234" ""))
        opened)
    (cl-letf (((symbol-function 'octocat-commit-open)
               (lambda (&rest a) (push (cons 'commit a) opened)))
              ((symbol-function 'octocat--run-gh)
               (lambda (_name _args parse callback) (funcall callback (funcall parse "false"))))
              ((symbol-function 'octocat-issue-open)
               (lambda (&rest a) (push (cons 'issue a) opened)))
              ((symbol-function 'octocat--search-repo--current-repo) (lambda () "me/mine")))
      (with-temp-buffer
        (insert out)
        (dolist (needle '("github.com" "#7" "abc1234"))
          (goto-char (1+ (string-match (regexp-quote needle) out)))
          (octocat-markdown-follow))))
    (should (equal (nreverse opened)
                   '((commit "torvalds/linux" "0123abc4567")
                     (issue "me/mine" 7)
                     (commit "me/mine" "abc1234"))))))

(ert-deftest octocat-core-test-browse-commands-go-external ()
  "\"Open in browser\" commands ask for an external browser, not octocat."
  (let (kinds)
    (cl-letf (((symbol-function 'browse-url-with-browser-kind)
               (lambda (kind url &rest _) (push (list kind url) kinds))))
      (with-temp-buffer
        (insert (propertize "row" 'octocat-dashboard-repo "o/r"))
        (goto-char (point-min))
        (octocat-dashboard-browse)))
    (should (equal kinds '((external "https://github.com/o/r"))))))

(provide 'octocat-core-tests)
;;; octocat-core-tests.el ends here
