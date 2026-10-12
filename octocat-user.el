;;; octocat-user.el --- GitHub user / organization page for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; A page for a GitHub handle such as `@octocat': the profile (name, bio,
;; company, location, follower counts), the repositories it has pinned,
;; and its repositories, most recently pushed first.  Organizations work too, since the
;; `users/LOGIN' endpoints serve both.  RET on a repository opens its
;; octocat-repo page.
;;
;; Rendered with vui.el like the repo page: the profile and the repository
;; list are independent async sections.  The `M-x octocat-user' entry
;; point is defined in octocat.el (see CONTRIBUTING.md, "Entry points");
;; this file defines `octocat-user-mode' and everything it needs.

;;; Code:

(require 'octocat-avatar)
(require 'octocat-core)
(require 'octocat-repo)
(require 'octocat-vui)
(require 'subr-x)
(require 'vui)
(require 'vui-components)

(defcustom octocat-user-show-avatar t
  "Whether the user page draws the avatar as ASCII art beside the profile."
  :type 'boolean
  :group 'octocat)

(defcustom octocat-user-avatar-max-columns 40
  "Widest the avatar is drawn, in characters.
The avatar takes a quarter of the window's width up to this limit, so it
grows when the window does, and is left out of a window too narrow for
it.  It is half as many lines tall as it is wide."
  :type 'integer
  :group 'octocat)

(defcustom octocat-user-avatar-style nil
  "Characters the avatar is drawn with.
nil picks quadrant blocks, or plain 7-bit ASCII when Emacs cannot
display Unicode.  The others are `blocks' (quadrant blocks with
foreground and background colours), `ramp' (Unicode shade characters)
and `ascii'.  See `octocat-avatar-render'."
  :type '(choice (const :tag "Automatic" nil)
                 (const :tag "Quadrant blocks" blocks)
                 (const :tag "Unicode shade ramp" ramp)
                 (const :tag "7-bit ASCII" ascii))
  :group 'octocat)

(defconst octocat-user--avatar-pixels 128
  "Size, in pixels, of the avatar requested from GitHub.
Enough for `octocat-user-avatar-max-columns' at the default of 40.")

(defvar-local octocat-user--login nil
  "The GitHub login (without the leading \"@\") this buffer shows.")


;;;; Fetching

(defun octocat-user--normalize (input)
  "Return INPUT as a bare GitHub login, or nil when it is not one.
Surrounding whitespace and a leading \"@\" are dropped."
  (let ((login (string-trim-left (string-trim (or input "")) "@")))
    (and (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9-]*\\'" login)
         login)))

(defun octocat-user--parse-profile (json-string)
  "Parse the `users/LOGIN' response JSON-STRING into a hash-table."
  (json-parse-string json-string :null-object nil))

(defun octocat-user--fetch-profile (login callback)
  "Fetch the profile of LOGIN and call CALLBACK with a hash-table.
CALLBACK receives a cons (error . MSG) on failure."
  (octocat--run-gh "user-profile"
                   (list "api" (format "users/%s" login))
                   #'octocat-user--parse-profile
                   callback))

(defun octocat-user--fetch-repos (login limit callback)
  "Fetch the LIMIT most recently pushed repositories of LOGIN.
CALLBACK receives a list of hash-tables, or a cons (error . MSG).  The
limit is part of the URL so that `gh api' issues a GET."
  (octocat--run-gh "user-repos"
                   (list "api"
                         (format "users/%s/repos?sort=pushed&per_page=%d"
                                 login limit))
                   #'octocat--parse-json-list
                   callback))


(defconst octocat-user--pinned-query
  "query($login:String!){repositoryOwner(login:$login){... on ProfileOwner{pinnedItems(first:6,types:REPOSITORY){nodes{... on Repository{nameWithOwner description stargazerCount primaryLanguage{name} pushedAt isFork isArchived}}}}}}"
  "GraphQL query behind `octocat-user--fetch-pinned'.
The REST API does not expose pinned repositories.")

(defun octocat-user--parse-pinned (json-string)
  "Parse the GraphQL response JSON-STRING into a list of repository tables.
Each table carries the REST API's keys (`full_name', `description',
`language', `stargazers_count', `pushed_at', `fork', `archived'), so the
rows of the repository list render it as they do.  Pinned gists, which
come back as empty nodes, are left out."
  (let* ((data  (gethash "data" (json-parse-string json-string :null-object nil)))
         (owner (and data (gethash "repositoryOwner" data)))
         (items (and owner (gethash "pinnedItems" owner)))
         (nodes (and items (gethash "nodes" items)))
         repos)
    (seq-doseq (node nodes)
      (when-let* ((name (and node (gethash "nameWithOwner" node)))
                  (repo (make-hash-table :test #'equal)))
        (puthash "full_name" name repo)
        (puthash "description" (gethash "description" node) repo)
        (puthash "language" (let ((l (gethash "primaryLanguage" node)))
                              (and l (gethash "name" l)))
                 repo)
        (puthash "stargazers_count" (gethash "stargazerCount" node) repo)
        (puthash "pushed_at" (gethash "pushedAt" node) repo)
        (puthash "fork" (gethash "isFork" node) repo)
        (puthash "archived" (gethash "isArchived" node) repo)
        (push repo repos)))
    (nreverse repos)))

(defun octocat-user--fetch-pinned (login callback)
  "Fetch the repositories LOGIN has pinned and call CALLBACK with a list.
CALLBACK receives a cons (error . MSG) on failure."
  (octocat--run-gh "user-pinned"
                   (list "api" "graphql"
                         "-f" (concat "query=" octocat-user--pinned-query)
                         "-F" (concat "login=" login))
                   #'octocat-user--parse-pinned
                   callback))


;;;; Rendering

(defun octocat-user--count (n label)
  "Return \"N LABEL\" with N in the default face, or nil when N is absent."
  (and (integerp n)
       (concat (number-to-string n) " " (propertize label 'face 'octocat-dimmed))))

(defun octocat-user--profile-lines (profile)
  "Return the list of header strings describing PROFILE (a hash-table)."
  (let* ((login   (gethash "login" profile))
         (name    (octocat--nonempty (gethash "name" profile)))
         (bio     (octocat--nonempty (gethash "bio" profile)))
         (type    (gethash "type" profile))
         (details (delq nil
                        (mapcar #'octocat--nonempty
                                (list (gethash "company" profile)
                                      (gethash "location" profile)
                                      (gethash "blog" profile)))))
         (counts  (delq nil
                        (list (octocat-user--count (gethash "followers" profile) "followers")
                              (octocat-user--count (gethash "following" profile) "following")
                              (octocat-user--count (gethash "public_repos" profile)
                                                   "public repos")))))
    (delq nil
          (list
           (concat (propertize (concat "@" login) 'face 'octocat-repo)
                   (when name (concat "  " (propertize name 'face 'octocat-pr-author)))
                   (when (equal type "Organization")
                     (propertize "  (organization)" 'face 'octocat-dimmed)))
           bio
           (and details (mapconcat #'identity details "  ·  "))
           (and counts (mapconcat #'identity counts "  ·  "))))))

(defun octocat-user--avatar-columns (window-width)
  "Return how many columns the avatar gets in a window WINDOW-WIDTH wide.
Zero means too narrow to draw it."
  (let ((cols (min octocat-user-avatar-max-columns (/ window-width 4))))
    (if (< cols 12) 0 cols)))

(defun octocat-user--beside (avatar lines)
  "Return LINES, each placed to the right of the matching row of AVATAR.
AVATAR is a list of equally wide strings; the shorter list is padded."
  (let ((pad (make-string (string-width (car avatar)) ?\s)))
    (cl-loop for i below (max (length avatar) (length lines))
             collect (concat (or (nth i avatar) pad) "  " (or (nth i lines) "")))))

(defun octocat-user--repo-row (repo)
  "Return a RET-able row vnode for REPO, a repository hash-table."
  (let* ((full  (gethash "full_name" repo))
         (desc  (octocat--nonempty (gethash "description" repo)))
         (lang  (octocat--nonempty (gethash "language" repo)))
         (stars (gethash "stargazers_count" repo))
         (pushed (octocat--format-ts-relative (or (gethash "pushed_at" repo) "")))
         (flags (concat (and (eq (gethash "fork" repo) t) " fork")
                        (and (eq (gethash "archived" repo) t) " archived"))))
    (octocat-vui-row
     (concat "  "
             (propertize (or full "") 'face 'octocat-repo)
             (propertize flags 'face 'octocat-dimmed)
             (when desc (concat "  " (truncate-string-to-width desc 60 nil nil "…")))
             (propertize
              (concat (when lang (concat "  " lang))
                      (when (and (integerp stars) (> stars 0)) (format "  ★ %d" stars))
                      (unless (string-empty-p pushed) (concat "  " pushed)))
              'face 'octocat-dimmed))
     (lambda () (octocat-visit-repo full))
     "RET: open repository")))


;;;; Components

(vui-defcomponent octocat-user--repos-section (login)
  "Repositories of LOGIN, with its own \"load more\" limit."
  :state ((limit octocat-section-limit))
  :render
  (let* ((sticky (octocat-vui-use-async-sticky (list 'user-repos login limit)
                   (lambda (resolve reject)
                     (octocat-user--fetch-repos
                      login limit
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (loading (and (or (eq (plist-get sticky :status) 'pending)
                           (plist-get sticky :refreshing))
                       t)))
    (octocat-vui-use-mode-line-loading loading)
    (vui-vstack
     (vui-text "Repositories" :face 'octocat-section-heading)
     (pcase (plist-get sticky :status)
       ('pending (vui-text (concat "(" (octocat-vui-loading-text) ")") :face 'octocat-dimmed))
       ('error   (vui-text (format "%s" (plist-get sticky :error)) :face 'octocat-dimmed))
       ('ready
        (let ((repos (plist-get sticky :data)))
          (vui-fragment
           (if (null repos)
               (vui-text "(no public repositories)" :face 'octocat-dimmed)
             (octocat-vui-reveal-list repos #'octocat-user--repo-row
                                      (lambda (r) (gethash "full_name" r))))
           (when (and repos
                      (or (>= (length repos) limit)
                          ;; Keep the button in place while a further page
                          ;; loads, but not for the first paint.
                          (and (plist-get sticky :refreshing)
                               (> limit octocat-section-limit))))
             (octocat-vui-load-more-button
              'load-more-user-repos octocat-section-limit
              "RET: load more repositories"
              (lambda () (vui-set-state :limit (+ limit octocat-section-limit)))
              (plist-get sticky :refreshing) 2)))))))))

(vui-defcomponent octocat-user--pinned-section (login)
  "Pinned repositories of LOGIN, shown only when there are any.
Pinned repositories are decoration, so nothing is drawn while they load
or when the fetch fails."
  :render
  (let* ((result (vui-use-async (list 'user-pinned login)
                   (lambda (resolve reject)
                     (octocat-user--fetch-pinned
                      login
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (repos  (and (eq (plist-get result :status) 'ready)
                      (plist-get result :data))))
    (if (null repos)
        (vui-fragment)
      (vui-vstack
       (vui-text "Pinned" :face 'octocat-section-heading)
       (vui-list repos #'octocat-user--repo-row
                 (lambda (r) (gethash "full_name" r)))
       (vui-newline)))))

(vui-defcomponent octocat-user--header (profile)
  "Profile lines of PROFILE with its avatar drawn beside them in ASCII.
The image is fetched and decoded once; it is drawn again, cheaply, each
time the window's width changes."
  :state ((win-width nil))
  :render
  (let* ((width  (octocat-vui-use-window-width))
         (url    (and octocat-user-show-avatar
                      (octocat--nonempty (gethash "avatar_url" profile))))
         (result (vui-use-async (list 'user-avatar url)
                   (lambda (resolve reject)
                     (if (null url)
                         (funcall resolve nil)
                       (octocat-avatar-fetch
                        (concat url (if (string-search "?" url) "&" "?")
                                "s=" (number-to-string octocat-user--avatar-pixels))
                        (lambda (r)
                          (if (eq (car-safe r) 'error)
                              (funcall reject (cdr r))
                            (funcall resolve (octocat-avatar-decode r)))))))))
         (cols   (octocat-user--avatar-columns width))
         (image  (and (eq (plist-get result :status) 'ready)
                      (plist-get result :data)))
         (lines  (octocat-user--profile-lines profile))
         (art    (cond ((= cols 0) nil)
                       (image (octocat-avatar-render
                               image cols nil octocat-user-avatar-style))
                       ;; Keep the text where it will be while loading.
                       ((and url (eq (plist-get result :status) 'pending))
                        (list (make-string cols ?\s))))))
    (vui-vstack
     (mapcar (lambda (line) (vui-text line))
             (if art (octocat-user--beside art lines) lines)))))

(vui-defcomponent octocat-user--root (login)
  "Root component of the user page: profile header, then repositories."
  :render
  (let* ((result (vui-use-async (list 'user-profile login)
                   (lambda (resolve reject)
                     (octocat-user--fetch-profile
                      login
                      (lambda (r) (octocat-repo-vui--resolve-or-reject r resolve reject))))))
         (loading (eq (plist-get result :status) 'pending)))
    (octocat-vui-use-mode-line-loading loading)
    (vui-vstack
     (pcase (plist-get result :status)
       ('ready
        (let ((profile (plist-get result :data)))
          (if profile
              (vui-component 'octocat-user--header :profile profile)
            (vui-text (propertize (concat "@" login) 'face 'octocat-repo)))))
       ('error
        (vui-vstack
         (vui-text (propertize (concat "@" login) 'face 'octocat-repo))
         (vui-text (format "%s" (plist-get result :error)) :face 'octocat-dimmed)))
       (_ (vui-text (propertize (concat "@" login) 'face 'octocat-repo))))
     (vui-newline)
     (vui-component 'octocat-user--pinned-section :login login)
     (vui-component 'octocat-user--repos-section :login login))))


;;;; Major mode

(defun octocat-user-browse ()
  "Open the current user's or organization's GitHub page in a browser."
  (interactive)
  (unless octocat-user--login
    (user-error "Octocat: Buffer is not associated with a GitHub user"))
  (message "Octocat: Opening @%s in browser…" octocat-user--login)
  (browse-url (concat "https://github.com/" octocat-user--login)))

(defvar octocat-user-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-user-mode'.")
(define-key octocat-user-mode-map (kbd "q") #'quit-window)
(define-key octocat-user-mode-map (kbd "g") #'revert-buffer)
(define-key octocat-user-mode-map (kbd "C-c C-o") #'octocat-user-browse)
(define-key octocat-user-mode-map (kbd "C-c C-r") #'octocat-switch-repo)

(define-derived-mode octocat-user-mode vui-mode "Octocat-User"
  "Major mode for a GitHub user or organization page.

\\{octocat-user-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-user-refresh)
  (octocat--ts-eldoc-setup))

(defun octocat-user-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the current octocat-user buffer."
  (interactive)
  (unless octocat-user--login
    (user-error "Octocat: Buffer is not associated with a GitHub user"))
  (octocat-vui-preserving-view
    (vui-mount (vui-component 'octocat-user--root :login octocat-user--login)
               (buffer-name))))

(defun octocat-user-open (login)
  "Open (or switch to) the page of the GitHub user or organization LOGIN.
A leading \"@\" is accepted."
  (let ((login (or (octocat-user--normalize login)
                   (user-error "Octocat: `%s' is not a GitHub login" login))))
    (pop-to-buffer (get-buffer-create (format "*@%s*" login)))
    (unless (derived-mode-p 'octocat-user-mode)
      (octocat-user-mode))
    (setq octocat-user--login login)
    (octocat-user-refresh)))

;; NOTE: the `M-x octocat-user' entry point is defined in `octocat.el' --
;; see CONTRIBUTING.md, "Entry points".

(provide 'octocat-user)
;;; octocat-user.el ends here
