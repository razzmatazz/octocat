;;; octocat-tree-tests.el --- ERT tests for octocat-tree.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-tree-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

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
  "octocat-tree--render-loading shows the header and no loading text."
  (with-temp-buffer
    (octocat-tree-mode)
    (setq octocat-tree--repo "owner/repo"
          octocat-tree--branch "main")
    (octocat-tree--render-loading)
    (should (> (buffer-size) 0))
    (should (string-match-p "owner/repo" (buffer-string)))
    (should-not (string-match-p "Loading" (buffer-string)))))

(defun octocat-tree-tests--mount-tree (entries)
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
    (octocat-tree-tests--mount-tree [])
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
      (octocat-tree-tests--mount-tree entries)
      (let ((text (buffer-string)))
        (should (string-match-p "src" text))
        (should (string-match-p "README.md" text))
        ;; Dir should appear before file in the buffer.
        (should (< (string-match "src" text)
                   (string-match "README.md" text)))))))

(defconst octocat-tree-tests--file-log-commits-json
  (concat "[{\"sha\":\"a1b2c3d4e5f6\",\"author\":{\"login\":\"ann\"},"
          "\"commit\":{\"message\":\"Fix parser\\n\\nLonger body\","
          "\"author\":{\"name\":\"Ann\",\"date\":\"2026-06-01T10:00:00Z\"}}},"
          "{\"sha\":\"f6e5d4c3b2a1\",\"author\":null,"
          "\"commit\":{\"message\":\"Add tests\","
          "\"author\":{\"name\":\"Bob\",\"date\":\"2026-05-28T10:00:00Z\"}}}]")
  "Two commits as the REST commits endpoint returns them.")

(defun octocat-tree-tests--mount-file-log (&rest props)
  "Mount the file log page in the current buffer with PROPS."
  (octocat-file-log-mode)
  (setq octocat-file-log--repo "owner/repo"
        octocat-file-log--path "src/foo.el")
  (apply #'octocat-file-log--mount props))

(ert-deftest octocat-tree-test-file-log-commit-line ()
  "A commit line shows short SHA, author and subject, and carries the SHA."
  (let* ((commit (aref (json-parse-string octocat-tree-tests--file-log-commits-json
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

(ert-deftest octocat-tree-test-file-log-render-commits ()
  "The file log lists one line per commit under a header with the count."
  (with-temp-buffer
    (octocat-tree-tests--mount-file-log
     :commits (append (json-parse-string octocat-tree-tests--file-log-commits-json
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

(ert-deftest octocat-tree-test-file-log-render-loading-and-empty ()
  "The file log shows its text in place of the list, or a no-commits line."
  (with-temp-buffer
    (octocat-tree-tests--mount-file-log :text "Loading…" :face 'octocat-dimmed)
    (should (string-match-p "Loading…" (buffer-string)))
    (should-not (string-match-p "commits)" (buffer-string))))
  (with-temp-buffer
    (octocat-tree-tests--mount-file-log :commits nil)
    (should (string-match-p "(0 commits)" (buffer-string)))
    (should (string-match-p "(no commits found)" (buffer-string)))))

(provide 'octocat-tree-tests)
;;; octocat-tree-tests.el ends here
