# Agent Instructions

See [README.md](README.md) for full project documentation.
See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions.
See [docs/magit-section.md](docs/magit-section.md) for magit-section usage, gotchas, and patterns.
See [docs/user-interface-conventions.md](docs/user-interface-conventions.md) for UI conventions: how to signal interactivity, `mouse-face`/`help-echo` patterns, and the decision table for RET-able sections vs inline buttons.

## Rules

- **Never commit or modify git state.** The developer handles all commits.
- **Always run `make ci`** (compile + lint + test) after making changes. Fix all errors and warnings before finishing.
- **Only call functions from declared dependencies.** The declared deps are in the `Package-Requires` header of `octocat.el`. Do not call into magit internals, transient internals, or any other package not listed there — even when taking inspiration from them. Re-implement the idea in plain Elisp instead.
- **Always use the provided file-editing tools for source edits.** Never use any other mechanism — shell commands (`sed`, `awk`, `tee`, etc.), `emacs__eval-elisp`, or anything else — to modify source files. Those bypass match-verification, make changes invisible to the diff, and risk corrupting file structure.

## Sub-agent parallelism

**Do not spawn multiple sub-agents that perform edits or run `make ci` concurrently.**
Both resources are singletons:

- **`make ci`** runs compile, lint, and tests inside a shared container.  Two
  parallel runs stomp on each other's `.elc` output, produce interleaved
  stderr, and make it impossible to attribute failures to a specific change.
- **The Emacs environment** (via `emacs__eval-elisp`) is a single live
  process.  Concurrent agents reloading files or querying buffer state will
  race, producing misleading results or corrupting the session.

Work sequentially: make all edits first (parallel read-only exploration is
fine), then reload into Emacs once, then run `make ci` once.  Only spawn
parallel sub-agents for **pure research / read-only** tasks.

## Checking paren structure

Before reloading or running `make ci`, use `tools/el-outline.py` to verify
the parenthesis structure of any `.el` file you have edited:

```bash
python3 tools/el-outline.py octocat-run.el octocat-workflow.el
```

The script prints an indented outline of every top-level form with its line
range, then exits 1 if any file is unbalanced.  Two markers flag problems:

- **`← UNCLOSED`** — a form with no matching `)` before EOF; the next
  top-level forms will appear as its children.
- **`← SPANS INTO NEXT FORM`** — a multi-line form whose closing line
  reaches the opening line of the next sibling, indicating a missing `)`.

This catches the class of bug where removing an expression (e.g.
`(goto-char (point-min))`) accidentally strips one of the surrounding
closing parens, silently swallowing subsequent `defun`s.

Run with `--depth N` to expand more nesting levels (default 4).  No
arguments processes all `*.el` files in the current directory.

When the outline flags a problem, four targeted sub-commands help find the
exact broken line:

**`--trace DEFUN`** — prints every source line of the named top-level form
with a running depth counter.  Now skips `declare-function` stubs and finds
the actual `defun`/`defvar` definition:

```bash
python3 tools/el-outline.py --trace octocat--render-prs octocat.el
```

**`--trace-line N`** — like `--trace` but selects whichever top-level form
*contains* line N.  Use this when the form has no distinct name, or when
`--trace` still resolves to the wrong occurrence:

```bash
python3 tools/el-outline.py --trace-line 274 octocat-commit.el
```

**`--depth-at N`** — shows the absolute paren depth at each line in a
±10-line window around N, then lists every form that is still open at that
line (innermost last).  Answers the question *"what is unclosed going into
line N?"*:

```bash
python3 tools/el-outline.py --depth-at 149 octocat-commit.el
```

**`--close-map --lines A-B`** — for every `)` in the given line range,
prints which `(` it closes, at what depth, and the head token of the opening
form.  Highlights closings that reach depth 0 (top-level) unexpectedly.  Use
this to find the `)` that is doing "double duty" — closing two forms at once
because a `)` is missing above it:

```bash
python3 tools/el-outline.py --close-map --lines 145-155 octocat-commit.el
```

## Reloading into Emacs

Use `emacs__eval-elisp` to reload **all** `octocat*.el` files after every
edit.  **Issue one `emacs__eval-elisp` call per phase** — `dolist` returns
`nil`, so a single call with multiple phases returns `nil` whether it
succeeded or crashed; splitting makes failures attributable.

Load order: `octocat-core.el` first (everything depends on it);
`octocat-evil.el` before `octocat.el` (the last lines of `octocat.el` call
`octocat-evil-setup`, and `require` is a no-op on an already-provided
feature, so a stale evil file silently wins).

