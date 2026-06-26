;;; octocat-issue.el --- Issue detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-4-6

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

;; Issue data fetching, detail rendering, and the octocat-issue-mode major mode.
;; Depends on octocat-core.el for shared infrastructure; must not depend on
;; octocat.el to avoid a circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-edit)

;; These commands are defined in octocat.el which loads this file, so we
;; cannot require it here.  Declare them to silence the byte-compiler.
(declare-function octocat-browse "octocat" ())
(declare-function octocat-visit  "octocat" ())

;;;; Edit / comment commands — submit helpers

(defun octocat-issue--submit-comment (body source on-success on-error)
  "Submit BODY as a new comment on the issue in SOURCE buffer.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (with-current-buffer source
    (let ((repo octocat--issue-repo)
          (num  (number-to-string octocat--issue-number)))
      (octocat--run-gh "comment"
        (list "issue" "comment" num "--repo" repo "--body" body)
        (lambda (out) (string-trim out))
        (lambda (result)
          (if (eq (car-safe result) 'error)
              (funcall on-error (cdr result))
            (funcall on-success)))))))

(defun octocat-issue--submit-edit-body (body source on-success on-error)
  "Replace the body of the issue in SOURCE buffer with BODY.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (with-current-buffer source
    (let ((repo octocat--issue-repo)
          (num  (number-to-string octocat--issue-number)))
      (octocat--run-gh "edit-body"
        (list "issue" "edit" num "--repo" repo "--body" body)
        (lambda (out) (string-trim out))
        (lambda (result)
          (if (eq (car-safe result) 'error)
              (funcall on-error (cdr result))
            (funcall on-success)))))))

(defun octocat-issue--submit-edit-comment (body source on-success on-error)
  "Edit the comment identified in `octocat-edit--user-data' with BODY.
The :comment-id plist key is read from the edit buffer (current-buffer at
call time).  SOURCE supplies the repo string.
Calls ON-SUCCESS on completion or ON-ERROR with a message on failure."
  (let ((repo       (with-current-buffer source octocat--issue-repo))
        (comment-id (plist-get octocat-edit--user-data :comment-id)))
    (octocat--run-gh "edit-comment"
      (list "api"
            (format "repos/%s/issues/comments/%s" repo comment-id)
            "--method" "PATCH"
            "-f" (format "body=%s" body))
      (lambda (out) (string-trim out))
      (lambda (result)
        (if (eq (car-safe result) 'error)
            (funcall on-error (cdr result))
          (funcall on-success))))))

;;;; Edit / comment commands

(defun octocat-issue-add-comment ()
  "Open an edit buffer to add a comment to the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (octocat--open-edit-buffer
   (format "New comment on issue #%d" octocat--issue-number)
   #'octocat-issue--submit-comment
   #'octocat-issue-refresh))

(defun octocat-issue-edit-body ()
  "Open an edit buffer to replace the body of the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  ;; Pre-populate with the current body from the cache so the user can
  ;; edit in-place rather than retyping everything.
  (let* ((cache (octocat--detail-cache-load octocat--issue-repo "issue" octocat--issue-number))
         (body  (and cache (octocat--nonempty (gethash "body" cache)))))
    (octocat--open-edit-buffer
     (format "Edit body of issue #%d" octocat--issue-number)
     #'octocat-issue--submit-edit-body
     #'octocat-issue-refresh
     body)))

(defun octocat-issue-edit-title ()
  "Prompt in the minibuffer to rename the title of the current issue."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (let* ((cache   (octocat--detail-cache-load octocat--issue-repo "issue" octocat--issue-number))
         (current (or (and cache (octocat--nonempty (gethash "title" cache))) ""))
         (new     (string-trim (read-string "Issue title: " current))))
    (when (string-empty-p new)
      (user-error "Octocat: Title must not be empty"))
    (unless (string-equal new current)
      (let ((repo octocat--issue-repo)
            (num  octocat--issue-number)
            (buf  (current-buffer)))
        (octocat--run-gh
         "edit-title"
         (list "issue" "edit" (number-to-string num) "--repo" repo "--title" new)
         #'identity
         (lambda (result)
           (if (eq (car-safe result) 'error)
               (message "Octocat: failed to update title: %s" (cdr result))
             (when (buffer-live-p buf)
               (with-current-buffer buf (octocat-issue-refresh))))))))))

(defun octocat-issue-edit ()
  "Edit the thing at point in the current issue buffer.
On the body section: replace the issue body.
On a comment you authored: edit that comment.
On someone else\\='s comment: signal an error."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (let* ((section (magit-current-section))
         (type    (oref section type)))
    (pcase type
      ('issue-body
       (octocat-issue-edit-body))
      ('comment
       (let* ((comment    (oref section value))
              (authored   (eq (gethash "viewerDidAuthor" comment) t))
              (comment-id (octocat--comment-numeric-id comment))
              (body       (octocat--nonempty (gethash "body" comment))))
         (unless authored
           (user-error "Octocat: You can't edit someone else's comment"))
         (unless comment-id
           (user-error "Octocat: Could not determine comment ID from URL"))
         (octocat--open-edit-buffer
          (format "Edit comment on issue #%d" octocat--issue-number)
          #'octocat-issue--submit-edit-comment
          #'octocat-issue-refresh
          body
          (list :comment-id comment-id))))
      (_
       (user-error "Octocat: Nothing to edit here")))))


;;;; Buffer-local declarations

(defvar-local octocat--issue-repo nil
  "The \"owner/repo\" this issue buffer belongs to.")

(defvar-local octocat--issue-number nil
  "The issue number this buffer is displaying.")


;;;; Data fetching

(defun octocat--list-issues (repo limit callback)
  "Fetch up to LIMIT open issues for REPO asynchronously and call CALLBACK.
CALLBACK is called with a list of issue hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "issues"
                   (list "issue" "list"
                         "--repo" repo
                         "--state" "open"
                         "--limit" (number-to-string limit)
                         "--json" "number,title,author,state")
                   #'octocat--parse-json-list
                   callback))

