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

(ert-deftest octocat-repo-test-branch-candidates ()
  "The default branch comes first, then the pushed local one, each noted."
  (should (equal (octocat--branch-candidates '("a" "main" "feat") "main" "feat")
                 '("main" "feat" "a")))
  (should (equal (octocat--branch-candidates '("a" "main") "main" "unpushed")
                 '("main" "a")))
  (should (equal (octocat--branch-candidates '("a" "main") "main" "main")
                 '("main" "a")))
  (should (equal (octocat--branch-note "main" "main" "feat") "  default"))
  (should (equal (octocat--branch-note "feat" "main" "feat") "  checked out"))
  (should-not (octocat--branch-note "a" "main" "feat")))

(ert-deftest octocat-repo-test-async-branches ()
  "The cached branches show first; the fetched ones replace and are cached."
  (let ((octocat-cache-directory (make-temp-file "octocat-cache" t))
        got deliver)
    (unwind-protect
        (cl-letf (((symbol-function 'octocat--list-branches)
                   (lambda (_repo callback) (setq deliver callback))))
          (octocat--items-cache-save "o/r" "branches" "all" '("old" "main"))
          (let ((stage (funcall (octocat--async-branches "o/r" "main" nil)
                                (lambda (action)
                                  (pcase action
                                    ('flush (setq got nil))
                                    ((pred consp) (setq got (append got action))))))))
            (funcall stage 'setup)
            (should (equal got '("main" "old")))
            (funcall deliver '("new" "main"))
            (should (equal got '("main" "new")))
            (should (equal (plist-get (octocat--items-cache-load "o/r" "branches" "all")
                                      :items)
                           '("new" "main")))))
      (delete-directory octocat-cache-directory t))))

(ert-deftest octocat-repo-test-commits-cache-id ()
  "The default branch keeps its cache; others get one each."
  (should (equal (octocat-repo--commits-cache-id nil) "default"))
  (should (equal (octocat-repo--commits-cache-id "feat/x") "branch-feat--x")))

(ert-deftest octocat-repo-test-item-lines ()
  "Item lines put the labels on the title line and cut only given a width."
  (let ((cells (list :title (make-string 60 ?t) :author "@a" :date "1d"
                     :chips "bug" :branch "b" :number "#1")))
    (pcase-let ((`(,top ,bottom) (octocat-repo-vui--item-lines "open" cells '(:review :branch))))
      (should (string-suffix-p "  bug" top))
      (should (string-match-p (make-string 60 ?t) top))
      (should (string-suffix-p "#1 by @a · 1d · b" bottom)))
    (dolist (line (octocat-repo-vui--item-lines "open" cells '(:branch) 40))
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
            (should (equal (plist-get u :upstream) "origin/main"))
            (should (= (plist-get u :behind) 1))))
      (delete-directory root t))))

(ert-deftest octocat-repo-test-parse-history ()
  "History edges become REST-shaped commits that keep their cursor."
  (let* ((json "{\"data\":{\"repository\":{\"object\":{\"history\":{\"edges\":[{\"cursor\":\"abc 0\",\"node\":{\"oid\":\"abc\",\"messageHeadline\":\"Fix it\",\"authoredDate\":\"2026-10-14T13:40:36Z\",\"author\":{\"name\":\"Ann\",\"email\":\"a@x\",\"user\":{\"login\":\"ann\"}}}},{\"cursor\":\"abc 1\",\"node\":{\"oid\":\"def\",\"messageHeadline\":\"Old\",\"authoredDate\":\"2026-10-13T00:00:00Z\",\"author\":{\"name\":\"Bo\",\"email\":\"b@x\",\"user\":null}}}]}}}}}")
         (commits (octocat-repo--parse-history json))
         (first   (car commits)))
    (should (equal (gethash "sha" first) "abc"))
    (should (equal (gethash "message" (gethash "commit" first)) "Fix it"))
    (should (equal (octocat--commit-author first) "@ann"))
    (should (equal (octocat--commit-author (cadr commits)) "Bo"))
    (should (equal (gethash "cursor" (cadr commits)) "abc 1")))
  (should-error (octocat-repo--parse-history
                 "{\"data\":{\"repository\":{\"object\":null}}}")))

(ert-deftest octocat-repo-test-numbers-link ()
  "Each number opens its own issue, in its repository when another."
  (let* ((refs (json-parse-string
                "[{\"number\":3},{\"number\":4,\"repository\":{\"name\":\"x\",\"owner\":{\"login\":\"o\"}}}]"))
         (s (octocat-repo-vui--numbers "a/b" refs (lambda (r n) (list r n)))))
    (should (equal (substring-no-properties s) "#3 o/x#4"))
    (should (get-text-property 0 'keymap s))
    (should (equal (funcall (lookup-key (get-text-property 4 'keymap s) (kbd "RET")))
                   '("o/x" 4)))))

(provide 'octocat-repo-tests)
;;; octocat-repo-tests.el ends here
