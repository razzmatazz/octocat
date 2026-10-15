# TODO list

## Report to vui.el: a handler's remount is undone, leaking the new page

File at https://github.com/d12frosted/vui.el/issues: title and body below.
Once fixed upstream, drop `octocat-vui-refresh-later` and its section in
docs/using-vui.md.

**Title:** A `vui-mount` inside an event handler is undone when the handler returns, leaking the new tree

**Body:**

When a button's `:on-click` (or a field's `:on-submit`, etc.) remounts
its own buffer with `vui-mount`, the buffer-local `vui--root-instance`
reverts to the old, already unmounted root as the handler returns.  The
next `vui-mount` of that buffer then tears down the dead root, and the
live tree is never unmounted: its effects stay installed and their
cleanups never run.

Seen on d8e76e7 and still present on master (f42b4d8).

#### Repro

```elisp
;;; -*- lexical-binding: t -*-
(defvar probe-live nil "Labels of the trees whose effect is installed.")

(vui-defcomponent probe-page (label)
  :render
  (progn
    (vui-use-effect ()
      (push label probe-live)
      (lambda () (setq probe-live (delete label probe-live))))
    (vui-button "remount"
      :on-click (lambda () (probe-mount (concat label "+"))))))

(defun probe-mount (label)
  (vui-mount (vui-component 'probe-page :label label) "*probe*"))
```

1. `(probe-mount "A")`: `probe-live` is `("A")`.
2. Press `[remount]` in `*probe*`: `probe-live` is `("A+")`, as expected,
   but `vui--root-instance` in `*probe*` is the tree of `"A"`, detached
   (`(vui-instance-buffer vui--root-instance)` is nil).
3. `(probe-mount "B")`: `probe-live` is `("B" "A+")`.  `"A+"` was never
   unmounted.

Expected after step 3: `("B")`.

#### Impact

The leaked tree's effects keep running.  In our case a
`window-size-change-functions` hook (added by an effect, removed in its
cleanup) called `vui-set-state` on the leaked tree via
`vui-with-async-context`; the tree is not detached, so the closure's
liveness check passes, and it re-rendered its stale props over the
buffer on every window resize.  On a list page, `C-x 3` swapped the
current filter and results for an earlier one.

#### Cause

The event wrappers run the handler inside

```elisp
(let ((vui--current-instance captured-instance)
      (vui--root-instance captured-root))
  (funcall wrapped-click))
```

(`vui-button`, checkbox, select, and `vui-field`'s `:notify` and
`:action`; five places on master).  `vui-mount` sets
`vui--root-instance` to the new root, but that `setq` hits the `let`
binding, which unwinds to the value from before the handler: the root
`vui-mount` just unmounted.

#### Possible fix

Carry a root replaced during the handler out of the `let`, in one helper
the five wrappers share:

```elisp
(let ((buf (current-buffer)) new-root)
  (let ((vui--current-instance captured-instance)
        (vui--root-instance captured-root))
    (funcall wrapped-click)
    ;; Read in BUF: the handler may have left another buffer current.
    (let ((root (buffer-local-value 'vui--root-instance buf)))
      (unless (eq root captured-root)
        (setq new-root root))))
  (when new-root
    (with-current-buffer buf (setq vui--root-instance new-root))))
```

A remount into another buffer is unaffected: the `let` binds the
clicked buffer's value only.

#### Workaround

Defer the remount until after the handler, e.g. with
`(run-at-time 0 nil ...)` in the clicked buffer.

## upload to melpa

https://github.com/melpa/melpa/pull/10048

## ability to load items on demand, i.e. when section opens, not when dashboard does

## ability to view checks

## ability to view PR reviews, i.e. view comments on code lines, etc.

## Prune the disk cache

`octocat-cache-directory` only grows: every PR, issue, commit, run and
checks view saves a `<type>-<id>.json` per repo (`octocat--detail-cache-save`)
and nothing ever removes them.  The PR diff cache (`pr-diff-N.json`, with
the full patches) makes this worse: a large PR can be a multi-MB file.