(defun octocat--fetch-issue (repo number callback)
  "Fetch detail for issue NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of issue data, or a cons \\=(error . MSG)."
  (octocat--run-gh "issue"
                   (list "issue" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "number,title,author,state,body,"
                                          "createdAt,closedAt,"
                                          "labels,comments,url"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))


;;;; Rendering helpers

(defun octocat--issue-state-face (state)
  "Return the face for issue STATE string."
  (if (equal state "OPEN") 'octocat-pr-state-open 'octocat-pr-state-closed))


;;;; Rendering

(defun octocat--render-issue-loading (number title state)
  "Render a loading skeleton for issue NUMBER with TITLE and STATE."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-issue-root)
      (magit-insert-heading
        (concat (propertize (or octocat--issue-repo "") 'face 'octocat-repo)
                "  "
                (propertize "issue" 'face 'octocat-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                title
                "  "
                (propertize (downcase state) 'face (octocat--issue-state-face state))))
      (magit-insert-section (issue-meta)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (let ((hint (list 'mouse-face 'magit-section-highlight
                          'help-echo  "RET: open repo view")))
          (magit-insert-section (repo-nav octocat--issue-repo)
            (magit-insert-heading
              (concat (apply #'propertize "  Repo     " hint)
                      (apply #'propertize (or octocat--issue-repo "")
                             'face 'octocat-repo hint)
                      (apply #'propertize "\n" hint)))))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (issue-body)
        (magit-insert-heading (propertize "Body" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (issue-labels)
        (magit-insert-heading (propertize "Labels" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (insert "\n")
      (magit-insert-section (issue-comments)
        (magit-insert-heading (propertize "Comments" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-issue (issue)
  "Erase the current buffer and render issue detail from hash-table ISSUE."
  (let* ((number   (gethash "number"    issue))
         (title    (or (gethash "title"  issue) ""))
         (state    (or (gethash "state"  issue) "OPEN"))
         (author   (octocat--author-login issue))
         (body     (or (gethash "body" issue) ""))
         (created  (or (gethash "createdAt" issue) ""))
         (closed   (gethash "closedAt" issue))
         (labels   (let ((v (gethash "labels" issue)))
                     (if (or (null v) (eq v :null)) [] v)))
         (comments (let ((v (gethash "comments" issue)))
                     (if (or (null v) (eq v :null)) [] v)))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-issue-root)
      ;; ── Header ────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--issue-repo "") 'face 'octocat-repo)
                "  "
                (propertize "issue" 'face 'octocat-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                title
                "  "
                (propertize (downcase state)
                            'face (octocat--issue-state-face state))))
      ;; ── Info ──────────────────────────────────────────────────────────
      (magit-insert-section (issue-meta)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (let ((hint (list 'mouse-face 'magit-section-highlight
                          'help-echo  "RET: open repo view")))
          (magit-insert-section (repo-nav octocat--issue-repo)
            (magit-insert-heading
              (concat (apply #'propertize "  Repo     " hint)
                      (apply #'propertize (or octocat--issue-repo "")
                             'face 'octocat-repo hint)
                      (apply #'propertize "\n" hint)))))
        (magit-insert-section (issue-title)
          (magit-insert-heading
            (let ((hint '(mouse-face magit-section-highlight
                          help-echo  "RET: edit title")))
              (concat (apply #'propertize "  Title    " hint)
                      (apply #'propertize title hint)
                      (apply #'propertize "\n" hint)))))
        (insert (format "  Author   %s\n"
                        (propertize author 'face 'octocat-pr-author)))
        (insert (format "  Created  %s\n" (octocat--format-ts-full created)))
        (when (and closed (not (eq closed :null)) (not (string-empty-p closed)))
          (insert (format "  Closed   %s\n" (octocat--format-ts-full closed)))))
      ;; ── Body ──────────────────────────────────────────────────────────
      (insert "\n")
      (magit-insert-section (issue-body)
        (magit-insert-heading (propertize "Body" 'face 'octocat-section-heading))
        (if (string-empty-p (string-trim body))
            (insert (propertize "  (no description)\n" 'face 'octocat-dimmed))
          (octocat--insert-markdown body)))
      ;; ── Labels ────────────────────────────────────────────────────────
      (insert "\n")
      (magit-insert-section (issue-labels)
        (magit-insert-heading
          (propertize (format "Labels (%d)" (length labels))
                      'face 'octocat-section-heading))
        (if (zerop (length labels))
            (insert (propertize "  (no labels)\n" 'face 'octocat-dimmed))
          (cl-loop for label across labels do
                   (let ((name (or (gethash "name" label) "")))
                     (insert (format "  %s\n"
                                     (propertize name 'face 'octocat-branch)))))))
      ;; ── Comments ──────────────────────────────────────────────────────
      (insert "\n")
      (magit-insert-section (issue-comments)
        (magit-insert-heading
          (propertize (format "Comments (%d)" (length comments))
                      'face 'octocat-section-heading))
        (octocat--render-comments comments)))))


;;;; Major mode

(defvar octocat-issue-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "RET")     #'octocat-visit)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "C-c C-a") #'octocat-issue-add-comment)
    (define-key map (kbd "C-c C-e") #'octocat-issue-edit)
    (define-key map (kbd "C-c C-v") #'octocat-toggle-markdown)
    (define-key map (kbd "C-c C-r") #'octocat-switch-repo)
    (define-key map (kbd "C-c C-s") #'octocat-search-repo)
    ;; Shadow magit-section-mode-map's "g" → revert-buffer with a prefix map.
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-issue-refresh)
    map)
  "Keymap for `octocat-issue-mode'.")

(define-derived-mode octocat-issue-mode magit-section-mode "Octocat-Issue"
  "Major mode for viewing a GitHub Issue.

\\{octocat-issue-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-issue-refresh)
  (setq-local octocat--refresh-fn #'octocat-issue-refresh)
  (font-lock-mode -1))


;;;; Refresh

(defun octocat-issue-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current issue detail buffer asynchronously.
Renders a disk cache immediately (stale-while-revalidate) when available,
then always fetches fresh data in the background."
  (interactive)
  (unless (and octocat--issue-repo octocat--issue-number)
    (user-error "Octocat: Buffer is not associated with an issue"))
  (let* ((buf         (current-buffer))
         (repo        octocat--issue-repo)
         (num         octocat--issue-number)
         (saved-point (octocat--save-point))
         (cache       (octocat--detail-cache-load repo "issue" num)))
    (when cache
      (octocat--render-issue cache)
      (octocat--restore-point saved-point))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-issue repo num
                          (lambda (result)
                            (when (buffer-live-p buf)
                              (with-current-buffer buf
                                (setq mode-line-process nil)
                                (if (eq (car-safe result) 'error)
                                    (let ((inhibit-read-only t))
                                      (erase-buffer)
                                      (insert (propertize
                                               (format "  Error: %s\n" (cdr result))
                                               'face 'error)))
                                  (octocat--detail-cache-save repo "issue" num result)
                                  (octocat--render-issue result)
                                  (octocat--restore-point saved-point))))))))

(provide 'octocat-issue)
;;; octocat-issue.el ends here
