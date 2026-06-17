# Plan: File Tree Browser (`octocat-tree-mode` + `octocat-file-mode`)

## Goal

Add a way to browse the repository file tree from within octocat.  The feature
consists of two new modes:

| Mode | Buffer name | Purpose |
|---|---|---|
| `octocat-tree-mode` | `*octocat-tree: owner/repo*` | Interactive tree browser; dirs expand on demand |
| `octocat-file-mode` | `*octocat-file: owner/repo path/to/file*` | Read-only file content viewer |

Entry point: a RET-able **"Browse files"** token on the repo header line in
`octocat-repo-mode`, plus a `T` keyboard shortcut for quick access.  There is
no dedicated new section; the token lives inside the existing repo header so it
remains lightweight and always visible.

---

## User Interaction Flow

```
octocat-repo-mode  ──RET on "Browse files" token (or T)──►  octocat-tree-mode          ──RET on file──►  octocat-file-mode
                                                              *octocat-tree: owner/repo*                   *octocat-file: owner/repo src/foo.el*
```

Inside `octocat-tree-mode`:

- **Root level** is fetched immediately when the buffer opens (async, with a
  "Loading…" skeleton while in flight).
- **Directory entries** start collapsed.  The first `TAB` on a dir fetches its
  children (async, "Loading…" placeholder in the dir body), then re-renders
  that subtree expanded.  Subsequent `TAB` presses toggle without re-fetching
  (children are cached in the section value).
- **File entries** are leaf sections; `RET` opens `octocat-file-mode`.
- **`o` / `C-c C-o`** opens the current entry on GitHub in the browser.
- **`gr`** re-fetches the root tree from scratch (full refresh, discards subtree cache).
- **`q`** quits the window.

Inside `octocat-file-mode`:

- Content is displayed with syntax highlighting via `delay-mode-hooks` +
  `set-auto-mode` on a temp buffer (or `font-lock-ensure`) then the propertized
  text is copied in — same approach as `octocat--insert-markdown`.
- **`o` / `C-c C-o`** opens the file on GitHub in the browser.
- **`q`** quits the window.
- `gr` re-fetches and re-renders the file.

---

## GitHub API

Both calls are made via `gh api` (routed through the existing
`octocat--run-gh` primitive):

### 1. Fetch a directory's contents — GitHub Trees API

```
GET /repos/{owner}/{repo}/git/trees/{tree_sha}
```

Returns JSON with a `tree` array of entries, each with `path`, `type`
(`"blob"` or `"tree"`), `sha`, `size`.  The `path` field is just the *name*
of the entry (no parent prefix) when `recursive` is omitted (default = depth 1).

The root tree SHA is obtained by fetching the branch tip commit:

```
gh api repos/OWNER/REPO/git/ref/heads/BRANCH --jq .object.sha
```

then:

```
gh api repos/OWNER/REPO/git/commits/COMMIT_SHA --jq .tree.sha
```

Or more directly with a single call that combines both:

```
gh api repos/OWNER/REPO/branches/BRANCH --jq .commit.commit.tree.sha
```

For **subdirectory** expansion the subtree SHA is already present in the
parent's entry (the `sha` field of the `type=tree` entry), so no extra
round-trip is needed to find it.

### 2. Fetch a file's content — GitHub Contents API

```
GET /repos/{owner}/{repo}/contents/{path}?ref={branch}
```

Returns JSON with `content` (base64-encoded) and `encoding`.  Decode with
`base64-decode-string`.

Alternative: fetch the raw blob by SHA (already known from the tree entry):

```
gh api repos/OWNER/REPO/git/blobs/SHA --jq .content
```

The blob approach avoids sending the full file path in the URL and is
slightly more stable for large files.  Use blob-by-SHA as the primary path;
fall back to contents-by-path when blob SHA is missing.

---

## New File: `octocat-tree.el`

