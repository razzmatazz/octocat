# Plan: Cap the width of issue and PR pages

## Goal

On a wide window, issue and PR pages run edge to edge, while GitHub keeps
its conversation column bounded.  Cap the page at `octocat-max-width`
columns by giving the window margins, and keep code blocks inside that
column.

Scope: `octocat-issue-mode` and `octocat-pr-mode`.  Commit and diff pages
keep the full width, since diffs need it.

## 1. Window margins

**`octocat-core.el`**

- `defcustom octocat-max-width` (integer or nil, default 100): the most
  columns a page's text area takes; nil means no limit.
- `octocat--centered-margins (full max)` → `(LEFT . RIGHT)`.  This is a
  pure function.  The margins share `full - max` evenly, or both are 0
  when `full <= max` or MAX is nil.
- `octocat--fit-window (win)` works out FULL as
  `window-body-width` plus the current `window-margins`, then calls
  `set-window-margins` only when the result differs.  Setting the same
  margins again would fire another size change.
- `octocat--max-width-setup` adds `octocat--fit-window` buffer-locally to
  `window-size-change-functions` and `window-buffer-change-functions`.
  These run per window, with the window as their argument.  It also fits
  every window that already shows the buffer.

**`octocat-issue.el`, `octocat-pr.el`:** call `octocat--max-width-setup`
in the mode bodies.  `*-open` calls `pop-to-buffer` before setting the
mode, so the window already exists and the margins are in place before
the first render.

Re-rendering needs no new code.  `octocat-vui-window-width`
(`window-body-width`) and `octocat--markdown-width`
(`window-max-chars-per-line`) both measure the body, which excludes the
margins.  So the existing `octocat-vui-use-window-width` hook sees the
narrower body and re-renders: tables and mermaid diagrams fit the column.

**To verify during implementation:**
- Buffer-local `window-size-change-functions` run before the global
  value, so the margins are set before vui's global hook measures the
  width.  If they don't, the first resize renders at the old width.
- Switching the window to another buffer keeps its margins.  Fitted
  windows carry an `octocat--fitted` parameter, and a global
  `window-buffer-change-functions` hook, `octocat--unfit-windows`,
  restores the margins of those now showing another buffer.

## 2. Code blocks fit the column

**`octocat-markdown.el`, `octocat-markdown--code-block`:** pad each line
to `min(natural, avail - 2)` instead of the widest line.  Short lines then
never wrap, and only the lines longer than the column soft-wrap.  When
`avail` is nil, keep today's behaviour.

**`octocat-markdown--finish`:** for code rows, the `wrap-prefix` ends in
a dimmed `↪ `, so a wrapped line is not mistaken for a newline.  The
renderer marks code rows with a text property that `--finish` checks.
The row's hang stays numeric, which keeps quotes and lists, which add to
it, unchanged.

Tables that cannot squeeze to fit are left as they are (out of scope).

## 3. Flush-left timeline

The header is already flush-left, so the timeline drops its 2-column
indent: rail `│`, bullets at column 0, and buttons that hang off the
rail.  Content under a section heading (PR Merge) keeps its indent.

## Tests

- `octocat--centered-margins`: nil max, narrow window, wide window,
  odd remainder.
- `octocat-markdown-render` with WIDTH and a fence holding one long line:
  the short lines are padded to the cap, not to the long line, and the
  long line's `wrap-prefix` contains `↪`.

## Follow-up (not in this change)

RET on a code block opens it in its own buffer, in the language's major
mode with `truncate-lines`, as the equivalent of GitHub's horizontal
scroll.
