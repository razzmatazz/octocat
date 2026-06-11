# Agent Instructions

See [README.md](README.md) for full project documentation.
See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions.
See [docs/magit-section.md](docs/magit-section.md) for magit-section usage, gotchas, and patterns.

## Rules

- **Never commit or modify git state.** The developer handles all commits.
- **Always run `make ci`** (compile + lint + test) after making changes. Fix all errors and warnings before finishing.

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

## Reloading into Emacs

After editing, use the `emacs__eval-elisp` MCP tool to reload **all** `octocat*.el` files — not just the ones changed. Use `load-file` (not `require`, so files are re-evaluated even if already loaded). Load order matters: `octocat-core.el` must be loaded before the rest.

**Always delete `.elc` files before reloading.** Emacs prefers compiled files over source, so stale `.elc` files will silently shadow your edits. Use `make clean` to remove them.

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


