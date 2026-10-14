;;; octocat-vui-tests.el --- ERT tests for octocat-vui.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-vui-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-vui-test-filter-active-p ()
  "Only a query other than the default counts as an active filter."
  (should-not (octocat-vui-list-filter-active-p nil))
  (should-not (octocat-vui-list-filter-active-p " is:open "))
  (should (octocat-vui-list-filter-active-p "is:closed"))
  (should (octocat-vui-list-filter-active-p "")))

(ert-deftest octocat-vui-test-filter-tokenize-keeps-quotes ()
  "Quoted values stay in one token."
  (should (equal (octocat-vui-list--tokenize "is:open label:\"good first issue\" bob")
                 '("is:open" "label:\"good first issue\"" "bob"))))

(ert-deftest octocat-vui-test-filter-values-unquotes ()
  "Qualifier values are returned unquoted, negated qualifiers excluded."
  (should (equal (octocat-vui-list--values
                  "label:bug label:\"good first issue\" -label:wip" "label:")
                 '("bug" "good first issue"))))

(ert-deftest octocat-vui-test-filter-with-values ()
  "Setting a qualifier replaces its tokens and quotes values with spaces."
  (should (equal (octocat-vui-list--with-values
                  "is:open label:old -label:wip" "label:" '("a b" "c"))
                 "is:open -label:wip label:\"a b\" label:c"))
  (should (equal (octocat-vui-list--with-values "is:open author:x" "author:" nil)
                 "is:open")))

(ert-deftest octocat-vui-test-filter-state ()
  "The state token is read, replaced and removed (\"all\")."
  (should (equal (octocat-vui-list--state "label:x is:closed") "closed"))
  (should (equal (octocat-vui-list--state "label:x") "all"))
  (should (equal (octocat-vui-list--with-state "is:open label:x" "merged")
                 "is:merged label:x"))
  (should (equal (octocat-vui-list--with-state "is:open label:x" "all")
                 "label:x")))

(ert-deftest octocat-vui-test-with-stale ()
  "Stale data stands in for a pending result and is marked as refreshing."
  (let ((pending '(:status pending)))
    (should (equal (octocat-vui-with-stale pending '(1 2))
                   '(:status ready :data (1 2) :refreshing t)))
    (should (eq (octocat-vui-with-stale pending nil) pending))
    (let ((ready '(:status ready :data (3))))
      (should (eq (octocat-vui-with-stale ready '(1 2)) ready)))))

(ert-deftest octocat-vui-test-detail-skeleton ()
  "The skeleton names the item and keeps its grey bars within WIDTH."
  (let ((text (octocat-vui-detail-skeleton "o/r" 7 30)))
    (should (string-prefix-p "o/r#7\n" text))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 30)))))

(ert-deftest octocat-vui-test-list-skeleton ()
  "The list skeleton draws two-line rows of grey bars within WIDTH."
  (let ((text (octocat-vui-list-skeleton 30)))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (should (= (% (length (split-string text "\n")) 2) 0))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 29)))))

(ert-deftest octocat-vui-test-line-skeleton ()
  "The line skeleton draws one-line rows of grey bars."
  (let ((text (octocat-vui-line-skeleton)))
    (should (text-property-any 0 (length text) 'face 'octocat-skeleton text))
    (should (> (length (split-string text "\n")) 1))))

(ert-deftest octocat-vui-test-mode-line-loading ()
  "The mode line shows :loading while any component of the buffer loads."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (octocat-vui--add-loading buf 1)
      (octocat-vui--add-loading buf 1)
      (should (equal mode-line-process '(":loading " octocat-vui--spinner)))
      (octocat-vui--add-loading buf -1)
      (should (equal mode-line-process '(":loading " octocat-vui--spinner)))
      (octocat-vui--add-loading buf -1)
      (should (null mode-line-process)))))

(provide 'octocat-vui-tests)
;;; octocat-vui-tests.el ends here