**Call 1 — kill display buffers** (stale keymaps stick to live buffers):
```elisp
(dolist (buf (buffer-list))
  (when (string-match-p "\\*octocat" (buffer-name buf))
    (kill-buffer buf)))
"display-buffers-killed"
```

**Call 2 — kill visited source buffers and delete `.elc` files**
(`insert-file-contents` prefers the visited buffer over disk; `.elc` shadows
source; `make ci` recreates `.elc`, so always delete even after a CI run):
```elisp
(dolist (f (directory-files "/Users/bob/src/octocat" t "\\.el$"))
  (let ((buf (find-buffer-visiting f)))
    (when buf (kill-buffer buf))))
(dolist (f (directory-files "/Users/bob/src/octocat" t "\\.elc$"))
  (delete-file f))
"source-buffers-killed-elc-deleted"
```

**Call 3 — load all files** (returns an alist; any entry whose value is a
string rather than `ok` is an error — fix it before proceeding):
```elisp
(let (results)
  (dolist (f (list "octocat-core.el" "octocat-edit.el" "octocat-commit.el"
                   "octocat-job.el" "octocat-run.el" "octocat-workflow.el"
                   "octocat-pr-diff.el" "octocat-pr.el" "octocat-issue.el"
                   "octocat-checks.el" "octocat-tree.el" "octocat-repo.el"
                   "octocat-evil.el" "octocat.el"))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents (expand-file-name f "/Users/bob/src/octocat"))
          (emacs-lisp-mode)
          (eval-buffer)
          (push (cons f 'ok) results))
      (error (push (cons f (error-message-string err)) results))))
  (nreverse results))
```

**Call 4 — verify a changed function is live** (returns byte offset or `nil`):
```elisp
(string-search "some-token"
               (format "%s" (symbol-function 'some-fn)))
```

**`makunbound` mode-map vars when keymaps change.** `defvar` skips
re-initialisation if the variable is already bound, so new bindings are
silently ignored on reload. Unset affected maps first (guard with `boundp`
or `ignore-errors` — `makunbound` on a void symbol signals an error):
```elisp
(ignore-errors (makunbound 'octocat-pr-mode-map))
;; … then proceed with Call 1–4 above
```

**Do not use `unload-feature`.** It cascade-unloads `markdown-mode`, leaving
dangling advice and repeated `jit-lock` errors. The `with-temp-buffer` +
`eval-buffer` sequence re-evaluates every `defun`/`defvar` without it.

## evil-define-key* aux-keymap slot divergence

`magit-section-mode`'s own evil integration calls `evil-define-key*` (and
registers `evil-collection` bindings) for its mode map **before**
`octocat-evil-setup` runs.  This means each octocat mode map that derives
from `magit-section-mode` already contains several `normal-state` entries
— distinct keymap objects — in its keymap vector by the time
`octocat-evil-setup` is called.

`evil-get-auxiliary-keymap MAP STATE t` returns the *first* such entry
(creating a new one if none exists).  `evil-define-key*`, however, creates
its bindings in a *different* aux keymap slot — one added at the tail of the
mode-map chain.  When there are already pre-existing `normal-state` slots,
these two objects diverge: the slot found by `evil-get-auxiliary-keymap`
wins in lookup order and **silently shadows** anything written by
`evil-define-key*` into its own slot.

The symptom is a binding (typically `RET`) that appears correctly set when
inspected via `evil-get-auxiliary-keymap` + `lookup-key`, but resolves to
the wrong command (e.g. `evil-ret`) at runtime via `key-binding`.

**The fix — use `define-key` directly on the keymap returned by
`evil-get-auxiliary-keymap`.**  Retrieve the aux keymaps once per mode, then
call `define-key` on them for every binding, including the `g`-prefix
cleanup.  Do **not** follow the `let`-block-for-g + separate
`evil-define-key*`-for-everything-else split; that pattern recreates the
divergence:

