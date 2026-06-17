;;; octocat-tree.el --- File tree browser for octocat  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius

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

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'octocat-core)

;; octocat-visit and octocat-browse live in octocat.el; circular load
;; prevention — declare them only.
(declare-function octocat-visit  "octocat" ())
(declare-function octocat-browse "octocat" ())

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
`octocat-tree--render' to decide whether to show a placeholder or
real children.  Cleared on full refresh (gr).")

(defvar-local octocat-tree--expanded-shas nil
  "List of tree-entry SHA strings that are currently expanded.
Saved before each re-render; used during construction to re-expand
the same dirs without re-fetching (data is in subtree-cache).")


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
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `octocat-tree-mode'.")
(define-key octocat-tree-mode-map (kbd "RET")     #'octocat-tree-visit)
(define-key octocat-tree-mode-map (kbd "TAB")     #'octocat-tree-expand)
(define-key octocat-tree-mode-map (kbd "q")       #'quit-window)
(define-key octocat-tree-mode-map (kbd "C-c C-o") #'octocat-tree-browse)
(define-key octocat-tree-mode-map (kbd "o")       #'octocat-tree-browse)

(define-derived-mode octocat-tree-mode magit-section-mode "Octocat-Tree"
  "Major mode for browsing a GitHub repository file tree.

\\{octocat-tree-mode-map}"
  :group 'octocat
  (setq-local buffer-read-only t)
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
(define-key octocat-file-mode-map (kbd "gr")      #'octocat-file-refresh)

(define-derived-mode octocat-file-mode special-mode "Octocat-File"
  "Major mode for viewing a GitHub file with syntax highlighting.

\\{octocat-file-mode-map}"
  :group 'octocat
  (setq-local truncate-lines nil)
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


;;;; Rendering — tree mode

(defun octocat-tree--render-loading ()
  "Render a loading skeleton in the current tree buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-tree-root)
      (magit-insert-heading
        (concat
         (propertize (or octocat-tree--repo "") 'face 'octocat-repo)
         "  "
         (octocat-tree--branch-glyph)
         "  "
         (propertize (or octocat-tree--branch "") 'face 'octocat-branch)))
      (insert (propertize "  Loading…\n" 'face 'octocat-dimmed)))))

(defun octocat-tree--collect-expanded-shas ()
  "Walk the live section tree and return SHAs of currently expanded dirs."
  (let (shas)
    (when (and (boundp 'magit-root-section) magit-root-section)
      (cl-labels ((walk (section)
                    (when (eq (oref section type) 'tree-dir)
                      (unless (oref section hidden)
                        (let* ((entry (oref section value))
                               (sha   (and (hash-table-p entry)
                                           (gethash "sha" entry))))
                          (when sha (push sha shas)))))
                    (dolist (child (oref section children))
                      (walk child))))
        (walk magit-root-section)))
    shas))

(defun octocat-tree--render-entries (entries depth)
  "Insert magit sections for ENTRIES (a vector) at nesting DEPTH.
Dirs are collapsed unless their SHA is in `octocat-tree--expanded-shas'.
Files are leaf sections."
  (let* ((sorted (cl-sort (cl-coerce entries 'list)
                           (lambda (a b)
                             (let ((ta (gethash "type" a ""))
                                   (tb (gethash "type" b "")))
                               (cond
                                ((and (equal ta "tree") (equal tb "blob")) t)
                                ((and (equal ta "blob") (equal tb "tree")) nil)
                                (t (string< (gethash "path" a "")
                                            (gethash "path" b ""))))))))
         (indent (make-string (* depth 2) ?\s)))
    (dolist (entry sorted)
      (let* ((name   (or (gethash "path" entry) ""))
             (type   (or (gethash "type" entry) ""))
             (sha    (or (gethash "sha"  entry) ""))
             (cached (cdr (assoc sha octocat-tree--subtree-cache)))
             (expandedp (member sha octocat-tree--expanded-shas)))
        (if (equal type "tree")
            (let ((sec (magit-insert-section (tree-dir entry)
                         (magit-insert-heading
                           (concat indent
                                   (propertize (concat "▸ " name "/")
                                               'face 'octocat-branch)))
                         (if (and expandedp cached)
                             (octocat-tree--render-entries cached (1+ depth))
                           ;; Placeholder: shown only while not yet loaded.
                           (magit-insert-section (tree-loading)
                             (magit-insert-heading
                               (concat indent "  "
                                       (propertize "Loading…" 'face 'octocat-dimmed)
                                       "\n")))))))
              ;; Collapse dirs that aren't in expanded-shas.
              (unless expandedp
                (magit-section-hide sec)))
          ;; Blob entry — leaf node.
          (magit-insert-section (tree-file entry)
            (magit-insert-heading
              (concat indent "  "
                      (propertize name 'face 'default)
                      "\n"))))))))

(defun octocat-tree--render (entries)
  "Erase the buffer and render the tree from ENTRIES (root vector)."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (octocat-tree-root)
      (magit-insert-heading
        (concat
         (propertize (or octocat-tree--repo "") 'face 'octocat-repo)
         "  "
         (octocat-tree--branch-glyph)
         "  "
         (propertize (or octocat-tree--branch "") 'face 'octocat-branch)
         "  "
         (propertize "[Browse files]"
                     'face       'octocat-dimmed
                     'mouse-face 'magit-section-highlight
                     'help-echo  "RET: browse file tree"
                     'octocat-action 'browse-files)))
      (octocat-tree--render-entries entries 0))))


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
            fontified)))


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
        octocat-tree--expanded-shas nil)
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
  "Toggle expansion of the directory section at point.
On a collapsed dir: shows it and fetches children if not yet loaded.
On an expanded dir: hides it.
On any other section type: delegates to `magit-section-toggle'."
  (interactive)
  (let ((section (magit-current-section)))
    (unless section
      (user-error "Octocat: No section at point"))
    (if (not (eq (oref section type) 'tree-dir))
        (magit-section-toggle section)
      (let* ((entry  (oref section value))
             (sha    (gethash "sha" entry))
             (hidden (oref section hidden))
             (cached (cdr (assoc sha octocat-tree--subtree-cache))))
        (if (not hidden)
            ;; Already expanded — collapse it.
            (magit-section-hide section)
          ;; Collapsed — expand it.
          (if cached
              ;; Already cached: just re-render with current expanded state.
              (progn
                (push sha octocat-tree--expanded-shas)
                (octocat-tree--re-render-from-cache))
            ;; Not yet fetched: fetch and then re-render.
            (push sha octocat-tree--expanded-shas)
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
                         (message "Octocat: Error loading dir: %s" (cdr result))
                       (push (cons sha result) octocat-tree--subtree-cache)
                       (octocat-tree--re-render-from-cache)))))))))))))

(defun octocat-tree--re-render-from-cache ()
  "Re-render the tree buffer in place, preserving collapse state."
  ;; Collect currently expanded SHAs before erasing buffer.
  (setq octocat-tree--expanded-shas (octocat-tree--collect-expanded-shas))
  (when octocat-tree--entries
    (octocat-tree--render octocat-tree--entries)))

(defun octocat-tree-visit ()
  "Open the file at point in `octocat-file-mode', or toggle a directory."
  (interactive)
  ;; First check for an inline octocat-action text property (Browse files token).
  (unless (eq (get-text-property (point) 'octocat-action) 'browse-files)
    (let ((section (magit-current-section)))
      (unless section
        (user-error "Octocat: No section at point"))
      (pcase (oref section type)
        ('tree-dir  (octocat-tree-expand))
        ('tree-file
         (let* ((entry    (oref section value))
                (path     (gethash "path" entry))
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

(defun octocat-tree-browse ()
  "Open the current tree entry on GitHub in the browser."
  (interactive)
  (let* ((section (magit-current-section))
         (repo    octocat-tree--repo)
         (branch  octocat-tree--branch))
    (unless (and repo branch)
      (user-error "Octocat: Buffer has no repo or branch context"))
    (pcase (and section (oref section type))
      ('tree-file
       (let* ((entry (oref section value))
              (path  (gethash "path" entry))
              (url   (format "https://github.com/%s/blob/%s/%s"
                             repo branch path)))
         (message "Octocat: Opening %s in browser…" path)
         (browse-url url)))
      ('tree-dir
       (let* ((entry (oref section value))
              (path  (gethash "path" entry))
              (url   (format "https://github.com/%s/tree/%s/%s"
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
