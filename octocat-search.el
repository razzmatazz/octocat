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
;; live `gh search' queries, through a consult async pipeline.  File paths
;; of the repository's default branch are matched too, locally, against a
;; file list fetched once and kept in memory.
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
(declare-function octocat-commit-open            "octocat-commit" (repo sha))
(declare-function octocat-tree--fetch-all-files  "octocat-tree"   (repo sha callback))
(declare-function octocat-tree--open-file-by-path "octocat-tree"  (repo branch path sha))



;;;; Candidates

(defun octocat--search-make-pr-candidate (pr repo)
  "Return a propertized candidate string for PR hash-table in REPO."
  (let* ((number (gethash "number" pr))
         (title  (or (octocat--nonempty (gethash "title" pr)) ""))
         (state  (or (octocat--nonempty (gethash "state" pr)) "OPEN"))
         (author (octocat--author-login pr))
         (state-face (pcase state
                       ("MERGED" 'octocat-pr-state-merged)
                       ("CLOSED" 'octocat-pr-state-closed)
                       (_        'octocat-pr-state-open)))
         (display
          (format "%-8s #%-5d  %-42s  %s  %s"
                  (propertize "[PR]" 'face 'octocat-section-heading)
                  number
                  (octocat--format-title title)
                  (propertize (format "(%s)" state) 'face state-face)
                  (propertize author 'face 'octocat-pr-author)))
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
         (state-face (if (equal state "OPEN")
                         'octocat-pr-state-open
                       'octocat-pr-state-closed))
         (display
          (format "%-8s #%-5d  %-42s  %s  %s"
                  (propertize "[Issue]" 'face 'octocat-section-heading)
                  number
                  (octocat--format-title title)
                  (propertize (format "(%s)" state) 'face state-face)
                  (propertize author 'face 'octocat-pr-author)))
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
                  (propertize "[Commit]" 'face 'octocat-section-heading)
                  (propertize short 'face 'octocat-commit-sha)
                  (octocat--format-title subject)
                  (propertize author 'face 'octocat-pr-author)))
         (cand (copy-sequence display)))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'commit :repo repo :sha sha)
                       cand)
    cand))

(defun octocat--search-make-file-candidate (file repo)
  "Return a propertized candidate string for FILE in REPO.
FILE is a (PATH . BLOB-SHA) cons."
  (let* ((path (car file))
         (cand (copy-sequence
                (format "%-8s %s"
                        (propertize "[File]" 'face 'octocat-section-heading)
                        path))))
    (put-text-property 0 1 'octocat-search-item
                       (list :type 'file :repo repo :path path :sha (cdr file))
                       cand)
    cand))

(defun octocat--search-open-item (item)
  "Open the octocat buffer described by ITEM, a plist from `octocat-search-item'."
  (let ((type (plist-get item :type))
        (repo (plist-get item :repo)))
    (pcase type
      ('file
       (octocat-tree--open-file-by-path
        repo "HEAD" (plist-get item :path) (plist-get item :sha)))
      ('pr
       (octocat-pr-open repo (plist-get item :number)))
      ('issue
       (octocat-issue-open repo (plist-get item :number)))
      ('commit
       (octocat-commit-open repo (plist-get item :sha))))))


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


;;;; Repository file list

(defconst octocat--search-files-ttl 600
  "Seconds an in-memory repository file list is reused by the search.")

(defconst octocat--search-files-limit 30
  "Maximum number of file candidates shown for one query.")

(defvar octocat--search-files-cache (make-hash-table :test #'equal)
  "Map from \"owner/name\" to (TIMESTAMP . ((PATH . BLOB-SHA) ...)).")

(defun octocat--search-files-cached (repo)
  "Return the fresh cached file list of REPO, or nil."
  (when-let* ((entry (gethash repo octocat--search-files-cache)))
    (when (< (- (float-time) (car entry)) octocat--search-files-ttl)
      (cdr entry))))

(defun octocat--search-files-match (files query)
  "Return the entries of FILES with every word of QUERY in their path.
Matching is case-insensitive; shorter paths sort first."
  (let ((words (split-string (downcase query) "[ \t]+" t))
        matches)
    (when words
      (dolist (file files)
        (let ((path (downcase (car file))))
          (when (cl-every (lambda (w) (string-search w path)) words)
            (push file matches))))
      (setq matches (sort matches (lambda (a b) (< (length (car a)) (length (car b))))))
      (seq-take matches octocat--search-files-limit))))


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
          (files-loading nil)                         ; file list fetch in flight
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
                                     (mapcar (lambda (type) (cdr (assoc type results)))
                                             (append (mapcar #'car specs)
                                                     (list "files"))))))
               (funcall sink all))
             (funcall sink
                      (if (or files-loading
                              (cl-some (lambda (s) (gethash (cons (car s) current) inflight))
                                       specs))
                          [indicator running]
                        [indicator finished])))
           ;; Show the files of the cached list matching the current input.
           (match-files ()
             (when-let* ((files (octocat--search-files-cached repo)))
               (setf (alist-get "files" results nil nil #'equal)
                     (mapcar (lambda (f) (octocat--search-make-file-candidate f repo))
                             (octocat--search-files-match files current)))))
           ;; Fetch the repository file list once; it is matched locally.
           (load-files ()
             (unless (or files-loading (octocat--search-files-cached repo))
               (setq files-loading t)
               (octocat-tree--fetch-all-files
                repo "HEAD"
                (lambda (result)
                  (setq files-loading nil)
                  (unless (eq (car-safe result) 'error)
                    (puthash repo (cons (float-time) result)
                             octocat--search-files-cache)
                    (when current
                      (match-files)))
                  (when current
                    (publish))))))
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
               (match-files)
               (load-files)
               (publish)))
            ;; Session ending: stop publishing but let searches fill the cache.
            ((or 'cancel 'destroy)
             (setq current nil)
             (funcall sink action))
            ;; All other consult actions: pass through unchanged.
            (_ (funcall sink action))))))))

(defun octocat-search-repo ()
  "Search for a PR, issue, commit, or file in the current repository.

Fires live `gh search' queries (PRs, issues, and commits in parallel)
against the repository associated with the current buffer.  Results
update as each query completes.  File paths containing every word of
the query are listed too.  Selecting a candidate opens the
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
