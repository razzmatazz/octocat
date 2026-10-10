;;; octocat-timeline.el --- GitHub-style timeline for issue and PR views  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-5-5

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The conversation of an issue or pull request, drawn the way GitHub does:
;; the opening post, comments, reviews, commits and events (labels,
;; assignments, close/reopen, merge, ...) as one list ordered by time, on a
;; vertical rail.  The issue and PR views (octocat-issue.el, octocat-pr.el)
;; both build their pages from the pieces here.
;;
;; An item is a plist.  Every item has
;;
;;   :time    ISO-8601 timestamp (these sort correctly as strings)
;;   :kind    `comment' or `review' (a box with a markdown body), `post'
;;            (the opening post: a box like any comment, but first and
;;            folded later), or `event' or `commit' (a single line)
;;   :actor   "@login", or "" when unknown
;;
;; and, optionally,
;;
;;   :verb    what a box's author did ("commented", "approved these changes")
;;   :body    markdown text of a box
;;   :empty   placeholder shown for a blank body; without it a blank body
;;            shows nothing
;;   :text    what happened (single lines)
;;   :suffix  extra text at the end of a single line
;;   :state   event name or review state, picks the colour of the bullet
;;   :target  value of the `octocat-timeline-target' text property, which
;;            the edit and browse commands read at point
;;   :on-visit  function to call when RET is pressed on a single line
;;   :help    its `help-echo'
;;
;; The events come from the REST timeline endpoint
;; (`octocat--fetch-issue-events'), whose own comment, review and commit
;; entries are ignored: those come with richer data from `gh issue view'
;; and `gh pr view'.

;;; Code:

(require 'octocat-core)
(require 'octocat-vui)
(require 'time-date) ; date-to-time
(require 'vui)
(require 'vui-components) ; vui-vstack, etc.

(declare-function octocat-repo-vui--resolve-or-reject "octocat-repo" (result resolve reject))


;;;; Data

(defun octocat--fetch-issue-events (repo number callback)
  "Fetch the timeline events of issue or PR NUMBER in REPO asynchronously.
Calls CALLBACK with a hash-table whose \"events\" key holds the vector of
timeline events of all pages, or a cons \\=(error . MSG)."
  (octocat--run-gh "timeline-events"
                   (list "api" "--paginate" "--slurp"
                         (format "repos/%s/issues/%d/timeline" repo number))
                   (lambda (output)
                     (let ((pages (json-parse-string (string-trim output)))
                           (result (make-hash-table :test 'equal)))
                       (puthash "events" (apply #'vconcat (append pages nil)) result)
                       result))
                   callback))

(defun octocat-timeline-use-events (repo number)
  "Hook: load the timeline events of NUMBER in REPO, cached on disk.
Return (EVENTS . LOADING): EVENTS is a vector of timeline events, or nil
while neither a cache nor a fetch has produced any; LOADING is non-nil
while the first fetch is outstanding.  Must be called during render."
  (let* ((cached (vui-use-memo (repo number)
                   (octocat--detail-cache-load repo "timeline" number)))
         (async  (vui-use-async (list 'timeline repo number)
                   (lambda (resolve reject)
                     (octocat--fetch-issue-events
                      repo number
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (fresh  (and (eq (plist-get async :status) 'ready)
                      (plist-get async :data))))
    (vui-use-effect (fresh)
      (when fresh (octocat--detail-cache-save repo "timeline" number fresh))
      nil)
    (cons (gethash "events" (or fresh cached (make-hash-table)))
          (and (not fresh) (eq (plist-get async :status) 'pending)))))


;;;; Model

(defun octocat-timeline--get (obj &rest keys)
  "Return the value under KEYS in the nested hash-table OBJ, or nil.
Missing keys, non-table intermediates and JSON null all give nil."
  (while (and keys (hash-table-p obj))
    (setq obj (gethash (pop keys) obj)))
  (and (null keys) (not (eq obj :null)) obj))

(defun octocat-timeline--actor (event)
  "Return \"@LOGIN\" for the actor of timeline EVENT, or \"\"."
  (let ((login (octocat-timeline--get event "actor" "login")))
    (if (stringp login) (concat "@" login) "")))

(defun octocat-timeline--rename-text (from to)
  "Return the phrase for a title change FROM → TO (either may be nil)."
  (format "changed the title %s → %s"
          (propertize (or from "") 'face 'octocat-dimmed)
          (or to "")))

(defun octocat-timeline--event-text (event)
  "Return what timeline EVENT did as a short string, or nil to skip it.
The actor is not included; see `octocat-timeline--actor'."
  (let ((label (octocat-timeline--get event "label"))
        (actor (octocat-timeline--get event "actor" "login"))
        (who   (octocat-timeline--get event "assignee" "login"))
        (asked (let ((login (octocat-timeline--get event "requested_reviewer" "login")))
                 (if login
                     (concat "@" login)
                   (octocat-timeline--get event "requested_team" "name")))))
    (pcase (gethash "event" event)
      ("labeled"   (and label (format "added the %s label" (octocat--format-label label))))
      ("unlabeled" (and label (format "removed the %s label" (octocat--format-label label))))
      ("assigned"   (and who (if (equal who actor)
                                 "self-assigned this"
                               (format "assigned @%s" who))))
      ("unassigned" (and who (if (equal who actor)
                                 "removed their assignment"
                               (format "unassigned @%s" who))))
      ("closed"   (pcase (octocat-timeline--get event "state_reason")
                    ("not_planned" "closed this as not planned")
                    ("completed"   "closed this as completed")
                    (_             "closed this")))
      ("reopened" "reopened this")
      ("merged"   "merged this")
      ("renamed"  (octocat-timeline--rename-text
                   (octocat-timeline--get event "rename" "from")
                   (octocat-timeline--get event "rename" "to")))
      ("milestoned"   (format "added this to the %s milestone"
                              (octocat-timeline--get event "milestone" "title")))
      ("demilestoned" (format "removed this from the %s milestone"
                              (octocat-timeline--get event "milestone" "title")))
      ("locked"   "locked this conversation")
      ("unlocked" "unlocked this conversation")
      ("review_requested"
       (and asked (format "requested a review from %s" asked)))
      ("review_request_removed"
       (and asked (format "removed the review request for %s" asked)))
      ("ready_for_review" "marked this as ready for review")
      ("convert_to_draft" "marked this as a draft")
      ("head_ref_deleted" "deleted the head branch")
      ("head_ref_restored" "restored the head branch")
      ("head_ref_force_pushed" "force-pushed the head branch")
      ("base_ref_changed" "changed the base branch")
      ("cross-referenced"
       (let ((num (octocat-timeline--get event "source" "issue" "number")))
         (and num (format "mentioned this in #%d %s" num
                          (or (octocat-timeline--get event "source" "issue" "title") "")))))
      ("referenced"
       (let ((sha (octocat-timeline--get event "commit_id")))
         (and (stringp sha)
              (format "referenced this in commit %s"
                      (propertize (substring sha 0 (min 7 (length sha)))
                                  'face 'octocat-branch)))))
      (_ nil))))

