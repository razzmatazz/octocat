;;; octocat-search.el --- Repo-wide PR, issue and commit search for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; `octocat-search-repo' (bound to C-c C-s in every octocat view) searches
;; the pull requests, issues and commits of the current repository with
;; live `gh search' queries, through a consult async pipeline.
;;
;; Results are cached on disk per (repo, type, query).  A cached result is
;; painted at once and refreshed in the background, the list being rebuilt
;; when the response arrives.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'consult)
(require 'octocat-core)

(declare-function octocat-pr-open                "octocat-pr"     (repo number))
(declare-function octocat-issue-open             "octocat-issue"  (repo number))
(declare-function octocat-commit-mode            "octocat-commit" ())
(declare-function octocat-commit-refresh         "octocat-commit" (&optional _ignore-auto _noconfirm))
(declare-function octocat--render-commit-loading "octocat-commit" (sha))

(defvar octocat--commit-repo)
(defvar octocat--commit-sha)


;;;; Candidates

(defun octocat--search-make-pr-candidate (pr repo)
  "Return a propertized candidate string for PR hash-table in REPO."
  (let* ((number (gethash "number" pr))
         (title  (or (octocat--nonempty (gethash "title" pr)) ""))
         (state  (or (octocat--nonempty (gethash "state" pr)) "OPEN"))
         (author (octocat--author-login pr))
         (state-face (pcase state
                       ("MERGED" 'magit-branch-remote)
                       ("CLOSED" 'error)
                       (_        'success)))
         (display
          (format "%-8s #%-5d  %-42s  %s  %s"
                  (propertize "[PR]" 'face 'magit-section-heading)
                  number
                  (octocat--format-title title)
                  (propertize (format "(%s)" state) 'face state-face)
                  (propertize author 'face 'magit-blame-name)))
         (cand (copy-sequence display)))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'pr :repo repo :number number
                             :title title :state state)
                       cand)
    cand))

(defun octocat--search-make-issue-candidate (issue repo)
  "Return a propertized candidate string for ISSUE hash-table in REPO."
  (let* ((number (gethash "number" issue))
         (title  (or (octocat--nonempty (gethash "title" issue)) ""))
         (state  (or (octocat--nonempty (gethash "state" issue)) "OPEN"))
         (author (octocat--author-login issue))
         (state-face (if (equal state "OPEN") 'success 'error))
         (display
          (format "%-8s #%-5d  %-42s  %s  %s"
                  (propertize "[Issue]" 'face 'magit-section-heading)
                  number
                  (octocat--format-title title)
                  (propertize (format "(%s)" state) 'face state-face)
                  (propertize author 'face 'magit-blame-name)))
         (cand (copy-sequence display)))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'issue :repo repo :number number
                             :title title :state state)
                       cand)
    cand))

(defun octocat--search-make-commit-candidate (commit repo)
  "Return a propertized candidate string for COMMIT hash-table in REPO.
Handles both the REST shape (\"sha\", nested \"commit\") and the GraphQL
shape (\"oid\", nested \"commit\") used in different parts of the codebase."
  (let* ((sha     (or (octocat--nonempty (gethash "sha"    commit))
                      (octocat--nonempty (gethash "oid"    commit)) ""))
         (short   (substring sha 0 (min 7 (length sha))))
         (c       (gethash "commit" commit))
         (msg     (or (and c (octocat--nonempty (gethash "message" c))) ""))
         (subject (car (split-string msg "\n")))
         (author  (octocat--commit-author commit))
         (display
          (format "%-8s %s  %-42s  %s"
                  (propertize "[Commit]" 'face 'magit-section-heading)
                  (propertize short 'face 'magit-hash)
                  (octocat--format-title subject)
                  (propertize author 'face 'magit-blame-name)))
         (cand (copy-sequence display)))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'commit :repo repo :sha sha)
                       cand)
    cand))

(defun octocat--search-open-item (item)
  "Open the octocat buffer described by ITEM, a plist from `octocat-search-item'."
  (let ((type (plist-get item :type))
        (repo (plist-get item :repo)))
    (pcase type
      ('pr
       (octocat-pr-open repo (plist-get item :number)))
      ('issue
       (octocat-issue-open repo (plist-get item :number)))
      ('commit
       (let* ((sha      (plist-get item :sha))
              (short    (substring sha 0 (min 7 (length sha))))
              (buf-name (format "*octocat-commit: %s@%s*" repo short))
              (buf      (get-buffer-create buf-name)))
         (pop-to-buffer buf)
         (unless (derived-mode-p 'octocat-commit-mode)
           (octocat-commit-mode))
         (setq octocat--commit-repo repo
               octocat--commit-sha  sha)
         (octocat--render-commit-loading sha)
         (octocat-commit-refresh))))))


;;;; Disk cache

(defcustom octocat-search-cache-ttl 60
  "Seconds before a cached object-search result is considered fresh.
`octocat-search-repo' always paints a cached result for a query at once.
An entry younger than this is trusted and no `gh search' is run; an older
one is shown immediately and refreshed in the background, the list being
updated when the response arrives.  Set to 0 to always refresh."
  :type 'integer
  :group 'octocat)

(defun octocat--search-objects-cache-file (repo type query)
  "Return the cache file for the TYPE search of QUERY in REPO."
  (expand-file-name
   (concat (secure-hash 'sha256 (mapconcat #'identity (list repo type query) "\0"))
           ".json")
   (expand-file-name "search-objects" octocat-cache-directory)))

(defun octocat--search-objects-cache-load (repo type query)
  "Load the cached TYPE search of QUERY in REPO.
Returns (TIMESTAMP . ITEMS) with ITEMS the raw `gh' hash-tables, or nil
when the entry is absent or unreadable."
  (let ((file (octocat--search-objects-cache-file repo type query)))
    (when (file-readable-p file)
      (condition-case nil
          (let ((data (json-parse-string
                       (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))))
            (cons (gethash "timestamp" data)
                  (cl-coerce (gethash "items" data) 'list)))
        (error nil)))))

(defun octocat--search-objects-cache-save (repo type query items)
  "Persist ITEMS, the TYPE search of QUERY in REPO, to disk.
Write errors are ignored so a full disk never breaks interactive search."
  (let* ((file (octocat--search-objects-cache-file repo type query))
         (obj  (make-hash-table :test #'equal)))
    (puthash "timestamp" (float-time) obj)
    (puthash "items"     (vconcat items) obj)
    (condition-case nil
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (set-buffer-multibyte nil)
            (insert (json-serialize obj))))
      (error nil))))


;;;; Async pipeline and command

(defun octocat--async-search-repo-objects (repo)
  "Build a consult async pipeline stage for live object search in REPO.
On each input string (minimum 2 chars) three `gh search' queries run in
parallel: pull requests, issues and commits.

Results are cached on disk per (REPO, type, query).  A cached result is
painted immediately; unless it is younger than `octocat-search-cache-ttl'
the query is also re-run, and the list is rebuilt as each response lands
\(fresh types replace their cached ones, pending types keep theirs).
Queries superseded by further typing are left to finish so that they
populate the cache.  The indicator shows `running' while any query for
the current input is in flight."
  (lambda (sink)
    (let ((current  nil)                              ; normalized current input
          (results nil)                               ; alist TYPE -> candidates
          (inflight (make-hash-table :test #'equal))  ; (TYPE . QUERY) -> process
          (specs (list (list "prs"     "number,title,state,author"
                             #'octocat--search-make-pr-candidate)
                       (list "issues"  "number,title,state,author"
                             #'octocat--search-make-issue-candidate)
                       (list "commits" "sha,commit,author"
                             #'octocat--search-make-commit-candidate))))
      (cl-labels
          ((candidates (spec items)
             (mapcar (lambda (item) (funcall (nth 2 spec) item repo)) items))
           ;; Replace the displayed list with RESULTS and update the indicator.
           (publish ()
             (funcall sink 'flush)
             (when-let* ((all (apply #'append
                                     (mapcar (lambda (s) (cdr (assoc (car s) results)))
                                             specs))))
               (funcall sink all))
             (funcall sink
                      (if (cl-some (lambda (s) (gethash (cons (car s) current) inflight))
                                   specs)
                          [indicator running]
                        [indicator finished])))
           ;; Run one gh search for SPEC; QUERY is the normalized cache key.
           (spawn (spec input query)
             (let* ((type (car spec))
                    (key  (cons type query))
                    (buf  (generate-new-buffer " *octocat-search-objects*")))
               (puthash
                key
                (make-process
                 :name            "octocat-search-objects"
                 :buffer          buf
                 :command         (list "gh" "search" type
                                        (format "--repo=%s" repo)
                                        "--json" (nth 1 spec)
                                        "--limit" "30"
                                        input)
                 :connection-type 'pipe
                 :noquery         t
                 :sentinel
                 (lambda (p event)
                   (unless (process-live-p p)
                     (remhash key inflight)
                     (let ((items
                            (and (string-prefix-p "finished" event)
                                 (condition-case nil
                                     (with-current-buffer buf
                                       (or (octocat--parse-json-list (buffer-string))
                                           'empty))
                                   (error nil)))))
                       (when (buffer-live-p buf)
                         (kill-buffer buf))
                       (when items
                         (let ((items (if (eq items 'empty) nil items)))
                           (octocat--search-objects-cache-save repo type query items)
                           (when (equal query current)
                             (setf (alist-get type results nil nil #'equal)
                                   (candidates spec items))))))
                     (when (equal query current)
                       (publish)))))
                inflight))))
        (lambda (action)
          (pcase action
            ;; New input: paint what the cache has, then refresh what is stale.
            ((pred stringp)
             (let ((query (downcase (string-trim action))))
               (setq current query
                     results nil)
               (dolist (spec specs)
                 (let* ((type   (car spec))
                        (cached (octocat--search-objects-cache-load repo type query))
                        (fresh  (and cached
                                     (> octocat-search-cache-ttl 0)
                                     (< (- (float-time) (car cached))
                                        octocat-search-cache-ttl))))
                   (when cached
                     (push (cons type (candidates spec (cdr cached))) results))
                   (unless (or fresh (gethash (cons type query) inflight))
                     (spawn spec action query))))
               (publish)))
            ;; Session ending: stop publishing but let searches fill the cache.
            ((or 'cancel 'destroy)
             (setq current nil)
             (funcall sink action))
            ;; All other consult actions: pass through unchanged.
            (_ (funcall sink action))))))))

(defun octocat-search-repo ()
  "Search for a PR, issue, or commit in the current repository.

Fires live `gh search' queries (PRs, issues, and commits in parallel)
against the repository associated with the current buffer.  Results
update as each query completes.  Selecting a candidate opens the
corresponding detail view.

The query is matched against titles, commit messages, and bodies.
Prefix a hash (e.g. \"a1b2c3\") to narrow to a specific commit."
  (interactive)
  (let ((repo (octocat--search-repo--current-repo)))
    (unless repo
      (user-error "Octocat: Cannot determine current repository"))
    (let* ((chosen (consult--read
                    (consult--async-pipeline
                     (consult--async-min-input 2)
                     (consult--async-throttle)
                     (octocat--async-search-repo-objects repo))
                    :prompt        (format "Search %s: " repo)
                    :category      'octocat-object
                    :sort          nil
                    ;; The default lookup returns the bare minibuffer text,
                    ;; dropping the `octocat-search-item' property.
                    :lookup        #'consult--lookup-member
                    :require-match t))
           (item (and chosen
                      (get-text-property 0 'octocat-search-item chosen))))
      (when item
        (octocat--search-open-item item)))))

(provide 'octocat-search)
;;; octocat-search.el ends here
