;;; octocat-tests.el --- ERT tests for octocat.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Basic test suite for octocat.el.  Run via:
;;   eask test ert test/octocat-tests.el

;;; Code:

(require 'ert)
(require 'octocat)
(require 'octocat-tree)


;;; octocat-repo--current-repo

(defmacro octocat-tests--with-remote (url &rest body)
  "Evaluate BODY with `shell-command-to-string' mocked to return URL."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'shell-command-to-string) (lambda (_) ,url)))
     ,@body))

(ert-deftest octocat-test-repo-ssh ()
  "Parse SSH remote URL."
  (octocat-tests--with-remote "git@github.com:owner/repo.git"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-test-repo-ssh-no-suffix ()
  "Parse SSH remote URL without .git suffix."
  (octocat-tests--with-remote "git@github.com:owner/repo"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-test-repo-https ()
  "Parse HTTPS remote URL."
  (octocat-tests--with-remote "https://github.com/owner/repo.git"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-test-repo-https-no-suffix ()
  "Parse HTTPS remote URL without .git suffix."
  (octocat-tests--with-remote "https://github.com/owner/repo"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-test-repo-no-remote ()
  "Signal user-error when no origin remote is found."
  (octocat-tests--with-remote ""
    (should-error (octocat-repo--current-repo) :type 'user-error)))

;;; octocat-tree tests

(ert-deftest octocat-tree-test-fontify-plain-text ()
  "octocat-tree--fontify returns the content string unchanged for plain text."
  (let ((content "hello world\n"))
    (should (equal content (octocat-tree--fontify "plain.txt" content)))))

(ert-deftest octocat-tree-test-fontify-el ()
  "octocat-tree--fontify returns a string with face properties for Elisp."
  (let* ((content ";; hello\n(defun foo () nil)\n")
         (result (octocat-tree--fontify "foo.el" content)))
    ;; The result must be a string (face properties may or may not apply
    ;; depending on font-lock support in the test environment).
    (should (stringp result))
    (should (= (length content) (length result)))))

(ert-deftest octocat-tree-test-branch-glyph ()
  "octocat-tree--branch-glyph returns a non-empty string."
  (let ((g (octocat-tree--branch-glyph)))
    (should (stringp g))
    (should (> (length g) 0))))

(ert-deftest octocat-tree-test-render-loading ()
  "octocat-tree--render-loading fills the buffer with a loading skeleton."
  (with-temp-buffer
    (octocat-tree-mode)
    (setq octocat-tree--repo "owner/repo"
          octocat-tree--branch "main")
    (octocat-tree--render-loading)
    (should (> (buffer-size) 0))
    (should (string-match-p "owner/repo" (buffer-string)))
    (should (string-match-p "Loading" (buffer-string)))))

(defun octocat-tests--mount-tree (entries)
  "Mount `octocat-tree--root' in the current buffer with root ENTRIES.
The root directory's children are pre-seeded in the subtree cache, so
no gh call is made."
  (octocat-tree-mode)
  (setq octocat-tree--repo "owner/repo"
        octocat-tree--branch "main"
        octocat-tree--subtree-cache (list (cons "rootsha" entries)))
  (vui-mount (vui-component 'octocat-tree--root
                            :repo "owner/repo" :branch "main"
                            :root-sha "rootsha")
             (buffer-name)))

(ert-deftest octocat-tree-test-render-entries-empty ()
  "Mounting the tree with an empty entries vector produces a valid buffer."
  (with-temp-buffer
    (octocat-tests--mount-tree [])
    (should (> (buffer-size) 0))
    (should (string-match-p "owner/repo" (buffer-string)))))

(ert-deftest octocat-tree-test-render-entries-mixed ()
  "The tree shows dirs before files and uses correct labels."
  (with-temp-buffer
    (let* ((dir-entry  (let ((h (make-hash-table :test #'equal)))
                         (puthash "path" "src"       h)
                         (puthash "type" "tree"      h)
                         (puthash "sha"  "abc123"    h)
                         h))
           (file-entry (let ((h (make-hash-table :test #'equal)))
                         (puthash "path" "README.md" h)
                         (puthash "type" "blob"      h)
                         (puthash "sha"  "def456"    h)
                         h))
           (entries    (vector dir-entry file-entry)))
      (octocat-tests--mount-tree entries)
      (let ((text (buffer-string)))
        (should (string-match-p "src" text))
        (should (string-match-p "README.md" text))
        ;; Dir should appear before file in the buffer.
        (should (< (string-match "src" text)
                   (string-match "README.md" text)))))))


;;; File log

(defconst octocat-tests--file-log-commits-json
  (concat "[{\"sha\":\"a1b2c3d4e5f6\",\"author\":{\"login\":\"ann\"},"
          "\"commit\":{\"message\":\"Fix parser\\n\\nLonger body\","
          "\"author\":{\"name\":\"Ann\",\"date\":\"2026-06-01T10:00:00Z\"}}},"
          "{\"sha\":\"f6e5d4c3b2a1\",\"author\":null,"
          "\"commit\":{\"message\":\"Add tests\","
          "\"author\":{\"name\":\"Bob\",\"date\":\"2026-05-28T10:00:00Z\"}}}]")
  "Two commits as the REST commits endpoint returns them.")

(defun octocat-tests--mount-file-log (&rest props)
  "Mount the file log page in the current buffer with PROPS."
  (octocat-file-log-mode)
  (setq octocat-file-log--repo "owner/repo"
        octocat-file-log--path "src/foo.el")
  (apply #'octocat-file-log--mount props))

(ert-deftest octocat-file-log-test-commit-line ()
  "A commit line shows short SHA, author and subject, and carries the SHA."
  (let* ((commit (aref (json-parse-string octocat-tests--file-log-commits-json
                                          :null-object nil)
                       0))
         (line   (octocat-file-log--commit-line commit)))
    (should (string-match-p "a1b2c3d " line))
    (should (string-match-p "@ann" line))
    (should (string-match-p "Fix parser" line))
    (should-not (string-match-p "Longer body" line))
    (should-not (string-search "\n" line))
    (should (equal (get-text-property 0 'octocat-file-log--sha line)
                   "a1b2c3d4e5f6"))
    (should (equal (get-text-property (1- (length line)) 'octocat-file-log--sha line)
                   "a1b2c3d4e5f6"))))

(ert-deftest octocat-file-log-test-render-commits ()
  "The file log lists one line per commit under a header with the count."
  (with-temp-buffer
    (octocat-tests--mount-file-log
     :commits (append (json-parse-string octocat-tests--file-log-commits-json
                                         :null-object nil)
                      nil))
    (let ((text (buffer-string)))
      (should (string-match-p "owner/repo  src/foo.el  (2 commits)" text))
      (should (< (string-search "Fix parser" text)
                 (string-search "Add tests" text))))
    (goto-char (point-min))
    (search-forward "Add tests")
    (should (equal (octocat-file-log--sha-at-point) "f6e5d4c3b2a1"))
    (goto-char (point-min))
    (should-not (octocat-file-log--sha-at-point))))

(ert-deftest octocat-file-log-test-render-loading-and-empty ()
  "The file log shows its text in place of the list, or a no-commits line."
  (with-temp-buffer
    (octocat-tests--mount-file-log :text "Loading…" :face 'octocat-dimmed)
    (should (string-match-p "Loading…" (buffer-string)))
    (should-not (string-match-p "commits)" (buffer-string))))
  (with-temp-buffer
    (octocat-tests--mount-file-log :commits nil)
    (should (string-match-p "(0 commits)" (buffer-string)))
    (should (string-match-p "(no commits found)" (buffer-string)))))

(ert-deftest octocat-test-format-label-colour ()
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

(ert-deftest octocat-test-format-label-fallback ()
  (let ((label (make-hash-table :test 'equal)))
    (puthash "name" "x" label)
    (should (eq (get-text-property 0 'face (octocat--format-label label))
                'octocat-branch))
    (should (equal (octocat--format-labels nil) ""))
    (should (equal (octocat--format-labels :null) ""))
    (should (equal (octocat--format-labels []) ""))))


;;; octocat-repo--parse-summary

(ert-deftest octocat-test-parse-summary-fork ()
  "A fork's summary carries its parent, default branch and counts."
  (should (equal (octocat-repo--parse-summary
                  "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\"},\"parent\":{\"nameWithOwner\":\"up/stream\"},\"issues\":{\"totalCount\":3},\"pullRequests\":{\"totalCount\":2}}}}")
                 '(:default-branch "main" :fork-parent "up/stream"
                   :open-issues 3 :open-prs 2))))

(ert-deftest octocat-test-parse-summary-empty-repo ()
  "A non-fork with no default branch yields nils, not errors."
  (should (equal (octocat-repo--parse-summary
                  "{\"data\":{\"repository\":{\"defaultBranchRef\":null,\"parent\":null,\"issues\":{\"totalCount\":0},\"pullRequests\":{\"totalCount\":0}}}}")
                 '(:default-branch nil :fork-parent nil
                   :open-issues 0 :open-prs 0))))

;;; List filters

(ert-deftest octocat-test-filter-args-default ()
  "No query lists open items via the default query."
  (should (equal (octocat--filter-args nil)
                 '("--state" "all" "--search" "is:open"))))

(ert-deftest octocat-test-filter-args-query ()
  "The query goes to --search unchanged; gh's own state never competes."
  (should (equal (octocat--filter-args "is:closed author:@me -label:wip")
                 '("--state" "all" "--search" "is:closed author:@me -label:wip"))))

(ert-deftest octocat-test-filter-args-empty-query ()
  "An empty query lists everything, with no --search."
  (should (equal (octocat--filter-args "  ") '("--state" "all"))))

(ert-deftest octocat-test-filter-active-p ()
  "Only a query other than the default counts as an active filter."
  (should-not (octocat-vui-list-filter-active-p nil))
  (should-not (octocat-vui-list-filter-active-p " is:open "))
  (should (octocat-vui-list-filter-active-p "is:closed"))
  (should (octocat-vui-list-filter-active-p "")))

(ert-deftest octocat-test-filter-tokenize-keeps-quotes ()
  "Quoted values stay in one token."
  (should (equal (octocat-vui-list--tokenize "is:open label:\"good first issue\" bob")
                 '("is:open" "label:\"good first issue\"" "bob"))))

(ert-deftest octocat-test-filter-values-unquotes ()
  "Qualifier values are returned unquoted, negated qualifiers excluded."
  (should (equal (octocat-vui-list--values
                  "label:bug label:\"good first issue\" -label:wip" "label:")
                 '("bug" "good first issue"))))

(ert-deftest octocat-test-filter-with-values ()
  "Setting a qualifier replaces its tokens and quotes values with spaces."
  (should (equal (octocat-vui-list--with-values
                  "is:open label:old -label:wip" "label:" '("a b" "c"))
                 "is:open -label:wip label:\"a b\" label:c"))
  (should (equal (octocat-vui-list--with-values "is:open author:x" "author:" nil)
                 "is:open")))

(ert-deftest octocat-test-filter-state ()
  "The state token is read, replaced and removed (\"all\")."
  (should (equal (octocat-vui-list--state "label:x is:closed") "closed"))
  (should (equal (octocat-vui-list--state "label:x") "all"))
  (should (equal (octocat-vui-list--with-state "is:open label:x" "merged")
                 "is:merged label:x"))
  (should (equal (octocat-vui-list--with-state "is:open label:x" "all")
                 "label:x")))

(ert-deftest octocat-test-quote-prefix-marks-every-line ()
  "Bodies rendered with the quote prefix start every line, blanks included, with \"  │ \"."
  (with-temp-buffer
    (setq octocat--markdown-raw t)
    (octocat--insert-markdown "first\n\nthird" octocat--quote-prefix)
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "  │ first\n  │ \n  │ third\n"))
    ;; Wrapped continuation lines repeat the prefix.
    (should (equal (get-text-property (point-min) 'wrap-prefix) octocat--quote-prefix))
    (should (equal (get-text-property (1- (point-max)) 'wrap-prefix) octocat--quote-prefix))))

;;; Stale-while-revalidate caches

(defmacro octocat-tests--with-cache-dir (&rest body)
  "Evaluate BODY with `octocat-cache-directory' pointing at a temp directory."
  (declare (indent 0))
  `(let ((octocat-cache-directory (make-temp-file "octocat-cache" t)))
     (unwind-protect (progn ,@body)
       (delete-directory octocat-cache-directory t))))

(ert-deftest octocat-test-items-cache-roundtrip ()
  "A saved item list loads back with its branch; a missing one is nil."
  (octocat-tests--with-cache-dir
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

(ert-deftest octocat-test-counts-and-summary-cache-roundtrip ()
  "Counts and the repo summary survive a save/load, nils included."
  (octocat-tests--with-cache-dir
    (octocat--counts-cache-save "o/r" 'pulls '(:open 1 :closed 0 :merged 9))
    (should (equal (octocat--counts-cache-load "o/r" 'pulls)
                   '(:open 1 :closed 0 :merged 9)))
    (octocat--counts-cache-save "o/r" 'issues '(:open 3 :closed 4))
    (should (equal (octocat--counts-cache-load "o/r" 'issues) '(:open 3 :closed 4)))
    (octocat-repo--summary-cache-save
     "o/r" '(:default-branch "main" :fork-parent nil :open-issues 2 :open-prs 1))
    (should (equal (octocat-repo--summary-cache-load "o/r")
                   '(:default-branch "main" :fork-parent nil :open-issues 2 :open-prs 1)))))

(ert-deftest octocat-test-with-stale-and-loading-suffix ()
  "Stale data stands in for a pending result and is marked as refreshing."
  (let ((pending '(:status pending)))
    (should (equal (octocat-vui-with-stale pending '(1 2))
                   '(:status ready :data (1 2) :refreshing t)))
    (should (eq (octocat-vui-with-stale pending nil) pending))
    (let ((ready '(:status ready :data (3))))
      (should (eq (octocat-vui-with-stale ready '(1 2)) ready))))
  (should (equal (octocat-vui-loading-suffix '(:refreshing t))
                 "  (loading…)"))
  (should (equal (octocat-vui-loading-suffix '(:refreshing t) 0) "  (loading… ⠋)"))
  (should (equal (octocat-vui-loading-suffix '(:refreshing t) 11) "  (loading… ⠙)"))
  (should (equal (octocat-vui-loading-suffix '(:status ready) 3) ""))
  (should (equal (octocat-vui-loading-suffix '(:status ready)) "")))

(ert-deftest octocat-test-state-label ()
  "State labels are fixed-width words; only open PRs can be drafts."
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN")) "open  "))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "CLOSED")) "closed"))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "MERGED" t)) "merged"))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN" t)) "draft "))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN" :false)) "open  ")))

(ert-deftest octocat-test-checks-ci-status ()
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

(ert-deftest octocat-test-checks-from-rest ()
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

(ert-deftest octocat-test-check-run-id ()
  "The workflow run ID comes from the details URL, not the check suite."
  (should (equal (octocat--check-run-id
                  (json-parse-string
                   "{\"details_url\":\"https://github.com/o/r/actions/runs/38218268003/job/1\",\"check_suite\":{\"id\":103543467452}}"))
                 38218268003))
  (should-not (octocat--check-run-id
               (json-parse-string "{\"details_url\":\"https://ci.example.com/build/7\"}"))))

(ert-deftest octocat-test-counts-query-and-parse ()
  "Pull requests also count merged; the response parses to a plist."
  (should (string-match-p "merged:pullRequests(states:MERGED)"
                          (octocat--counts-query 'pulls)))
  (should-not (string-match-p "merged" (octocat--counts-query 'issues)))
  (should (equal (octocat--parse-counts
                  "{\"data\":{\"repository\":{\"open\":{\"totalCount\":2},\"closed\":{\"totalCount\":5}}}}")
                 '(:open 2 :closed 5))))


;;; Issue timeline

(defun octocat-tests--json (string)
  "Parse the JSON STRING the way the gh helpers do."
  (json-parse-string string))

(defconst octocat-tests--issue-json
  (concat "{\"number\":7,\"state\":\"CLOSED\",\"body\":\"opening\","
          "\"createdAt\":\"2026-01-01T10:00:00Z\",\"closedAt\":\"2026-01-03T10:00:00Z\","
          "\"author\":{\"login\":\"ann\"},\"labels\":[],"
          "\"comments\":[{\"author\":{\"login\":\"bob\"},\"body\":\"later\","
          "\"createdAt\":\"2026-01-04T10:00:00Z\"},"
          "{\"author\":{\"login\":\"cy\"},\"body\":\"first\","
          "\"createdAt\":\"2026-01-02T10:00:00Z\"}]}")
  "A closed issue with two comments, the later one listed first.")

(ert-deftest octocat-test-issue-timeline-orders-by-time ()
  "Post, comments and events interleave by timestamp."
  (let* ((issue  (octocat-tests--json octocat-tests--issue-json))
         (events (octocat-tests--json
                  (concat "[{\"event\":\"labeled\",\"created_at\":\"2026-01-02T12:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"},\"label\":{\"name\":\"bug\",\"color\":\"d73a4a\"}},"
                          "{\"event\":\"commented\",\"created_at\":\"2026-01-02T10:00:00Z\"},"
                          "{\"event\":\"closed\",\"created_at\":\"2026-01-03T10:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"},\"state_reason\":\"completed\"}]")))
         (items (octocat-timeline-items issue "opened this issue" events)))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items)
                   '(post comment event event comment)))
    (should (equal (plist-get (nth 1 items) :actor) "@cy"))
    (should (equal (plist-get (nth 3 items) :text) "closed this as completed"))
    (should (eq (plist-get (car items) :target) 'body))
    (should (hash-table-p (plist-get (nth 1 items) :target)))))

(ert-deftest octocat-test-timeline-merges-label-events ()
  "One actor's label events within a minute become a single entry."
  (let* ((issue  (octocat-tests--json octocat-tests--issue-json))
         (ev (lambda (kind actor time name)
               (format "{\"event\":\"%s\",\"created_at\":\"%s\",\"actor\":{\"login\":\"%s\"},\"label\":{\"name\":\"%s\",\"color\":\"d73a4a\"}}"
                       kind time actor name)))
         (events (octocat-tests--json
                  (concat "["
                          (string-join
                           (list (funcall ev "labeled" "ann" "2026-01-02T12:00:00Z" "bug")
                                 (funcall ev "labeled" "ann" "2026-01-02T12:00:01Z" "docs")
                                 (funcall ev "unlabeled" "ann" "2026-01-02T12:00:02Z" "wip")
                                 (funcall ev "labeled" "bob" "2026-01-02T12:00:03Z" "x")
                                 (funcall ev "labeled" "ann" "2026-01-02T13:00:00Z" "y"))
                           ",")
                          "]")))
         (texts (mapcar (lambda (i) (substring-no-properties (plist-get i :text)))
                        (seq-filter (lambda (i) (eq (plist-get i :kind) 'event))
                                    (octocat-timeline-items issue "opened this issue" events)))))
    (should (equal (seq-take texts 3)
                   '("added the  bug   docs  labels and removed the  wip  label"
                     "added the  x  label"
                     "added the  y  label")))))

(ert-deftest octocat-test-timeline-merges-renames ()
  "Consecutive title changes by one actor become one entry."
  (let* ((issue  (octocat-tests--json octocat-tests--issue-json))
         (ev (lambda (time from to)
               (format "{\"event\":\"renamed\",\"created_at\":\"%s\",\"actor\":{\"login\":\"ann\"},\"rename\":{\"from\":\"%s\",\"to\":\"%s\"}}"
                       time from to)))
         (events (octocat-tests--json
                  (concat "[" (string-join
                               (list (funcall ev "2026-01-02T12:00:00Z" "a" "b")
                                     (funcall ev "2026-01-02T12:05:00Z" "b" "c"))
                               ",")
                          "]")))
         (renames (seq-filter (lambda (i) (plist-get i :rename))
                              (octocat-timeline-items issue "opened this issue" events))))
    (should (= (length renames) 1))
    (should (equal (plist-get (car renames) :rename) '("a" . "c")))
    (should (equal (substring-no-properties (plist-get (car renames) :text))
                   "changed the title a → c"))))

(ert-deftest octocat-test-issue-timeline-close-without-events ()
  "Before the events load, a close still shows, from `closedAt'."
  (let ((items (octocat-timeline-items (octocat-tests--json octocat-tests--issue-json)
                                       "opened this issue" nil)))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items)
                   '(post comment event comment)))
    (should (equal (plist-get (nth 2 items) :actor) ""))))

(ert-deftest octocat-test-issue-event-text ()
  "Events render as short phrases; unknown ones are skipped."
  (let ((text (lambda (json) (octocat-timeline--event-text (octocat-tests--json json)))))
    (should (equal (funcall text "{\"event\":\"assigned\",\"actor\":{\"login\":\"a\"},\"assignee\":{\"login\":\"a\"}}")
                   "self-assigned this"))
    (should (equal (funcall text "{\"event\":\"assigned\",\"actor\":{\"login\":\"a\"},\"assignee\":{\"login\":\"b\"}}")
                   "assigned @b"))
    (should (equal (substring-no-properties
                    (funcall text "{\"event\":\"renamed\",\"rename\":{\"from\":\"x\",\"to\":\"y\"}}"))
                   "changed the title x → y"))
    (should (equal (funcall text "{\"event\":\"reopened\"}") "reopened this"))
    (should-not (funcall text "{\"event\":\"subscribed\"}"))
    (should-not (funcall text "{\"event\":\"labeled\",\"label\":null}"))))

(ert-deftest octocat-test-issue-entry-string ()
  "A comment entry carries its target, a quote rail and its body."
  (let* ((comment (octocat-tests--json
                   "{\"author\":{\"login\":\"bob\"},\"body\":\"hi\\nthere\",\"createdAt\":\"2026-01-04T10:00:00Z\"}"))
         (entry (octocat-timeline--entry-string
                 (list :time "2026-01-04T10:00:00Z" :kind 'comment :actor "@bob"
                       :verb "commented" :body "hi\nthere" :target comment)
                 t 80)))
    (should (string-match-p "@bob commented" entry))
    (should (string-match-p "│ hi\n  │ there\\'" (substring-no-properties entry)))
    (should (eq (get-text-property (1- (length entry)) 'octocat-timeline-target entry)
                comment))))

(ert-deftest octocat-test-timeline-merged-pr ()
  "A merged PR shows its merge, not the close GitHub logs beside it."
  (let* ((pr (octocat-tests--json
              (concat "{\"body\":\"\",\"createdAt\":\"2026-01-01T10:00:00Z\","
                      "\"mergedAt\":\"2026-01-02T10:00:00Z\",\"closedAt\":\"2026-01-02T10:00:00Z\","
                      "\"author\":{\"login\":\"ann\"},\"comments\":[]}")))
         (events (octocat-tests--json
                  (concat "[{\"event\":\"closed\",\"created_at\":\"2026-01-02T10:00:00Z\"},"
                          "{\"event\":\"merged\",\"created_at\":\"2026-01-02T10:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"}}]")))
         (kinds (lambda (evs)
                  (mapcar (lambda (i) (plist-get i :text))
                          (cdr (octocat-timeline-items pr "opened this pull request" evs))))))
    (should (equal (funcall kinds events) '("merged this")))
    ;; Without events the merge still shows, from `mergedAt'.
    (should (equal (funcall kinds nil) '("merged this")))))

(ert-deftest octocat-test-timeline-post-leads ()
  "The opening post comes first even if an extra item predates it."
  (let* ((pr (octocat-tests--json
              "{\"body\":\"x\",\"createdAt\":\"2026-01-02T10:00:00Z\",\"author\":{\"login\":\"ann\"},\"comments\":[]}"))
         (items (octocat-timeline-items
                 pr "opened this pull request" nil
                 (list (list :time "2026-01-01T10:00:00Z" :kind 'commit :actor "" :text "c")))))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items) '(post commit)))))

(ert-deftest octocat-test-timeline-review-events ()
  "Review requests name a user or a team."
  (let ((text (lambda (json) (octocat-timeline--event-text (octocat-tests--json json)))))
    (should (equal (funcall text "{\"event\":\"review_requested\",\"requested_reviewer\":{\"login\":\"zed\"}}")
                   "requested a review from @zed"))
    (should (equal (funcall text "{\"event\":\"review_requested\",\"requested_team\":{\"name\":\"core\"}}")
                   "requested a review from core"))))

(ert-deftest octocat-test-user-normalize ()
  "A handle is accepted with or without \"@\"; anything else is rejected."
  (should (equal (octocat-user--normalize "@octocat") "octocat"))
  (should (equal (octocat-user--normalize "  octo-cat ") "octo-cat"))
  (should-not (octocat-user--normalize "octocat/hello"))
  (should-not (octocat-user--normalize "@"))
  (should-not (octocat-user--normalize "")))

(ert-deftest octocat-test-user-profile-lines ()
  "The header shows the handle, name, bio, details and counts."
  (let* ((profile (octocat-tests--json
                   "{\"login\":\"octocat\",\"name\":\"The Octocat\",\"type\":\"User\",\"bio\":\"Hi\",\"company\":\"@github\",\"location\":null,\"blog\":\"\",\"followers\":3,\"following\":1,\"public_repos\":8}"))
         (lines (mapcar #'substring-no-properties (octocat-user--profile-lines profile))))
    (should (equal (nth 0 lines) "@octocat  The Octocat"))
    (should (equal (nth 1 lines) "Hi"))
    (should (equal (nth 2 lines) "@github"))
    (should (equal (nth 3 lines) "3 followers  ·  1 following  ·  8 public repos"))))

(ert-deftest octocat-test-user-parse-pinned ()
  "Pinned repositories come back REST-shaped; gists and unknown owners drop out."
  (let ((repos (octocat-user--parse-pinned
                (concat "{\"data\":{\"repositoryOwner\":{\"pinnedItems\":{\"nodes\":["
                        "{\"nameWithOwner\":\"bob/app\",\"description\":null,"
                        "\"stargazerCount\":7,\"primaryLanguage\":{\"name\":\"Go\"},"
                        "\"pushedAt\":\"2026-01-01T10:00:00Z\",\"isFork\":false,\"isArchived\":true},"
                        "{}]}}}}"))))
    (should (= (length repos) 1))
    (should (equal (gethash "full_name" (car repos)) "bob/app"))
    (should (equal (gethash "language" (car repos)) "Go"))
    (should (= (gethash "stargazers_count" (car repos)) 7))
    (should (eq (gethash "archived" (car repos)) t))
    (should-not (octocat-user--parse-pinned "{\"data\":{\"repositoryOwner\":null}}"))))

(provide 'octocat-tests)
;;; octocat-tests.el ends here
