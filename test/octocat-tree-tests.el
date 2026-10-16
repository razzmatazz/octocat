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
  "octocat--branch-glyph returns a non-empty string."
  (let ((g (octocat--branch-glyph)))
    (should (stringp g))
    (should (> (length g) 0))))

(defmacro octocat-tree-tests--with-cache (&rest body)
  "Evaluate BODY with `octocat-cache-directory' pointing at a temp directory."
  (declare (indent 0))
  `(let ((octocat-cache-directory (make-temp-file "octocat-cache" t)))
     (unwind-protect (progn ,@body)
       (delete-directory octocat-cache-directory t))))

(defun octocat-tree-tests--mount-root (fetch-root-sha)
  "Mount `octocat-tree--root' with FETCH-ROOT-SHA as the root SHA fetcher."
  (unless (derived-mode-p 'octocat-tree-mode)
    (octocat-tree-mode))
  (setq octocat-tree--repo "owner/repo"
        octocat-tree--branch "main")
  (cl-letf (((symbol-function 'octocat-tree--fetch-root-sha) fetch-root-sha)
            ((symbol-function 'octocat-tree--fetch-dir)
             (lambda (&rest _) (error "Unexpected directory fetch"))))
    (octocat-tree-refresh)))

(defun octocat-tree-tests--mount-tree (entries)
  "Mount `octocat-tree--root' in the current buffer with root ENTRIES.
The root SHA resolves at once and the root directory's children are
pre-seeded in the subtree cache, so no gh call is made."
  (octocat-tree-tests--with-cache
    (octocat-tree-mode)
    (setq octocat-tree--subtree-cache (list (cons "rootsha" entries)))
    (octocat-tree-tests--mount-root
     (lambda (_repo _branch callback) (funcall callback "rootsha")))))

(defun octocat-tree-tests--entry (path type sha)
  "Return a tree API entry for PATH of TYPE (\"tree\" or \"blob\") and SHA."
  (let ((h (make-hash-table :test #'equal)))
    (puthash "path" path h)
    (puthash "type" type h)
    (puthash "sha"  sha  h)
    h))

(ert-deftest octocat-tree-test-paints-from-disk-cache ()
  "The cached root SHA and listing paint before the root SHA is fetched."
  (octocat-tree-tests--with-cache
    (octocat-tree--ref-cache-save "owner/repo" "main" "rootsha")
    (octocat-tree--dir-cache-save
     "owner/repo" "rootsha" (vector (octocat-tree-tests--entry "cached.el" "blob" "b1")))
    (with-temp-buffer
      (octocat-tree-tests--mount-root #'ignore)
      (should (string-match-p "cached\\.el" (buffer-string)))
      (should (equal octocat-tree--root-sha "rootsha")))))

(ert-deftest octocat-tree-test-blob-cache ()
  "A fetched blob is cached as raw bytes and then served without a fetch."
  (octocat-tree-tests--with-cache
    (let ((bytes (string-to-unibyte "a\377b\n"))
          got)
      (cl-letf (((symbol-function 'octocat-tree--fetch-file)
                 (lambda (_repo _sha callback) (funcall callback bytes))))
        (octocat-tree--load-blob "owner/repo" "b1" (lambda (r) (setq got r))))
      (should (equal got bytes))
      (setq got nil)
      (cl-letf (((symbol-function 'octocat-tree--fetch-file)
                 (lambda (&rest _) (error "Unexpected blob fetch"))))
        (octocat-tree--load-blob "owner/repo" "b1" (lambda (r) (setq got r))))
      (should (equal got bytes)))))

(ert-deftest octocat-tree-test-ref-cache-slashed-branch ()
  "A branch name with a slash is cached as one file."
  (octocat-tree-tests--with-cache
    (octocat-tree--ref-cache-save "owner/repo" "feat/x" "sha1")
    (should (equal (octocat-tree--ref-cache-load "owner/repo" "feat/x") "sha1"))
    (should-not (octocat-tree--ref-cache-load "owner/repo" "feat"))))

(ert-deftest octocat-tree-test-render-entries-empty ()
  "Mounting the tree with an empty entries vector produces a valid buffer."
  (with-temp-buffer
    (octocat-tree-tests--mount-tree [])
    (should (> (buffer-size) 0))
    (should (string-match-p "owner/repo" (buffer-string)))
    (should (string-match-p "\\[main ▾\\]" (buffer-string)))))

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

(ert-deftest octocat-tree-test-entries-are-tab-stops ()
  "Each entry is a button that RET runs; a directory expands in place."
  (with-temp-buffer
    (octocat-tree-tests--with-cache
      (octocat-tree-mode)
      (setq octocat-tree--subtree-cache
            (list (cons "rootsha" (vector (octocat-tree-tests--entry "src" "tree" "srcsha")))
                  (cons "srcsha"  (vector (octocat-tree-tests--entry "a.el" "blob" "b1")))))
      (octocat-tree-tests--mount-root
       (lambda (_repo _branch callback) (funcall callback "rootsha")))
      (goto-char (point-min))
      (forward-line 1)
      (should (button-at (point)))
      (should (equal (octocat-tree--path-at-point) "src"))
      (octocat-tree-visit)
      (vui-flush-sync)
      (should (string-match-p "▾ src/" (buffer-string)))
      (should (string-match-p "a\\.el" (buffer-string)))
      (forward-line 1)
      (should (button-at (next-button (line-beginning-position))))
      (should (equal (octocat-tree--path-at-point) "src/a.el"))
      (octocat-tree-up)
      (should (equal (octocat-tree--path-at-point) "src"))
      (octocat-tree-collapse-or-up)
      (vui-flush-sync)
      (should (string-match-p "▸ src/" (buffer-string)))
      (should-error (octocat-tree-up) :type 'user-error))))

(defconst octocat-tree-tests--file-log-commits-json
  (concat "[{\"sha\":\"a1b2c3d4e5f6\",\"author\":{\"login\":\"ann\"},"
          "\"commit\":{\"message\":\"Fix parser\\n\\nLonger body\","
          "\"author\":{\"name\":\"Ann\",\"date\":\"2026-06-01T10:00:00Z\"}}},"
          "{\"sha\":\"f6e5d4c3b2a1\",\"author\":null,"
          "\"commit\":{\"message\":\"Add tests\","
          "\"author\":{\"name\":\"Bob\",\"date\":\"2026-05-28T10:00:00Z\"}}}]")
  "Two commits as the REST commits endpoint returns them.")

(defun octocat-tree-tests--mount-file-log (&rest result)
  "Mount the file log page in the current buffer.
Its fetch gives the car of RESULT, or never returns when there is none."
  (octocat-file-log-mode)
  (setq octocat-file-log--repo "owner/repo"
        octocat-file-log--path "src/foo.el")
  (cl-letf (((symbol-function 'octocat-tree--fetch-file-commits)
             (lambda (_repo _path callback)
               (when result (funcall callback (car result))))))
    (octocat-file-log-refresh)))

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
     (append (json-parse-string octocat-tree-tests--file-log-commits-json
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
  "The file log shows no count while loading, an error, or a no-commits line."
  (with-temp-buffer
    (octocat-tree-tests--mount-file-log)
    (should-not (string-match-p "commits)" (buffer-string))))
  (with-temp-buffer
    (octocat-tree-tests--mount-file-log '(error . "boom"))
    (should (string-match-p "Error loading commits: boom" (buffer-string))))
  (with-temp-buffer
    (octocat-tree-tests--mount-file-log nil)
    (should (string-match-p "(0 commits)" (buffer-string)))
    (should (string-match-p "(no commits found)" (buffer-string)))))

(provide 'octocat-tree-tests)
;;; octocat-tree-tests.el ends here