```elisp
;; CORRECT — all bindings in the same let block via define-key
(let ((aux   (evil-get-auxiliary-keymap octocat-pr-mode-map 'normal t))
      (aux-m (evil-get-auxiliary-keymap octocat-pr-mode-map 'motion t)))
  (define-key aux   (kbd "g")       nil)           ; clear stale g prefix
  (define-key aux   (kbd "RET")     #'octocat-visit)
  (define-key aux   (kbd "o")       #'octocat-browse)
  (define-key aux   (kbd "C-c C-o") #'octocat-browse)
  (define-key aux   (kbd "q")       #'quit-window)
  (define-key aux   (kbd "gr")      #'octocat-pr-refresh)
  (define-key aux-m (kbd "RET")     #'octocat-visit))

;; BROKEN — evil-define-key* writes RET into a different slot
(let ((aux (evil-get-auxiliary-keymap octocat-pr-mode-map 'normal t)))
  (define-key aux (kbd "g") nil))
(evil-define-key* 'normal octocat-pr-mode-map
  (kbd "RET")  #'octocat-visit   ; ← silently shadowed at runtime
  (kbd "o")    #'octocat-browse)
```

**Modes affected:** any mode that derives from `magit-section-mode` and uses
`gr` (or another `g`-prefixed two-key binding) — which requires the
`define-key aux (kbd "g") nil` cleanup.  Currently: `octocat-pr-mode`,
`octocat-commit-mode`, `octocat-issue-mode`, `octocat-pr-diff-mode`,
`octocat-workflow-mode`, `octocat-run-mode`, `octocat-job-mode`.

`octocat-mode` and `octocat-repo-mode` do **not** use `gr`, so they have no
pre-existing `normal-state` slot conflict and `evil-define-key*` is safe for
them.

### Gotcha — `evil-get-auxiliary-keymap` returns the *parent*'s aux keymap without `IGNORE-PARENT`

`evil-get-auxiliary-keymap MAP STATE &optional CREATE IGNORE-PARENT` scans
MAP's keymap alist for a slot whose prompt matches the state name.  Because
child mode maps inherit their parent's alist entries (via `set-keymap-parent`),
the *parent*'s `normal-state` slot appears **before** any child-owned slot.
Calling `(evil-get-auxiliary-keymap child-map 'normal t)` therefore returns
the `magit-section-mode-map` aux keymap, not a fresh child-specific one.

Every subsequent `define-key` call then mutates this shared parent keymap.
The bindings accumulate across all child modes — the last mode's `c`, `+`,
`RET`, and `gr` all end up in `magit-section-mode-map`'s normal-state aux —
and bleed into **every** buffer whose keymap chain passes through
`magit-section-mode`, including plain `magit-status` buffers.

The symptom is user-facing errors like `Octocat: Buffer is not associated
with an issue` when pressing `c` in a regular Magit buffer.

**The fix — always pass `t t` (CREATE + IGNORE-PARENT) for child modes.**
The fourth argument forces `evil-get-auxiliary-keymap` to create a new keymap
owned by the child map, bypassing the inherited parent slot:

```elisp
;; CORRECT — IGNORE-PARENT t ensures a child-owned aux keymap
(let ((aux   (evil-get-auxiliary-keymap octocat-pr-mode-map 'normal t t))
      (aux-m (evil-get-auxiliary-keymap octocat-pr-mode-map 'motion t t)))
  (define-key aux   (kbd "RET") #'octocat-visit)
  ...)

;; BROKEN — returns magit-section-mode-map's shared aux keymap
(let ((aux (evil-get-auxiliary-keymap octocat-pr-mode-map 'normal t)))
  (define-key aux (kbd "RET") #'octocat-visit))  ; ← mutates parent!
```

This applies to **all** octocat child modes (pr, commit, pr-diff, issue,
workflow, run, job) for both `'normal` and `'motion` states.  The `octocat-mode`
and `octocat-repo-mode` maps do not derive from `magit-section-mode`, so they
are unaffected and continue to use `evil-define-key*` directly.

## Byte-compiler warnings about functions "not known to be defined"

`make ci` compiles all files in parallel.  The compiler warns "the function
`foo' is not known to be defined" when it sees a call to `foo` in file A
before it has compiled file B (which defines `foo`).  This warning is
non-deterministic — it may appear in some runs and not others depending on
scheduling.

**Fix: add `declare-function` in the calling file.**  When file A calls a
function defined in file B (which A cannot `require` due to circular-load
constraints), suppress the warning by adding a `declare-function` near the
top of A, alongside the other declarations:

```elisp
(declare-function octocat-commit-mode    "octocat-commit" ())
(declare-function octocat-commit-refresh "octocat-commit" (&optional _ignore-auto _noconfirm))
```

The `declare-function` form tells the byte-compiler the function exists
without actually loading the file.  At runtime all files are already loaded
by `octocat.el`, so there is no actual missing-definition risk.


