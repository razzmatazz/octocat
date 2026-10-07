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

(defun octocat-vui-load-more-button (key count help-echo on-click)
  "Return a \"Load COUNT more…\" vui-button with HELP-ECHO, invoking ON-CLICK.
KEY is a per-section symbol: it is the button's cursor identity, so point
stays on this section's button when growing the list re-renders it
instead of drifting to a neighbouring section's button.
Rows carry no trailing newline (`vui-list' only separates them), so the
button starts on a fresh line and carries the same two-space indent."
  (vui-fragment
   (vui-newline)
   (vui-text "  ")
   (vui-button (format "[+] Load %d more…" count)
               :no-decoration t
               :face 'octocat-dimmed
               :key key
               :help-echo help-echo
               :on-click on-click)))

(provide 'octocat-vui)
;;; octocat-vui.el ends here
