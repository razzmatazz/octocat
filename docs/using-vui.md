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

## Remounting a page from a button or field handler

A command that remounts its own buffer's page (`vui-mount`) must not do so
synchronously when it runs as the `:on-click` of a `vui-button`, or the
`:on-submit` of a `vui-field`.  Defer the remount with
`octocat-vui-refresh-later`:

```elisp
(defun octocat-repo-reset-branch ()
  (interactive)
  (setq octocat-repo--branch nil)
  (octocat-vui-refresh-later #'octocat-repo-refresh))
```

Why: vui runs those handlers inside
`(let ((vui--root-instance captured-root)) ...)`.  The `vui-mount` in the
handler sets the buffer's root to the new page, and the `let` restores
the old, already unmounted one as the handler returns.  The next mount
tears down that dead root instead of the page on screen, which stays
alive with its effects installed.  Its `octocat-vui-use-window-width`
hook then repaints it, with its old props, over the buffer on every
window resize: on a PR list, `C-x 3` brought back an earlier filter and
its results.

Deferring is harmless when the command runs from a key instead, so the
commands defer unconditionally.  A re-render (`vui-set-state`,
`vui-update-props`) is unaffected; only a remount is.

Remove this once vui.el is fixed (see TODO.md).