A single new file handles both modes.  The file viewer is small enough that a
separate `octocat-file.el` is not warranted.

### Module structure

```
octocat-tree.el
  ├── require / declare-function header
  ├── Buffer-local variables (defvar-local)
  ├── octocat-tree-mode + octocat-tree-mode-map
  ├── octocat-file-mode + octocat-file-mode-map
  ├── API fetch helpers
  │     octocat-tree--fetch-root-sha (repo branch callback)
  │     octocat-tree--fetch-dir (repo sha callback)
  │     octocat-tree--fetch-file (repo sha path callback)
  ├── Rendering helpers
  │     octocat-tree--render-loading ()
  │     octocat-tree--render (entries)
  │     octocat-tree--render-subtree (section entries)
  │     octocat-tree--render-file-loading (path)
  │     octocat-tree--render-file (path content)
  ├── Interactive commands
  │     octocat-tree-open (repo branch &optional local-dir)
  │     octocat-tree-refresh (&optional _ignore-auto _noconfirm)
  │     octocat-tree-expand ()        ← TAB override
  │     octocat-tree-visit ()         ← RET; opens file buffer
  │     octocat-file-refresh (...)
  └── (provide 'octocat-tree)
```

---

## Section Structure

### `octocat-tree-mode` buffer

The buffer heading prominently displays the branch so the user always knows
which ref they are browsing.  The branch name uses `octocat-branch` face
(same as the branch column in the PR list), which is distinct from the repo
name face.  The buffer-local `octocat-tree--branch` is set at open time and
persisted across refreshes, making it straightforward to add a branch-switch
command (`b`) later without changing the rendering logic.

```
(octocat-tree-root)                          heading: "owner/repo  ⎇  main  [Browse files]"
  (tree-dir  ENTRY-HT)                       heading: "▸ src/"    (collapsed)
    (tree-loading)                           placeholder: "  Loading…"
                                             ← replaced on first expand
  (tree-dir  ENTRY-HT)                       heading: "▸ tests/"  (collapsed)
    ...
  (tree-file ENTRY-HT)                       heading: "  .gitignore"
  (tree-file ENTRY-HT)                       heading: "  README.md"
```

The `⎇` glyph (U+2387, Alternative Key Symbol) visually signals "branch"
without requiring an extra word.  Fall back to `@` if the terminal cannot
render it (check via `char-displayable-p`).

All `(tree-dir)` sections start **collapsed** via
`(magit-section-hide (magit-insert-section (tree-dir entry) …))`.

The section `:value` for both `tree-dir` and `tree-file` is a hash-table with
keys `path` (entry name), `sha`, `type`, and an extra key `octocat-loaded`
that is `nil` until the subtree has been fetched.  Because the value is a
hash-table, the existing `cl-defmethod magit-section-ident-value` override
(keyed on `sha`) gives each entry a stable identity for point preservation
across re-renders.

### `octocat-file-mode` buffer

`octocat-file-mode` derives from `special-mode`, so the buffer has no
magit-section tree.  Content is inserted directly:

```
── buffer start ───────────────────────────────────────────────────────
owner/repo  ⎇  main  path/to/file                   ← propertized header line
                                                      (face: octocat-repo / octocat-branch / default)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ← separator (propertize with 'face 'octocat-dimmed)

<fontified file content>
── buffer end ─────────────────────────────────────────────────────────
```

`octocat-file-browse` (bound to `o` / `C-c C-o`) reads
`octocat-tree--file-repo`, `octocat-tree--file-branch`, and
`octocat-tree--file-path` from buffer-locals to construct the GitHub URL:
`https://github.com/REPO/blob/BRANCH/PATH`.

---

## Lazy Loading Mechanics

`TAB` in `octocat-tree-mode` is overridden by `octocat-tree-expand`:

