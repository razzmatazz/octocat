# Contributing to octocat.el

## Code conventions

### Indicating loading / async activity

Use the buffer-local `mode-line-process` variable to indicate that a
background operation is in flight.  Set it to a short string (e.g.
`" [refreshing…]"`) when async calls start; clear it to `nil` when they
complete.  Do not erase or replace existing buffer content just to show a
loading state — keep stale content visible and let `mode-line-process` signal
that fresh data is on its way.

### Refresh and disk cache

This pattern applies to all octocat views — dashboard, PR detail, issue
detail, and others as they grow.  Each view caches its last successful fetch
to disk as a pretty-printed JSON file under `octocat-cache-directory`.  The
refresh flow is the same everywhere:

1. **Load cache** — if a file exists for the current key (repo, item number,
   filter values, etc.), render it immediately so the buffer is never blank
   on re-open.
2. **Always fetch** — kick off background `gh` calls and show
   `" [refreshing…]"` in `mode-line-process`.
3. **On arrival** — render fresh data, write updated cache file, clear
   `mode-line-process`.

Cache is only written on a fully successful result — errors and
disabled-feature responses are not persisted.

Cache file naming: sanitize all key components (repo slug, PR/issue number,
filter values) to filesystem-safe strings and join them.  Files are JSON so
they can be inspected directly.  Do **not** hardcode
`~/.config/emacs/.local/cache` — that is Doom-specific.  Use
`(locate-user-emacs-file "octocat/cache/")` as the default, exposed via
`defcustom octocat-cache-directory`.

### magit-section

See [docs/magit-section.md](docs/magit-section.md) for the section tree
structure, hiding/collapsing gotchas, and the correct patterns for preserving
collapse state across refreshes.
