# Contributing to octocat.el

## Code conventions

### Indicating loading / async activity

Use the buffer-local `mode-line-process` variable to indicate that a
background operation is in flight.  Set it to a short string (e.g.
`" [refreshing…]"`) when async calls start; clear it to `nil` when they
complete.  Do not erase or replace existing buffer content just to show a
loading state — keep stale content visible and let `mode-line-process` signal
that fresh data is on its way.