```
octocat-tree-expand ()
  section ← (magit-current-section)
  if section.type ≠ tree-dir  →  call (magit-section-toggle section) and return
  if section hidden? → call (magit-section-show section)
                    → if NOT yet loaded (octocat-loaded absent/nil):
                          set placeholder "Loading…" inside the section body
                          fire octocat-tree--fetch-dir for section.value.sha
                          on result: call octocat-tree--render-subtree
                                     to replace placeholder with real children
                    else: already loaded, magit-section-show is enough
  else (already expanded) → call (magit-section-hide section)
```

`octocat-tree--render-subtree` replaces the `(tree-loading)` placeholder in
place:
1. Find the `(tree-loading)` child section of the `(tree-dir)` section.
2. Use `inhibit-read-only t` + delete the placeholder region.
3. Move point to the former placeholder position.
4. Call `magit-insert-section` for each child entry (dirs collapsed, files
   as leaves).
5. Mark `octocat-loaded t` in the parent entry hash-table so subsequent
   expands skip the fetch.

Because we are inserting into an already-existing section tree (not
re-rendering the whole buffer), we do **not** call `erase-buffer`.  The
`magit-root-section` end marker automatically extends as text is inserted.

> **Note on in-place insertion:** magit-section was designed for full-buffer
> re-renders.  Inserting into the middle of an existing section tree is
> non-trivial because end-markers of ancestor sections must be advanced.
> The simplest safe approach is a **partial re-render**: after a subtree
> fetch completes, call `octocat-tree-refresh` for the whole buffer (preserving
> collapse state), not an in-place splice.  This avoids marker arithmetic
> entirely and follows the established refresh pattern.  The trade-off is that
> all other dir sections must be re-rendered too, but since we cache `entries`
> in the buffer-local `octocat-tree--subtree-cache` alist (keyed by sha), only
> the expanded dir's `gh api` call is avoided.

---

## Subtree Cache

```elisp
(defvar-local octocat-tree--subtree-cache nil
  "Alist mapping directory SHA string to fetched entries vector.
Populated by octocat-tree--fetch-dir callbacks; consulted by
octocat-tree--render to decide whether to show a placeholder or
real children.  Cleared on full refresh (gr).")
```

During `octocat-tree--render (entries)`:
- For each `type=tree` entry: check `octocat-tree--subtree-cache` for its SHA.
  - If found: render children recursively (also collapsed, from cache).
  - If not found: render a collapsed `(tree-dir)` with a `(tree-loading)`
    placeholder body.

This makes the render function fully driven by the cache state, so the same
`octocat-tree-refresh` path handles both first-open and post-expand re-renders.

---

## Collapse-State Preservation

Follow the same pattern used in `octocat-repo-mode`:

```elisp
(defvar-local octocat-tree--expanded-shas nil
  "List of tree-entry SHA strings that are currently expanded.
Saved before each re-render; used during construction to re-expand
the same dirs without re-fetching (data is in subtree-cache).")
```

Before every re-render, walk the live section tree and collect SHA values of
`(tree-dir)` sections whose `:hidden` is `nil` (expanded).  After building
the new tree, use `magit-section-hide` at construction time for dirs whose SHA
is *not* in `octocat-tree--expanded-shas`.

---

## Buffer-Local Variables

```elisp
(defvar-local octocat-tree--repo   nil "\"owner/repo\" string.")
(defvar-local octocat-tree--branch nil "Branch/ref name.")
(defvar-local octocat-tree--root-sha nil "SHA of the root git tree object.")
(defvar-local octocat-tree--entries nil "Root-level entries vector from GitHub API.")
(defvar-local octocat-tree--subtree-cache nil "Alist SHA → entries vector.")
(defvar-local octocat-tree--expanded-shas nil "SHAs of currently expanded dirs.")

(defvar-local octocat-tree--file-repo nil)
(defvar-local octocat-tree--file-path nil)
(defvar-local octocat-tree--file-sha  nil)
(defvar-local octocat-tree--file-branch nil)
```

