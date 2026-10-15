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
;;   `octocat-tree-open'     — open the tree browser (C-c C-t in repo mode,
;;                             or the Code tab of any repo page)
;;   `octocat-file-log-open' — open the file commit log (C-c C-l in file mode)
;;
;; octocat-file-mode derives from `special-mode'.
;; octocat-file-log-mode derives from `vui-mode' and is rendered by
;; `octocat-file-log--page': one line per commit, carrying the commit's
;; SHA in the `octocat-file-log--sha' text property, which RET
;; (`octocat-file-log-visit') and o (`octocat-file-log-browse') read.
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
(require 'octocat-vui)
(require 'vui)
(require 'vui-components)

;; octocat-repo buffer-locals accessed from octocat-tree-open.
(defvar octocat-repo--repo)
(defvar octocat-repo--branch)
(defvar octocat-repo--default-branch)

(declare-function octocat-commit-open "octocat-commit" (repo sha))


;;;; Buffer-local variables — tree mode

(defvar-local octocat-tree--repo nil
  "The \"owner/repo\" string for the tree browser buffer.")

(defvar-local octocat-tree--branch nil
  "Branch/ref name currently being browsed.")

(defvar-local octocat-tree--default-branch nil
  "The repository's default branch, when known; listed first by the picker.")

(defvar-local octocat-tree--root-sha nil
  "SHA of the root git tree object for the current branch.")

(defvar-local octocat-tree--subtree-cache nil
  "Alist mapping directory SHA string to fetched entries vector.
Consulted by `octocat-tree--dir' before the disk cache, so collapsing
and re-expanding a directory neither refetches nor rereads it.  A tree
SHA names fixed contents, so entries never go stale.  Expanded/collapsed
state is not kept here: it lives in each `octocat-tree--node' as vui
state.")

(defvar-local octocat-tree--all-files nil
  "Cached result of the recursive tree fetch used by `octocat-tree-find-file'.
An alist mapping file path strings to their blob SHA strings.
Populated on first call and reused until the root SHA changes.")


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
(define-key octocat-tree-mode-map (kbd "TAB")     #'octocat-tree-toggle-or-forward)
(define-key octocat-tree-mode-map (kbd "<tab>")   #'octocat-tree-toggle-or-forward)
(define-key octocat-tree-mode-map (kbd "^")       #'octocat-tree-up)
(define-key octocat-tree-mode-map (kbd "n")       #'next-line)
(define-key octocat-tree-mode-map (kbd "p")       #'previous-line)
(define-key octocat-tree-mode-map (kbd "C-c C-f") #'octocat-tree-find-file)
(define-key octocat-tree-mode-map (kbd "C-c C-b") #'octocat-tree-switch-branch)
(define-key octocat-tree-mode-map (kbd "q")       #'octocat-quit-window)
(define-key octocat-tree-mode-map (kbd "C-c C-o") #'octocat-tree-browse)
(define-key octocat-tree-mode-map (kbd "o")       #'octocat-tree-browse)
(define-key octocat-tree-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-tree-mode-map (kbd "C-c C-s") #'octocat-search-repo)
(define-key octocat-tree-mode-map (kbd "gr")      #'octocat-tree-refresh)

(defvar octocat-tree--dir-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB")   #'octocat-tree-toggle-or-forward)
    (define-key map (kbd "<tab>") #'octocat-tree-toggle-or-forward)
    map)
  "Keymap of a directory's button; it outranks vui's TAB on buttons.")

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
    (set-keymap-parent map vui-mode-map)
    map)
  "Keymap for `octocat-file-log-mode'.")
(define-key octocat-file-log-mode-map (kbd "q")       #'octocat-quit-window)
(define-key octocat-file-log-mode-map (kbd "RET")     #'octocat-file-log-visit)
(define-key octocat-file-log-mode-map (kbd "C-c C-o") #'octocat-file-log-browse)
(define-key octocat-file-log-mode-map (kbd "o")       #'octocat-file-log-browse)
(define-key octocat-file-log-mode-map (kbd "C-c C-r") #'octocat-switch-repo)
(define-key octocat-file-log-mode-map (kbd "C-c C-s") #'octocat-search-repo)
(define-key octocat-file-log-mode-map (kbd "gr")      #'octocat-file-log-refresh)

(define-derived-mode octocat-file-log-mode vui-mode "Octocat-File-Log"
  "Major mode for browsing the commit history of a single file.
The buffer is rendered by vui.el; see `octocat-file-log--page'.

\\{octocat-file-log-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-file-log-refresh)
  (octocat--ts-eldoc-setup))


;;;; Branch glyph helper



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


;;;; Disk cache
;;
;; A branch's root SHA is cached so the tree paints at once and is
;; replaced if the fresh one differs.  Directory listings and file
;; contents are cached by tree and blob SHA: a SHA names fixed contents,
;; so they are never refetched.

(defun octocat-tree--ref-cache-id (branch)
  "Return the cache id of BRANCH's root SHA; branches may contain \"/\"."
  (octocat--cache-safe-repo branch))

(defun octocat-tree--ref-cache-load (repo branch)
  "Return the cached root tree SHA of REPO on BRANCH, or nil."
  (when-let* ((data (octocat--detail-cache-load
                     repo "tree-ref" (octocat-tree--ref-cache-id branch)))
              (sha  (gethash "sha" data)))
    (and (stringp sha) sha)))

(defun octocat-tree--ref-cache-save (repo branch sha)
  "Cache SHA as the root tree SHA of REPO on BRANCH."
  (let ((data (make-hash-table :test #'equal)))
    (puthash "sha" sha data)
    (octocat--detail-cache-save
     repo "tree-ref" (octocat-tree--ref-cache-id branch) data)))

(defun octocat-tree--dir-cache-load (repo sha)
  "Return the cached entries vector of directory SHA in REPO, or nil."
  (when-let* ((data (octocat--detail-cache-load repo "tree" sha))
              (tree (gethash "tree" data)))
    (and (vectorp tree) tree)))

(defun octocat-tree--dir-cache-save (repo sha entries)
  "Cache ENTRIES, the children of directory SHA in REPO."
  (let ((data (make-hash-table :test #'equal)))
    (puthash "tree" entries data)
    (octocat--detail-cache-save repo "tree" sha data)))

(defun octocat-tree--blob-cache-file (repo sha)
  "Return the cache file of blob SHA in REPO.
Blobs are stored as raw bytes, not JSON: they need not be text."
  (expand-file-name (format "blob-%s" sha)
                    (file-name-directory
                     (octocat--detail-cache-file repo "blob" sha))))

(defun octocat-tree--load-blob (repo sha callback)
  "Call CALLBACK with the content of blob SHA in REPO, or (error . MSG).
Served from the disk cache when there, at once; else fetched and cached."
  (let ((file (octocat-tree--blob-cache-file repo sha)))
    (if (file-readable-p file)
        (funcall callback (with-temp-buffer
                            (set-buffer-multibyte nil)
                            (insert-file-contents-literally file)
                            (buffer-string)))
      (octocat-tree--fetch-file
       repo sha
       (lambda (result)
         (unless (eq (car-safe result) 'error)
           (make-directory (file-name-directory file) t)
           (ignore-errors
             (let ((coding-system-for-write 'no-conversion))
               (write-region result nil file nil 'silent))))
         (funcall callback result))))))


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

(defun octocat-tree--entry-line (indent glyph name face type entry path activate
                                        &optional open)
  "Return one tree line as a vnode (no trailing newline).
INDENT is a string of leading spaces.  GLYPH is a 1-2 char icon.
NAME is the file/dir name.  FACE is applied to the icon+name.
TYPE is \\='dir or \\='file.  ENTRY is the API hash-table.  PATH is the
entry's full repository path: the API's own \"path\" field is only the
name within its directory, so it is wrong below the root.  ACTIVATE is a
zero-argument function run by RET on the line.  OPEN is non-nil for an
expanded directory.

The icon+name is a button, so TAB stops on each entry.  The
type/entry/path/activate properties span the entire line including the
indent (the button keeps its label's), so `get-text-property' at
`line-beginning-position' works regardless of nesting depth.  Commands
read them rather than relying on a keymap, so they keep working under
Evil, whose state keymaps outrank text-property keymaps."
  (let ((props (list 'octocat-tree--type     type
                     'octocat-tree--entry    entry
                     'octocat-tree--path     path
                     'octocat-tree--activate activate
                     'octocat-tree--open     open))
        (help  (if (eq type 'dir)
                   "RET: expand  o: browse on GitHub"
                 "RET: view file  o: browse on GitHub")))
    (vui-fragment
     (unless (string-empty-p indent)
       (vui-text (apply #'propertize indent props)))
     (vui-button (apply #'propertize (concat glyph " " name) props)
                 :no-decoration t
                 :face face
                 :help-echo help
                 :keymap (and (eq type 'dir) octocat-tree--dir-button-map)
                 :on-click activate))))


;;;; Rendering — tree mode

(defun octocat-tree--header (repo branch)
  "Return the vnodes of the tree header for REPO on BRANCH.
BRANCH is a picker button, as GitHub's branch dropdown."
  (list (vui-text (propertize (or repo "") 'face 'octocat-repo 'octocat-tree--type 'header))
        (vui-hstack :spacing 0
          (vui-text (octocat--branch-glyph))
          (vui-button (format "[%s ▾]" (or branch ""))
                      :no-decoration t
                      :face 'octocat-branch
                      :help-echo "RET: browse another branch (C-c C-b)"
                      :on-click #'octocat-tree-switch-branch))))

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
;;   `octocat-tree--dir'   reads from `octocat-tree--subtree-cache', the
;;                         disk cache or the API the children of one
;;                         directory SHA and lists them as nodes.
;;   `octocat-tree--node'  one entry's line; a directory node owns its
;;                         expanded/collapsed state and, when expanded,
;;                         nests another `octocat-tree--dir'.
;;
;; Lines carry no trailing newline: `vui-list' separates siblings, and a
;; node's children follow it after one `vui-newline'.  Nodes are keyed by
;; path, not SHA, so a directory changed by a new root SHA stays expanded;
;; its listing stays up until the new one is loaded.

(vui-defcomponent octocat-tree--dir (repo branch sha depth path)
  "Children of the directory with tree SHA, at nesting DEPTH.
PATH is this directory's full repository path (\"\" for the root)."
  :render
  (let* ((buf    (current-buffer))
         (indent (make-string (* depth 2) ?\s))
         (remember (lambda (entries)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (push (cons sha entries) octocat-tree--subtree-cache)))))
         (result (octocat-vui-use-async-sticky (list 'dir repo sha)
                   (lambda (resolve reject)
                     (if-let* ((cached (or (cdr (assoc sha (buffer-local-value
                                                            'octocat-tree--subtree-cache buf)))
                                           (let ((disk (octocat-tree--dir-cache-load repo sha)))
                                             (when disk (funcall remember disk))
                                             disk))))
                         (funcall resolve cached)
                       (octocat-tree--fetch-dir
                        repo sha
                        (lambda (r)
                          (if (eq (car-safe r) 'error)
                              (funcall reject (cdr r))
                            (funcall remember r)
                            (octocat-tree--dir-cache-save repo sha r)
                            (funcall resolve r))))))))
         (loading (or (eq (plist-get result :status) 'pending)
                      (plist-get result :refreshing))))
    (octocat-vui-use-mode-line-loading loading)
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
                     (lambda (entry)
                       (concat (gethash "type" entry) ":" (gethash "path" entry)))))))
      (_ (vui-text (octocat-tree--skeleton indent))))))

(defun octocat-tree--skeleton (indent)
  "Return grey bars shaped like a few tree entries, each after INDENT."
  (octocat-vui-skeleton (mapcar (lambda (n) (list indent "  " n)) '(14 22 10 18))))

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
                        'octocat-branch 'dir entry path toggle expanded)))
          (vui-fragment
           line
           (when expanded
             (vui-fragment
              (vui-newline)
              (vui-component 'octocat-tree--dir
                             :repo repo :branch branch
                             :sha sha :depth (1+ depth) :path path)))))
      ;; Blob — leaf node.  Single-space glyph matches the width of "▸"/"▾"
      ;; so that file names align with directory names at the same depth.
      (octocat-tree--entry-line
       indent " " name 'default 'file entry path
       (lambda ()
         (octocat-tree--open-file-by-path
          repo branch path sha))))))

(vui-defcomponent octocat-tree--root (repo branch tick)
  "Root component of the tree buffer: the tree of BRANCH of REPO.
Another BRANCH starts the tree afresh, folded and painted from its own
cache; a new TICK refetches it in place."
  :render
  (vui-component 'octocat-tree--branch
                 :key (or branch 'default) :repo repo :branch branch :tick tick))

(vui-defcomponent octocat-tree--branch (repo branch tick)
  "The tree of BRANCH of REPO: header, then the root directory.
The root SHA of BRANCH is painted from the disk cache and refetched; a
new TICK refetches it again."
  :render
  (let* ((buf    (current-buffer))
         (result (octocat-vui-use-cached
                  (list 'root repo branch tick)
                  (lambda () (octocat-tree--ref-cache-load repo branch))
                  (lambda (sha) (octocat-tree--ref-cache-save repo branch sha))
                  (lambda (resolve reject)
                    (octocat-tree--fetch-root-sha
                     repo branch
                     (lambda (r)
                       (if (eq (car-safe r) 'error)
                           (funcall reject (cdr r))
                         (funcall resolve r)))))))
         (sha    (and (eq (plist-get result :status) 'ready)
                      (plist-get result :data))))
    (octocat-vui-use-mode-line-loading
     (or (eq (plist-get result :status) 'pending)
         (plist-get result :refreshing)))
    (vui-use-effect (sha)
      (when (and sha (buffer-live-p buf))
        (with-current-buffer buf
          (unless (equal sha octocat-tree--root-sha)
            (setq octocat-tree--root-sha sha
                  octocat-tree--all-files nil))))
      nil)
    (vui-vstack
     (apply #'vui-hstack :spacing 2
            (append (octocat-tree--header repo branch)
                    (octocat-vui-repo-tabs repo 'code)))
     (pcase (plist-get result :status)
       ('error (vui-text (propertize (format "  Error: %s" (plist-get result :error))
                                     'face 'error)))
       ;; The root directory is itself the tree with this SHA; everything
       ;; below it is fetched lazily as directories are expanded.
       ('ready (vui-component 'octocat-tree--dir
                              :repo repo :branch branch :sha sha
                              :depth 0 :path ""))
       (_ (vui-text (octocat-tree--skeleton "")))))))


;;;; Rendering — file mode

(defun octocat-tree--render-file-loading (path)
  "Render a loading skeleton for file PATH in the current file buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (or octocat-tree--file-repo "") 'face 'octocat-repo)
            "  "
            (octocat--branch-glyph)
            (propertize (or octocat-tree--file-branch "") 'face 'octocat-branch)
            "  "
            (or path "")
            "\n"
            (propertize (make-string 60 ?━) 'face 'octocat-dimmed)
            "\n"
            (octocat-vui-skeleton '((30) (46) ("  " 38) ("  " 24) (12))))))

(defun octocat-tree--render-file (path content)
  "Render file PATH with fontified CONTENT in the current file buffer."
  (let* ((inhibit-read-only t)
         (fontified (octocat-tree--fontify path content)))
    (erase-buffer)
    (insert (propertize (or octocat-tree--file-repo "") 'face 'octocat-repo)
            "  "
            (octocat--branch-glyph)
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

(defun octocat-tree--entry-at-point-p ()
  "Return non-nil when the current line is a file or directory entry."
  (memq (octocat-tree--type-at-point) '(dir file)))

(defun octocat-tree--goto-path (path)
  "Move point to the name of the entry with PATH, if it is shown."
  (let ((pos (save-excursion
               (goto-char (point-min))
               (catch 'found
                 (while (not (eobp))
                   (when (equal (octocat-tree--path-at-point) path)
                     (back-to-indentation)
                     (throw 'found (point)))
                   (forward-line 1))))))
    (when pos (goto-char pos))))


;;;; Interactive commands — tree mode

(defun octocat-tree-open (&optional repo)
  "Open the file tree browser for the current octocat-repo buffer.
With REPO, an \"owner/name\" string, open it for that repository
instead; this is how the tab strip of the other repo pages gets here."
  (interactive)
  (unless (or repo (derived-mode-p 'octocat-repo-mode))
    (user-error "Octocat: Not in an octocat-repo buffer"))
  (let* ((in-repo  (derived-mode-p 'octocat-repo-mode))
         (repo     (or repo octocat-repo--repo))
         (default  (and in-repo octocat-repo--default-branch))
         (branch   (or (and in-repo octocat-repo--branch) default "HEAD"))
         (buf-name (format "*%s tree*" repo))
         (buf      (get-buffer-create buf-name)))
    (octocat-display-buffer buf)
    (unless (derived-mode-p 'octocat-tree-mode)
      (octocat-tree-mode))
    (setq octocat-tree--repo   repo
          octocat-tree--branch branch)
    (when default
      (setq octocat-tree--default-branch default))
    (octocat-tree-refresh)))

(defun octocat-tree-switch-branch ()
  "Browse the tree of another branch, picked from the repository's."
  (interactive)
  (unless octocat-tree--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (setq octocat-tree--branch   (octocat--read-branch
                                octocat-tree--repo octocat-tree--default-branch
                                (plist-get (octocat--head-info) :branch)
                                octocat-tree--branch)
        octocat-tree--root-sha nil)
  (octocat-tree-refresh))

(defun octocat-tree-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the tree buffer from the GitHub API.
Refetches the root SHA, keeping what is expanded; the cached tree shows
until it arrives."
  (interactive)
  (unless octocat-tree--repo
    (user-error "Octocat: Buffer is not associated with a repository"))
  (octocat-vui-refresh-page 'octocat-tree--root
                            octocat-tree--repo
                            (list :repo octocat-tree--repo
                                  :branch octocat-tree--branch)))

(defun octocat-tree-toggle-or-forward ()
  "Toggle the directory at point, as TAB does in treemacs or magit.
Elsewhere, and in Evil's normal state, where TAB walks the buttons,
move to the next button instead."
  (interactive)
  (if (and (eq (octocat-tree--type-at-point) 'dir)
           (not (memq (bound-and-true-p evil-state) '(normal motion))))
      (funcall (octocat-tree--activate-at-point))
    (call-interactively #'vui-forward)))

(defun octocat-tree-up ()
  "Move point to the directory containing the entry at point."
  (interactive)
  (let ((path (or (octocat-tree--path-at-point)
                  (user-error "Octocat: No entry at point"))))
    (unless (string-search "/" path)
      (user-error "Octocat: Already at the top"))
    (octocat-tree--goto-path (directory-file-name (file-name-directory path)))))

(defun octocat-tree-collapse-or-up ()
  "Collapse the directory at point, or else move to its containing one."
  (interactive)
  (if (and (eq (octocat-tree--type-at-point) 'dir)
           (get-text-property (line-beginning-position) 'octocat-tree--open))
      (funcall (octocat-tree--activate-at-point))
    (octocat-tree-up)))

(defun octocat-tree-visit ()
  "Open the file at point in `octocat-file-mode', or toggle a directory.
On a button, such as the header's branch picker, press it: Evil's RET
binding outranks the button's own."
  (interactive)
  (if (button-at (point))
      (push-button)
    (when-let* ((activate (octocat-tree--activate-at-point)))
      (funcall activate))))

(defun octocat-tree--open-file-by-path (repo branch path sha)
  "Open the file viewer buffer for PATH (blob SHA) in REPO on BRANCH."
  (let* ((buf-name (format "*%s:%s*" repo path))
         (buf      (get-buffer-create buf-name)))
    (octocat-display-buffer buf)
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
      (setq mode-line-process (octocat-vui-mode-line-busy ":loading"))
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
           (branch (or octocat-repo--branch octocat-repo--default-branch "HEAD"))
           (buf-name (format "*%s tree*" repo))
           (tree-buf (get-buffer buf-name)))
      (if (and tree-buf
               (equal (buffer-local-value 'octocat-tree--branch tree-buf) branch)
               (buffer-local-value 'octocat-tree--root-sha tree-buf))
          ;; Tree buffer already has a loaded root SHA — use its cache.
          (with-current-buffer tree-buf
            (octocat-tree--do-find-file repo branch octocat-tree--root-sha))
        ;; No tree buffer yet (or root not loaded).  Fetch the root SHA
        ;; fresh without opening the tree browser.
        (setq mode-line-process (octocat-vui-mode-line-busy ":loading"))
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
                   (setq mode-line-process (octocat-vui-mode-line-busy ":loading"))
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
           (buf-name (format "*%s tree*" repo))
           (tree-buf (get-buffer buf-name)))
      (if (and tree-buf
               (equal (buffer-local-value 'octocat-tree--branch tree-buf) branch)
               (buffer-local-value 'octocat-tree--root-sha tree-buf))
          ;; Tree buffer already has a loaded root SHA — use its cache.
          (with-current-buffer tree-buf
            (octocat-tree--do-find-file repo branch octocat-tree--root-sha))
        ;; No tree buffer yet (or root not loaded).  Fetch the root SHA
        ;; fresh without opening the tree browser.
        (setq mode-line-process (octocat-vui-mode-line-busy ":loading"))
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
                   (setq mode-line-process (octocat-vui-mode-line-busy ":loading"))
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
         (octocat-browse-external url)))
      ('dir
       (let ((url (format "https://github.com/%s/tree/%s/%s"
                            repo branch path)))
         (message "Octocat: Opening %s/ in browser…" path)
         (octocat-browse-external url)))
      (_
       (let ((url (format "https://github.com/%s/tree/%s" repo branch)))
         (message "Octocat: Opening %s tree in browser…" repo)
         (octocat-browse-external url))))))


;;;; Interactive commands — file mode

(defun octocat-file-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the file viewer buffer from its blob.
The blob is fixed by its SHA, so a cached copy is shown without a fetch."
  (interactive)
  (unless (and octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (let ((buf    (current-buffer))
        (repo   octocat-tree--file-repo)
        (sha    octocat-tree--file-sha)
        (path   octocat-tree--file-path))
    (when (and sha (not (file-readable-p (octocat-tree--blob-cache-file repo sha))))
      (octocat-tree--render-file-loading path)
      (setq mode-line-process (octocat-vui-mode-line-busy ":loading")))
    (if sha
        (octocat-tree--load-blob
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
    (octocat-browse-external url)))

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

(defun octocat-file-log--commit-line (commit)
  "Return the log line for COMMIT, a hash-table (no trailing newline).
The line shows the short SHA, date, author and subject.  The full SHA
is in the `octocat-file-log--sha' property across the whole line, which
`octocat-file-log-visit' and `octocat-file-log-browse' read: like the
tree lines, commands read a property rather than a per-line keymap, so
they keep working under Evil."
  (let* ((sha     (or (gethash "sha" commit) ""))
         (short   (substring sha 0 (min 7 (length sha))))
         (c       (gethash "commit" commit))
         (msg     (or (and c (gethash "message" c)) ""))
         (subject (car (split-string msg "\n")))
         (date-s  (or (and c
                           (let ((a (gethash "author" c)))
                             (and a (gethash "date" a))))
                      ""))
         (date    (octocat--format-ts-relative date-s))
         (author  (octocat--commit-author commit))
         (line    (concat
                   "  "
                   (propertize short 'face 'octocat-dimmed)
                   "  "
                   (propertize (format "%-14s" date) 'face 'octocat-dimmed)
                   "  "
                   (propertize (format "%-16s" (truncate-string-to-width author 16 nil ?\s "…"))
                               'face 'octocat-pr-author)
                   "  "
                   (octocat--format-title subject))))
    (add-text-properties 0 (length line)
                         (list 'octocat-file-log--sha sha
                               'mouse-face            'highlight)
                         line)
    (octocat-vui--default-help-echo
     line "RET: open commit details  o: browse on GitHub")))

(vui-defcomponent octocat-file-log--page (repo path commits text face)
  "The file log page: a REPO and PATH header, then COMMITS or TEXT.
COMMITS is a list of commit hash-tables.  When TEXT is non-nil it is
shown in FACE in place of the list (errors; \"\" while loading, drawn
as grey bars), and the
header leaves out the commit count."
  :render
  (vui-vstack
   (vui-text (concat
              (propertize (or repo "") 'face 'octocat-repo)
              "  "
              (propertize (or path "") 'face 'octocat-branch)
              (unless text
                (concat "  "
                        (propertize (format "(%d commits)" (length commits))
                                    'face 'octocat-dimmed)))))
   (cond
    ((equal text "")
     (vui-text (octocat-vui-line-skeleton "  ")))
    (text
     (vui-text (propertize (concat "  " text) 'face face)))
    ((null commits)
     (vui-text (propertize "  (no commits found)" 'face 'octocat-dimmed)))
    (t
     (vui-list commits
               (lambda (commit) (vui-text (octocat-file-log--commit-line commit)))
               (lambda (commit) (gethash "sha" commit)))))))

(defun octocat-file-log--mount (&rest props)
  "Mount `octocat-file-log--page' in the current buffer.
The repo and path come from the buffer; PROPS are the page's other
properties (:commits, or :text and :face)."
  (vui-mount (apply #'vui-component 'octocat-file-log--page
                    :repo octocat-file-log--repo
                    :path octocat-file-log--path
                    props)
             (buffer-name)))

(defun octocat-file-log--render-loading ()
  "Render a loading skeleton in the current file-log buffer."
  (octocat-file-log--mount :text "" :face nil))

(defun octocat-file-log--sha-at-point ()
  "Return the full SHA of the commit on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-file-log--sha))


;;;; Interactive commands — file log mode

(defun octocat-file-log-open ()
  "Open the commit log browser for the file shown in the current buffer.
Works from an `octocat-file-mode' buffer.  Opens (or switches to) the
\\='*REPO:PATH log*\\=' buffer and refreshes it."
  (interactive)
  (unless (derived-mode-p 'octocat-file-mode)
    (user-error "Octocat: Not in a file viewer buffer"))
  (unless (and octocat-tree--file-repo octocat-tree--file-path)
    (user-error "Octocat: Buffer has no file context"))
  (let* ((repo     octocat-tree--file-repo)
         (path     octocat-tree--file-path)
         (branch   octocat-tree--file-branch)
         (buf-name (format "*%s:%s log*" repo path))
         (buf      (get-buffer-create buf-name)))
    (octocat-display-buffer buf)
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
    (setq mode-line-process (octocat-vui-mode-line-busy ":refreshing"))
    (octocat-tree--fetch-file-commits
     repo path
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq mode-line-process nil)
           (octocat-vui-preserving-view
             (if (eq (car-safe result) 'error)
                 (octocat-file-log--mount
                  :text (format "Error loading commits: %s" (cdr result))
                  :face 'error)
               (octocat-file-log--mount :commits result)))))))))

(defun octocat-file-log-visit ()
  "Open the commit detail view for the commit at point."
  (interactive)
  (when-let* ((sha (octocat-file-log--sha-at-point)))
    (octocat-commit-open octocat-file-log--repo sha)))

(defun octocat-file-log-browse ()
  "Open the commit at point on GitHub.
Away from a commit line, open the file's history page instead."
  (interactive)
  (unless (and octocat-file-log--repo octocat-file-log--path)
    (user-error "Octocat: Buffer is not associated with a file"))
  (let ((sha (octocat-file-log--sha-at-point)))
    (if sha
        (progn
          (message "Octocat: Opening commit %s in browser…"
                   (substring sha 0 (min 7 (length sha))))
          (octocat-browse-external (format "https://github.com/%s/commit/%s"
                                           octocat-file-log--repo sha)))
      (message "Octocat: Opening file history in browser…")
      (octocat-browse-external (format "https://github.com/%s/commits/%s/%s"
                                       octocat-file-log--repo
                                       (or octocat-file-log--branch "HEAD")
                                       octocat-file-log--path)))))


(provide 'octocat-tree)
;;; octocat-tree.el ends here
