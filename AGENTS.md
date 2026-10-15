# Agent Instructions

See [README.md](README.md) for full project documentation.
See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions.
See [docs/user-interface-conventions.md](docs/user-interface-conventions.md) for UI conventions: how to signal interactivity, `mouse-face`/`help-echo` patterns, and the decision table for RET-able sections vs inline buttons.
See [docs/using-vui.md](docs/using-vui.md) for vui.el gotchas, e.g. updating a page in place instead of remounting it.
See "Functional core" in [CONTRIBUTING.md](CONTRIBUTING.md): keep functions as functional as possible, with context (e.g. width) passed in as arguments and side effects confined to commands and effects.

## Rules

- **Never commit or modify git state.** The developer handles all commits.
- **Always run `make ci`** (compile + lint + test) after making changes. Fix all errors and warnings before finishing.
- **Only call functions from declared dependencies.** The declared deps are in the `Package-Requires` header of `octocat.el`. Do not call into magit internals, transient internals, or any other package not listed there — even when taking inspiration from them. Re-implement the idea in plain Elisp instead.
- **Keep docs and comments minimal.** Say only what the code doesn't: the why, the non-obvious. Short, but complete enough to understand.
- **Never modify source files through Emacs** (`emacs__eval-elisp`, buffer edits, `save-buffer`, etc.); it risks a live buffer and the file on disk drifting apart. Use the file-editing tools or any shell tool (`sed`, Python, etc.).

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

Load order: `octocat-mermaid.el` first (standalone), then
`octocat-markdown.el` (requires it; `octocat-core.el` requires that), then
`octocat-core.el` (everything else depends on it), then `octocat-vui.el`
and `octocat-diff.el` (which the commit and PR diff pages require);
`octocat-evil.el` before `octocat.el` (the last lines of `octocat.el` call
`octocat-evil-setup`, and `require` is a no-op on an already-provided
feature, so a stale evil file silently wins).

**Do not kill the user's buffers by default.**  Calls 1 and 2 close their
open octocat buffers and visited source files, which loses their place.
Run only Call 3 (and Call 4 to verify) unless killing is actually
necessary, and tell the user to `gr` any already-open buffer to re-render
it with the new code.  Kill buffers only when the change would otherwise
not take effect, e.g.:

- a keymap or `evil` binding changed (stale keymaps stick to live
  buffers; also `makunbound` the affected map, see below);
- a source buffer is visited and stale on disk, or a stale `.elc`
  shadows the source (Call 2).

Mention in the final reply whether you killed anything and why.

**Call 1 — kill display buffers** (only when necessary, see above; stale
keymaps stick to live buffers):
```elisp
(dolist (buf (buffer-list))
  (when (string-prefix-p "octocat-"
                         (symbol-name (buffer-local-value 'major-mode buf)))
    (kill-buffer buf)))
"display-buffers-killed"
```

**Call 2 — kill visited source buffers and delete `.elc` files**
(only when necessary, see above; `insert-file-contents` prefers the visited buffer over disk; `.elc` shadows
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
  (dolist (f (list "octocat-mermaid.el" "octocat-markdown.el"
                   "octocat-core.el" "octocat-vui.el" "octocat-diff.el"
                   "octocat-edit.el"
                   "octocat-commit.el" "octocat-job.el" "octocat-run.el"
                   "octocat-workflow.el" "octocat-pr-diff.el"
                   "octocat-timeline.el" "octocat-pr.el" "octocat-issue.el"
                   "octocat-checks.el" "octocat-tree.el" "octocat-repo.el"
                   "octocat-actions.el" "octocat-search.el" "octocat-avatar.el"
                   "octocat-user.el" "octocat-evil.el" "octocat.el"))
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

**Do not use `unload-feature`.** It cascade-unloads dependent features,
leaving dangling advice and repeated `jit-lock` errors. The `with-temp-buffer` +
`eval-buffer` sequence re-evaluates every `defun`/`defvar` without it.

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
without actually loading the file.  At runtime, every `;;;###autoload`
entry point (`M-x octocat`, `M-x octocat-repo`, ...) is defined in
`octocat.el` itself (see "Entry points" in CONTRIBUTING.md), and
`octocat.el` unconditionally `require`s every other file — so any code path
a user can actually reach guarantees all files are loaded, and there is no
missing-definition risk. This is a structural guarantee, not just an
assumption: no other file is allowed to carry its own `;;;###autoload`
command, precisely so a second, independent load path (bypassing
`octocat.el`) can never exist. See `plans/repo-mode-evil-ret-binding.md`
for the bug this convention was introduced to fix (an Evil keybinding
trigger that only ran when `octocat.el` happened to be loaded first).


