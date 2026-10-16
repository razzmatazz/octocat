;;; octocat-timeline-tests.el --- ERT tests for octocat-timeline.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-timeline-tests.el

;;; Code:

(require 'ert)
(require 'octocat)

(defconst octocat-timeline-tests--issue-json
  (concat "{\"number\":7,\"state\":\"CLOSED\",\"body\":\"opening\","
          "\"createdAt\":\"2026-01-01T10:00:00Z\",\"closedAt\":\"2026-01-03T10:00:00Z\","
          "\"author\":{\"login\":\"ann\"},\"labels\":[],"
          "\"comments\":[{\"author\":{\"login\":\"bob\"},\"body\":\"later\","
          "\"createdAt\":\"2026-01-04T10:00:00Z\"},"
          "{\"author\":{\"login\":\"cy\"},\"body\":\"first\","
          "\"createdAt\":\"2026-01-02T10:00:00Z\"}]}")
  "A closed issue with two comments, the later one listed first.")

(ert-deftest octocat-timeline-test-issue-orders-by-time ()
  "Post, comments and events interleave by timestamp."
  (let* ((issue  (json-parse-string octocat-timeline-tests--issue-json))
         (events (json-parse-string
                  (concat "[{\"event\":\"labeled\",\"created_at\":\"2026-01-02T12:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"},\"label\":{\"name\":\"bug\",\"color\":\"d73a4a\"}},"
                          "{\"event\":\"commented\",\"created_at\":\"2026-01-02T10:00:00Z\"},"
                          "{\"event\":\"closed\",\"created_at\":\"2026-01-03T10:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"},\"state_reason\":\"completed\"}]")))
         (items (octocat-timeline-items issue "opened this issue" events nil)))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items)
                   '(post comment event event comment)))
    (should (equal (plist-get (nth 1 items) :actor) "@cy"))
    (should (equal (plist-get (nth 3 items) :text) "closed this as completed"))
    (should (eq (plist-get (car items) :target) 'body))
    (should (hash-table-p (plist-get (nth 1 items) :target)))))

(ert-deftest octocat-timeline-test-merges-label-events ()
  "One actor's label events within a minute become a single entry."
  (let* ((issue  (json-parse-string octocat-timeline-tests--issue-json))
         (ev (lambda (kind actor time name)
               (format "{\"event\":\"%s\",\"created_at\":\"%s\",\"actor\":{\"login\":\"%s\"},\"label\":{\"name\":\"%s\",\"color\":\"d73a4a\"}}"
                       kind time actor name)))
         (events (json-parse-string
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
                                    (octocat-timeline-items issue "opened this issue" events nil)))))
    (should (equal (seq-take texts 3)
                   '("added the  bug   docs  labels and removed the  wip  label"
                     "added the  x  label"
                     "added the  y  label")))))