Ideas: delete files not read for N days at load time or on a timer; cap the
directory by total size, evicting the least recently used; skip saving (or
drop the `patch` fields) above a size threshold; a `M-x octocat-cache-clear`
for the manual case.

## ~~Can we show active PR more prominently on the dashboard?~~

`octocat-branch-current` face (bold + underline, same green as `octocat-branch`) applied
to the matching `headRefName` / `headBranch` column in the dashboard PR list, Workflow Runs
list, and the Branch line in PR detail view.  Follows Magit's own `magit-branch-current`
convention (bold + underline on the branch name itself; no prefix glyph so column
alignment stays intact).  See docs/user-interface-conventions.md for the full rationale
and code patterns.

## ability to select current branch for filtering commits+runs+prs (single pr shown) form the dashboard

## ability to review PRs, submit comments, etc.

## I want C-o to work inside PRs, issues, etc as well -- not only from dashboard

I.e easy acess to whatever I am viewing now

## I want job output to be shown expanded

So find works immediately with C-s / or forward slash in email.

I.e. don't collapse sections by default

## Build out the GitHub markdown renderer

`octocat-markdown.el` replaced `markdown-mode`/`gfm-view-mode` (no longer a
dependency; the edit buffer is now a plain `text-mode`).  `octocat-markdown-render`
now renders headings, emphasis, inline code and code fences, lists and task
lists, quotes and alerts, links, tables, `@mentions` and `#123` references.

Design goal: render as tightly as possible, to save vertical space.  Blank
source lines beside blocks that stand out on their own (rules, tables,
headings, quotes, lists) are dropped, also inside list items and quotes.  A
blank row between two plain paragraphs, and the one around a code box, are
kept for readability.

Done since: RET-able links, `#123`, `owner/repo#123`, commit SHAs and
`owner/repo@sha` (a `keymap` text property, so it works in vui and Evil buffers
alike; a number is opened as a PR or an issue after asking
the API which it is); `@mentions` link to the profile; syntax-highlighted
fences (`octocat-markdown-language-modes`); setext headings; indented code;
reference-style links and footnotes; `:emoji:` shortcodes; `<img>` and `<kbd>`;
lazy list continuation; collapsible `<details>` (RET on the summary); inline
`$math$` and `math` fences as Unicode; terminal-friendly h1/h2 faces; markdown
font-lock in `octocat-edit-mode`.

Still to do:

- Mermaid (`octocat-mermaid.el`) draws flowcharts/graphs, sequence diagrams,
  state diagrams (transitions only) and pie charts, to fit the window: labels
  wrap, a left-to-right chart turns top-down, sequence diagrams squeeze.  Not
  drawn (shown as labelled source): nested subgraphs, edges to a subgraph
  itself, a subgraph that would have to take in a node of another one (e.g.
  `A --> C --> B` with only A and B in it), self-loops, composite states,
  class/ER/gantt/journey/git graphs, and anything that does not fit the width
  even squeezed.  Dense flowcharts with many back-edges come out cramped
  (arrows share the row below a node), and edges that cross merge into
  junctions rather than hopping.
- TeX is approximated (fractions, roots, scripts and symbols only).
- `<details>` folds are not remembered across a refresh, and a `<details>`
  inside another one is shown flat.
- A bare `|` inside a code span in a table cell splits the cell, as on GitHub
  (write `\|`); only the escaped form stays in the cell.
- Setext headings are one line only.

## ~~Render Markdown in a better way~~

(Superseded: this was done with `gfm-view-mode`, since replaced by
`octocat-markdown.el`.)

All/most of the text in GitHub uses markdown. Can we render this better in
our views?

**Approach:** Use `gfm-view-mode` font-lock (already installed via `markdown-mode`, no new
dependencies). Write an `octocat--insert-markdown (text)` helper that:

