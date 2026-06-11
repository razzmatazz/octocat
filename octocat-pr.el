;;; octocat-pr.el --- Pull Request detail view for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; PR data fetching, detail rendering, and the octocat-pr-mode major mode.
;; Depends on octocat-core.el for shared infrastructure; must not depend on
;; octocat.el to avoid a circular require.

;;; Code:

(require 'octocat-core)
(require 'octocat-commit)
(require 'octocat-edit)

;; Forward declarations for buffer-locals defined later in this file.
;; Needed so the byte-compiler doesn't warn about free variables in
;; rendering functions that run in `octocat-pr-mode' buffers.
(defvar octocat--pr-repo)
(defvar octocat--pr-number)

;; These commands are defined in octocat.el which loads this file, so we
;; cannot require it here.  Declare them to silence the byte-compiler.
(declare-function octocat-browse "octocat" ())
(declare-function octocat-visit  "octocat" ())

;;;; Edit / comment commands

(defun octocat-pr-add-comment ()
  "Open an edit buffer to add a comment to the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (octocat--open-edit-buffer octocat--pr-repo 'pr octocat--pr-number 'comment))

(defun octocat-pr-edit-body ()
  "Open an edit buffer to replace the body of the current PR."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  ;; Pre-populate with the current body from the cache so the user can
  ;; edit in-place rather than retyping everything.
  (let* ((cache (octocat--detail-cache-load octocat--pr-repo "pr" octocat--pr-number))
         (body  (and cache (octocat--nonempty (gethash "body" cache)))))
    (octocat--open-edit-buffer octocat--pr-repo 'pr octocat--pr-number 'edit-body body)))

(defun octocat-pr-edit ()
  "Edit the thing at point in the current PR buffer.
On the body section: replace the PR body.
On a comment you authored: edit that comment.
On someone else\\='s comment: signal an error."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (let* ((section (magit-current-section))
         (type    (oref section type)))
    (pcase type
      ('pr-body
       (octocat-pr-edit-body))
      ('comment
       (let* ((comment    (oref section value))
              (authored   (eq (gethash "viewerDidAuthor" comment) t))
              (comment-id (octocat--comment-numeric-id comment))
              (body       (octocat--nonempty (gethash "body" comment))))
         (unless authored
           (user-error "Octocat: You can't edit someone else's comment"))
         (unless comment-id
           (user-error "Octocat: Could not determine comment ID from URL"))
         (octocat--open-edit-buffer octocat--pr-repo 'pr octocat--pr-number
                                    'edit-comment body comment-id)))
      (_
       (user-error "Octocat: Nothing to edit here")))))


;;;; Data fetching

(defun octocat--list-prs (repo callback)
  "Fetch open PRs for REPO asynchronously and call CALLBACK with results.
CALLBACK is called with a list of PR hash-tables, or a cons \\=(error . MSG)."
  (octocat--run-gh "prs"
                   (list "pr" "list"
                         "--repo" repo
                         "--state" "open"
                         "--json" "number,title,author,state,statusCheckRollup")
                   #'octocat--parse-json-list
                   callback))

(defun octocat--fetch-pr (repo number callback)
  "Fetch detail for pull request NUMBER in REPO asynchronously.
Calls CALLBACK with a single hash-table of PR data, or a cons \\=(error . MSG)."
  (octocat--run-gh "pr"
                   (list "pr" "view"
                         (number-to-string number)
                         "--repo" repo
                         "--json" (concat "number,title,author,state,body,"
                                          "createdAt,mergedAt,closedAt,"
                                          "baseRefName,headRefName,"
                                          "additions,deletions,changedFiles,"
                                          "labels,reviewDecision,latestReviews,"
                                          "comments,statusCheckRollup,url,commits"))
                   (lambda (output) (json-parse-string (string-trim output)))
                   callback))


;;;; Rendering

(defun octocat--pr-state-face (state)
  "Return the face for PR STATE string."
  (cond ((equal state "MERGED") 'octocat-pr-state-merged)
        ((equal state "CLOSED") 'octocat-pr-state-closed)
        (t                      'octocat-pr-state-open)))

(defun octocat--render-pr-loading (number title state)
  "Render a loading skeleton for PR NUMBER with TITLE and STATE."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-pr-root)
      (magit-insert-heading
        (concat (propertize (or octocat--pr-repo "") 'face 'octocat-repo)
                "  "
                (propertize "PR" 'face 'octocat-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                title
                "  "
                (propertize (downcase state) 'face (octocat--pr-state-face state))))
      (magit-insert-section (pr-body)
        (magit-insert-heading (propertize "Body" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (pr-commits)
        (magit-insert-heading (propertize "Commits" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (pr-checks)
        (magit-insert-heading (propertize "Checks" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (pr-reviews)
        (magit-insert-heading (propertize "Reviews" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))
      (magit-insert-section (pr-comments)
        (magit-insert-heading (propertize "Comments" 'face 'octocat-section-heading))
        (insert (propertize "  Loading…\n" 'face 'octocat-dimmed))))))

(defun octocat--render-pr (pr)
  "Erase the current buffer and render PR detail from hash-table PR."
  (let* ((number      (gethash "number"       pr))
         (title       (or (gethash "title"    pr) ""))
         (state       (or (gethash "state"    pr) "OPEN"))
         (author      (or (gethash "login" (gethash "author" pr)) ""))
         (body        (or (gethash "body" pr) ""))
         (base        (or (gethash "baseRefName" pr) ""))
         (head        (or (gethash "headRefName" pr) ""))
         (created     (or (gethash "createdAt"   pr) ""))
         (merged      (gethash "mergedAt"  pr))
         (closed      (gethash "closedAt"  pr))
         (additions   (or (gethash "additions"   pr) 0))
         (deletions   (or (gethash "deletions"   pr) 0))
         (files       (or (gethash "changedFiles" pr) 0))
         (commits     (let ((v (gethash "commits" pr)))
                        (if (or (null v) (eq v :null)) [] v)))
         (checks      (let ((v (gethash "statusCheckRollup" pr)))
                        (if (or (null v) (eq v :null)) [] v)))
         (reviews     (let ((v (gethash "latestReviews" pr)))
                        (if (or (null v) (eq v :null)) [] v)))
         (comments    (let ((v (gethash "comments" pr)))
                        (if (or (null v) (eq v :null)) [] v)))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-pr-root)
      ;; ── Header ──────────────────────────────────────────────────────────
      (magit-insert-heading
        (concat (propertize (or octocat--pr-repo "") 'face 'octocat-repo)
                "  "
                (propertize "PR" 'face 'octocat-dimmed)
                " "
                (propertize (format "#%d" number) 'face 'octocat-pr-number)
                "  "
                title
                "  "
                (propertize (downcase state)
                            'face (octocat--pr-state-face state))))
      ;; ── Meta ────────────────────────────────────────────────────────────
      (magit-insert-section (pr-meta)
        (magit-insert-heading (propertize "Info" 'face 'octocat-section-heading))
        (insert (format "  Author   %s\n"
                        (propertize (concat "@" author) 'face 'octocat-pr-author)))
        (insert (format "  Branch   %s → %s\n"
                        (propertize head 'face 'octocat-branch)
                        (propertize base 'face 'octocat-branch)))
        (insert (format "  Created  %s\n" (octocat--format-ts created)))
        (when (and merged (not (eq merged :null)) (not (string-empty-p merged)))
          (insert (format "  Merged   %s\n" (octocat--format-ts merged))))
        (when (and closed (not (eq closed :null)) (not (string-empty-p closed))
                   (not (equal state "MERGED")))
          (insert (format "  Closed   %s\n" (octocat--format-ts closed))))
        (magit-insert-section (pr-changes)
          (magit-insert-heading
            (format "  Changes  %s %s across %d file(s)\n"
                    (propertize (format "+%d" additions) 'face 'diff-added)
                    (propertize (format "-%d" deletions) 'face 'diff-removed)
                    files))))
      ;; ── Body ────────────────────────────────────────────────────────────
      (magit-insert-section (pr-body)
        (magit-insert-heading (propertize "Body" 'face 'octocat-section-heading))
        (if (string-empty-p (string-trim body))
            (insert (propertize "  (no description)\n" 'face 'octocat-dimmed))
          (octocat--insert-markdown body)))
      ;; ── Commits ─────────────────────────────────────────────────────────
      (magit-insert-section (pr-commits)
        (magit-insert-heading
          (propertize (format "Commits (%d)" (length commits))
                      'face 'octocat-section-heading))
        (if (zerop (length commits))
            (insert (propertize "  (no commits)\n" 'face 'octocat-dimmed))
          (let ((head-oid (or (gethash "oid" (aref commits (1- (length commits)))) "")))
            (cl-loop for commit across commits do
                     (let* ((oid     (or (gethash "oid"             commit) ""))
                            (subject (or (gethash "messageHeadline" commit) ""))
                            (commit-authors (gethash "authors" commit))
                            (author  (or (and commit-authors
                                             (> (length commit-authors) 0)
                                             (gethash "name" (aref commit-authors 0)))
                                         ""))
                            (date    (octocat--format-ts
                                      (or (gethash "committedDate" commit) "")))
                            (short   (substring oid 0 (min 7 (length oid))))
                            (headp   (string= oid head-oid)))
                       (magit-insert-section (commit commit)
                         (magit-insert-heading
                           (concat
                            "  "
                            (propertize short 'face 'octocat-commit-sha)
                            "  "
                            (truncate-string-to-width
                             (format "%-50s" subject) 50 nil ?\s "…")
                            "  "
                            (propertize (format "%-16s" author)
                                        'face 'octocat-pr-author)
                            "  "
                            (propertize date 'face 'octocat-dimmed)
                            (when headp
                              (concat "  " (octocat--ci-label pr)))
                            "\n"))))))))
      ;; ── Checks ──────────────────────────────────────────────────────────
      (magit-insert-section (pr-checks)
        (magit-insert-heading
          (concat (propertize (format "Checks (%d)" (length checks))
                              'face 'octocat-section-heading)
                  (unless (zerop (length checks))
                    (concat "  " (octocat--ci-label pr)))))
        (if (zerop (length checks))
            (insert (propertize "  (no checks)\n" 'face 'octocat-dimmed))
          (cl-loop for check across checks do
                   (let* ((name       (or (gethash "name"         check) ""))
                          (workflow   (or (gethash "workflowName" check) ""))
                          (status     (or (gethash "status"       check) ""))
                          (conclusion (let ((c (gethash "conclusion" check)))
                                        (when (and c (not (eq c :null))) c)))
                          (started    (let ((s (gethash "startedAt" check)))
                                        (when (and s (not (eq s :null))) s)))
                          (completed  (let ((c (gethash "completedAt" check)))
                                        (when (and c (not (eq c :null))) c)))
                          (duration   (octocat--run-duration started completed))
                          (icon       (octocat--run-icon status conclusion)))
                     (insert (format "  %s  %-30s  %-16s  %s  %s\n"
                                     icon
                                     (truncate-string-to-width name 30 nil ?\s "…")
                                     (propertize workflow 'face 'octocat-dimmed)
                                     (propertize (or duration "") 'face 'octocat-dimmed)
                                     (propertize (octocat--format-ts (or started ""))
                                                 'face 'octocat-dimmed)))))))
      ;; ── Reviews ─────────────────────────────────────────────────────────
      (magit-insert-section (pr-reviews)
        (magit-insert-heading
          (propertize (format "Reviews (%d)" (length reviews))
                      'face 'octocat-section-heading))
        (if (zerop (length reviews))
            (insert (propertize "  (no reviews)\n" 'face 'octocat-dimmed))
          (cl-loop for review across reviews do
                   (let* ((login (or (gethash "login" (gethash "author" review)) ""))
                          (rstate (downcase (or (gethash "state" review) ""))))
                     (insert (format "  %-20s  %s\n"
                                     (propertize (concat "@" login) 'face 'octocat-pr-author)
                                     rstate))))))
      ;; ── Comments ────────────────────────────────────────────────────────
      (magit-insert-section (pr-comments)
        (magit-insert-heading
          (propertize (format "Comments (%d)" (length comments))
                      'face 'octocat-section-heading))
        (octocat--render-comments comments)))))


;;;; Major mode

(defvar octocat-pr-mode-map
  (let ((map (make-sparse-keymap))
        (g   (make-sparse-keymap)))   ; "g" prefix — lets evil's "gg" through
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "RET")     #'octocat-visit)
    (define-key map (kbd "o")       #'octocat-browse)
    (define-key map (kbd "C-c C-o") #'octocat-browse)
    (define-key map (kbd "c")       #'octocat-pr-add-comment)
    (define-key map (kbd "e")       #'octocat-pr-edit)
    ;; Shadow magit-section-mode-map's "g" → revert-buffer with a prefix map.
    (define-key map (kbd "g")  g)
    (define-key map (kbd "gr") #'octocat-pr-refresh)
    map)
  "Keymap for `octocat-pr-mode'.")
(define-derived-mode octocat-pr-mode magit-section-mode "Octocat-PR"
  "Major mode for viewing a GitHub Pull Request.

\\{octocat-pr-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-pr-refresh)
  (font-lock-mode -1))

(defvar-local octocat--pr-number nil
  "The PR number this buffer is displaying.")

(defvar-local octocat--pr-repo nil
  "The \"owner/repo\" this PR buffer belongs to.")


;;;; Refresh

(defun octocat-pr-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current PR detail buffer asynchronously.
Renders a disk cache immediately (stale-while-revalidate) when available,
then always fetches fresh data in the background."
  (interactive)
  (unless (and octocat--pr-repo octocat--pr-number)
    (user-error "Octocat: Buffer is not associated with a pull request"))
  (let* ((buf         (current-buffer))
         (repo        octocat--pr-repo)
         (num         octocat--pr-number)
         (saved-point (octocat--save-point)))
    (let ((cache (octocat--detail-cache-load repo "pr" num)))
      (when cache
        (octocat--render-pr cache)
        (octocat--restore-point saved-point)))
    (setq mode-line-process " [refreshing…]")
    (octocat--fetch-pr repo num
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
                               (octocat--detail-cache-save repo "pr" num result)
                               (octocat--render-pr result)
                               (octocat--restore-point saved-point))))))))

(provide 'octocat-pr)
;;; octocat-pr.el ends here
