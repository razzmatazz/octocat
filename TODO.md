# TODO items

# ability to view checks

# ability to view PR reviews, i.e. view comments on code lines, etc.

# can we show active PR more promintently on the dashboard? bold or whatever is the proper way

# ability to select current branch for filtering commits+runs+prs (single pr shown) form the dashboard

# ability to review PRs, submit comments, etc.

## I want C-o to work inside PRs, issues, etc as well -- not only from dashboard

I.e easy acess to whatever I am viewing now

## I want job output to be shown expanded

So find works immediately with C-s / or forward slash in email.

I.e. don't collapse sections by default

## ~~Render Markdown in a better way~~

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

## A way to view the entire diff for PR

Currently I need to view this commit-by-commit

## PR: We need a way to view reviews

Probably show the entire diff, file sections, with subsections where review comments are shown?

## ~~PR/issue body rendering~~

Fixed by stripping `\r` from body and comment text in both `octocat-pr.el` and `octocat-issue.el` at the binding site, before any rendering or splitting.

## Commits can be and should be cached