(defun octocat-timeline--state-fallback (obj)
  "Return a one-item list for how OBJ ended, from its own fields, or nil.
OBJ is an issue or PR hash-table.  Used until the timeline events are
known, so a merge or close still shows up, without who did it."
  (let* ((merged (octocat-timeline--get obj "mergedAt"))
         (closed (octocat-timeline--get obj "closedAt"))
         (time   (if (and (stringp merged) (not (string-empty-p merged))) merged closed)))
    (and (stringp time) (not (string-empty-p time))
         (list (list :time time :kind 'event :actor ""
                     :text (if (eq time merged) "merged this" "closed this")
                     :state (if (eq time merged) "merged" "closed"))))))

(defun octocat-timeline-items (obj post-verb events &optional extra)
  "Return the timeline items of OBJ merged with EVENTS, oldest first.
OBJ is the issue or PR hash-table from `gh issue view' / `gh pr view';
its body, author and comments become the opening post (described by
POST-VERB, \"opened this issue\") and the comments.  EVENTS is a vector of
timeline events or nil while they are not known.  EXTRA is a list of
further items, such as a PR's reviews and commits."
  (let* ((merged (octocat-timeline--get obj "mergedAt"))
         (items
          (append
           (list (list :time (or (octocat-timeline--get obj "createdAt") "")
                       :kind 'post
                       :actor (octocat--author-login obj)
                       :verb post-verb
                       :body (or (octocat-timeline--get obj "body") "")
                       :empty "(no description)"
                       :target 'body))
           (mapcar (lambda (comment)
                     (list :time (or (gethash "createdAt" comment) "")
                           :kind 'comment
                           :actor (octocat--author-login comment)
                           :verb "commented"
                           :body (or (gethash "body" comment) "")
                           :empty "(empty)"
                           :target comment))
                   (octocat-timeline--get obj "comments"))
           extra
           (if events
               (delq nil
                     (mapcar (lambda (event)
                               (let ((text (octocat-timeline--event-text event))
                                     (name (gethash "event" event)))
                                 ;; GitHub logs a close next to every merge.
                                 (and text
                                      (not (and merged (equal name "closed")))
                                      (list :time (or (octocat-timeline--get event "created_at") "")
                                            :kind 'event
                                            :actor (octocat-timeline--actor event)
                                            :text text
                                            :label (octocat-timeline--get event "label")
                                            :rename (and (equal name "renamed")
                                                         (cons (octocat-timeline--get event "rename" "from")
                                                               (octocat-timeline--get event "rename" "to")))
                                            :state name))))
                             events))
             (octocat-timeline--state-fallback obj)))))
    ;; The post leads even when something predates it, like a PR's first
    ;; commit; the rest goes by time.
    (cons (car items)
          (octocat-timeline--merge-renames
           (octocat-timeline--merge-labels
            (sort (cdr items)
                  (lambda (a b) (string< (plist-get a :time) (plist-get b :time)))))))))

(defun octocat-timeline--merge-renames (items)
  "Return ITEMS with one actor's consecutive renames merged into one.
The merged entry reads from the first old title to the last new one and
carries the time of the last change."
  (let (result)
    (dolist (item items)
      (let ((prev (car result)))
        (if (and (plist-get item :rename) prev (plist-get prev :rename)
                 (equal (plist-get prev :actor) (plist-get item :actor)))
            (let ((rename (cons (car (plist-get prev :rename))
                                (cdr (plist-get item :rename)))))
              (setcar result
                      (append (list :rename rename
                                    :time (plist-get item :time)
                                    :text (octocat-timeline--rename-text
                                           (car rename) (cdr rename)))
                              prev)))
          (push item result))))
    (nreverse result)))

(defconst octocat-timeline--merge-window 60
  "Seconds within which one actor's label events are shown as one entry.")

(defun octocat-timeline--seconds (time)
  "Return ISO 8601 string TIME as float seconds, or nil if unparsable."
  (ignore-errors (float-time (date-to-time time))))

(defun octocat-timeline--labels-text (labeled)
  "Return the phrase for LABELED, a list of (STATE . LABEL) in order."
  (let* ((names (lambda (state)
                  (octocat--format-labels
                   (vconcat (mapcar #'cdr (seq-filter (lambda (l) (equal (car l) state))
                                                      labeled))))))
         (added   (funcall names "labeled"))
         (removed (funcall names "unlabeled"))
         (phrase  (lambda (verb str state)
                    (let ((n (seq-count (lambda (l) (equal (car l) state)) labeled)))
                      (format "%s the %s %s" verb str (if (= n 1) "label" "labels"))))))
    (string-join
     (delq nil
           (list (and (not (string-empty-p added))
                      (funcall phrase "added" added "labeled"))
                 (and (not (string-empty-p removed))
                      (funcall phrase "removed" removed "unlabeled"))))
     " and ")))

(defun octocat-timeline--merge-labels (items)
  "Return ITEMS with label events of one actor in a row merged into one.
Like GitHub, consecutive labeled/unlabeled events of the same actor,
within `octocat-timeline--merge-window' seconds of the first, become a
single entry such as \"added the A B labels\"."
  (let (result run)
    (cl-flet ((flush ()
                (when run
                  (let ((first (car (last run)))
                        (ordered (reverse run)))
                    (push (if (cdr run)
                              (append
                               (list :text (octocat-timeline--labels-text
                                            (mapcar (lambda (i) (cons (plist-get i :state)
                                                                      (plist-get i :label)))
                                                    ordered)))
                               first)
                            first)
                          result))
                  (setq run nil)))
              (label-p (item)
                (and (eq (plist-get item :kind) 'event)
                     (member (plist-get item :state) '("labeled" "unlabeled"))
                     (plist-get item :label))))
      (dolist (item items)
        (if (not (label-p item))
            (progn (flush) (push item result))
          (let ((start (car (last run))))
            (unless (and start
                         (equal (plist-get start :actor) (plist-get item :actor))
                         (let ((t0 (octocat-timeline--seconds (plist-get start :time)))
                               (t1 (octocat-timeline--seconds (plist-get item :time))))
                           (and t0 t1 (<= (- t1 t0) octocat-timeline--merge-window))))
              (flush))
            (push item run))))
      (flush))
    (nreverse result)))


;;;; Rendering

(defconst octocat-timeline--rail (propertize "  │" 'face 'octocat-dimmed)
  "The timeline's vertical line, drawn between two entries.")

(defconst octocat-timeline--body-prefix (propertize "  │ " 'face 'octocat-dimmed)
  "Prefix of a box body: the rail, then the text.
The text lines up with the author's handle in the heading above it.")

(defun octocat-timeline--bullet-face (state)
  "Return the face of the bullet of an entry in STATE (see \"Model\")."
  (pcase state
    ((or "closed" "changes_requested") 'octocat-pr-state-closed)
    ((or "approved" "reopened")        'octocat-pr-state-open)
    ("merged"                          'octocat-pr-state-merged)
    (_                                 'octocat-dimmed)))

(defun octocat-timeline--entry-string (item raw)
  "Return the text of timeline ITEM, without a final newline.
ITEM is as described in the Commentary.  RAW non-nil shows markdown
bodies verbatim.  The text carries ITEM's target in the
`octocat-timeline-target' property."
  (let* ((line  (memq (plist-get item :kind) '(event commit)))
         (actor (propertize (plist-get item :actor) 'face 'octocat-pr-author))
         (date  (propertize (octocat--format-ts-full (plist-get item :time))
                            'face 'octocat-dimmed))
         (bullet (propertize (if line "○" "●")
                             'face (octocat-timeline--bullet-face (plist-get item :state))))
         (text
          (if line
              (concat "  " bullet " " actor (if (string-empty-p actor) "" " ")
                      (plist-get item :text) "  " date (plist-get item :suffix))
            (let ((body   (plist-get item :body))
                  (empty  (plist-get item :empty))
                  (prefix octocat-timeline--body-prefix))
              (concat "  " bullet " " actor " "
                      (propertize (plist-get item :verb) 'face 'octocat-dimmed)
                      "  " date
                      (cond
                       ((not (string-empty-p (string-trim body)))
                        (concat "\n" (string-remove-suffix
                                      "\n" (octocat--markdown-string
                                            body prefix raw))))
                       (empty
                        (concat "\n" prefix
                                (propertize empty 'face 'octocat-dimmed)))))))))
    (when-let* ((target (plist-get item :target)))
      (put-text-property 0 (length text) 'octocat-timeline-target target text))
    text))

(defcustom octocat-timeline-body-lines 30
  "Lines of an opening post shown before the rest is folded away.
The rest expands on RET.  The last entry of a timeline is never folded.
Nil never folds."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)

(defcustom octocat-timeline-comment-lines 10
  "Lines of a comment or review shown before the rest is folded away.
See `octocat-timeline-body-lines'."
  :type '(choice (const :tag "Never fold" nil) integer)
  :group 'octocat)

(defconst octocat-timeline--expand-growth 0.5
  "How much faster each frame of the unfolding animation is than the last.
Every frame reveals this fraction of what is already unfolded (at least
two things more), so the unfolding starts slowly and then speeds up.")

(defconst octocat-timeline--expand-interval 0.025
  "Seconds between the frames of the unfolding animation.")

(defun octocat-timeline--line-limit (item)
  "Return how many body lines of ITEM show while folded, or nil."
  (if (eq (plist-get item :kind) 'post)
      octocat-timeline-body-lines
    octocat-timeline-comment-lines))

(vui-defcomponent octocat-timeline-fold (total limit render prefix noun key)
  "Show the first LIMIT of TOTAL things, the rest folded behind a marker row.
RENDER is a function of the number of things to show, returning a vnode.
PREFIX starts the marker row and NOUN (\"lines\", \"checks\") names the
things in it.  KEY names the marker button, so point stays on it when
the view re-renders.  With LIMIT nil, or TOTAL not above it, nothing
folds.  RET on the marker unfolds the rest at a growing pace, and then
folds it back."
  :state ((shown nil) (open nil) (closing nil))
  :render
  (let* ((folds   (and limit (> total limit)))
         (visible (if folds (min total (or shown limit)) total))
         (done    (>= visible total))
         (unfolding (and open (not done) (not closing))))
    ;; Unfold progressively: a timer adds more things each frame (see
    ;; `octocat-timeline--expand-growth') until all show.  It exists only
    ;; while that is going on.
    (vui-use-effect (unfolding)
      (when unfolding
        (let ((timer (run-with-timer
                      octocat-timeline--expand-interval
                      octocat-timeline--expand-interval
                      (vui-with-async-context
                        (vui-set-state
                         :shown (lambda (old)
                                  (let ((now (or old limit)))
                                    (min total
                                         (+ now (max 2 (ceiling (* octocat-timeline--expand-growth
                                                                   (- now limit)))))))))))))
          (lambda () (cancel-timer timer)))))
    ;; Fold back the same way, in reverse: each frame hides a fraction of
    ;; what is still unfolded, so it starts fast and eases out onto LIMIT.
    (vui-use-effect (closing)
      (when closing
        (let* ((now visible)
               (timer nil))
          (setq timer
                (run-with-timer
                 octocat-timeline--expand-interval
                 octocat-timeline--expand-interval
                 (vui-with-async-context
                   (setq now (max limit
                                  (- now (max 2 (ceiling (* octocat-timeline--expand-growth
                                                            (- now limit)))))))
                   (if (> now limit)
                       (vui-set-state :shown now)
                     (cancel-timer timer)
                     (vui-set-state :shown nil)
                     (vui-set-state :open nil)
                     (vui-set-state :closing nil)))))
          (lambda () (cancel-timer timer)))))
    (vui-fragment
     (funcall render visible)
     (when folds
       (vui-fragment
        (vui-newline)
        ;; A real button, so TAB / S-TAB stop on it like on the buttons
        ;; at the bottom of the buffer.
        (vui-text prefix)
        (vui-button (cond ((not open) (format "▸ %d more %s  (RET to expand)"
                                              (- total visible) noun))
                          ((or done closing) "▴ show less")
                          (t          (format "▾ %d more %s…" (- total visible) noun)))
                    :no-decoration t
                    :face 'octocat-dimmed
                    :key key
                    :help-echo (if open "RET: fold this back" "RET: show the rest")
                    :on-click (vui-with-async-context
                                (cond (closing nil)
                                      ((and open done) (vui-set-state :closing t))
                                      (t (vui-set-state :open t))))))))))

(vui-defcomponent octocat-timeline--entry (item raw width limit index)
  "One timeline ITEM; fold its body to LIMIT lines (nil: never).
RAW is as for `octocat-timeline--entry-string'; WIDTH only invalidates the
rendered text when the window is resized."
  :render
  (let* ((cut (vui-use-memo (item raw width)
                ;; Cut the text by position, not by splitting and joining
                ;; it, so a folded <details> row keeps its invisible newline.
                (let ((string (octocat-timeline--entry-string item raw))
                      (start 0) ends)
                  (while (string-match "\n" string start)
                    (push (match-beginning 0) ends)
                    (setq start (match-end 0)))
                  (cons string (nreverse ends)))))
         (full  (car cut))
         (ends  (cdr cut))
         (visit (plist-get item :on-visit)))
    (vui-component
     'octocat-timeline-fold
     :total (length ends)
     :limit limit
     :noun "lines"
     :key (intern (format "fold-%d" index))
     :prefix octocat-timeline--body-prefix
     :render (lambda (shown)
               (let ((text (substring full 0 (if (< shown (length ends))
                                                 (nth shown ends)
                                               (length full)))))
                 (if visit
                     (octocat-vui-row text visit (plist-get item :help))
                   (vui-text text)))))))

(defun octocat-timeline-entries (items raw)
  "Return the vnodes of timeline ITEMS, rail lines included.
RAW is as for `octocat-timeline--entry-string'.  An item with an
:on-visit function is a RET-able row.  Long bodies and comments are
folded (see `octocat-timeline-body-lines'), except in the last item."
  (let ((width (octocat-vui-window-width))
        (index 0)
        nodes)
    (while items
      (let ((item (pop items)))
        (when nodes (push (vui-text octocat-timeline--rail) nodes))
        (push (vui-component 'octocat-timeline--entry
                             :item item :raw raw :width width :index (cl-incf index)
                             :limit (and items (octocat-timeline--line-limit item)))
              nodes)))
    (nreverse nodes)))

(defun octocat-timeline-buttons (buttons &optional joined)
  "Return the vnodes of a row of BUTTONS, each (LABEL HELP ON-CLICK).
With JOINED the row hangs off the end of the timeline's rail.  A nil
entry in BUTTONS is skipped."
  (list (if joined (vui-text octocat-timeline--rail) (vui-newline))
        (apply #'vui-hstack :spacing 0
               (vui-text "  ")
               (let (nodes)
                 (dolist (button (delq nil buttons))
                   (when nodes (push (vui-text "   ") nodes))
                   (push (vui-button (format "[%s]" (nth 0 button))
                                     :no-decoration t
                                     :face 'octocat-dimmed
                                     :key (nth 0 button)
                                     :help-echo (nth 1 button)
                                     :on-click (nth 2 button))
                         nodes))
                 (nreverse nodes)))))

(defun octocat-timeline-state-change (kind verb repo number refresh)
  "Close or reopen issue or PR NUMBER of REPO after asking, then REFRESH.
KIND is \"issue\" or \"pr\" (the `gh' subcommand) and VERB is \"close\" or
\"reopen\".  REFRESH is called in the current buffer on success."
  (when (y-or-n-p (format "%s %s #%d? " (capitalize verb)
                          (if (equal kind "pr") "pull request" "issue") number))
    (let ((buf (current-buffer)))
      (octocat--run-gh
       verb
       (list kind verb (number-to-string number) "--repo" repo)
       #'identity
       (lambda (result)
         (if (eq (car-safe result) 'error)
             (message "Octocat: failed to %s #%d: %s" verb number (cdr result))
           (message "Octocat: #%d %s" number (if (equal verb "close") "closed" "reopened"))
           (when (buffer-live-p buf)
             (with-current-buffer buf (funcall refresh)))))))))

(defun octocat-timeline-target ()
  "Return what the timeline entry at point stands for, or nil.
It is the symbol `title' or `body', or a comment hash-table, as stored in
the `octocat-timeline-target' text property by the renderer."
  (get-text-property (point) 'octocat-timeline-target))

(provide 'octocat-timeline)
;;; octocat-timeline.el ends here
