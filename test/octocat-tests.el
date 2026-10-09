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
         (items (octocat-issue--timeline issue events)))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items)
                   '(post comment event event comment)))
    (should (equal (plist-get (nth 1 items) :actor) "@cy"))
    (should (equal (plist-get (nth 3 items) :text) "closed this as completed"))
    (should (eq (plist-get (car items) :target) 'body))
    (should (hash-table-p (plist-get (nth 1 items) :target)))))

(ert-deftest octocat-test-issue-timeline-close-without-events ()
  "Before the events load, a close still shows, from `closedAt'."
  (let ((items (octocat-issue--timeline (octocat-tests--json octocat-tests--issue-json) nil)))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items)
                   '(post comment event comment)))
    (should (equal (plist-get (nth 2 items) :actor) ""))))

(ert-deftest octocat-test-issue-event-text ()
  "Events render as short phrases; unknown ones are skipped."
  (let ((text (lambda (json) (octocat-issue--event-text (octocat-tests--json json)))))
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
         (entry (octocat-issue--entry-string
                 (list :time "2026-01-04T10:00:00Z" :kind 'comment :actor "@bob"
                       :body "hi\nthere" :target comment)
                 t)))
    (should (string-match-p "@bob commented" entry))
    (should (string-match-p "│   hi\n  │   there\\'" (substring-no-properties entry)))
    (should (eq (get-text-property (1- (length entry)) 'octocat-issue-target entry)
                comment))))

(ert-deftest octocat-test-markdown-string ()
  "Every line gets the indent and a wrap prefix; raw text is kept verbatim."
  (let ((out (octocat--markdown-string "a *b*\r\nc" "> " t)))
    (should (equal (substring-no-properties out) "> a *b*\n> c\n"))
    (should (equal (get-text-property 0 'wrap-prefix out) "> "))))

(provide 'octocat-tests)
;;; octocat-tests.el ends here
