;;; octocat-user-tests.el --- ERT tests for octocat-user.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-user-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(ert-deftest octocat-user-test-normalize ()
  "A handle is accepted with or without \"@\"; anything else is rejected."
  (should (equal (octocat-user--normalize "@octocat") "octocat"))
  (should (equal (octocat-user--normalize "  octo-cat ") "octo-cat"))
  (should-not (octocat-user--normalize "octocat/hello"))
  (should-not (octocat-user--normalize "@"))
  (should-not (octocat-user--normalize "")))

(ert-deftest octocat-user-test-profile-lines ()
  "The header shows the handle, name, bio, details and counts."
  (let* ((profile (json-parse-string
                   "{\"login\":\"octocat\",\"name\":\"The Octocat\",\"type\":\"User\",\"bio\":\"Hi\",\"company\":\"@github\",\"location\":null,\"blog\":\"\",\"followers\":3,\"following\":1,\"public_repos\":8}"))
         (lines (mapcar #'substring-no-properties (octocat-user--profile-lines profile))))
    (should (equal (nth 0 lines) "@octocat  The Octocat"))
    (should (equal (nth 1 lines) "Hi"))
    (should (equal (nth 2 lines) "@github"))
    (should (equal (nth 3 lines) "3 followers  ·  1 following  ·  8 public repos"))))

(ert-deftest octocat-user-test-parse-pinned ()
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

(provide 'octocat-user-tests)
;;; octocat-user-tests.el ends here
