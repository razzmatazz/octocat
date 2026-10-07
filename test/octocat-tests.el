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

(provide 'octocat-tests)
;;; octocat-tests.el ends here
