;;; octocat-repo-tests.el --- ERT tests for octocat-repo.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-repo-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defmacro octocat-repo-tests--with-remote (url &rest body)
  "Evaluate BODY with `shell-command-to-string' mocked to return URL."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'shell-command-to-string) (lambda (_) ,url)))
     ,@body))

(ert-deftest octocat-repo-test-ssh ()
  "Parse SSH remote URL."
  (octocat-repo-tests--with-remote "git@github.com:owner/repo.git"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-ssh-no-suffix ()
  "Parse SSH remote URL without .git suffix."
  (octocat-repo-tests--with-remote "git@github.com:owner/repo"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-https ()
  "Parse HTTPS remote URL."
  (octocat-repo-tests--with-remote "https://github.com/owner/repo.git"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-https-no-suffix ()
  "Parse HTTPS remote URL without .git suffix."
  (octocat-repo-tests--with-remote "https://github.com/owner/repo"
    (should (equal (octocat-repo--current-repo) "owner/repo"))))

(ert-deftest octocat-repo-test-no-remote ()
  "Signal user-error when no origin remote is found."
  (octocat-repo-tests--with-remote ""
    (should-error (octocat-repo--current-repo) :type 'user-error)))

(ert-deftest octocat-repo-test-parse-summary-fork ()
  "A fork's summary carries its parent, default branch and counts."
  (should (equal (octocat-repo--parse-summary
                  "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"name\":\"main\"},\"parent\":{\"nameWithOwner\":\"up/stream\"},\"issues\":{\"totalCount\":3},\"pullRequests\":{\"totalCount\":2}}}}")
                 '(:default-branch "main" :fork-parent "up/stream"
                   :open-issues 3 :open-prs 2))))

(ert-deftest octocat-repo-test-parse-summary-empty-repo ()
  "A non-fork with no default branch yields nils, not errors."
  (should (equal (octocat-repo--parse-summary
                  "{\"data\":{\"repository\":{\"defaultBranchRef\":null,\"parent\":null,\"issues\":{\"totalCount\":0},\"pullRequests\":{\"totalCount\":0}}}}")
                 '(:default-branch nil :fork-parent nil
                   :open-issues 0 :open-prs 0))))

(ert-deftest octocat-repo-test-state-label ()
  "State labels are fixed-width words; only open PRs can be drafts."
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN")) "open  "))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "CLOSED")) "closed"))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "MERGED" t)) "merged"))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN" t)) "draft "))
  (should (equal (substring-no-properties (octocat-repo-vui--state-label "OPEN" :false)) "open  ")))

(defun octocat-repo-tests--commits (&rest shas)
  "Return commit hash-tables for SHAS."
  (mapcar (lambda (sha)
            (let ((c (make-hash-table :test #'equal)))
              (puthash "sha" sha c)
              c))
          shas))

(ert-deftest octocat-repo-test-commits-merge ()
  "The longest list from the same head wins; another head is dropped."
  (let ((fresh  (octocat-repo-tests--commits "c" "b"))
        (longer (octocat-repo-tests--commits "c" "b" "a"))
        (stale  (octocat-repo-tests--commits "b" "a" "z")))
    (should (eq (octocat-repo--commits-merge fresh longer) longer))
    (should (eq (octocat-repo--commits-merge fresh stale) fresh))
    (should (eq (octocat-repo--commits-merge longer fresh nil) longer))
    (should-not (octocat-repo--commits-merge nil fresh))))

(ert-deftest octocat-repo-test-item-lines ()
  "Item lines put the author on the title line and cut only given a width."
  (let ((cells (list :title (make-string 60 ?t) :author "@a" :date "1d"
                     :chips "bug" :branch "b" :ref "o/r#1")))
    (pcase-let ((`(,top ,bottom) (octocat-repo-vui--item-lines "open" cells '(:branch))))
      (should (string-suffix-p "  @a · 1d" top))
      (should (string-match-p (make-string 60 ?t) top))
      (should (string-suffix-p "bug  b" bottom)))
    (dolist (line (octocat-repo-vui--item-lines "open" cells '(:ref :branch) 40))
      (should (<= (string-width line) 39)))))

(ert-deftest octocat-repo-test-unpushed ()
  "Count local commits against the upstream, and how far it is ahead."
  (skip-unless (executable-find "git"))
  (let* ((root   (make-temp-file "octocat-unpushed" t))
         (origin (expand-file-name "origin" root))
         (clone  (expand-file-name "clone" root))
         (git    (lambda (dir &rest args)
                   (let ((default-directory (file-name-as-directory dir)))
                     (apply #'call-process "git" nil nil nil
                            "-c" "user.name=T" "-c" "user.email=t@t" args)))))
    (unwind-protect
        (progn
          (make-directory origin)
          (funcall git origin "init" "-q" "-b" "main")
          (funcall git origin "commit" "-q" "--allow-empty" "-m" "base")
          (funcall git root "clone" "-q" origin clone)
          (should-not (octocat-repo--unpushed clone))
          (funcall git clone "commit" "-q" "--allow-empty" "-m" "one")
          (funcall git clone "commit" "-q" "--allow-empty" "-m" "two")
          (funcall git origin "commit" "-q" "--allow-empty" "-m" "theirs")
          (funcall git clone "fetch" "-q")
          (let ((u (octocat-repo--unpushed clone)))
            (should (equal (mapcar (lambda (c) (plist-get c :subject))
                                   (plist-get u :commits))
                           '("two" "one")))
            (should (equal (plist-get u :branch) "main"))
            (should (equal (plist-get u :upstream) "origin/main"))
            (should (= (plist-get u :behind) 1))))
      (delete-directory root t))))

(provide 'octocat-repo-tests)
;;; octocat-repo-tests.el ends here
