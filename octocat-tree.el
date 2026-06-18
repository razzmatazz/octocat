;;; octocat-tree.el --- File tree browser for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Two new modes for browsing a repository's file tree:
;;
;;   octocat-tree-mode — interactive tree browser; dirs expand on demand
;;   octocat-file-mode — read-only file content viewer with syntax highlighting
;;
;; Entry point: `octocat-tree-open', bound to T in `octocat-repo-mode'.
;;
;; octocat-tree-mode derives from `special-mode'.  The buffer is rendered
;; entirely with plain text and text properties — no magit-section machinery.
;; Each non-header line carries:
;;
;;   octocat-tree--type   \\='dir | \\='file  — kind of entry
;;   octocat-tree--entry  <hash-table>    — the GitHub API entry object
;;
;; Expand/collapse state is tracked in `octocat-tree--expanded-shas'.

;;; Code:

(require 'cl-lib)
(require 'octocat-core)

;; octocat-repo buffer-locals accessed from octocat-tree-open.
(defvar octocat-repo--repo)
(defvar octocat-repo--current-branch)
(defvar octocat-repo--default-branch)


;;;; Buffer-local variables — tree mode

(defvar-local octocat-tree--repo nil
  "The \"owner/repo\" string for the tree browser buffer.")

(defvar-local octocat-tree--branch nil
  "Branch/ref name currently being browsed.")

(defvar-local octocat-tree--root-sha nil
  "SHA of the root git tree object for the current branch.")

(defvar-local octocat-tree--entries nil
  "Root-level entries vector fetched from the GitHub API.")

(defvar-local octocat-tree--subtree-cache nil
  "Alist mapping directory SHA string to fetched entries vector.
Populated by `octocat-tree--fetch-dir' callbacks; consulted by
`octocat-tree--render' to decide whether to show children or not.
Cleared on full refresh (gr).")

(defvar-local octocat-tree--expanded-shas nil
  "List of tree-entry SHA strings that are currently expanded.")

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
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap for `octocat-tree-mode'.")
(define-key octocat-tree-mode-map (kbd "RET")     #'octocat-tree-visit)
(define-key octocat-tree-mode-map (kbd "TAB")     #'octocat-tree-expand)
(define-key octocat-tree-mode-map (kbd "T")       #'octocat-tree-find-file)
(define-key octocat-tree-mode-map (kbd "q")       #'quit-window)
(define-key octocat-tree-mode-map (kbd "C-c C-o") #'octocat-tree-browse)
(define-key octocat-tree-mode-map (kbd "o")       #'octocat-tree-browse)
(define-key octocat-tree-mode-map (kbd "gr")      #'octocat-tree-refresh)

(define-derived-mode octocat-tree-mode special-mode "Octocat-Tree"
  "Major mode for browsing a GitHub repository file tree.

\\{octocat-tree-mode-map}"
  :group 'octocat
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-tree-refresh)
  (font-lock-mode -1))


;;;; Mode: octocat-file-mode

(defvar octocat-file-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keymap for `octocat-file-mode'.")
(define-key octocat-file-mode-map (kbd "C-c C-o") #'octocat-file-browse)
(define-key octocat-file-mode-map (kbd "o")       #'octocat-file-browse)
(define-key octocat-file-mode-map (kbd "T")       #'octocat-tree-find-file)
(define-key octocat-file-mode-map (kbd "gr")      #'octocat-file-refresh)

(define-derived-mode octocat-file-mode special-mode "Octocat-File"
  "Major mode for viewing a GitHub file with syntax highlighting.

\\{octocat-file-mode-map}"
  :group 'octocat
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-file-refresh))


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

(defun octocat-tree--propertize-line (str props)
  "Return STR with PROPS applied over its whole length, plus a trailing newline.
The newline does not carry PROPS."
  (concat (apply #'propertize str props) "\n"))

(defun octocat-tree--insert-entry-line (indent glyph name face type entry)
  "Insert one tree line with text properties.
INDENT is a string of leading spaces.  GLYPH is a 1-2 char icon.
NAME is the file/dir name.  FACE is applied to the icon+name.
TYPE is \\='dir or \\='file.  ENTRY is the API hash-table stored as a property.

The type/entry/mouse-face/help-echo properties span the entire line
including the indent, so `get-text-property' at `line-beginning-position'
works regardless of nesting depth."
  (let* ((label (propertize (concat glyph " " name) 'face face))
         (line  (concat indent label))
         (help  (if (eq type 'dir)
                    "RET/TAB: expand  o: browse on GitHub"
                  "RET: view file  o: browse on GitHub")))
    (add-text-properties 0 (length line)
                         (list 'octocat-tree--type  type
                               'octocat-tree--entry entry
                               'mouse-face          'highlight
                               'help-echo           help)
                         line)
    (insert line "\n")))


;;;; Rendering — tree mode

(defun octocat-tree--render-loading ()
  "Render a loading skeleton in the current tree buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize
             (concat
              (propertize (or octocat-tree--repo "") 'face 'octocat-repo)
              "  "
              (octocat-tree--branch-glyph)
              "  "
              (propertize (or octocat-tree--branch "") 'face 'octocat-branch))
             'octocat-tree--type 'header)
            "\n"
            (propertize "  Loading…\n" 'face 'octocat-dimmed))))

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

(defun octocat-tree--render-entries (entries depth)
  "Insert plain-text lines for ENTRIES (a vector) at nesting DEPTH.
Dirs whose SHA is in `octocat-tree--expanded-shas' are recursively
expanded (using cached children from `octocat-tree--subtree-cache')."
  (let ((indent (make-string (* depth 2) ?\s)))
    (dolist (entry (octocat-tree--sorted-entries entries))
      (let* ((name      (or (gethash "path" entry) ""))
             (type      (or (gethash "type" entry) ""))
             (sha       (or (gethash "sha"  entry) ""))
             (expandedp (member sha octocat-tree--expanded-shas))
             (cached    (cdr (assoc sha octocat-tree--subtree-cache))))
        (if (equal type "tree")
            (progn
              (octocat-tree--insert-entry-line
               indent
               (if expandedp "▾" "▸")
               (concat name "/")
               'octocat-branch
               'dir
               entry)
              (when (and expandedp cached)
                (octocat-tree--render-entries cached (1+ depth)))
              (when (and expandedp (not cached))
                ;; Fetch in flight — show loading placeholder at child indent,
                ;; so it aligns with the entries that will replace it.
                (let ((child-indent (make-string (* (1+ depth) 2) ?\s)))
                  (insert (propertize
                           (concat child-indent "  "
                                   (propertize "Loading…" 'face 'octocat-dimmed))
                           'octocat-tree--type 'loading)
                          "\n"))))
          ;; Blob — leaf node.  Single-space glyph matches the width of "▸"/"▾"
          ;; so that file names align with directory names at the same depth.
          (octocat-tree--insert-entry-line
           indent " " name 'default 'file entry))))))

(defun octocat-tree--render (entries)
  "Erase the buffer and render the full tree from root ENTRIES vector.
Point is restored to the same line and column after re-rendering."
  (let ((saved-line (line-number-at-pos))
        (saved-col  (current-column))
        (inhibit-read-only t))
    (erase-buffer)
    ;; Header line.
    (insert (propertize
             (concat
              (propertize (or octocat-tree--repo "") 'face 'octocat-repo)
              "  "
              (octocat-tree--branch-glyph)
              "  "
              (propertize (or octocat-tree--branch "") 'face 'octocat-branch)
              "  "
              (propertize "[Browse files]"
                          'face            'octocat-dimmed
                          'mouse-face      'highlight
                          'help-echo       "RET: browse file tree"
                          'octocat-action  'browse-files))
             'octocat-tree--type 'header)
            "\n")
    (octocat-tree--render-entries entries 0)
    ;; Restore point to the same line and column.
    (goto-char (point-min))
    (forward-line (1- saved-line))
    (move-to-column saved-col)))


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

(defun octocat-tree--entry-at-point ()
  "Return the entry hash-table on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-tree--entry))

(defun octocat-tree--type-at-point ()
  "Return the \\='octocat-tree--type symbol on the current line, or nil."
  (get-text-property (line-beginning-position) 'octocat-tree--type))


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
        octocat-tree--expanded-shas nil
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
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (propertize (format "Error: %s\n" (cdr result))
                                     'face 'error)))
             (setq octocat-tree--root-sha result)
             (octocat-tree--fetch-dir
              repo result
              (lambda (entries-result)
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (if (eq (car-safe entries-result) 'error)
                        (let ((inhibit-read-only t))
                          (erase-buffer)
                          (insert (propertize
                                   (format "Error: %s\n" (cdr entries-result))
                                   'face 'error)))
                      (setq octocat-tree--entries entries-result)
                      (octocat-tree--render entries-result)))))))))))))

(defun octocat-tree-expand ()
  "Toggle expansion of the directory entry at point.
On a collapsed dir: marks it expanded and re-renders; fetches children
if not yet cached.  On an expanded dir: collapses it and re-renders."
  (interactive)
  (let ((type  (octocat-tree--type-at-point))
        (entry (octocat-tree--entry-at-point)))
    (unless (eq type 'dir)
      (user-error "Octocat: No directory at point"))
    (let* ((sha       (gethash "sha" entry))
           (expandedp (member sha octocat-tree--expanded-shas))
           (cached    (cdr (assoc sha octocat-tree--subtree-cache))))
      (if expandedp
          ;; Already expanded — collapse it.
          (progn
            (setq octocat-tree--expanded-shas
                  (delete sha octocat-tree--expanded-shas))
            (octocat-tree--render octocat-tree--entries))
        ;; Collapsed — expand it.
        (push sha octocat-tree--expanded-shas)
        (if cached
            ;; Already cached: re-render immediately.
            (octocat-tree--render octocat-tree--entries)
          ;; Not yet fetched: show expanded glyph with loading placeholder,
          ;; then fetch asynchronously.
          (octocat-tree--render octocat-tree--entries)
          (let ((buf  (current-buffer))
                (repo octocat-tree--repo))
            (setq mode-line-process " [loading…]")
            (octocat-tree--fetch-dir
             repo sha
             (lambda (result)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq mode-line-process nil)
                   (if (eq (car-safe result) 'error)
                       (progn
                         (setq octocat-tree--expanded-shas
                               (delete sha octocat-tree--expanded-shas))
                         (message "Octocat: Error loading dir: %s" (cdr result))
                         (octocat-tree--render octocat-tree--entries))
                     (push (cons sha result) octocat-tree--subtree-cache)
                     (octocat-tree--render octocat-tree--entries))))))))))))

(defun octocat-tree-visit ()
  "Open the file at point in `octocat-file-mode', or toggle a directory."
  (interactive)
  ;; Header line may carry an octocat-action property for the Browse-files token.
  (if (eq (get-text-property (point) 'octocat-action) 'browse-files)
      nil  ; no-op here; browser shortcut is on o/C-c C-o
    (let ((type  (octocat-tree--type-at-point))
          (entry (octocat-tree--entry-at-point)))
      (pcase type
        ('dir  (octocat-tree-expand))
        ('file
         (let* ((path     (gethash "path" entry))
                (sha      (gethash "sha"  entry))
                (repo     octocat-tree--repo)
                (branch   octocat-tree--branch)
                (buf-name (format "*octocat-file: %s %s*" repo path))
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
        (_ nil)))))

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
         (entry  (octocat-tree--entry-at-point)))
    (unless (and repo branch)
      (user-error "Octocat: Buffer has no repo or branch context"))
    (pcase type
      ('file
       (let* ((path (gethash "path" entry))
              (url  (format "https://github.com/%s/blob/%s/%s"
                            repo branch path)))
         (message "Octocat: Opening %s in browser…" path)
         (browse-url url)))
      ('dir
       (let* ((path (gethash "path" entry))
              (url  (format "https://github.com/%s/tree/%s/%s"
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

(provide 'octocat-tree)
;;; octocat-tree.el ends here