---

## Mode Definitions

### `octocat-tree-mode`

```elisp
(defvar octocat-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map))
(define-key octocat-tree-mode-map (kbd "RET")     #'octocat-tree-visit)
(define-key octocat-tree-mode-map (kbd "TAB")     #'octocat-tree-expand)
(define-key octocat-tree-mode-map (kbd "q")       #'quit-window)
(define-key octocat-tree-mode-map (kbd "C-c C-o") #'octocat-tree-browse)
;; gr via sub-map (same pattern as other modes)

(define-derived-mode octocat-tree-mode magit-section-mode "Octocat-Tree"
  "Major mode for browsing a GitHub repository file tree."
  :group 'octocat
  (setq-local buffer-read-only t)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function #'octocat-tree-refresh)
  (font-lock-mode -1))
```

### `octocat-file-mode`

`octocat-file-mode` derives from **`special-mode`** rather than
`magit-section-mode`.  There are no nested sections in a file viewer — the
content is a flat, fontified blob — so pulling in magit-section machinery
would add complexity for no benefit.  `special-mode` already provides
`buffer-read-only`, `q` → `quit-window`, and is the standard Emacs base for
read-only informational buffers.

```elisp
(defvar octocat-file-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map))
(define-key octocat-file-mode-map (kbd "C-c C-o") #'octocat-file-browse)
(define-key octocat-file-mode-map (kbd "o")        #'octocat-file-browse)
;; gr via sub-map — revert-buffer-function set in mode body

(define-derived-mode octocat-file-mode special-mode "Octocat-File"
  "Major mode for viewing a GitHub file."
  :group 'octocat
  (setq-local truncate-lines nil)
  (setq-local revert-buffer-function #'octocat-file-refresh))
```

Because `octocat-file-mode` no longer derives from `magit-section-mode`, it
does **not** need the `evil-get-auxiliary-keymap … t t` treatment; standard
`evil-define-key*` on `octocat-file-mode-map` is sufficient (same as
`octocat-mode` and `octocat-repo-mode`).  There is no `gr` two-key sequence
here, so the slot-divergence issue does not arise.

---

## Syntax Highlighting in `octocat-file-mode`

After decoding the base64 content, render it with syntax highlighting using
the same technique `octocat--insert-markdown` uses for markdown:

```elisp
(defun octocat-tree--fontify (path content)
  "Return CONTENT string with face properties from the appropriate major mode.
PATH is used only to select the mode via `auto-mode-alist'."
  (with-temp-buffer
    (insert content)
    (let ((buffer-file-name path))   ; trick auto-mode-alist
      (delay-mode-hooks (set-auto-mode)))
    (font-lock-ensure)
    (buffer-string)))                ; text + face properties
```

The propertized string is then inserted into the `octocat-file-mode` buffer
with a plain `(insert ...)`.

---

## `octocat-browse` Extension

Add `tree-file` and `tree-dir` section types to `octocat-browse` dispatch in
`octocat.el`:

```elisp
('tree-file
 (let* ((entry (oref section value))
        (path  (gethash "path" entry))
        (url   (format "https://github.com/%s/blob/%s/%s"
                       repo branch path)))
   (browse-url url)))
('tree-dir
 (let* ((entry (oref section value))
        (path  (gethash "path" entry))
        (url   (format "https://github.com/%s/tree/%s/%s"
                       repo branch path)))
   (browse-url url)))
```

Also add a major-mode fallback for `octocat-file-mode` and
`octocat-tree-mode`.

---

## `octocat-visit` Extension

`octocat-visit` in `octocat.el` gains two new responsibilities:

### 1. `octocat-action` text property — "Browse files" token

Before the section-type dispatch, check for the inline action property:

```elisp
(when (eq (get-text-property (point) 'octocat-action) 'browse-files)
  (octocat-tree-open)
  (cl-return-from octocat-visit nil))   ; or just use a (when …) guard
```

### 2. `tree-file` section type

```elisp
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
   ;; octocat-file-mode uses its own set of buffer-locals (not shared
   ;; with octocat-tree--* vars in octocat-tree-mode buffers)
   (setq octocat-tree--file-repo   repo
         octocat-tree--file-path   path
         octocat-tree--file-sha    sha
         octocat-tree--file-branch branch)
   (octocat-tree--render-file-loading path)
   (octocat-file-refresh)))
