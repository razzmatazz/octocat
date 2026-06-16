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

### Indicating interactivity in the UI

See [docs/user-interface-conventions.md](docs/user-interface-conventions.md)
for how to signal that a section heading or inline value is RET-able:
`mouse-face`, `help-echo` wording, when to use `buttonize`, and the decision
table for each situation.

### Evil keybindings

Evil bindings for all octocat modes live in `octocat-evil.el` and are
installed by `octocat-evil-setup`.

**Always use `evil-get-auxiliary-keymap` with `t t` (CREATE + IGNORE-PARENT)
for modes that derive from `magit-section-mode`**, then call `define-key` on
the returned keymap for every binding:

```elisp
(let ((aux   (evil-get-auxiliary-keymap octocat-issue-mode-map 'normal t t))
      (aux-m (evil-get-auxiliary-keymap octocat-issue-mode-map 'motion t t)))
  (define-key aux (kbd "RET") #'octocat-visit)
  ...)
```

Without the fourth `t`, `evil-get-auxiliary-keymap` walks up the keymap
inheritance chain and returns the *parent* (`magit-section-mode-map`) aux
keymap.  Writing into it mutates a shared object and bleeds octocat bindings
into every Magit buffer.  See AGENTS.md — *"evil-define-key\* aux-keymap slot
divergence"* and its sub-section *"Gotcha — evil-get-auxiliary-keymap returns
the parent's aux keymap without IGNORE-PARENT"* — for the full explanation.
