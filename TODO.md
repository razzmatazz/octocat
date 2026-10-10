# TODO list

## upload to melpa

https://github.com/melpa/melpa/pull/10048

## ability to load items on demand, i.e. when section opens, not when dashboard does

## ability to view checks

## ability to view PR reviews, i.e. view comments on code lines, etc.

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

Design goal: render as tightly as possible, to save vertical space.  Done
for the top level: blank source lines beside blocks that stand out on their
own (rules, tables, headings, quotes) are dropped, so `*bold* **italic**`,
`---`, then a code fence is 3 rows, not 5.  A blank row between two plain
paragraphs, and the one after a code box, are kept for readability.  Not yet
tightened: blank rows inside list items and quotes, and around lists.

Still to do: make links and `#123` references RET-able (links already carry an
`octocat-markdown-url` property), syntax-highlight fenced code by language,
setext headings, indented code blocks, and give `octocat-edit-mode` markdown
font-lock from the same module.

Also not handled yet:

- h1/h2 only look bold in a terminal (the larger font height is ignored).
- `<details>`/`<summary>`: the tags are stripped and the content always shows;
  could become a collapsible section.
- Reference-style links (`[text][1]`), footnotes, `:emoji:` shortcodes and
  `<img>` tags (stripped; a markdown image shows as `[image: alt]`).
- Short commit SHAs and `owner/repo@sha` are not recognised as references.
- mermaid and math fences render as plain code.
- List items continued without indentation, and `|` inside a code span in a
  table cell.

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

Binding `f`: bind directly in the mode-map (not via `evil-define-key*`).
All octocat modes derive from `magit-section-mode`, which carries the
`(override-state . all)` keymap property — this tells Evil the mode-map
beats all state maps, so `f` shadows `evil-find-char` automatically, exactly
as Magit does for its own `f` → `magit-fetch`. Mirror it in `octocat-evil.el`
via `evil-define-key* 'normal` for consistency with the existing pattern.

## ~~PR/issue body rendering~~

Fixed by stripping `\r` from body and comment text in both `octocat-pr.el` and `octocat-issue.el` at the binding site, before any rendering or splitting.
