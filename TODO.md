# TODO items

## Some form of caching is needed to long load of dashboard for large repos

Two separate problems:

**~~Stage 1 — Stale-while-revalidate~~**
`octocat-refresh` now only shows the "Loading…" skeleton on first open
(`buffer-size` is zero); subsequent `gr` calls keep existing content visible.
`mode-line-process` is set to `" [refreshing…]"` while background calls are
in flight, cleared when `octocat--render` completes.

**Stage 2 — Disk cache**
One file per `(repo . filters)` key under a `defcustom octocat-cache-directory`
defaulting to `(locate-user-emacs-file "octocat/cache/")` — portable across
Doom, no-littering, and vanilla Emacs.  Do NOT hardcode
`~/.config/emacs/.local/cache` (that is Doom-specific).  Store as JSON
(pretty-printed) so cache files are easy to inspect and debug directly.

Store a timestamp alongside the data in each cache file.

Flow:
- On buffer open: load cache file → render immediately (no blank screen).
  If cache is older than TTL, kick off background `gh` calls; re-render +
  overwrite cache file when they arrive.  If within TTL, do nothing further.
- `gr`: always forces a refresh regardless of TTL.
- No cache file yet (first open): show "Loading…" as today, write cache on
  arrival.

TTL as `defcustom octocat-cache-ttl` in seconds, default 300 (5 min).

Implement Stage 1 first, then Stage 2 alongside or after the filter feature
(since the cache key must include filter state).

## It is not clear that last item shows on PR list indicates c/i status

Hide it or show text

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