1. Inserts `text` into a temp buffer running `gfm-view-mode`.
2. Calls `font-lock-ensure` to force fontification.
3. Copies the resulting propertized string into the target buffer with
   `insert` (text properties — bold, italic, heading faces, inline-code
   face, hidden markup delimiters — come along for free).

Apply this helper everywhere body text is currently inserted plain:
- `octocat-pr.el` — PR body (`octocat--render-pr`)
- `octocat-issue.el` — issue body (`octocat--render-issue`)
- `octocat-commit.el` — commit message body (`octocat--render-commit`)

Comment snippets (one-liner truncated previews) stay as plain text — no
need to fontify a 72-char snippet.

**Optional upgrade path:** if `cmark-gfm` is on PATH (`brew install cmark`),
pipe through `cmark-gfm --unsafe -e table -e strikethrough` → HTML →
`shr-insert-document` for full GFM rendering (proper list bullets, link
buttons, tables). Guard with `(when (executable-find "cmark-gfm") ...)` so
it degrades gracefully to the font-lock path.

## ~~Some form of caching is needed to long load of dashboard for large repos~~

Two separate problems:

**~~Stage 1 — Stale-while-revalidate~~**
`octocat-refresh` now only shows the "Loading…" skeleton on first open
(`buffer-size` is zero); subsequent `gr` calls keep existing content visible.
`mode-line-process` is set to `" [refreshing…]"` while background calls are
in flight, cleared when `octocat--render` completes.

**~~Stage 2 — Disk cache~~**
One file per `(repo . filters)` key under a `defcustom octocat-cache-directory`
defaulting to `(locate-user-emacs-file "octocat/cache/")` — portable across
Doom, no-littering, and vanilla Emacs.  Do NOT hardcode
`~/.config/emacs/.local/cache` (that is Doom-specific).  Store as JSON
(pretty-printed) so cache files are easy to inspect and debug directly.

Flow:
- On buffer open: load cache file → render immediately (no blank screen),
  then always kick off background `gh` calls with `[refreshing…]` indicator;
  re-render + overwrite cache file when they arrive.
- No cache file yet (first open): show "Loading…" as today, write cache on
  arrival.

Implement Stage 1 first, then Stage 2 alongside or after the filter feature
(since the cache key must include filter state).

## ~~It is not clear that last item shows on PR list indicates c/i status~~

Added `octocat--ci-label` to `octocat-core.el` returning a dimmed `CI:` prefix
plus the coloured icon (e.g. `CI: ✓`).  Used in the dashboard PR list,
the PR detail Checks section heading (rollup badge next to count), and the
per-check icon now goes through the shared `octocat--run-icon` helper.

## ~~Cannot open dashboard when repo has PRs or issues or actions disabled~~

Each section now handles errors independently — a disabled feature shows a
dimmed inline note and the rest of the dashboard renders normally.

## ~~Better defaults for the dashboard~~

Both `octocat--list-prs` and `octocat--list-issues` now use `--state open`.
Header counts updated to say "N open PR(s) / N open issue(s)".
Both list functions now live in their respective `-pr.el` / `-issue.el` files.

## Filters for PR and issue lists

Use a transient popup bound to `f`, context-sensitive based on the section
point is in (dashboard) or the current buffer (pr/issue detail views).

Filters to support:
- state: open / closed / all
- author: free-text (maps to `--author`)
- label: completing-read from repo labels (maps to `--label`)

Filter values stored as buffer-locals; `gr` re-fetches with current filters.
Transient title reflects context: "PR Filters" vs "Issue Filters".
Applies to `octocat-mode` (dashboard) and dedicated `octocat-pr-mode` /
`octocat-issue-mode` buffers via the same `f` binding.

Binding `f`: bind it in the mode-map and, so it shadows `evil-find-char`,
with `evil-define-key* 'normal` in `octocat-evil.el`.

## ~~PR/issue body rendering~~

Fixed by stripping `\r` from body and comment text in both `octocat-pr.el` and `octocat-issue.el` at the binding site, before any rendering or splitting.
