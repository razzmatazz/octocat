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

;; Small, octocat-agnostic building blocks on top of vui.el: hooks,
;; components and vnode builders that are not specific to the repo view.
;; Keep them free of GitHub/repo knowledge so any future vui-based buffer
;; can reuse them.  Everything vui-related that is *not* generic stays in
;; the buffer's own file (e.g. `octocat-repo.el').
;;
;; Contents:
;;
;;   `octocat-vui-row'               RET-able, per-segment-styled line
;;   `octocat-vui-use-async-sticky'  `vui-use-async' that keeps old data
;;                                   visible while the next page loads
;;   `octocat-vui-load-more-button'  "[+] Load N more…" button
;;   `octocat-vui-list-mode'         base mode of the list pages (below);
;;                                   the one place that knows about a
;;                                   repo, to share keymap and browse

;;; Code:

(require 'octocat-core) ; `octocat-dimmed' face
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
`wrong-type-argument commandp' the moment RET is actually pressed."
  (let ((map (let ((m (make-sparse-keymap)))
               (define-key m (kbd "RET") (lambda () (interactive) (funcall on-visit)))
               m)))
    (vui-region :keymap map
      (vui-text line 'mouse-face 'highlight
                'help-echo (or help-echo "RET: view details")))))

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

(defun octocat-vui-load-more-button (key count help-echo on-click &optional loading)
  "Return a \"Load COUNT more…\" vui-button with HELP-ECHO, invoking ON-CLICK.
KEY is a per-section symbol: it is the button's cursor identity, so point
stays on this section's button when growing the list re-renders it
instead of drifting to a neighbouring section's button.
When LOADING is non-nil (the next page is being fetched, see
`octocat-vui-use-async-sticky'), the label reads \"Loading…\" and the
button is disabled so it cannot be triggered twice.
Rows carry no trailing newline (`vui-list' only separates them), so the
button starts on a fresh line and carries the same two-space indent."
  (vui-fragment
   (vui-newline)
   (vui-text "  ")
   (vui-button (if loading
                   "[…] Loading…"
                 (format "[+] Load %d more…" count))
               :no-decoration t
               :face 'octocat-dimmed
               :key key
               :disabled loading
               :help-echo (if loading nil help-echo)
               :on-click on-click)))

(defun octocat-vui-list-header (repo title)
  "Return a header vnode for a list page TITLE of REPO."
  (vui-fragment
   (vui-hstack :spacing 2
     (vui-text repo :face 'octocat-repo)
     (vui-text title :face 'octocat-dimmed))
   (vui-newline)))


;;;; List-page base mode
;;
;; Skeleton shared by the PR, issue and workflow list pages (defined in
;; octocat-pr.el, octocat-issue.el and octocat-workflow.el): the repo they
;; show, the github.com path `octocat-vui-list-browse' opens, and the
;; common keymap.  Each page derives from this mode, sets its own
;; `revert-buffer-function', and is opened via `octocat--open-list'
;; (octocat.el).

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

(declare-function octocat-switch-repo "octocat-core" ())
(declare-function octocat-search-repo "octocat-core" ())

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
  (setq-local truncate-lines t))


;;;; List filters
;;
;; Pages that support filtering (PRs, issues) set
;; `octocat-vui-list--states' in their mode body, pass
;; `octocat-vui-list--filter' to their component on every refresh, and
;; show `octocat-vui-list-filter-bar'.  Changing a facet stores the new
;; filter and refreshes the buffer.  The filter plist is described in
;; octocat-core.el ("List filters").

(declare-function octocat--list-labels "octocat-core" (repo callback))
(declare-function octocat--list-people "octocat-core" (repo callback))

(defvar-local octocat-vui-list--filter nil
  "Current filter plist of this list buffer; nil means defaults.")

(defvar-local octocat-vui-list--states nil
  "State names this page can filter by, or nil when it has no filters.")

(defconst octocat-vui-list--facets
  '((:state "State" octocat-vui-list-set-state)
    (:author "Author" octocat-vui-list-set-author)
    (:assignee "Assignee" octocat-vui-list-set-assignee)
    (:labels "Label" octocat-vui-list-set-labels)
    (:search "Search" octocat-vui-list-set-search))
  "Filter facets as (KEY LABEL COMMAND), in filter-bar order.")

(defun octocat-vui-list--facet-value (filter key)
  "Return the display string of facet KEY in FILTER, or nil when unset."
  (let ((v (plist-get filter key)))
    (pcase key
      (:state  (or v "open"))
      (:labels (and v (string-join v ",")))
      (_       v))))

(defun octocat-vui-list--facet-active-p (filter key)
  "Return non-nil when facet KEY of FILTER differs from the default."
  (let ((v (octocat-vui-list--facet-value filter key)))
    (if (eq key :state) (not (equal v "open")) (and v t))))

(defun octocat-vui-list-filter-active-p (filter)
  "Return non-nil when FILTER constrains the list beyond the default."
  (seq-some (lambda (facet) (octocat-vui-list--facet-active-p filter (car facet)))
            octocat-vui-list--facets))

(defun octocat-vui-list-filter-bar (filter)
  "Return a vnode with one button per facet of FILTER, plus a clear button.
Facets that differ from the default are highlighted."
  (vui-fragment
   (apply #'vui-hstack :spacing 2
          (append
           (mapcar
            (lambda (facet)
              (pcase-let ((`(,key ,label ,command) facet))
                (vui-button
                 (format "%s: %s" label
                         (truncate-string-to-width
                          (or (octocat-vui-list--facet-value filter key) "any")
                          24 nil nil "…"))
                 :no-decoration t
                 :face (if (octocat-vui-list--facet-active-p filter key)
                           'octocat-branch
                         'octocat-dimmed)
                 :key key
                 :help-echo (format "RET: filter by %s" (downcase label))
                 :on-click (lambda () (call-interactively command)))))
            octocat-vui-list--facets)
           (when (octocat-vui-list-filter-active-p filter)
             (list (vui-button "[clear]"
                               :no-decoration t
                               :face 'octocat-dimmed
                               :key :clear
                               :help-echo "RET: clear all filters"
                               :on-click #'octocat-vui-list-clear-filter)))))
   (vui-newline)))

(defun octocat-vui-list--check-filterable ()
  "Signal a `user-error' unless the current buffer is a filterable list."
  (unless octocat-vui-list--states
    (user-error "Octocat: This page has no filters")))

(defun octocat-vui-list--set (key value)
  "Set filter facet KEY to VALUE (nil or empty clears it) and refresh."
  (let ((filter (copy-sequence octocat-vui-list--filter)))
    (setq octocat-vui-list--filter
          (plist-put filter key (if (member value '(nil "" ("")))
                                    nil
                                  value)))
    (revert-buffer nil t)))

(defun octocat-vui-list--complete-async (fetch key prompt multiple extra)
  "Fetch candidates with FETCH, prompt with PROMPT, then set facet KEY.
FETCH is `octocat--list-labels' or `octocat--list-people'.  MULTIPLE
non-nil reads several comma-separated values.  EXTRA is a list of
candidates added to the fetched ones (e.g. \"@me\").  The fetch is
asynchronous; the prompt opens once it completes, outside the process
sentinel.  Candidates are only a convenience: free text is accepted, and
a failed fetch just logs a message."
  (let ((buf     (current-buffer))
        (repo    octocat-vui-list--repo)
        (initial (octocat-vui-list--facet-value octocat-vui-list--filter key)))
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
                               (value (if multiple
                                          (completing-read-multiple prompt names nil nil initial)
                                        (completing-read prompt names nil nil initial))))
                          (octocat-vui-list--set key value)))))))))))