```

---

## Entry Point from `octocat-repo-mode`

### "Browse files" token on the repo header

The repo buffer heading (the `(octocat-root)` section heading rendered at the
top of `octocat-repo-mode`) is extended with a small RET-able token:

```
owner/repo  [Browse files]
```

The token is rendered with `mouse-face 'magit-section-highlight` and
`help-echo "RET: browse file tree"` — consistent with the interactivity
conventions in `docs/user-interface-conventions.md`.

Mechanically, the heading string passed to `magit-insert-heading` in
`octocat-repo--render` gains a trailing propertized span:

```elisp
(concat
 (propertize "owner/repo" 'face 'octocat-repo)
 "  "
 (propertize "[Browse files]"
             'face       'octocat-dimmed
             'mouse-face 'magit-section-highlight
             'help-echo  "RET: browse file tree"
             'octocat-action 'browse-files)   ; sentinel read by octocat-visit
 "\n")
```

`octocat-visit` checks for the `octocat-action` text property at point *before*
dispatching on section type — if `(get-text-property (point) 'octocat-action)`
is `'browse-files`, it calls `octocat-tree-open` directly.  This avoids adding
a dedicated `(browse-files)` section type for a single inline token.

### `T` keyboard shortcut

For users who prefer not to navigate to the token:

```elisp
(define-key octocat-repo-mode-map (kbd "T") #'octocat-tree-open)
```

### `octocat-tree-open`

```elisp
(defun octocat-tree-open ()
  "Open the file tree browser for the current octocat-repo buffer."
  (interactive)
  (unless (derived-mode-p 'octocat-repo-mode)
    (user-error "Not in an octocat-repo buffer"))
  (let* ((repo   octocat-repo--repo)
         (branch (or octocat-repo--current-branch
                     octocat-repo--default-branch
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
```

---

## Evil Keybindings (`octocat-evil.el`)

`octocat-tree-mode` derives from `magit-section-mode` and uses `gr`, so it
needs the `evil-get-auxiliary-keymap … t t` + `define-key` pattern, per the
AGENTS.md "evil-define-key* aux-keymap slot divergence" section.

`octocat-file-mode` derives from `special-mode` (no magit-section ancestry),
so `evil-define-key*` is safe and simpler — there is no pre-existing
`normal-state` slot in the parent to clash with.  There is also no `gr`
two-key binding, so no `g` → nil cleanup is needed.

```elisp
;; ── octocat-tree-mode ─────────────────────────────────────────────────
;; Derives from magit-section-mode: use evil-get-auxiliary-keymap t t.
(let ((aux   (evil-get-auxiliary-keymap octocat-tree-mode-map 'normal t t))
      (aux-m (evil-get-auxiliary-keymap octocat-tree-mode-map 'motion t t)))
  (define-key aux   (kbd "g")       nil)
  (define-key aux   (kbd "RET")     #'octocat-tree-visit)
  (define-key aux   (kbd "TAB")     #'octocat-tree-expand)
  (define-key aux   (kbd "C-c C-o") #'octocat-tree-browse)
  (define-key aux   (kbd "o")       #'octocat-tree-browse)
  (define-key aux   (kbd "q")       #'quit-window)
  (define-key aux   (kbd "gr")      #'octocat-tree-refresh)
  (define-key aux-m (kbd "RET")     #'octocat-tree-visit))

;; ── octocat-file-mode ─────────────────────────────────────────────────
;; Derives from special-mode (not magit-section-mode): evil-define-key* is safe.
(evil-define-key* 'normal octocat-file-mode-map
  (kbd "C-c C-o") #'octocat-file-browse
  (kbd "o")       #'octocat-file-browse
  (kbd "q")       #'quit-window
  (kbd "gr")      #'octocat-file-refresh)
(evil-define-key* 'motion octocat-file-mode-map
  (kbd "gr")      #'octocat-file-refresh)
```

