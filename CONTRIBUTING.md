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

### Collapsing magit sections by default

The `HIDE` argument to `magit-insert-section` sets the `hidden` slot on the
section object but does **not** apply the hiding overlay to the buffer text.
As a result, sections appear expanded on first render, and TAB must be pressed
twice to collapse them (the first press calls `magit-section-show` because
`hidden` is already `t`; the second finally calls `magit-section-hide`).

To correctly collapse a section on creation, wrap the `magit-insert-section`
call with `magit-section-hide`, which applies the overlay immediately after
the section's end-marker is set:

```elisp
(magit-section-hide
 (magit-insert-section (my-section value)
   (magit-insert-heading ...)
   (insert ...)))
```
