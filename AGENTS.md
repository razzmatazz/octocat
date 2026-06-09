# Agent Instructions

See [README.md](README.md) for full project documentation.
See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions.

## Rules

- **Never commit or modify git state.** The developer handles all commits.
- **Always run `make ci`** (compile + lint + test) after making changes. Fix all errors and warnings before finishing.

## Reloading into Emacs

After editing, use the `emacs__eval-elisp` MCP tool to reload **all** `octocat*.el` files — not just the ones changed. Use `load-file` (not `require`, so files are re-evaluated even if already loaded). Load order matters: `octocat-core.el` must be loaded before the rest.

**Always delete `.elc` files before reloading.** Emacs prefers compiled files over source, so stale `.elc` files will silently shadow your edits. Use `make clean` to remove them.