Also add `declare-function` stubs and `defvar` forward declarations for the
new symbols at the top of `octocat-evil.el`.

---

## Affected Files

| File | Change |
|---|---|
| **`octocat-tree.el`** | **New file** — all tree/file mode code |
| `octocat-repo.el` | Add `T` keybinding; `(require 'octocat-tree)` |
| `octocat.el` | Add `(require 'octocat-tree)`; extend `octocat-visit` + `octocat-browse` with new section types and mode fallbacks |
| `octocat-evil.el` | Add evil bindings for both new modes; add `declare-function` + `defvar` stubs |
| `AGENTS.md` | Add `octocat-tree.el` to reload sequence and `unload-feature` list |
| `test/octocat-tests.el` | Add smoke tests for new fetch helpers and render functions |

---

## Caching

The subtree cache (`octocat-tree--subtree-cache`) is **session-only**
(buffer-local, no disk persistence).  The root tree and all subtree entries
live only for the lifetime of the `*octocat-tree: …*` buffer.  Disk caching
of tree data is explicitly out of scope for this plan — repository trees can
be large and change frequently, making disk cache benefit marginal.

---

## Out of Scope

- **Branch/ref picker** — the tree always opens on the default branch (or
  current branch from the repo buffer).  The branch is displayed prominently
  in both the tree and file buffer headings so the user always knows which ref
  they are on.  A `b` binding to switch refs can be added later; the
  buffer-local `octocat-tree--branch` is already designed to support it.
- Searching / filtering the tree.
- Download of binary files (show a "binary file" notice and offer `o` to open in browser).
- Disk caching of tree data.
- Pagination (GitHub's Trees API returns up to 100,000 items in a single recursive call; at depth-1 per dir this is never a concern).
- Editing files via the tree browser.

---

## Implementation Order

Steps are sequential.

1. **`octocat-tree.el` — scaffold**: create the file with both mode definitions,
   buffer-local vars, and stub bodies for all functions (so the file compiles
   cleanly).  Wire `octocat-repo.el` `T` binding and `octocat.el` requires.
   Run `make ci` — should pass with no new errors.

2. **Root tree fetch + initial render**: implement
   `octocat-tree--fetch-root-sha`, `octocat-tree--fetch-dir`,
   `octocat-tree--render-loading`, `octocat-tree--render`.  After this step,
   opening the tree buffer shows the root level (dirs collapsed, files as
   leaves).

3. **Lazy expand**: implement `octocat-tree-expand` with the
   full-buffer-refresh-from-cache approach.  After this step, `TAB` on a dir
   fetches and shows its children; subsequent `TAB` presses toggle without
   re-fetching.

4. **File viewer**: implement `octocat-tree--fetch-file`,
   `octocat-tree--render-file-loading`, `octocat-tree--render-file`,
   `octocat-tree--fontify`, `octocat-file-refresh`, and the `octocat-visit`
   `tree-file` dispatch.  After this step, `RET` on a file opens its content.

5. **Browse support**: extend `octocat-browse` in `octocat.el` with `tree-file`,
   `tree-dir`, and mode fallbacks.

6. **Evil bindings**: add the two new binding blocks to `octocat-evil.el`.

7. **Tests**: add smoke tests to `test/octocat-tests.el`.

8. **Docs**: update `AGENTS.md` reload sequence; update `README.md`.

9. **Final `make ci`**: resolve any remaining byte-compiler warnings.
