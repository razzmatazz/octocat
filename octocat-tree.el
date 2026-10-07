;;; octocat-tree.el --- File tree and file log browser for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Three modes for browsing a repository's files:
;;
;;   octocat-tree-mode     — interactive tree browser; dirs expand on demand
;;   octocat-file-mode     — read-only file content viewer with syntax highlighting
;;   octocat-file-log-mode — commit log for a single file (git log -- <path>)
;;
;; Entry points:
;;   `octocat-tree-open'     — open the tree browser (bound to T in repo mode)
;;   `octocat-file-log-open' — open the file commit log (C-c C-l in file mode)
;;
;; octocat-file-mode derives from `special-mode'.
;; octocat-file-log-mode derives from `magit-section-mode' and renders
;; one magit-section per commit so RET can navigate to the commit detail view.
;; octocat-tree-mode derives from `vui-mode' and is rendered with vui.el:
;; `octocat-tree--dir' (lazy, cached child fetch) and `octocat-tree--node'
;; (one line; directories own their expanded state) recurse from
;; `octocat-tree--root'.  Each line carries text properties so commands
;; work regardless of keymap precedence (e.g. under Evil):
;;
;;   octocat-tree--type      \\='dir | \\='file  — kind of entry
;;   octocat-tree--entry     <hash-table>    — the GitHub API entry object
;;   octocat-tree--activate  <function>      — what RET does on the line

;;; Code:

(require 'cl-lib)
(require 'octocat-core)
(require 'vui)
(require 'vui-components)

;; octocat-repo buffer-locals accessed from octocat-tree-open.
(defvar octocat-repo--repo)
(defvar octocat-repo--current-branch)
(defvar octocat-repo--default-branch)

;; octocat-visit and octocat-browse are defined in octocat.el and bound in
;; octocat-file-log-mode-map.  Declare them here so the byte-compiler does not warn.
(declare-function octocat-visit  "octocat" ())
(declare-function octocat-browse "octocat" ())


;;;; Buffer-local variables — tree mode

(defvar-local octocat-tree--repo nil
  "The \"owner/repo\" string for the tree browser buffer.")

(defvar-local octocat-tree--branch nil
  "Branch/ref name currently being browsed.")

(defvar-local octocat-tree--root-sha nil
  "SHA of the root git tree object for the current branch.")

(defvar-local octocat-tree--subtree-cache nil
  "Alist mapping directory SHA string to fetched entries vector.
Populated when a directory's children are fetched; consulted by
`octocat-tree--dir' so collapsing and re-expanding a directory does not
refetch it.  Cleared on full refresh (gr).  Expanded/collapsed state is
not kept here: it lives in each `octocat-tree--node' as vui state.")

(defvar-local octocat-tree--all-files nil
  "Cached result of the recursive tree fetch used by `octocat-tree-find-file'.
An alist mapping file path strings to their blob SHA strings.
Populated on first call and reused until `octocat-tree-refresh' clears it.")


;;;; Buffer-local variables — file mode

(defvar-local octocat-tree--file-repo nil
  "The \"owner/repo\" string for the file viewer buffer.")

(defvar-local octocat-tree--file-path nil
  "Relative file path being displayed in the file viewer buffer.")

(defvar-local octocat-tree--file-sha nil
  "Blob SHA for the file being displayed, or nil when unknown.")

(defvar-local octocat-tree--file-branch nil
  "Branch/ref name for the file being displayed.")


;;;; Mode: octocat-tree-mode

(defvar octocat-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-tree-mode'.")
(define-key octocat-tree-mode-map (kbd "RET")     #'octocat-tree-visit)
(define-key octocat-tree-mode-map (kbd "TAB")     #'octocat-tree-expand)
(define-key octocat-tree-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)
(define-key octocat-tree-mode-map (kbd "q")       #'quit-window)
(define-key octocat-tree-mode-map (kbd "C-c C-o") #'octocat-tree-browse)
(define-key octocat-tree-mode-map (kbd "o")       #'octocat-tree-browse)
(define-key octocat-tree-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-tree-mode-map (kbd "C-c C-s") #'octocat-search-repo)
(define-key octocat-tree-mode-map (kbd "gr")      #'octocat-tree-refresh)

(define-derived-mode octocat-tree-mode vui-mode "Octocat-Tree"
  "Major mode for browsing a GitHub repository file tree.
The buffer is rendered by vui.el; see `octocat-tree--root'.

\\{octocat-tree-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-tree-refresh))


