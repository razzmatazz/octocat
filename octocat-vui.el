;;; octocat-vui.el --- vui.el helpers and components for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Small building blocks on top of vui.el: hooks, components and vnode
;; builders shared by the vui-based buffers.  The generic ones (rows,
;; sticky async, load-more) know nothing about GitHub; the list-page
;; section below is the exception and knows just enough about a repo to
;; share the keymap, the header counts and the search-query filter.
;; Everything buffer-specific stays in the buffer's own file (e.g.
;; `octocat-repo.el').
;;
;; Contents:
;;
;;   `octocat-vui-row'               RET-able, per-segment-styled line
;;   `octocat-vui-use-async-sticky'  `vui-use-async' that keeps old data
;;                                   visible while the next page loads
;;   `octocat-vui-use-cached'        async fetch painted from a cache first
;;   `octocat-vui-refresh-page'      mount a page, or refresh it in place
;;   `octocat-vui-load-more-button'  "[+] Load N more…" button
;;   `octocat-vui-reveal-list'       `vui-list' whose later-added rows
;;                                   unfold progressively
;;   `octocat-vui-fold'              header row with an animated fold
;;   `octocat-vui-fold-header'       its ▸/▾ header, a TAB stop
;;   `octocat-vui-list-mode'         base mode of the PR/issue list pages
;;                                   and the Actions page
;;   `octocat-vui-actions-top-row'   top row of workflow, run and job pages
;;   `octocat-vui-repo-tabs'         Code / Issues / Pull requests / Actions
;;                                   tab strip shared by the repo pages
;;   `octocat-vui-list-header'       list page header with open/closed counts
;;   `octocat-vui-list-filter-bar'   query line + facet buttons

;;; Code:

(require 'octocat-core) ; `octocat-dimmed' face
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'vui)
(require 'vui-components)

(defun octocat-vui-row (line on-visit &optional help-echo)
  "Build a RET-able row vnode from already-propertized LINE.
ON-VISIT is a zero-argument function invoked when RET is pressed on the
row.  HELP-ECHO defaults to a generic hint.

A row is a `vui-region' wrapping a single `vui-text' line, with a tiny
keymap binding RET to the row's navigation.  `vui-text' inserts its
content as-is, preserving whatever per-segment `face' properties LINE
already carries (e.g. a different face for a branch column vs. the title
vs. the state); it is deliberately not a `vui-button', since a button
applies a single `face' across the whole label, which would clobber that
per-segment styling.

The keymap binds RET to a wrapper command, not ON-VISIT directly:
`command-execute' (what a real keypress dispatches through) requires
`commandp', which a plain lambda without `(interactive)' does not
satisfy -- binding ON-VISIT itself would look right but signal
`wrong-type-argument commandp' the moment RET is actually pressed.

HELP-ECHO goes only on the parts of LINE without a `help-echo' of their
own, so a segment such as a relative date keeps its own hover text
\(the exact time, see `octocat--format-ts-relative')."
  (let ((map (let ((m (make-sparse-keymap)))
               (define-key m (kbd "RET") (lambda () (interactive) (funcall on-visit)))
               m)))
    (vui-region :keymap map
      (vui-text (octocat-vui--default-help-echo
                 line (or help-echo "RET: view details"))
                'mouse-face 'highlight))))

(defun octocat-vui--default-help-echo (string help-echo)
  "Return a copy of STRING with HELP-ECHO on the parts lacking a `help-echo'."
  (let ((s   (copy-sequence string))
        (pos 0))
    (while (< pos (length s))
      (let ((next (next-single-property-change pos 'help-echo s (length s))))
        (unless (get-text-property pos 'help-echo s)
          (put-text-property pos next 'help-echo help-echo s))
        (setq pos next)))
    s))

(defun octocat-vui-use-async-sticky (key loader)
  "Like `vui-use-async' for KEY and LOADER, but keep showing old data.
Each section's async KEY includes its page limit, so bumping the limit
starts a fresh load whose status is `pending'.  Rendering that as
\"Loading…\" would collapse the whole section to one line while the next
page is fetched.  Instead, while a load is pending and an earlier one
succeeded, return that earlier data as `ready' with :refreshing t.
Must be called during render, like any hook."
  (let ((result (vui-use-async key loader))
        (last   (vui-use-ref nil)))
    (pcase (plist-get result :status)
      ('ready (setcar last (plist-get result :data))
              result)
      ('pending (if (car last)
                    (list :status 'ready :data (car last) :refreshing t)
                  result))
      (_ result))))

(defun octocat-vui-use-cached (key load save loader)
  "Return the async result of LOADER for KEY, painted from a cache first.
LOAD returns the data last saved, or nil; it is called once per page
mount.  SAVE is called with each fresh result.  KEY should include the
page's refresh tick (see `octocat-vui-refresh-page'): a new tick
refetches, and what is shown stays up, with :refreshing t, until the
fresh data replaces it.  Must be called during render, like any hook."
  (let* ((cached (vui-use-memo () (funcall load)))
         (sticky (octocat-vui-use-async-sticky key loader))
         (fresh  (and (eq (plist-get sticky :status) 'ready)
                      (not (plist-get sticky :refreshing))
                      (plist-get sticky :data))))
    (vui-use-effect (fresh)
      (when fresh (funcall save fresh))
      nil)
    (octocat-vui-with-stale sticky cached)))

(defun octocat-vui-with-stale (result stale)
  "Return RESULT, or STALE shown as `ready' while RESULT is still pending.
RESULT is a `vui-use-async' (or `octocat-vui-use-async-sticky') result
plist and STALE is data remembered from an earlier session, or nil.  The
stale data comes back with :refreshing t, like the sticky hook's old
data, so the view paints at once and is replaced in place when the
fresh data arrives, instead of flashing a \"Loading…\" placeholder."
  (if (and stale (eq (plist-get result :status) 'pending))
      (list :status 'ready :data stale :refreshing t)
    result))

(defun octocat-vui-load-more-button (key count help-echo on-click &optional loading indent)
  "Return a \"Load COUNT more…\" vui-button with HELP-ECHO, invoking ON-CLICK.
KEY is a per-section symbol: it is the button's cursor identity, so point
stays on this section's button when growing the list re-renders it
instead of drifting to a neighbouring section's button.
When LOADING is non-nil (a page is being fetched, see
`octocat-vui-use-async-sticky') the button is disabled so it cannot be
triggered twice; its label stays put, since the page's top line shows
the activity (see `octocat-vui-loading-suffix').
Rows carry no trailing newline (`vui-list' only separates them), so the
button starts on a fresh line and carries the same indent, INDENT columns
\(default two).  The flush-left list pages pass 0."
  (vui-fragment
   (vui-newline)
   (vui-text (make-string (or indent 2) ?\s))
   (vui-button (format "[+] Load %d more…" count)
               :no-decoration t
               :face 'octocat-dimmed
               :key key
               :disabled loading
               :help-echo (if loading nil help-echo)
               :on-click on-click)))

(defconst octocat-vui-unfold-growth 0.5
  "How much faster each frame of an unfolding animation is than the last.
Every frame reveals this fraction of what is already unfolded (at least
two things more), so the unfolding starts slowly and then speeds up.")

(defconst octocat-vui-unfold-interval 0.025
  "Seconds between the frames of an unfolding animation.")

(vui-defcomponent octocat-vui-reveal (items render)
  "Call RENDER with ITEMS, revealing items added later one frame at a time.
RENDER is a function of the list of items to show, returning a vnode.
The first render shows every item at once.  When ITEMS then grows (a
\"Load more\" page arrived), the new items unfold at a growing pace like
the rest of a long comment (see `octocat-timeline-fold'), instead of
all appearing in one jump.  A list that shrinks just shows what is left.
The timer exists only while items are being revealed."
  :state ((tick 0))
  :render
  (let* ((cell  (vui-use-ref nil))
         (total (length items)))
    ;; The reveal state, [VISIBLE TOTAL BASE], lives in the ref so the
    ;; timer and the render read the same numbers: BASE is where the
    ;; current unfolding started, TOTAL what it unfolds towards.
    (cond
     ((null (car cell))
      (setcar cell (vector total total total)))
     ((/= total (aref (car cell) 1))
      (let ((v (car cell)))
        (cond ((<= total (aref v 0))
               (aset v 0 total)
               (aset v 2 total))
              ((>= (aref v 0) (aref v 1)) ; idle: this growth starts a new unfolding
               (aset v 2 (aref v 0))))
        (aset v 1 total))))
    (let* ((v          (car cell))
           (visible    (aref v 0))
           (unfolding  (< visible total)))
      (vui-use-effect (unfolding)
        (when unfolding
          (let ((timer nil))
            (setq timer
                  (run-with-timer
                   octocat-vui-unfold-interval octocat-vui-unfold-interval
                   (vui-with-async-context
                     (let* ((now  (aref v 0))
                            (all  (aref v 1))
                            (step (max 2 (ceiling (* octocat-vui-unfold-growth
                                                     (- now (aref v 2)))))))
                       (aset v 0 (min all (+ now step)))
                       (when (>= (aref v 0) all)
                         (cancel-timer timer))
                       (vui-set-state :tick (lambda (n) (1+ n)))))))
            (lambda () (cancel-timer timer)))))
      (funcall render (seq-take items visible)))))

(vui-defcomponent octocat-vui-fold (header prepare deps)
  "A header row and a folded body that unfolds and folds back animated.
HEADER is a function of whether the body is open and of a command that
toggles it, returning the header vnode; typically an `octocat-vui-row'
with the toggle as its RET.  PREPARE builds the body, only once it is
first unfolded and again when DEPS change: it returns (TOTAL . RENDER),
the body's number of lines and a function of how many of them to show
returning a list of vnodes.  Unfolding reveals lines at a growing pace,
as `octocat-timeline-fold' does; folding hides them the same way in
reverse.  Lines added while open, say by a refresh, unfold too."
  :state ((open nil) (shown 0))
  :render
  (let* ((active (or open (> shown 0)))
         (body   (vui-use-memo (deps active) (and active (funcall prepare))))
         (total  (or (car body) 0))
         (target (if open total 0))
         (moving (/= shown target))
         (toggle (vui-async-callback () (vui-set-state :open (not open)))))
    (vui-use-effect (moving open total)
      (when moving
        (let ((timer (run-with-timer
                      octocat-vui-unfold-interval octocat-vui-unfold-interval
                      (vui-with-async-context
                        (vui-set-state
                         :shown (lambda (now)
                                  ;; A fraction of what shows: unfolding speeds up,
                                  ;; folding starts fast and eases out.
                                  (let ((step (max 2 (ceiling (* octocat-vui-unfold-growth now)))))
                                    (if open
                                        (min total (+ now step))
                                      (max 0 (- (min now total) step))))))))))
          (lambda () (cancel-timer timer)))))
    (apply #'vui-vstack
           (funcall header open toggle)
           (and body (> shown 0) (funcall (cdr body) (min shown total))))))

(defun octocat-vui-fold-header (indent open toggle title help)
  "Return a header row for `octocat-vui-fold': a ▸/▾ marker, then TITLE.
INDENT starts the row.  OPEN and TOGGLE are as the fold passes them;
HELP is a pair of hints, for when the fold is closed and open.  The
marker is a button, so TAB stops on it; the title is a row, so its own
faces show (a button would draw it in one face).  RET on either toggles."
  (let ((hint (if open (cdr help) (car help))))
    (vui-hstack
     :spacing 0
     (vui-text indent)
     (vui-button (if open "▾" "▸")
                 :no-decoration t
                 :face 'octocat-dimmed
                 :key 'fold-toggle
                 :help-echo hint
                 :on-click toggle)
     (octocat-vui-row (concat " " title) toggle hint))))

(defun octocat-vui-line-ends (string)
  "Return the positions of the newlines in STRING, for `octocat-vui-take-lines'."
  (let ((start 0) ends)
    (while (string-match "\n" string start)
      (push (match-beginning 0) ends)
      (setq start (match-end 0)))
    (nreverse ends)))

(defun octocat-vui-take-lines (string ends n)
  "Return the first N lines of STRING, whose newlines are at ENDS."
  (cond ((<= n 0) "")
        ((nth (1- n) ends) (substring string 0 (nth (1- n) ends)))
        (t string)))

(defun octocat-vui-reveal-list (items row-fn key-fn)
  "Return a `vui-list' of ITEMS drawn by ROW-FN and keyed by KEY-FN.
Items that arrive after the first render unfold progressively, see
`octocat-vui-reveal'.  Lay columns out from all of ITEMS before calling
this, so they do not shift as the new rows appear."
  (vui-component 'octocat-vui-reveal
                 :items items
                 :render (lambda (shown) (vui-list shown row-fn key-fn))))

(defconst octocat-vui-spinner-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames of the loading spinner, shown inside \"(loading… )\".")

(defmacro octocat-vui-use-spinner (active)
  "Advance the component's `spin' state ten times a second while ACTIVE.
ACTIVE is a variable, true while something is loading.  The component
must declare a `(spin 0)' entry in its `:state'; pass that value as the
SPIN argument of `octocat-vui-loading-suffix' to draw the frame.  The
timer only exists while ACTIVE, and is cancelled when it turns nil or the
component unmounts."
  `(vui-use-effect (,active)
     (when ,active
       (let ((timer (run-with-timer 0.1 0.1
                                    (vui-with-async-context
                                      (vui-set-state :spin #'1+)))))
         (lambda () (cancel-timer timer))))))

(defun octocat-vui-window-width ()
  "Return the body width of the window showing the current buffer, or 80."
  (let ((win (get-buffer-window (current-buffer) t)))
    (if win (window-body-width win) 80)))

(defmacro octocat-vui-use-window-width ()
  "Return the width of the buffer's window, re-rendering when it changes.
The component must declare a `(win-width nil)' entry in its `:state'.
The size-change hook only exists while the component is mounted."
  `(progn
     (vui-use-effect ()
       (let* ((buf  (current-buffer))
              (last (octocat-vui-window-width))
              (set  (vui-with-async-context
                      (vui-set-state :win-width (octocat-vui-window-width))))
              (hook (lambda (_frame)
                      (when (buffer-live-p buf)
                        (let ((w (with-current-buffer buf
                                   (octocat-vui-window-width))))
                          (unless (eql w last)
                            (setq last w)
                            (funcall set)))))))
         (add-hook 'window-size-change-functions hook)
         (lambda () (remove-hook 'window-size-change-functions hook))))
     (or win-width (octocat-vui-window-width))))

(defun octocat-vui--save-view ()
  "Return the point and scroll of every window showing the current buffer.
Each entry is (WINDOW POINT-LINE POINT-COLUMN START-LINE)."
  (let (view)
    (dolist (win (get-buffer-window-list (current-buffer) nil t))
      (save-excursion
        (goto-char (window-point win))
        (let ((line (line-number-at-pos))
              (col  (current-column))
              (start (line-number-at-pos (window-start win))))
          (push (list win line col start) view))))
    view))

(defun octocat-vui--goto-line-column (line col)
  "Return the position at LINE and COL of the current buffer, clamped."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column col)
    (point)))

(defun octocat-vui--restore-view (view)
  "Put point and scroll back as VIEW, from `octocat-vui--save-view', says."
  (dolist (entry view)
    (pcase-let ((`(,win ,line ,col ,start) entry))
      (when (and (window-live-p win)
                 (eq (window-buffer win) (current-buffer)))
        (let ((pos (octocat-vui--goto-line-column line col)))
          (set-window-point win pos)
          (when (eq win (selected-window))
            (goto-char pos))
          (set-window-start win (octocat-vui--goto-line-column start 0)))))))

(defmacro octocat-vui-preserving-view (&rest body)
  "Run BODY, then restore point and scroll in the current buffer's windows.
For a `vui-mount' of the buffer's own page: the mount erases the buffer
and leaves point at the top, so a refresh would otherwise throw the
reader back to the first line.  The restore is by line and column, which
holds as the page is repainted from the disk cache before it refetches."
  (declare (indent 0))
  `(let ((view (octocat-vui--save-view)))
     (prog1 (progn ,@body)
       (octocat-vui--restore-view view))))

(defvar-local octocat-vui--page nil
  "The page `octocat-vui-refresh-page' mounted here: (COMPONENT ID INSTANCE).")

(defvar-local octocat-vui--tick 0
  "Bumped by each `octocat-vui-refresh-page'.")

(defun octocat-vui-refresh-page (component id props)
  "Mount COMPONENT with PROPS in the current buffer, or refresh it in place.
ID names what the page shows.  When this buffer already shows COMPONENT
for ID, it is re-rendered with new props instead of remounted, so it
keeps its state, such as what is unfolded.  PROPS get a :tick, new on
each call, for the page's fetch keys (see `octocat-vui-use-cached')."
  (let ((props (append props (list :tick (cl-incf octocat-vui--tick)))))
    (if (and (eq (nth 0 octocat-vui--page) component)
             (equal (nth 1 octocat-vui--page) id))
        (vui-update-props (nth 2 octocat-vui--page) props)
      (setq octocat-vui--page
            (list component id
                  (octocat-vui-preserving-view
                    (vui-mount (apply #'vui-component component props)
                               (buffer-name))))))))

(defun octocat-vui-loading-suffix (result &optional spin)
  "Return a dimmed \"(loading…)\" marker for a section heading, or \"\".
It is shown while RESULT (see `octocat-vui-use-async-sticky') displays
earlier or cached data that a fetch is about to replace.  SPIN, the
component's `spin' counter (see `octocat-vui-use-spinner'), picks the
spinner frame appended to the marker."
  (if (plist-get result :refreshing)
      (propertize (concat "  (loading…"
                          (when spin
                            (concat " " (aref octocat-vui-spinner-frames
                                              (mod spin (length octocat-vui-spinner-frames)))))
                          ")")
                  'face 'octocat-dimmed)
    ""))


;;;; List-page base mode
;;
;; Skeleton shared by the PR, issue and workflow list pages (defined in
;; octocat-pr.el, octocat-issue.el and octocat-workflow.el): the repo they
;; show, the github.com path `octocat-vui-list-browse' opens, and the
;; common keymap.  Each page derives from this mode, sets its own
;; `revert-buffer-function', and is opened via `octocat--open-list'
;; (octocat.el).

(declare-function octocat--fetch-counts "octocat-core" (repo kind callback))
(declare-function octocat--counts-cache-load "octocat-core" (repo kind))
(declare-function octocat--counts-cache-save "octocat-core" (repo kind counts))
(declare-function octocat--list-labels "octocat-core" (repo callback))
(declare-function octocat--list-people "octocat-core" (repo callback))
(declare-function octocat-switch-repo "octocat-core" ())
(declare-function octocat-visit-repo "octocat-core" (repo))
(declare-function octocat-issues "octocat" ())
(declare-function octocat-prs "octocat" ())
(declare-function octocat-actions "octocat" ())
(declare-function octocat-tree-open "octocat-tree" (&optional repo))
(declare-function octocat-search-repo "octocat-search" ())

(defvar-local octocat-vui-list--repo nil
  "The \"owner/repo\" string this list buffer is tracking.")

(defvar-local octocat-vui-list--path nil
  "Path under github.com/OWNER/REPO that shows this list in a browser.")

(defun octocat-vui-list-browse ()
  "Open the GitHub page matching the current list buffer in a browser."
  (interactive)
  (unless (and octocat-vui-list--repo octocat-vui-list--path)
    (user-error "Octocat: Buffer is not associated with a repository"))
  (message "Octocat: Opening %s in browser…" octocat-vui-list--repo)
  (browse-url (format "https://github.com/%s/%s"
                      octocat-vui-list--repo octocat-vui-list--path)))

(defvar octocat-vui-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-vui-list-mode' and the list pages derived from it.")
(define-key octocat-vui-list-mode-map (kbd "q") #'quit-window)
(define-key octocat-vui-list-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-vui-list-mode-map (kbd "C-c C-o") #'octocat-vui-list-browse)
(define-key octocat-vui-list-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-vui-list-mode-map (kbd "C-c C-s") #'octocat-search-repo)

(define-derived-mode octocat-vui-list-mode vui-mode "Octocat-List"
  "Base major mode for the octocat PR, issue and workflow list pages.

\\{octocat-vui-list-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (octocat--ts-eldoc-setup))

(defun octocat-vui-commit-top-row (repo sha suffix)
  "Return the top row of a page about commit SHA of REPO.
That is `owner/repo@sha', RET-able to the repo page, as `owner/repo#N'
is on an issue, then the repo tab strip with Code highlighted and
SUFFIX, the page's loading indicator (see `octocat-vui-loading-suffix')."
  (apply #'vui-hstack :spacing 2
         (octocat-vui-row
          (concat (propertize repo 'face 'octocat-repo)
                  (propertize (concat "@" (substring sha 0 (min 7 (length sha))))
                              'face 'octocat-commit-sha))
          (lambda () (octocat-visit-repo repo))
          "RET: open repo view")
         (append (octocat-vui-repo-tabs repo nil nil nil 'code)
                 (and suffix (not (string-empty-p suffix))
                      (list (vui-text (string-trim-left suffix)))))))

(defun octocat-vui-actions-top-row (repo suffix)
  "Return the top row of a workflow, run or job page of REPO.
That is the repo, RET-able to the repo page, the tab strip with Actions
highlighted, and SUFFIX, the page's loading indicator (see
`octocat-vui-loading-suffix')."
  (apply #'vui-hstack :spacing 2
         (octocat-vui-row (propertize repo 'face 'octocat-repo)
                          (lambda () (octocat-visit-repo repo))
                          "RET: open repo view")
         (append (octocat-vui-repo-tabs repo nil nil nil 'actions)
                 (and suffix (not (string-empty-p suffix))
                      (list (vui-text (string-trim-left suffix)))))))

(defun octocat-vui-fields (fields)
  "Return a vnode of FIELDS on one line, or nil when none has a value.
FIELDS is a list of (LABEL . VALUE): a nil or empty VALUE is skipped, a
nil LABEL shows VALUE alone.  Labels and separators are dimmed."
  (let ((parts (delq nil
                     (mapcar (lambda (f)
                               (and (cdr f) (not (equal (cdr f) ""))
                                    (if (car f)
                                        (concat (propertize (car f) 'face 'octocat-dimmed)
                                                " " (cdr f))
                                      (cdr f))))
                             fields))))
    (and parts
         (vui-text (mapconcat #'identity parts (propertize " · " 'face 'octocat-dimmed))))))

(defun octocat-vui-repo-tabs (repo current &optional issues prs highlight)
  "Return a list of vnodes: the tab strip of REPO's pages, as on GitHub.
The tabs are those of `octocat--repo-tabs'.  CURRENT is the symbol of
the list page being shown; its tab is drawn as a heading and is not
clickable.  HIGHLIGHT is the tab a detail page belongs to: drawn the same
way, but still a button that opens the list.  The others open their page
for REPO.  ISSUES and PRS, when non-nil, are open counts shown on their
tabs (a string such as \"…\" while they load)."
  (mapcar
   (lambda (tab)
     (pcase-let* ((`(,sym ,label ,help ,fn) tab)
                  (label (pcase sym
                           ('issues (if issues (format "%s (%s)" label issues) label))
                           ('pulls  (if prs (format "%s (%s)" label prs) label))
                           (_ label))))
       (if (eq sym current)
           (vui-text label :face 'octocat-section-heading)
         (vui-button label
                     :face (if (eq sym highlight)
                               'octocat-section-heading
                             'octocat-dimmed)
                     :help-echo help
                     :on-click (lambda () (funcall fn repo))))))
   octocat--repo-tabs))

(vui-defcomponent octocat-vui-list-header (repo tab kind loading)
  "Header for a list page: REPO, the tab strip and, for KIND, item counts.
TAB is the symbol of the current tab (see `octocat-vui-repo-tabs').
KIND is `issues' or `pulls' to show \"N open · M closed\" (plus merged
for pulls) from one API call, or nil for no counts.  A non-nil LOADING
adds an animated \"(loading…)\" marker: the list below is stale data being
refreshed."
  :state ((spin 0))
  :render
  (let* ((cached (vui-use-memo (repo kind)
                   (and kind (octocat--counts-cache-load repo kind))))
         (result (vui-use-async (list 'counts kind repo)
                   (lambda (resolve _reject)
                     (if (null kind)
                         (funcall resolve nil)
                       (octocat--fetch-counts
                        repo kind
                        (lambda (r)
                          (funcall resolve (unless (eq (car-safe r) 'error) r))))))))
         (fresh  (and (eq (plist-get result :status) 'ready)
                      (plist-get result :data)))
         ;; The cached counts show until the fresh ones arrive.
         (counts (or fresh cached)))
    (vui-use-effect (fresh)
      (when (and kind fresh)
        (octocat--counts-cache-save repo kind fresh))
      nil)
    (octocat-vui-use-spinner loading)
    (vui-fragment
     (apply #'vui-hstack :spacing 2
            ;; A row, not a button: buttons draw their [brackets], and the
            ;; repo name is plain text on every other page's top line.
            (octocat-vui-row (propertize repo 'face 'octocat-repo)
                             (lambda () (octocat-visit-repo repo))
                             "RET: open repository page")
            (append (octocat-vui-repo-tabs repo tab)
                    (and loading
                         (list (vui-text (string-trim-left
                                          (octocat-vui-loading-suffix
                                           '(:refreshing t) spin)))))))
     (vui-newline)
     (when counts
       (vui-fragment
        (vui-text (string-join
                   (delq nil
                         (list (format "%d open" (plist-get counts :open))
                               (format "%d closed" (plist-get counts :closed))
                               (and (plist-get counts :merged)
                                    (format "%d merged" (plist-get counts :merged)))))
                   " · ")
                  :face 'octocat-dimmed)
        (vui-newline))))))


;;;; List filters
;;
;; The PR and issue pages are filtered by a GitHub search query string
;; (see octocat-core.el, "List filters"), kept in `octocat-vui-list--query'
;; and shown as a line above the list.  `/' edits it directly, with
;; completion for the usual qualifiers; the State / Author / Assignee /
;; Label buttons (or `F') edit single qualifiers through a toggle prompt:
;; choosing an item checks it, choosing a checked item unchecks it.
;; Either way the buffer is refreshed with the new query.

(defvar-local octocat-vui-list--query nil
  "Current search query of this list buffer; nil means the default query.")

(defvar-local octocat-vui-list--states nil
  "State names this page can filter by, or nil when it has no filters.")

(defconst octocat-vui-list--state-tokens '("is:open" "is:closed" "is:merged")
  "Query tokens that select the state of the listed items.")

(defconst octocat-vui-list--qualifiers
  '("is:open" "is:closed" "is:merged" "is:draft" "author:" "author:@me"
    "assignee:" "assignee:@me" "label:" "-label:" "no:label" "no:assignee"
    "base:" "head:" "mentions:" "milestone:" "review:required"
    "review:approved" "review:changes_requested" "sort:updated-desc"
    "sort:created-desc" "sort:comments-desc")
  "Qualifier completions offered while editing a query.")

(defvar octocat-vui-list--query-history nil
  "Minibuffer history of list queries.")

(defun octocat-vui-list-query ()
  "Return the search query of the current list buffer."
  (or octocat-vui-list--query octocat--default-list-query))

(defun octocat-vui-list-filter-active-p (query)
  "Return non-nil when QUERY differs from the default query."
  (not (equal (string-trim (or query octocat--default-list-query))
              octocat--default-list-query)))

(defun octocat-vui-list--tokenize (query)
  "Split QUERY into whitespace-separated tokens, keeping quoted text whole."
  (let ((pos 0) tokens)
    (while (string-match "\\(?:[^[:space:]\"]\\|\"[^\"]*\"\\|\"\\)+" query pos)
      (push (match-string 0 query) tokens)
      (setq pos (match-end 0)))
    (nreverse tokens)))

(defun octocat-vui-list--quote (value)
  "Return VALUE, double-quoted if whitespace is part of it."
  (if (string-match-p "[[:space:]]" value)
      (format "\"%s\"" value)
    value))

(defun octocat-vui-list--values (query prefix)
  "Return the unquoted values of QUERY's tokens that start with PREFIX."
  (delq nil (mapcar (lambda (token)
                      (and (string-prefix-p prefix token)
                           (replace-regexp-in-string
                            "\"" "" (substring token (length prefix)))))
                    (octocat-vui-list--tokenize query))))

(defun octocat-vui-list--replace (query drop-p new-tokens)
  "Return QUERY without tokens satisfying DROP-P, plus NEW-TOKENS at the end."
  (string-join (append (seq-remove drop-p (octocat-vui-list--tokenize query))
                       new-tokens)
               " "))

(defun octocat-vui-list--state (query)
  "Return the state named in QUERY: \"open\", \"closed\", \"merged\" or \"all\"."
  (let ((token (seq-find (lambda (tok) (member tok octocat-vui-list--state-tokens))
                         (octocat-vui-list--tokenize query))))
    (if token (substring token 3) "all")))

(defun octocat-vui-list--with-state (query state)
  "Return QUERY with its state token set to STATE (\"all\" drops the token)."
  (let ((rest (octocat-vui-list--replace
               query (lambda (tok) (member tok octocat-vui-list--state-tokens)) nil)))
    (string-trim (if (equal state "all") rest (concat "is:" state " " rest)))))

(defun octocat-vui-list--with-values (query prefix values)
  "Return QUERY with the PREFIX qualifier set to VALUES (nil drops it)."
  (octocat-vui-list--replace
   query (lambda (tok) (string-prefix-p prefix tok))
   (mapcar (lambda (v) (concat prefix (octocat-vui-list--quote v))) values)))

(defun octocat-vui-list--toggle-read (prompt candidates selected multi)
  "Read values by toggling CANDIDATES; return the new list of selected values.
PROMPT names what is being chosen.  SELECTED are the initially checked
values.  Items are shown with a
trailing check mark when selected, checked ones first.  Choosing an item
toggles it; free text not in CANDIDATES is added as a new checked value.
With MULTI the prompt repeats until an empty answer; otherwise it
returns after the first choice, and choosing the checked item clears it."
  (let ((all (delete-dups (append selected candidates)))
        (selected selected)
        (done nil))
    (while (not done)
      (let* ((items (append (seq-filter (lambda (c) (member c selected)) all)
                            (seq-remove (lambda (c) (member c selected)) all)))
             (marked (mapcar (lambda (c) (if (member c selected) (concat c " ✓") c))
                             items))
             (table (lambda (string pred action)
                      (if (eq action 'metadata)
                          '(metadata (display-sort-function . identity)
                                     (cycle-sort-function . identity))
                        (complete-with-action action marked string pred))))
             (choice (string-trim
                      (completing-read
                       (format "%s (✓ = selected%s): " prompt
                               (if multi ", empty = done" ""))
                       table nil nil)))
             (value (string-remove-suffix " ✓" choice)))
        (cond
         ((string-empty-p choice) (setq done t))
         (t
          (unless (member value all) (setq all (append all (list value))))
          (setq selected (if (member value selected)
                             (delete value selected)
                           (if multi (append selected (list value)) (list value))))
          (unless multi (setq done t))))))
    selected))

(defun octocat-vui-list--check-filterable ()
  "Signal a `user-error' unless the current buffer is a filterable list."
  (unless octocat-vui-list--states
    (user-error "Octocat: This page has no filters")))

(defun octocat-vui-list--apply (query)
  "Make QUERY the current query and refresh the buffer."
  (setq octocat-vui-list--query (string-trim query))
  (revert-buffer nil t))

(defun octocat-vui-list--qualifier-capf ()
  "Complete a search qualifier before point (see `octocat-vui-list--qualifiers')."
  (let ((end (point))
        (beg (save-excursion (skip-chars-backward "^[:space:]") (point))))
    (list beg end octocat-vui-list--qualifiers)))

(defun octocat-vui-list-edit-query ()
  "Edit the search query of the current list in the minibuffer."
  (interactive)
  (octocat-vui-list--check-filterable)
  (let ((query (minibuffer-with-setup-hook
                   (lambda ()
                     (add-hook 'completion-at-point-functions
                               #'octocat-vui-list--qualifier-capf nil t))
                 (read-string "Filter (GitHub search syntax): "
                              (octocat-vui-list-query)
                              'octocat-vui-list--query-history))))
    (octocat-vui-list--apply query)))

(defun octocat-vui-list--edit-facet (prefix prompt multi fetch extra)
  "Toggle the PREFIX qualifier of the query through a prompt named PROMPT.
Candidates come from FETCH (`octocat--list-labels' or
`octocat--list-people') plus EXTRA.  MULTI allows several values.  The
fetch is asynchronous; the prompt opens once it completes, outside the
process sentinel.  A failed fetch only logs a message, leaving free text
as the way to enter a value."
  (let ((buf   (current-buffer))
        (repo  octocat-vui-list--repo)
        (query (octocat-vui-list-query)))
    (funcall fetch repo
             (lambda (result)
               (when (buffer-live-p buf)
                 (run-at-time
                  0 nil
                  (lambda ()
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (let* ((names (if (eq (car-safe result) 'error)
                                          (progn (message "Octocat: %s" (cdr result)) nil)
                                        (append extra result)))
                               (picked (octocat-vui-list--toggle-read
                                        prompt names
                                        (octocat-vui-list--values query prefix)
                                        multi)))
                          (octocat-vui-list--apply
                           (octocat-vui-list--with-values
                            (octocat-vui-list-query) prefix picked))))))))))))

(defun octocat-vui-list-filter-state ()
  "Choose which state to list."
  (interactive)
  (octocat-vui-list--check-filterable)
  (let* ((query  (octocat-vui-list-query))
         (picked (octocat-vui-list--toggle-read
                  "State" octocat-vui-list--states
                  (list (octocat-vui-list--state query)) nil)))
    (octocat-vui-list--apply
     (octocat-vui-list--with-state query (or (car picked) "all")))))

(defun octocat-vui-list-filter-author ()
  "Filter by author."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--edit-facet "author:" "Author" nil
                                #'octocat--list-people '("@me")))

(defun octocat-vui-list-filter-assignee ()
  "Filter by assignee."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--edit-facet "assignee:" "Assignee" nil
                                #'octocat--list-people '("@me")))

(defun octocat-vui-list-filter-label ()
  "Filter by labels (all selected labels must match)."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--edit-facet "label:" "Label" t #'octocat--list-labels nil))

(defun octocat-vui-list-clear-filter ()
  "Reset the query of the current list to the default."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--apply octocat--default-list-query))

(defconst octocat-vui-list--facets
  '(("State"    . octocat-vui-list-filter-state)
    ("Author"   . octocat-vui-list-filter-author)
    ("Assignee" . octocat-vui-list-filter-assignee)
    ("Label"    . octocat-vui-list-filter-label))
  "Filter facets as (LABEL . COMMAND), in filter-bar order.")

(defun octocat-vui-list-filter ()
  "Pick a filter facet to change, like GitHub's filter menu."
  (interactive)
  (octocat-vui-list--check-filterable)
  (let* ((choices (append octocat-vui-list--facets
                          '(("Query…" . octocat-vui-list-edit-query)
                            ("Clear"  . octocat-vui-list-clear-filter))))
         (choice  (completing-read "Filter: " (mapcar #'car choices) nil t)))
    (call-interactively (cdr (assoc choice choices)))))

(defun octocat-vui-list-filter-bar (query)
  "Return a vnode showing the search QUERY and one button per facet.
The query line is highlighted when it differs from the default."
  (let ((active (octocat-vui-list-filter-active-p query)))
    (vui-fragment
     ;; The label and the facet row's indent are both as wide as "Filter"
     ;; (plus the stack's spacing), so the query box and the facet buttons
     ;; start in the same column.
     (vui-hstack :spacing 2
       (vui-text "Filter" :face 'octocat-dimmed)
       (vui-button (let* ((q     (string-trim (or query "")))
                          (shown (if (string-empty-p q) "(everything)" q)))
                     ;; Drawn as an input box: padded, with a search mark.
                     (truncate-string-to-width
                      (concat "⌕ " shown) (max 40 (+ 3 (string-width shown)))
                      nil ?\s))
                   :no-decoration t
                   :face (if active
                             '(octocat-branch octocat-filter-input)
                           'octocat-filter-input)
                   :key :query
                   :help-echo "RET or /: edit the search query"
                   :on-click #'octocat-vui-list-edit-query))
     (vui-newline)
     (apply #'vui-hstack :spacing 2
            (vui-text "      ")
            (append
             (mapcar (lambda (facet)
                       (vui-button (format "[%s]" (car facet))
                                   :no-decoration t
                                   :face 'octocat-dimmed
                                   :key (car facet)
                                   :help-echo (format "RET: filter by %s"
                                                      (downcase (car facet)))
                                   :on-click (cdr facet)))
                     octocat-vui-list--facets)
             (when active
               (list (vui-button "[clear]"
                                 :no-decoration t
                                 :face 'octocat-dimmed
                                 :key :clear
                                 :help-echo "RET: reset the query"
                                 :on-click #'octocat-vui-list-clear-filter)))))
     (vui-newline))))

(define-key octocat-vui-list-mode-map (kbd "/") #'octocat-vui-list-edit-query)
(define-key octocat-vui-list-mode-map (kbd "F") #'octocat-vui-list-filter)

(provide 'octocat-vui)
;;; octocat-vui.el ends here