(defun octocat-vui-list-set-state ()
  "Choose the state to list."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--set
   :state (completing-read "State: " octocat-vui-list--states nil t
                           nil nil (or (plist-get octocat-vui-list--filter :state) "open"))))

(defun octocat-vui-list-set-author ()
  "Filter by author; empty input clears the filter."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--complete-async
   #'octocat--list-people :author "Author (empty clears): " nil '("@me")))

(defun octocat-vui-list-set-assignee ()
  "Filter by assignee; empty input clears the filter."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--complete-async
   #'octocat--list-people :assignee "Assignee (empty clears): " nil '("@me")))

(defun octocat-vui-list-set-labels ()
  "Filter by labels (comma-separated, all must match); empty clears."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--complete-async
   #'octocat--list-labels :labels "Labels (comma-separated, empty clears): " t nil))

(defun octocat-vui-list-set-search ()
  "Filter by free text in GitHub search syntax; empty input clears."
  (interactive)
  (octocat-vui-list--check-filterable)
  (octocat-vui-list--set
   :search (read-string "Search (GitHub syntax, empty clears): "
                        (plist-get octocat-vui-list--filter :search))))

(defun octocat-vui-list-clear-filter ()
  "Reset all filters of the current list to the defaults."
  (interactive)
  (octocat-vui-list--check-filterable)
  (setq octocat-vui-list--filter nil)
  (revert-buffer nil t))

(defun octocat-vui-list-filter ()
  "Pick a filter facet to change, like GitHub's filter menu."
  (interactive)
  (octocat-vui-list--check-filterable)
  (let* ((choices (append (mapcar (lambda (f) (cons (nth 1 f) (nth 2 f)))
                                  octocat-vui-list--facets)
                          '(("Clear" . octocat-vui-list-clear-filter))))
         (choice  (completing-read "Filter: " (mapcar #'car choices) nil t)))
    (call-interactively (cdr (assoc choice choices)))))

(define-key octocat-vui-list-mode-map (kbd "/") #'octocat-vui-list-filter)

(provide 'octocat-vui)
;;; octocat-vui.el ends here
