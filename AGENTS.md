# Agent Instructions

See [README.md](README.md) for full project documentation.
See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions.
See [docs/magit-section.md](docs/magit-section.md) for magit-section usage, gotchas, and patterns.
See [docs/user-interface-conventions.md](docs/user-interface-conventions.md) for UI conventions: how to signal interactivity, `mouse-face`/`help-echo` patterns, and the decision table for RET-able sections vs inline buttons.

## Rules

- **Never commit or modify git state.** The developer handles all commits.
- **Always run `make ci`** (compile + lint + test) after making changes. Fix all errors and warnings before finishing.
- **Only call functions from declared dependencies.** The declared deps are in the `Package-Requires` header of `octocat.el`. Do not call into magit internals, transient internals, or any other package not listed there — even when taking inspiration from them. Re-implement the idea in plain Elisp instead.

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

After editing, use the `emacs__eval-elisp` MCP tool to reload **all** `octocat*.el` files — not just the ones changed. Use `load-file` (not `require`, so files are re-evaluated even if already loaded). Load order matters:

- `octocat-core.el` must be first (everything depends on it).
- `octocat-evil.el` must come **before** `octocat.el`. The last lines of `octocat.el` call `octocat-evil-setup`; if `octocat-evil.el` has not been `load-file`d yet the old definition runs silently. `require` inside `octocat--evil-init` is a no-op when the feature is already provided, so failing to explicitly `load-file` `octocat-evil.el` means evil keybinding changes are never applied — buffers look correct but keys do nothing.

The canonical reload sequence is:

```elisp
(dolist (buf (buffer-list))
  (when (string-match-p "\\*octocat" (buffer-name buf))
    (kill-buffer buf)))
(dolist (f (directory-files "/path/to/octocat" t "\\.elc$"))
  (delete-file f))
(load-file "octocat-core.el")
(load-file "octocat-edit.el")
(load-file "octocat-commit.el")
(load-file "octocat-job.el")
(load-file "octocat-run.el")
(load-file "octocat-workflow.el")
(load-file "octocat-pr-diff.el")
(load-file "octocat-pr.el")
(load-file "octocat-issue.el")
(load-file "octocat-checks.el")
(load-file "octocat-repo.el")
(load-file "octocat-evil.el")   ; ← before octocat.el
(load-file "octocat.el")
```

**Always delete `.elc` files before reloading.** Emacs prefers compiled files over source, so stale `.elc` files will silently shadow your edits. Use `make clean` to remove them.

> **Gotcha — `make ci` recreates `.elc` files.**  The compile step inside
> `make ci` writes fresh `.elc` files into the workspace.  If you run
> `make ci` and then reload without running `make clean` first, Emacs will
> load the compiled versions and your latest source edits will have no
> effect.  The symptom is a change that appears to do nothing in the live
> buffer even though the source file is correct.  Always run `make clean`
> immediately before every `load-file` reload, regardless of whether
> `make ci` was run in between.

**Always kill existing octocat buffers before reloading.** Mode keymaps are defined with `defvar`, which only initialises on first load. Existing buffers capture the old keymap object at mode-activation time and will not pick up new bindings even after a reload. Kill all live octocat buffers first so fresh ones are created against the new keymaps:

```elisp
(dolist (buf (buffer-list))
  (when (string-match-p "\\*octocat" (buffer-name buf))
    (kill-buffer buf)))
```

**`makunbound` mode-map vars when keymaps change.** If you add or remove keybindings inside a `defvar MODE-map …` form, `defvar` will silently skip re-initialisation on subsequent reloads because the variable is already bound. Unset the affected map variables first, then reload:

```elisp
(makunbound 'octocat-pr-mode-map)
(makunbound 'octocat-issue-mode-map)
;; … then load-file as usual
```

> **Gotcha — `makunbound` on a void symbol raises an error.** If the
> variable is already void (e.g. it was cleared by a previous `makunbound`
> call or by `unload-feature`), calling `makunbound` again signals
> `Symbol's value as variable is void`.  Always guard it:
>
> ```elisp
> (when (boundp 'octocat-pr-mode-map)
>   (makunbound 'octocat-pr-mode-map))
> ```
>
> Or use `ignore-errors`.

**Prefer `unload-feature` over `makunbound` for full reloads.** The `makunbound` + `load-file` pattern has a subtle failure mode: `load-file` re-evaluates the file and calls `(provide 'octocat-FOO)`, but if the feature was never removed from `features`, any transitive `(require 'octocat-FOO)` inside other files will be a no-op — which means `defvar` forms in that file never re-run after a `makunbound`.  The safest approach for a full reload is to `unload-feature` every octocat package in **reverse dependency order** first, so all `defvar` and `defun` forms run fresh:

```elisp
;; 1. Kill buffers and .elc files as usual.
;; 2. Unload in reverse load order (most-dependent first):
(ignore-errors (unload-feature 'octocat t))
(ignore-errors (unload-feature 'octocat-repo t))
(ignore-errors (unload-feature 'octocat-evil t))
(ignore-errors (unload-feature 'octocat-checks t))
(ignore-errors (unload-feature 'octocat-issue t))
(ignore-errors (unload-feature 'octocat-pr t))
(ignore-errors (unload-feature 'octocat-pr-diff t))
(ignore-errors (unload-feature 'octocat-workflow t))
(ignore-errors (unload-feature 'octocat-run t))
(ignore-errors (unload-feature 'octocat-job t))
(ignore-errors (unload-feature 'octocat-commit t))
(ignore-errors (unload-feature 'octocat-edit t))
(ignore-errors (unload-feature 'octocat-core t))
;; 3. Then load-file in normal order as usual.
```

Use `ignore-errors` on each `unload-feature` call so that features which
are not currently loaded don't abort the sequence.

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


