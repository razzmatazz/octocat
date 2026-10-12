# Contributing to octocat.el

## AI-assisted code

Using AI to assist in writing code or opening pull requests is fine, but the
human author should be the first and most thorough reviewer of any such
output.  Please help track AI assistance by adding a
[Linux-style `Assisted-by:` line](https://docs.kernel.org/process/coding-assistants.html#attribution)
immediately after the `Author:` header (or `Copyright` line in sub-files that
omit `Author:`):

```elisp
;; Author: Your Name <you@example.com>
;; Assisted-by: Claude:claude-sonnet-4-6
```

`AGENT_NAME` is the product name (e.g. `Claude`) and `MODEL_VERSION` is the
specific model (e.g. `claude-sonnet-4-6`).  This convention follows
[MELPA's attribution spec](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org).

## Code conventions

### Entry points (`;;;###autoload` commands)

**All `;;;###autoload` / `M-x`-invokable commands must be defined in
`octocat.el`**, even when the mode/logic they open lives elsewhere — e.g.
`octocat-repo` is a thin wrapper in `octocat.el` that calls into
`octocat-repo-mode` and friends, defined in `octocat-repo.el`.

`octocat.el` is the only file every other file omits requiring (to avoid
circularity), so it's the only file that can assume everything else is
loaded — including its own bottom-of-file `octocat--evil-init` trigger,
which wires up Evil keybindings. A second autoloaded command elsewhere
could be invoked first, in a session where that trigger never ran, leaving
Evil bindings unset. See AGENTS.md's "Byte-compiler warnings" section for
the related loaded-by-`octocat.el` invariant.

When adding a new entry point: define the `;;;###autoload` command in
`octocat.el` alongside `octocat`/`octocat-repo`; put the mode, keymap, and
supporting logic in its own `octocat-<feature>.el` file; and make sure
`octocat.el` `require`s that file.

### Indicating loading / async activity

Use the buffer-local `mode-line-process` variable to indicate that a
background operation is in flight: `(octocat-vui-mode-line-busy ":loading")`,
Emacs's `(Mode:run)` style plus a spinner (vui pages:
`octocat-vui-use-mode-line-loading`).  Clear it to `nil`
when the calls complete.  Do not erase or replace existing buffer content just to show a
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
   `:loading` in `mode-line-process`.
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

### UI framework: vui.el

Every buffer is rendered with vui.el: the dashboard (`octocat-mode`), the
repo overview (`octocat-repo.el`, `octocat-repo-mode`), the user page
(`octocat-user-mode`), the PR, issue, PR diff, commit, checks, workflow,
run and job detail views (`octocat-pr-mode`, `octocat-issue-mode`,
`octocat-pr-diff-mode`, `octocat-commit-mode`, `octocat-checks-mode`,
`octocat-workflow-mode`, `octocat-run-mode`, `octocat-job-mode`; PR diff
and commit share `octocat-diff.el`), the file tree and file log
(`octocat-tree-mode`, `octocat-file-log-mode`) and the PR and issue list
pages and the Actions page (`octocat-pr-list-mode`,
`octocat-issue-list-mode`, defined next to the matching detail views, and
`octocat-actions-mode` in `octocat-actions.el`; all derive from
`octocat-vui-list-mode`).  The issue and PR views are GitHub-style
timelines of the opening post, comments and events; what point is on is
carried by a text property (e.g. `octocat-issue-target`).  The repo
overview is a dashboard of independent async sections, each with its own
fetch (`vui-use-async`), pagination counter (`:state`) and collapse state
(`vui-collapsible`).

Generic, repo-agnostic vui helpers (the RET-able `octocat-vui-row`,
`octocat-vui-use-async-sticky`, `octocat-vui-load-more-button`) live in
`octocat-vui.el`; buffer-specific vui code stays in that buffer's file.
Put new reusable vui hooks/components there, and keep them free of GitHub
knowledge.

vui.el gotchas:

- `vui-collapsible` indents only the **first** body line (default `:indent
  2`).  Rows here carry their own two-space prefix, so every collapsible
  passes `:indent 0`; otherwise the first row is indented by four spaces.
- Rows use `vui-text` inside a `vui-region` (not `vui-button`) so per-segment
  faces are preserved; see "Row rendering" in `octocat-repo.el`.
- Every repeating timer goes through `octocat-vui-use-timer`, never a bare
  `run-with-timer`.  It ties the timer to the component: it is cancelled
  when the component unmounts or the hook's dependencies change, when the
  callback returns nil (done), and when the callback signals, so a broken
  frame is reported once instead of on every tick.  A callback that sets
  state to the value it already has does not re-render, so a timer that
  only stopped on a re-render would run forever: return nil instead.

### Functional core

Write functions to be as functional as possible: take everything they
need as arguments and return a value, rather than reading ambient state
(windows, the current buffer, buffer-local or global variables) or
changing it.  Keep the core body of the code functional, and push side
effects out to a thin layer of commands, effects and async callbacks.
Prefer a required argument to an optional one that falls back to ambient
state.

In particular, render code (vui components, memo bodies, section
inserters) and library modules (markdown, mermaid, avatar, timeline) must
not select windows or frames, move point other than by inserting, or
change global state, and must not prompt or `sit-for`.  Side effects
belong in commands and `vui-use-effect`.

vui re-renders from timers, often while the buffer sits in an unselected
window.  Selecting that window resets the buffer's point mid-render and
scrambles the page.  That happened via `window-max-chars-per-line`, which
selects the window internally.  So read window state once in the page
component and pass it down, e.g. `(octocat--markdown-width)` into
`octocat-timeline-entries`.  Wrap any window query that might select a
window in `save-excursion`.

### Dependencies

Runtime dependencies are exactly those in the `Package-Requires` header of
`octocat.el`, and the `Eask` file must list the same set.  Only call functions
from declared dependencies.

`vui` comes from MELPA; `Package-Requires` declares `(vui "0.1")`.  Treat
it as a young, fast-moving library: re-test when bumping it, and keep
generic vui helpers in `octocat-vui.el`.

### Indicating interactivity in the UI

See [docs/user-interface-conventions.md](docs/user-interface-conventions.md)
for how to signal that a section heading or inline value is RET-able:
`mouse-face`, `help-echo` wording, when to use `buttonize`, and the decision
table for each situation.

### Evil keybindings

Evil bindings for all octocat modes live in `octocat-evil.el` and are
installed by `octocat-evil-setup`.

Each mode's map gets its bindings with `evil-define-key*`.  Rows bind RET
themselves (a `keymap` text property, see `octocat-vui-row`), so only the
mode-wide commands go there.
