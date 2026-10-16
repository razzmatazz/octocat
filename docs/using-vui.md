# Using vui.el

Gotchas of vui.el as octocat uses it, and how the code works around them.

## Layout

- `vui-collapsible` indents only the **first** body line (default `:indent
  2`).  Rows here carry their own two-space prefix, so every collapsible
  passes `:indent 0`; otherwise the first row is indented by four spaces.
- Rows use `vui-text` inside a `vui-region` (not `vui-button`) so per-segment
  faces are preserved; see "Row rendering" in `octocat-repo.el`.

## Timers

Every repeating timer goes through `octocat-vui-use-timer`, never a bare
`run-with-timer`.  It ties the timer to the component: it is cancelled
when the component unmounts or the hook's dependencies change, when the
callback returns nil (done), and when the callback signals, so a broken
frame is reported once instead of on every tick.  A callback that sets
state to the value it already has does not re-render, so a timer that
only stopped on a re-render would run forever: return nil instead.

## Update a page in place; don't remount it

To change what a page shows (the list's query, the repo page's branch),
re-render it with new props, `octocat-vui-update-page` or
`octocat-vui-refresh-page`, not `vui-mount`.  A part that must start
afresh takes the new prop as its `:key` (the list's results, keyed by
the query).

- **Cost.**  A remount rebuilds every component: memos recompute, every
  `vui-use-async` refetches, folds and "load more" are lost.
- **vui.el bug.**  vui runs handlers (`:on-click`, `:on-submit`, ...)
  inside `(let ((vui--root-instance captured-root)) ...)`, so a
  `vui-mount` in a handler is undone as it returns.  The new page is
  never unmounted and its effects keep running: its window-width hook
  repainted a PR list's old filter over the current one on `C-x 3`.  See
  the vui.el item in TODO.md.
- **Focus.**  `vui-mount` ends with `switch-to-buffer`, so a remount
  from an async callback, such as a merge finishing, pulls the user back
  to the page (see "Never steal focus" in
  docs/user-interface-conventions.md).

A page mounts once, when it is opened, through
`octocat-vui-refresh-page`.  Its refresh (`g`, or after an action) calls
that again, which re-renders in place with a new `:tick`.  Each fetch
takes the tick into its key (`octocat-vui-use-cached`,
`octocat-vui-use-async-sticky`), so it refetches and keeps showing the
old data until the new data arrives.  A handler that must remount
defers it, e.g. `(run-at-time 0 nil ...)`.