;;;; Mode: octocat-file-mode

(defvar octocat-file-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap for `octocat-file-mode'.")
(define-key octocat-file-mode-map (kbd "C-c C-o") #'octocat-file-browse)
(define-key octocat-file-mode-map (kbd "o")       #'octocat-file-browse)
(define-key octocat-file-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)
(define-key octocat-file-mode-map (kbd "C-c C-l") #'octocat-file-log-open)
(define-key octocat-file-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-file-mode-map (kbd "C-c C-s") #'octocat-search-repo)
(define-key octocat-file-mode-map (kbd "gr")      #'octocat-file-refresh)

(define-derived-mode octocat-file-mode special-mode "Octocat-File"
  "Major mode for viewing a GitHub file with syntax highlighting.

\\{octocat-file-mode-map}"
  :group 'octocat
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-file-refresh))


;;;; Buffer-local variables — file log mode

(defvar-local octocat-file-log--repo nil
  "The \"owner/repo\" string for the file log buffer.")

(defvar-local octocat-file-log--path nil
  "Relative file path whose commit history is being shown.")

(defvar-local octocat-file-log--branch nil
  "Branch/ref name for the file log buffer.")


;;;; Mode: octocat-file-log-mode

(defvar octocat-file-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `octocat-file-log-mode'.")
(define-key octocat-file-log-mode-map (kbd "q")       #'quit-window)
(define-key octocat-file-log-mode-map (kbd "RET")     #'octocat-visit)
(define-key octocat-file-log-mode-map (kbd "C-c C-o") #'octocat-browse)
(define-key octocat-file-log-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-file-log-mode-map (kbd "C-c C-s") #'octocat-search-repo)
(define-key octocat-file-log-mode-map (kbd "gr")      #'octocat-file-log-refresh)

(define-derived-mode octocat-file-log-mode magit-section-mode "Octocat-File-Log"
  "Major mode for browsing the commit history of a single file.

\\{octocat-file-log-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-file-log-refresh)
  (font-lock-mode -1))


;;;; Branch glyph helper

(defun octocat-tree--branch-glyph ()
  "Return a branch indicator glyph: ⎇ when displayable, else @."
  (if (char-displayable-p ?⎇) "⎇" "@"))


;;;; API fetch helpers

(defun octocat-tree--fetch-root-sha (repo branch callback)
  "Fetch the root git tree SHA for REPO on BRANCH asynchronously.
Calls CALLBACK with a SHA string, or a cons (error . MSG)."
  (octocat--run-gh
   "tree-root-sha"
   (list "api"
         (format "repos/%s/branches/%s" repo branch)
         "--jq" ".commit.commit.tree.sha")
   (lambda (output)
     (let ((s (string-trim output)))
       (if (string-empty-p s)
           (error "Empty tree SHA in branch response")
         s)))
   callback))

(defun octocat-tree--fetch-dir (repo sha callback)
  "Fetch the children of directory with SHA in REPO asynchronously.
Calls CALLBACK with a vector of entry hash-tables, or a cons (error . MSG)."
  (octocat--run-gh
   (format "tree-dir-%s" (substring sha 0 (min 8 (length sha))))
   (list "api"
         (format "repos/%s/git/trees/%s" repo sha))
   (lambda (output)
     (let* ((data  (json-parse-string output))
            (tree  (gethash "tree" data)))
       (if (vectorp tree)
           tree
         (error "Unexpected tree response format"))))
   callback))

(defun octocat-tree--fetch-all-files (repo sha callback)
  "Fetch the full recursive file list for REPO rooted at tree SHA.
Calls CALLBACK with an alist of (PATH . BLOB-SHA) pairs for every blob
in the tree, or a cons (error . MSG) on failure."
  (octocat--run-gh
   "tree-all-files"
   (list "api"
         (format "repos/%s/git/trees/%s?recursive=1" repo sha))
   (lambda (output)
     (let* ((data  (json-parse-string output))
            (tree  (gethash "tree" data)))
       (if (vectorp tree)
           (let (result)
             (seq-doseq (entry tree)
               (when (equal (gethash "type" entry) "blob")
                 (push (cons (gethash "path" entry)
                             (gethash "sha"  entry))
                       result)))
             (nreverse result))
         (error "Unexpected tree response format"))))
   callback))

(defun octocat-tree--fetch-file (repo sha callback)
  "Fetch the content of blob SHA in REPO asynchronously.
CALLBACK is called with decoded file content string, or a cons (error . MSG)."
  (octocat--run-gh
   (format "tree-blob-%s" (substring sha 0 (min 8 (length sha))))
   (list "api"
         (format "repos/%s/git/blobs/%s" repo sha)
         "--jq" ".content")
   (lambda (output)
     (let ((b64 (string-trim output)))
       ;; GitHub wraps lines at 60 chars; strip newlines before decoding.
       (base64-decode-string (replace-regexp-in-string "\n" "" b64))))
   callback))


;;;; Syntax highlighting

(defun octocat-tree--fontify (path content)
  "Return CONTENT string with face properties from the appropriate major mode.
PATH is used only to select the mode via `auto-mode-alist'."
  (with-temp-buffer
    (insert content)
    (let ((buffer-file-name path))
      (delay-mode-hooks (set-auto-mode)))
    (ignore-errors (font-lock-ensure))
    (buffer-string)))


;;;; Rendering helpers

(defun octocat-tree--entry-line (indent glyph name face type entry path activate)
  "Return one tree line (a propertized string, no trailing newline).
INDENT is a string of leading spaces.  GLYPH is a 1-2 char icon.
NAME is the file/dir name.  FACE is applied to the icon+name.
TYPE is \\='dir or \\='file.  ENTRY is the API hash-table.  PATH is the
entry's full repository path: the API's own \"path\" field is only the
name within its directory, so it is wrong below the root.  ACTIVATE is a
zero-argument function run by RET (`octocat-tree-visit') on the line;
for a directory it is also what TAB (`octocat-tree-expand') runs.

The type/entry/path/activate/mouse-face/help-echo properties span the entire
line including the indent, so `get-text-property' at
`line-beginning-position' works regardless of nesting depth.  Commands
read them rather than relying on a keymap, so they keep working under
Evil, whose state keymaps outrank text-property keymaps."
  (let* ((label (propertize (concat glyph " " name) 'face face))
         (line  (concat indent label))
         (help  (if (eq type 'dir)
                    "RET/TAB: expand  o: browse on GitHub"
                  "RET: view file  o: browse on GitHub")))
    (add-text-properties 0 (length line)
                         (list 'octocat-tree--type     type
                               'octocat-tree--entry    entry
                               'octocat-tree--path     path
                               'octocat-tree--activate activate
                               'mouse-face             'highlight
                               'help-echo              help)
                         line)
    line))


;;;; Rendering — tree mode

(defun octocat-tree--header-line (repo branch &optional browse-token)
  "Return the tree header line for REPO on BRANCH (no trailing newline).
With BROWSE-TOKEN, append the dimmed \"[Browse files]\" token."
  (propertize
   (concat
    (propertize (or repo "") 'face 'octocat-repo)
    "  "
    (octocat-tree--branch-glyph)
    "  "
    (propertize (or branch "") 'face 'octocat-branch)
    (when browse-token
      (concat "  "
              (propertize "[Browse files]"
                          'face            'octocat-dimmed
                          'mouse-face      'highlight
                          'help-echo       "RET: browse file tree"
                          'octocat-action  'browse-files))))
   'octocat-tree--type 'header))

(vui-defcomponent octocat-tree--message (repo branch text face)
  "Header plus a single TEXT line in FACE (used for loading and errors)."
  :render
  (vui-vstack
   (vui-text (octocat-tree--header-line repo branch))
   (vui-text (propertize (concat "  " text) 'face face))))

(defun octocat-tree--render-loading ()
  "Render a loading skeleton in the current tree buffer."
  (vui-mount (vui-component 'octocat-tree--message
                            :repo octocat-tree--repo
                            :branch octocat-tree--branch
                            :text "Loading…"
                            :face 'octocat-dimmed)
             (buffer-name)))

(defun octocat-tree--sorted-entries (entries)
  "Return ENTRIES (a vector) as a list sorted dirs-first then alphabetically."
  (cl-sort (cl-coerce entries 'list)
           (lambda (a b)
             (let ((ta (gethash "type" a ""))
                   (tb (gethash "type" b "")))
               (cond
                ((and (equal ta "tree") (equal tb "blob")) t)
                ((and (equal ta "blob") (equal tb "tree")) nil)
                (t (string< (gethash "path" a "")
                            (gethash "path" b ""))))))))

;; The tree is a recursion of two components:
;;
;;   `octocat-tree--dir'   fetches (or reads from the buffer-local
;;                         `octocat-tree--subtree-cache') the children of
;;                         one directory SHA and lists them as nodes.
;;   `octocat-tree--node'  one entry's line; a directory node owns its
;;                         expanded/collapsed state and, when expanded,
;;                         nests another `octocat-tree--dir'.
;;
;; Lines carry no trailing newline: `vui-list' separates siblings, and a
;; node's children follow it after one `vui-newline'.

(vui-defcomponent octocat-tree--dir (repo branch sha depth path)
  "Children of the directory with tree SHA, at nesting DEPTH.
PATH is this directory's full repository path (\"\" for the root)."
  :render
  (let* ((buf    (current-buffer))
         (indent (make-string (* depth 2) ?\s))
         (result (vui-use-async (list 'dir repo sha)
                   (lambda (resolve reject)
                     (let ((cached (cdr (assoc sha (buffer-local-value
                                                    'octocat-tree--subtree-cache buf)))))
                       (if cached
                           (funcall resolve cached)
                         (octocat-tree--fetch-dir
                          repo sha
                          (lambda (r)
                            (if (eq (car-safe r) 'error)
                                (funcall reject (cdr r))
                              (when (buffer-live-p buf)
                                (with-current-buffer buf
                                  (push (cons sha r) octocat-tree--subtree-cache)))
                              (funcall resolve r))))))))))
    (pcase (plist-get result :status)
      ('error
       (vui-text (propertize (format "%s  Error: %s" indent (plist-get result :error))
                             'face 'error)))
      ('ready
       (let ((entries (octocat-tree--sorted-entries (plist-get result :data))))
         (if (null entries)
             (vui-text (propertize (concat indent "  (empty)") 'face 'octocat-dimmed))
           (vui-list entries
                     (lambda (entry)
                       (vui-component 'octocat-tree--node
                                      :repo repo :branch branch
                                      :entry entry :depth depth :parent path))
                     (lambda (entry) (gethash "sha" entry))))))
      (_
       ;; Same indent as the entries that will replace it.
       (vui-text (propertize (concat indent "  "
                                     (propertize "Loading…" 'face 'octocat-dimmed))
                             'octocat-tree--type 'loading))))))

(vui-defcomponent octocat-tree--node (repo branch entry depth parent)
  "One tree ENTRY (hash-table) at nesting DEPTH, inside directory PARENT.
PARENT is the containing directory's full path (\"\" at the root)."
  :state ((expanded nil))
  :render
  (let* ((name   (or (gethash "path" entry) ""))
         (path   (if (string-empty-p parent) name (concat parent "/" name)))
         (type   (or (gethash "type" entry) ""))
         (sha    (or (gethash "sha"  entry) ""))
         (indent (make-string (* depth 2) ?\s)))
    (if (equal type "tree")
        (let* ((toggle (vui-with-async-context
                         (vui-set-state :expanded (lambda (old) (not old)))))
               (line   (octocat-tree--entry-line
                        indent (if expanded "▾" "▸") (concat name "/")
                        'octocat-branch 'dir entry path toggle)))
          (vui-fragment
           (vui-text line)
           (when expanded
             (vui-fragment
              (vui-newline)
              (vui-component 'octocat-tree--dir
                             :repo repo :branch branch
                             :sha sha :depth (1+ depth) :path path)))))
      ;; Blob — leaf node.  Single-space glyph matches the width of "▸"/"▾"
      ;; so that file names align with directory names at the same depth.
      (vui-text (octocat-tree--entry-line
                 indent " " name 'default 'file entry path
                 (lambda ()
                   (octocat-tree--open-file-by-path
                    repo branch path sha)))))))

(vui-defcomponent octocat-tree--root (repo branch root-sha)
  "Root component of the tree buffer: header, then the root directory."
  :render
  (vui-vstack
   (vui-text (octocat-tree--header-line repo branch t))
   (vui-component 'octocat-tree--dir
                  :repo repo :branch branch :sha root-sha :depth 0 :path "")))


;;;; Rendering — file mode

(defun octocat-tree--render-file-loading (path)
  "Render a loading skeleton for file PATH in the current file buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (or octocat-tree--file-repo "") 'face 'octocat-repo)
            "  "
            (octocat-tree--branch-glyph)
            "  "
            (propertize (or octocat-tree--file-branch "") 'face 'octocat-branch)
            "  "
            (or path "")
            "\n"
            (propertize (make-string 60 ?━) 'face 'octocat-dimmed)
            "\n"
            (propertize "  Loading…\n" 'face 'octocat-dimmed))))

(defun octocat-tree--render-file (path content)
  "Render file PATH with fontified CONTENT in the current file buffer."
  (let* ((inhibit-read-only t)
         (fontified (octocat-tree--fontify path content)))
    (erase-buffer)
    (insert (propertize (or octocat-tree--file-repo "") 'face 'octocat-repo)
            "  "
            (octocat-tree--branch-glyph)
            "  "
            (propertize (or octocat-tree--file-branch "") 'face 'octocat-branch)
            "  "
            (or path "")
            "\n"
            (propertize (make-string 60 ?━) 'face 'octocat-dimmed)
            "\n"
            fontified)
    (goto-char (point-min))))


;;;; Point navigation helpers

(defun octocat-tree--type-at-point ()
  "Return the \\='octocat-tree--type symbol on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-tree--type))

(defun octocat-tree--path-at-point ()
  "Return the full repository path of the entry on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-tree--path))

(defun octocat-tree--activate-at-point ()
  "Return the RET action closure stored on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-tree--activate))


;;;; Interactive commands — tree mode

(defun octocat-tree-open ()
  "Open the file tree browser for the current octocat-repo buffer."
  (interactive)
  (unless (derived-mode-p 'octocat-repo-mode)
    (user-error "Octocat: Not in an octocat-repo buffer"))
  (let* ((repo   octocat-repo--repo)
         (branch (or (and (boundp 'octocat-repo--current-branch)
                          octocat-repo--current-branch)
                     (and (boundp 'octocat-repo--default-branch)
                          octocat-repo--default-branch)
                     "HEAD"))
         (buf-name (format "*octocat-tree: %s*" repo))
         (buf      (get-buffer-create buf-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-tree-mode)
      (octocat-tree-mode))
    (setq octocat-tree--repo   repo
          octocat-tree--branch branch)
    (octocat-tree--render-loading)
    (octocat-tree-refresh)))

(defun octocat-tree-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the tree buffer from the GitHub API.
Clears the subtree cache and re-fetches the root tree."
  (interactive)
  (unless octocat-tree--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (setq octocat-tree--subtree-cache nil
        octocat-tree--all-files     nil)
  (let ((buf    (current-buffer))
        (repo   octocat-tree--repo)
        (branch octocat-tree--branch))
    (setq mode-line-process " [refreshing…]")
    (octocat-tree--fetch-root-sha
     repo branch
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq mode-line-process nil)
           (if (eq (car-safe result) 'error)
               (vui-mount (vui-component 'octocat-tree--message
                                         :repo repo :branch branch
                                         :text (format "Error: %s" (cdr result))
                                         :face 'error)
                          (buffer-name))
             ;; The root directory is itself the tree with this SHA, so
             ;; `octocat-tree--dir' fetches the root entries; everything
             ;; below it is fetched lazily as directories are expanded.
             (setq octocat-tree--root-sha result)
             (vui-mount (vui-component 'octocat-tree--root
                                       :repo repo :branch branch
                                       :root-sha result)
                        (buffer-name)))))))))

(defun octocat-tree-expand ()
  "Toggle expansion of the directory entry at point.
The directory's expanded state lives in its `octocat-tree--node'
component; the line carries a closure (the `octocat-tree--activate'
property) that flips it.  Children are fetched on first expansion and
come from `octocat-tree--subtree-cache' afterwards."
  (interactive)
  (unless (eq (octocat-tree--type-at-point) 'dir)
    (user-error "Octocat: No directory at point"))
  (funcall (octocat-tree--activate-at-point)))

(defun octocat-tree-visit ()
  "Open the file at point in `octocat-file-mode', or toggle a directory."
  (interactive)
  ;; Header line may carry an octocat-action property for the Browse-files token.
  (unless (eq (get-text-property (point) 'octocat-action) 'browse-files)
    ;; no-op on the header; browser shortcut is on o/C-c C-o
    (when-let* ((activate (octocat-tree--activate-at-point)))
      (funcall activate))))

(defun octocat-tree--open-file-by-path (repo branch path sha)
  "Open the file viewer buffer for PATH (blob SHA) in REPO on BRANCH."
  (let* ((buf-name (format "*octocat-file: %s %s*" repo path))
         (buf      (get-buffer-create buf-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-file-mode)
      (octocat-file-mode))
    (setq octocat-tree--file-repo   repo
          octocat-tree--file-path   path
          octocat-tree--file-sha    sha
          octocat-tree--file-branch branch)
    (octocat-tree--render-file-loading path)
    (octocat-file-refresh)))

(defun octocat-tree--do-find-file (repo branch root-sha)
  "Fetch the recursive file list for REPO/BRANCH (root SHA ROOT-SHA).
Uses `completing-read' to let the user pick a file, then opens it."
  (let ((buf (current-buffer)))
    (if octocat-tree--all-files
        ;; Already cached — jump straight to completing-read.
        (let* ((path (completing-read "Find file: " octocat-tree--all-files nil t))
               (sha  (cdr (assoc path octocat-tree--all-files))))
          (octocat-tree--open-file-by-path repo branch path sha))
      ;; Not yet cached — fetch, cache, then prompt.
      (setq mode-line-process " [loading…]")
      (octocat-tree--fetch-all-files
       repo root-sha
       (lambda (result)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq mode-line-process nil)
             (if (eq (car-safe result) 'error)
                 (message "Octocat: Error loading file list: %s" (cdr result))
               (setq octocat-tree--all-files result)
               (let* ((path (completing-read "Find file: " result nil t))
                      (sha  (cdr (assoc path result))))
                 (octocat-tree--open-file-by-path repo branch path sha))))))))))

(defun octocat-tree-find-file ()
  "Interactively find and open a file in this repository by path.
Fetches the full recursive file tree (cached after first call), presents
all file paths via `completing-read', and opens the selected file in
`octocat-file-mode'.  Works from both `octocat-tree-mode' and
`octocat-repo-mode' buffers."
  (interactive)
  (cond
   ((derived-mode-p 'octocat-tree-mode)
    (unless octocat-tree--repo
      (user-error "Octocat: Buffer is not associated with a repository"))
    (unless octocat-tree--root-sha
      (user-error "Octocat: Tree root SHA not yet loaded; wait for refresh to finish"))
    (octocat-tree--do-find-file octocat-tree--repo
                                octocat-tree--branch
                                octocat-tree--root-sha))
   ((derived-mode-p 'octocat-repo-mode)
    (unless octocat-repo--repo
      (user-error "Octocat: Buffer is not associated with a repository"))
    ;; Repo buffers don't keep a root SHA — open (or reuse) the tree buffer
    ;; so we can delegate to its cache.  octocat-tree-open switches to the
    ;; buffer and runs a refresh if needed, so root-sha will be set.
    (let* ((repo   octocat-repo--repo)
           (branch (or octocat-repo--current-branch
                       (and (boundp 'octocat-repo--default-branch)
                            octocat-repo--default-branch)
                       "HEAD"))
           (buf-name (format "*octocat-tree: %s*" repo))
           (tree-buf (get-buffer buf-name)))
      (if (and tree-buf
               (buffer-local-value 'octocat-tree--root-sha tree-buf))
          ;; Tree buffer already has a loaded root SHA — use its cache.
          (with-current-buffer tree-buf
            (octocat-tree--do-find-file repo branch octocat-tree--root-sha))
        ;; No tree buffer yet (or root not loaded).  Fetch the root SHA
        ;; fresh without opening the tree browser.
        (setq mode-line-process " [loading…]")
        (let ((repo-buf (current-buffer)))
          (octocat-tree--fetch-root-sha
           repo branch
           (lambda (sha-result)
             (when (buffer-live-p repo-buf)
               (with-current-buffer repo-buf
                 (setq mode-line-process nil)
                 (if (eq (car-safe sha-result) 'error)
                     (message "Octocat: Error fetching tree root: %s"
                              (cdr sha-result))
                   ;; Now fetch all files; we don't have a tree buffer to
                   ;; cache in, so just fetch+prompt directly.
                   (setq mode-line-process " [loading…]")
                   (octocat-tree--fetch-all-files
                    repo sha-result
                    (lambda (files-result)
                      (when (buffer-live-p repo-buf)
                        (with-current-buffer repo-buf
                          (setq mode-line-process nil)
                          (if (eq (car-safe files-result) 'error)
                              (message "Octocat: Error loading file list: %s"
                                       (cdr files-result))
                            (let* ((path (completing-read "Find file: "
                                                          files-result nil t))
                                   (sha  (cdr (assoc path files-result))))
                              (octocat-tree--open-file-by-path
                               repo branch path sha))))))))))))))))
   ((derived-mode-p 'octocat-file-mode)
    (unless octocat-tree--file-repo
      (user-error "Octocat: Buffer is not associated with a file"))
    ;; File buffers don't keep a root SHA.  Reuse an existing tree buffer's
    ;; cache when available; otherwise fetch the root SHA fresh.
    (let* ((repo     octocat-tree--file-repo)
           (branch   octocat-tree--file-branch)
           (buf-name (format "*octocat-tree: %s*" repo))
           (tree-buf (get-buffer buf-name)))
      (if (and tree-buf
               (buffer-local-value 'octocat-tree--root-sha tree-buf))
          ;; Tree buffer already has a loaded root SHA — use its cache.
          (with-current-buffer tree-buf
            (octocat-tree--do-find-file repo branch octocat-tree--root-sha))
        ;; No tree buffer yet (or root not loaded).  Fetch the root SHA
        ;; fresh without opening the tree browser.
        (setq mode-line-process " [loading…]")
        (let ((file-buf (current-buffer)))
          (octocat-tree--fetch-root-sha
           repo branch
           (lambda (sha-result)
             (when (buffer-live-p file-buf)
               (with-current-buffer file-buf
                 (setq mode-line-process nil)
                 (if (eq (car-safe sha-result) 'error)
                     (message "Octocat: Error fetching tree root: %s"
                              (cdr sha-result))
                   (setq mode-line-process " [loading…]")
                   (octocat-tree--fetch-all-files
                    repo sha-result
                    (lambda (files-result)
                      (when (buffer-live-p file-buf)
                        (with-current-buffer file-buf
                          (setq mode-line-process nil)
                          (if (eq (car-safe files-result) 'error)
                              (message "Octocat: Error loading file list: %s"
                                       (cdr files-result))
                            (let* ((path (completing-read "Find file: "
                                                          files-result nil t))
                                   (sha  (cdr (assoc path files-result))))
                              (octocat-tree--open-file-by-path
                               repo branch path sha))))))))))))))))
   (t
    (user-error "Octocat: Not in a repo or tree buffer"))))

(defun octocat-tree-browse ()
  "Open the current tree entry on GitHub in the browser."
  (interactive)
  (let* ((repo   octocat-tree--repo)
         (branch octocat-tree--branch)
         (type   (octocat-tree--type-at-point))
         (path   (octocat-tree--path-at-point)))
    (unless (and repo branch)
      (user-error "Octocat: Buffer has no repo or branch context"))
    (pcase type
      ('file
       (let ((url (format "https://github.com/%s/blob/%s/%s"
                          repo branch path)))
         (message "Octocat: Opening %s in browser…" path)
         (browse-url url)))
      ('dir
       (let ((url (format "https://github.com/%s/tree/%s/%s"
                            repo branch path)))
         (message "Octocat: Opening %s/ in browser…" path)
         (browse-url url)))
      (_
       (let ((url (format "https://github.com/%s/tree/%s" repo branch)))
         (message "Octocat: Opening %s tree in browser…" repo)
         (browse-url url))))))


;;;; Interactive commands — file mode

(defun octocat-file-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the file viewer buffer by re-fetching the blob content."
  (interactive)
  (unless (and octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (let ((buf    (current-buffer))
        (repo   octocat-tree--file-repo)
        (sha    octocat-tree--file-sha)
        (path   octocat-tree--file-path))
    (octocat-tree--render-file-loading path)
    (setq mode-line-process " [loading…]")
    (if sha
        (octocat-tree--fetch-file
         repo sha
         (lambda (result)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (setq mode-line-process nil)
               (if (eq (car-safe result) 'error)
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert (propertize
                              (format "Error loading file: %s\n" (cdr result))
                              'face 'error)))
                 (octocat-tree--render-file path result))))))
      ;; No SHA — show an error.
      (setq mode-line-process nil)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Error: no blob SHA available for this file.\n"
                            'face 'error))))))

(defun octocat-file-browse ()
  "Open the current file on GitHub in the browser."
  (interactive)
  (unless (and octocat-tree--file-repo
               octocat-tree--file-branch
               octocat-tree--file-path)
    (user-error "Octocat: Buffer has no file context"))
  (let ((url (format "https://github.com/%s/blob/%s/%s"
                     octocat-tree--file-repo
                     octocat-tree--file-branch
                     octocat-tree--file-path)))
    (message "Octocat: Opening %s in browser…" octocat-tree--file-path)
    (browse-url url)))

;;;; API fetch helper — file commits

(defun octocat-tree--fetch-file-commits (repo path callback)
  "Fetch commit history for PATH in REPO asynchronously.
Requests up to 25 commits touching PATH using the GitHub REST
commits endpoint with the \\='path\\=' filter.  Calls CALLBACK with a
list of commit hash-tables, or a cons (error . MSG) on failure."
  (octocat--run-gh
   "file-commits"
   (list "api"
         (format "repos/%s/commits?per_page=25&path=%s"
                 repo (url-hexify-string path)))
   #'octocat--parse-json-list
   callback))


;;;; Rendering — file log mode

(defun octocat-file-log--render-loading ()
  "Render a loading skeleton in the current file-log buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-file-log-root)
      (magit-insert-heading
        (concat
         (propertize (or octocat-file-log--repo "") 'face 'octocat-repo)
         "  "
         (propertize (or octocat-file-log--path "") 'face 'octocat-branch)
         "\n"))
      (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))))

(defun octocat-file-log--render (commits)
  "Render COMMITS (a list of commit hash-tables) in the current file-log buffer."
  (let ((inhibit-read-only t)
        (repo   octocat-file-log--repo)
        (path   octocat-file-log--path))
    (erase-buffer)
    (magit-insert-section (octocat-file-log-root)
      (magit-insert-heading
        (concat
         (propertize (or repo "") 'face 'octocat-repo)
         "  "
         (propertize (or path "") 'face 'octocat-branch)
         "  "
         (propertize (format "(%d commits)" (length commits))
                     'face 'octocat-dimmed)
         "\n"))
      (if (null commits)
          (insert (propertize "  (no commits found)\n" 'face 'octocat-dimmed))
        (dolist (commit commits)
          (let* ((sha     (or (gethash "sha" commit) ""))
                 (short   (substring sha 0 (min 7 (length sha))))
                 (c       (gethash "commit" commit))
                 (msg     (or (and c (gethash "message" c)) ""))
                 (subject (car (split-string msg "\n")))
                 (date-s  (or (and c
                                   (let ((a (gethash "author" c)))
                                     (and a (gethash "date" a))))
                              ""))
                 (date    (octocat--format-ts date-s))
                 (author  (octocat--commit-author commit))
                 (hint    '(mouse-face magit-section-highlight
                            help-echo  "RET: open commit details  C-c C-o: browse on GitHub")))
            (magit-insert-section (octocat-file-log-commit commit)
              (magit-insert-heading
                (apply #'propertize
                       (concat
                        "  "
                        (propertize short 'face 'octocat-dimmed)
                        "  "
                        (propertize (format "%-16s" date)  'face 'octocat-dimmed)
                        "  "
                        (propertize (format "%-16s" (truncate-string-to-width author 16 nil ?\s "…"))
                                    'face 'octocat-pr-author)
                        "  "
                        (octocat--format-title subject)
                        "\n")
                       hint)))))))))


;;;; Interactive commands — file log mode

(defun octocat-file-log-open ()
  "Open the commit log browser for the file shown in the current buffer.
Works from an `octocat-file-mode' buffer.  Opens (or switches to) the
\\='*octocat-file-log: REPO PATH*\\=' buffer and refreshes it."
  (interactive)
  (unless (derived-mode-p 'octocat-file-mode)
    (user-error "Octocat: Not in a file viewer buffer"))
  (unless (and octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Buffer has no file context"))
  (let* ((repo     octocat-tree--file-repo)
         (path     octocat-tree--file-path)
         (branch   octocat-tree--file-branch)
         (buf-name (format "*octocat-file-log: %s %s*" repo path))
         (buf      (get-buffer-create buf-name)))
    (pop-to-buffer buf)
    (unless (derived-mode-p 'octocat-file-log-mode)
      (octocat-file-log-mode))
    (setq octocat-file-log--repo   repo
          octocat-file-log--path   path
          octocat-file-log--branch branch)
    (octocat-file-log--render-loading)
    (octocat-file-log-refresh)))

(defun octocat-file-log-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the file log buffer by re-fetching commits from the GitHub API."
  (interactive)
  (unless (and octocat-file-log--repo octocat-file-log--path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (let ((buf    (current-buffer))
        (repo   octocat-file-log--repo)
        (path   octocat-file-log--path))
    (setq mode-line-process " [refreshing…]")
    (octocat-tree--fetch-file-commits
     repo path
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq mode-line-process nil)
           (let ((saved (octocat--save-point)))
             (if (eq (car-safe result) 'error)
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert (propertize
                            (format "Error loading commits: %s\n" (cdr result))
                            'face 'error)))
               (octocat-file-log--render result))
             (octocat--restore-point saved))))))))


(provide 'octocat-tree)
;;; octocat-tree.el ends here