(ert-deftest octocat-timeline-test-merges-renames ()
  "Consecutive title changes by one actor become one entry."
  (let* ((issue  (json-parse-string octocat-timeline-tests--issue-json))
         (ev (lambda (time from to)
               (format "{\"event\":\"renamed\",\"created_at\":\"%s\",\"actor\":{\"login\":\"ann\"},\"rename\":{\"from\":\"%s\",\"to\":\"%s\"}}"
                       time from to)))
         (events (json-parse-string
                  (concat "[" (string-join
                               (list (funcall ev "2026-01-02T12:00:00Z" "a" "b")
                                     (funcall ev "2026-01-02T12:05:00Z" "b" "c"))
                               ",")
                          "]")))
         (renames (seq-filter (lambda (i) (plist-get i :rename))
                              (octocat-timeline-items issue "opened this issue" events nil))))
    (should (= (length renames) 1))
    (should (equal (plist-get (car renames) :rename) '("a" . "c")))
    (should (equal (substring-no-properties (plist-get (car renames) :text))
                   "changed the title a → c"))))

(ert-deftest octocat-timeline-test-issue-close-without-events ()
  "Before the events load, a close still shows, from `closedAt'."
  (let ((items (octocat-timeline-items (json-parse-string octocat-timeline-tests--issue-json)
                                       "opened this issue" nil nil)))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items)
                   '(post comment event comment)))
    (should (equal (plist-get (nth 2 items) :actor) ""))))

(ert-deftest octocat-timeline-test-issue-event-text ()
  "Events render as short phrases; unknown ones are skipped."
  (let ((text (lambda (json) (octocat-timeline--event-text (json-parse-string json) nil))))
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

(ert-deftest octocat-timeline-test-issue-entry-string ()
  "A comment entry carries its target, a quote rail and its body."
  (let* ((comment (json-parse-string
                   "{\"author\":{\"login\":\"bob\"},\"body\":\"hi\\nthere\",\"createdAt\":\"2026-01-04T10:00:00Z\"}"))
         (entry (octocat-timeline--entry-string
                 (list :time "2026-01-04T10:00:00Z" :kind 'comment :actor "@bob"
                       :verb "commented" :body "hi\nthere" :target comment)
                 t 80)))
    (should (string-match-p "@bob commented" entry))
    (should (string-match-p "\n│ hi\n│ there\\'" (substring-no-properties entry)))
    (should (eq (get-text-property (1- (length entry)) 'octocat-timeline-target entry)
                comment))))

(ert-deftest octocat-timeline-test-event-line-wraps ()
  "An event line wider than WIDTH breaks, hung under its actor."
  (let ((entry (substring-no-properties
                (octocat-timeline--entry-string
                 (list :time "" :kind 'event :actor "@bob"
                       :text "changed the title aaa bbb → ccc ddd")
                 nil 20))))
    (should (string-prefix-p "○ @bob changed the\n  title" entry))
    (should (cl-every (lambda (l) (<= (string-width l) 20))
                      (split-string entry "\n")))))

(ert-deftest octocat-timeline-test-merged-pr ()
  "A merged PR shows its merge, not the close GitHub logs beside it."
  (let* ((pr (json-parse-string
              (concat "{\"body\":\"\",\"createdAt\":\"2026-01-01T10:00:00Z\","
                      "\"mergedAt\":\"2026-01-02T10:00:00Z\",\"closedAt\":\"2026-01-02T10:00:00Z\","
                      "\"author\":{\"login\":\"ann\"},\"comments\":[]}")))
         (events (json-parse-string
                  (concat "[{\"event\":\"closed\",\"created_at\":\"2026-01-02T10:00:00Z\"},"
                          "{\"event\":\"merged\",\"created_at\":\"2026-01-02T10:00:00Z\","
                          "\"actor\":{\"login\":\"ann\"}}]")))
         (kinds (lambda (evs)
                  (mapcar (lambda (i) (plist-get i :text))
                          (cdr (octocat-timeline-items pr "opened this pull request" evs nil))))))
    (should (equal (funcall kinds events) '("merged this")))
    ;; Without events the merge still shows, from `mergedAt'.
    (should (equal (funcall kinds nil) '("merged this")))))

(ert-deftest octocat-timeline-test-post-leads ()
  "The opening post comes first even if an extra item predates it."
  (let* ((pr (json-parse-string
              "{\"body\":\"x\",\"createdAt\":\"2026-01-02T10:00:00Z\",\"author\":{\"login\":\"ann\"},\"comments\":[]}"))
         (items (octocat-timeline-items
                 pr "opened this pull request" nil nil
                 (list (list :time "2026-01-01T10:00:00Z" :kind 'commit :actor "" :text "c")))))
    (should (equal (mapcar (lambda (i) (plist-get i :kind)) items) '(post commit)))))

(ert-deftest octocat-timeline-test-review-events ()
  "Review requests name a user or a team."
  (let ((text (lambda (json) (octocat-timeline--event-text (json-parse-string json) nil))))
    (should (equal (funcall text "{\"event\":\"review_requested\",\"requested_reviewer\":{\"login\":\"zed\"}}")
                   "requested a review from @zed"))
    (should (equal (funcall text "{\"event\":\"review_requested\",\"requested_team\":{\"name\":\"core\"}}")
                   "requested a review from core"))))

(defun octocat-timeline-tests--submit (result)
  "Submit text from an edit dialog with `gh' returning RESULT.
Return (ACTION-WHILE-RUNNING ACTION-AFTER REFRESHED REOPENED CLOSED)."
  (let ((source (generate-new-buffer " source"))
        running refreshed reopened closed)
    (unwind-protect
        (cl-letf (((symbol-function 'octocat-vui-update-page) #'ignore)
                  ((symbol-function 'octocat--run-gh)
                   (lambda (_name _args _parse callback)
                     (setq running (buffer-local-value 'octocat-timeline--action source))
                     (funcall callback result)))
                  ((symbol-function 'octocat--open-edit-buffer)
                   (lambda (&rest args) (setq reopened args))))
          (with-current-buffer source
            (setq-local octocat--refresh-fn (lambda () (setq refreshed t))))
          (with-temp-buffer
            (setq octocat-edit--title "New comment"
                  octocat-edit--submit-fn #'ignore)
            (octocat-timeline-submit "Posting comment…" "comment" '("x")
                                     "hello" source (lambda () (setq closed t))))
          (list running (buffer-local-value 'octocat-timeline--action source)
                refreshed reopened closed))
      (kill-buffer source))))

(ert-deftest octocat-timeline-test-submit-success ()
  "A submitted dialog closes at once, shows its action, then refreshes."
  (pcase-let ((`(,running ,after ,refreshed ,reopened ,closed)
               (octocat-timeline-tests--submit "ok")))
    (should (equal running "Posting comment…"))
    (should-not after)
    (should refreshed)
    (should-not reopened)
    (should closed)))

(ert-deftest octocat-timeline-test-submit-failure-reopens ()
  "A failed submission reopens the dialog with the typed text."
  (pcase-let ((`(,_running ,after ,refreshed ,reopened ,_closed)
               (octocat-timeline-tests--submit '(error . "boom"))))
    (should-not after)
    (should-not refreshed)
    (should (equal (nth 0 reopened) "New comment"))
    (should (equal (nth 3 reopened) "hello"))))

(provide 'octocat-timeline-tests)
;;; octocat-timeline-tests.el ends here
