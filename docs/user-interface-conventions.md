# User Interface Conventions

This document captures the visual and interaction conventions used across
octocat.el buffers, and the research behind them.

---

## Indicating that a line or section is interactive (RET-able)

A RET-able row is built with `octocat-vui-row`: a `vui-text` line in a
`vui-region` whose keymap binds RET, with `mouse-face 'highlight` and a
`help-echo` on the whole line.  The row keeps the faces of its segments
(a `vui-button` would apply one face to the whole label).  A segment that
has its own `help-echo`, such as a relative date, keeps it.

```elisp
(octocat-vui-row (concat icon "  " (propertize name 'face 'octocat-run-job-name))
                 (lambda () (octocat-job-open repo run-id job-id name))
                 "RET: open job")
```

A separate action inside a line, such as a tab or "Load N more…", is a
`vui-button`, drawn without brackets where the line already reads as a
control (see "Brackets mean \"button\"" below).

### Folds

A fold's toggle must be reachable with TAB, and its title must keep its
own faces.  A `vui-button` gives the first but draws its label in one face;
a row gives the second but is not a TAB stop.  So a fold header is both:
the ▸/▾ marker is a `vui-button`, the TAB stop, and the title after it is
an `octocat-vui-row`.  RET on either toggles.  `octocat-vui-fold-header`
builds it, for `octocat-vui-fold`:

```
  ▸ [✓] Set up job      success  1s     ← TAB stops on ▸; RET anywhere toggles
  ▾ [✗] Compile         failure  11s
      ▸ Run make compile                ← a nested fold, same shape
10:32:34 make compile                   ← the body: copyable, not indented
```

Unfolding and folding are animated like the timeline's long entries, and
a body that is costly to lay out (a step's log) is built only once
unfolded.

### Expand all

Wherever a section hides content by default, its heading carries an
`[Expand all]` button, which turns into `[Collapse all]`.  It unfolds
everything in the section, nested folds included, so isearch and other
buffer searches can find text that would otherwise be hidden; RET on one
fold's header still toggles just that fold.

```
Steps (8)  [Expand all]
```

`octocat-vui-expand-all-button` draws it.  The section keeps its last
value in its state and passes it to each `octocat-vui-fold` as `:bulk`,
and a fold passes it on to the folds in its body.  The job page's Steps
and the Files of the commit and PR diff pages do this; other folded
content (long timeline entries, the PR checks list) should follow.

Content hidden by default may start shown when it is small: the Files
section starts unfolded when the whole diff fits in the window, by
starting with the value Expand all would give (a fold that mounts with
it open paints open, without animating).

### Decision table

| Situation | Approach |
|---|---|
| The whole line opens something | `octocat-vui-row` with a `help-echo` |
| One control among others on a line | `vui-button` |
| A name or number within a line opens its page (a header's `#N`, `@author`, Assignees, Closes) | `octocat-repo-vui--link`: an unbracketed `vui-button`, so TAB stops on it; inside a row, pass `octocat-vui-row` a list of strings and vnodes |
| A foldable block | `vui-collapsible` for a plain title; `octocat-vui-fold` with `octocat-vui-fold-header` when the title has its own faces or the body should be built only once unfolded (see "Folds") |

### Go along with vui.el

Build interactive parts from vui's components (`vui-button`, `vui-field`,
`vui-region :keymap`), not hand-made text properties or `button.el`
calls: only vui's elements are TAB stops, and its internals may change.
Rendered markdown's links are still `keymap` text properties, so not
TAB stops: the markdown renders to one string, not vnodes.

---

## Editing fields: edit buffer vs. minibuffer

Two distinct mechanisms are used depending on whether the field is
single-line or multi-line:

### Multi-line fields → `octocat--open-edit-buffer`

Used for PR/issue **bodies** and **comments** — content where the user
may need multiple lines, markdown preview, and the ability to abandon
their work mid-edit.  The edit buffer derives from `text-mode` and
presents a familiar Magit-style commit-message workflow:

```
C-c C-c   submit (calls gh, refreshes source buffer, kills edit buffer)
C-c C-k   discard (confirms if modified, kills edit buffer)
```

The header line shows the action and a keyboard hint.  The source buffer
is refreshed automatically on success.

### Single-line fields → `read-string` in the minibuffer

Used for **titles** — content that is always a single line and where
opening a split window would be disproportionate.  The current value is
pre-filled as the initial input so the user can edit in place:

```elisp
(read-string "PR title: " current-title)
```

Validation (non-empty) and the `gh` call happen immediately after the
user confirms with `RET`.  The buffer refreshes asynchronously on
success; on failure a message is shown in the echo area.

### Decision table

| Field type | Mechanism | Rationale |
|---|---|---|
| Multi-line markdown (body, comment) | `octocat--open-edit-buffer` | Needs line editing, markdown mode, and an explicit discard path |
| Single-line string (title) | `read-string` minibuffer | Single line; a split window would be disproportionate |
| List search query | inline `vui-field` (`octocat-vui-list-query-field`) | Always on screen; editing it below in the minibuffer was confusing |

---

## Displaying commit authors

GitHub's REST commits endpoint exposes two distinct author objects for each
commit:

| Field path | Type | Contains |
|---|---|---|
| `commit["author"]` (top-level) | GitHub user object | `"login"` — the GitHub handle |
| `commit["commit"]["author"]` (nested) | Git identity object | `"name"`, `"email"`, `"date"` |

The top-level object is `null` when the git commit email is not linked to
any GitHub account (e.g. bots, external contributors, unverified emails).

Three helpers in `octocat-core.el` cover the different display contexts:

### `octocat--author-login (obj)`

For **any** GitHub entity whose `"author"` key is a user node — PRs,
issues, reviews, comments.  Returns `"@login"` or `""`.  Do **not** use
this for commit hash-tables from the REST endpoint; use one of the two
commit-specific helpers below instead.

### `octocat--commit-author (commit)`

For **compact list rows** (e.g. the dashboard Commits section) where
horizontal space is at a premium.  Returns `"@login"` when the commit is
linked to a GitHub account, otherwise falls back to the bare git author
`name`.  Always a single short token.

### `octocat--commit-author-full (commit)`

For the **Author line** in detail views.  Returns a git-log-style
`Name  <email>` string built from the nested git identity fields:

```
Linus Torvalds  <torvalds@linux-foundation.org>
```

The GitHub handle is intentionally excluded from this string.  Callers
that want the handle should call `octocat--commit-author-login` and render
it on a **separate GitHub line** immediately below the Author line:

```
  Author  Linus Torvalds  <torvalds@linux-foundation.org>
  GitHub  @torvalds
  Date    2026-06-11 14:23
```

The GitHub line should be omitted entirely when
`octocat--commit-author-login` returns nil (commit not linked to an
account).

### `octocat--commit-author-login (commit)`

Returns `"@login"` when the commit's git email is linked to a GitHub
account, or `nil` otherwise.  Used exclusively to populate the optional
GitHub info line in detail views — do not use for compact list rows
(`octocat--commit-author` already handles the handle-or-name fallback
there).

### Decision table

| Context | Helper(s) | Example output |
|---|---|---|
| PR/issue/review/comment author | `octocat--author-login` | `@torvalds` |
| Commit list row (dashboard) | `octocat--commit-author` | `@torvalds` or `Linus Torvalds` |
| Commit detail Author line | `octocat--commit-author-full` | `Linus Torvalds  <torvalds@linux-foundation.org>` |
| Commit detail GitHub line | `octocat--commit-author-login` | `@torvalds` (omit line if nil) |

### `help-echo` wording

Follow magit's own wording style: `"mouse-2, RET: <imperative phrase>"`.
If mouse interaction is not expected (terminal-only views), `"RET:
<imperative phrase>"` is fine.

Examples:

```
"RET: open diff view"
"mouse-2, RET: open in browser"
"RET: expand commit"
```

---

## Formatting branch names in tabular rows

Branch names appear in columnar list views (dashboard Workflow Runs, PR
list, workflow detail).  Two helpers in `octocat-core.el` centralise the
width computation and rendering so every list stays consistent.

### `octocat-branch-max-width`

A `defconst` (currently `16`) that caps the branch column width across all
views.  Change it in one place to resize every list at once.

### `octocat--branch-column-width (runs key)`

Computes the branch column width for a given list of hash-tables:

```elisp
(octocat--branch-column-width runs "headBranch")
(octocat--branch-column-width prs  "headRefName")
```

Returns `(min octocat-branch-max-width (max 1 longest-name-length))`, so
the column is as narrow as possible while fitting every branch name —
up to the cap.  Call this once outside the `dolist` and bind the result to
`branch-w`.

### `octocat--format-branch (branch width)`

Renders a single branch string for insertion:

```elisp
(octocat--format-branch branch branch-w)
```

Pads/truncates `branch` to exactly `width` characters (trailing `…` when
truncated) and applies `octocat-branch` face.  Use this instead of
inline `propertize` + `truncate-string-to-width` at every call site.

### Pattern

```elisp
(let ((branch-w (octocat--branch-column-width items "headBranch")))
  (dolist (item items)
    (let ((branch (or (gethash "headBranch" item) "")))
      ...
      (octocat--format-branch branch branch-w)
      ...)))
```

---

## Formatting timestamps

Show the relative age (`3 days ago`); put the exact time in `help-echo`
(`Mon 2026-06-08 14:23:05 EEST`) for the mouse and ElDoc (echo area,
after `eldoc-idle-delay`) for point.  Never print both.  Every octocat
major mode calls `(octocat--ts-eldoc-setup)` in its body.

Helpers in `octocat-core.el` take an ISO-8601 UTC string; nil, `:null`
or `""` give `""`.

| Context | Helper | Output |
|---|---|---|
| Any displayed timestamp | `octocat--format-ts-relative` | `3 days ago`, exact time on hover |
| Not shown in a buffer | `octocat--relative-ts` | `3 days ago`, no properties |

- `propertize` and `format` padding keep the `help-echo`.
- `octocat-vui-row` adds its row hint only where no `help-echo` is set,
  so the date keeps its own.  Do the same for hand-built rows.
- Relative ages go stale; `gr` refreshes.
- Plain Elisp only, no `ts.el` or magit (see `AGENTS.md`).

---

## Copyable content is not indented

Text a user may copy out verbatim (diff lines, code, job logs, a file such as
the repo page's README) starts at column 0, so it pastes as-is.  A file shows
as it would in its own buffer.  Decoration (headings, comment boxes) may indent.

---

## Indicating the active (currently checked-out) branch

### Background: Magit's convention

Magit marks the currently checked-out branch in its branch lists with a
combination of bold weight and an underline, using the `magit-branch-current`
face (which inherits `magit-branch-local` and adds `:underline t`).  It also
prepends a `*` glyph in some views.  The core signal is: **bold + underline
on the branch name itself**, no extra column or prefix character required.

`magit-branch-current` lives in the `magit` package, which octocat.el does
not depend on.

### The `octocat-branch-current` face

`octocat-core.el` defines `octocat-branch-current` as the equivalent for
octocat views:

```elisp
(defface octocat-branch-current
  '((((class color) (background dark))
     :foreground "#8ec07c" :weight bold :underline t)
    (((class color) (background light))
     :foreground "#427b58" :weight bold :underline t)
    (t :inherit (bold octocat-branch) :underline t))
  "Face for the currently checked-out branch …")
```

It deliberately reuses the same green as `octocat-branch` so the active
branch reads as a *highlighted variant* of the normal branch colour, not
a categorically different thing.  The bold weight and underline match
Magit's own current-branch treatment.

### Where it is applied

| View | Location | What changes |
|---|---|---|
| Dashboard PR list | `headRefName` column | `octocat-branch-current` face instead of `octocat-branch` |
| Dashboard Workflow Runs list | `headBranch` column | same |
| PR detail Info section, Branch line | head branch name | `octocat-branch-current` face |

No prefix glyph (`*`, `▶`, etc.) is added.  The bold + underline on the
branch name is sufficient and keeps column alignment intact.

### Helper: `octocat--current-branch ()`

`octocat-core.el` exposes a synchronous helper that returns the name of the
currently checked-out local branch, or `nil` on detached HEAD or any error:

```elisp
(octocat--current-branch)   ; => "feat/my-feature"  or  nil
```

Implemented with a single `git symbolic-ref --short HEAD` call — fast
enough to call inline at render time.

### Pattern for list rows

```elisp
(let* ((branch  (or (gethash "headRefName" pr) ""))
       (activep (and current-branch (string= branch current-branch)))
       (b-face  (if activep 'octocat-branch-current 'octocat-branch)))
  (propertize (truncate-string-to-width branch width nil ?\s "…")
              'face b-face))
```

`current-branch` is passed in from the caller (captured once per render,
not re-read per row).  Comparing with `string=` is correct; branch names
are plain ASCII strings.

### Pattern for detail-view info lines

In an info section the branch name is rendered inline without padding, so
the same face swap applies directly:

```elisp
(insert (format "  Branch   %s → %s\n"
                (propertize head
                            'face (if (string= head current-branch)
                                      'octocat-branch-current
                                    'octocat-branch))
                (propertize base 'face 'octocat-branch)))
```

`current-branch` is obtained by calling `(octocat--current-branch)` once at
the top of the render function and binding it to a local variable.  Do not
re-call the helper per line.

---

## Opening items in the browser (`C-c C-o`)

Every mode binds `C-c C-o` to its own browse command, which opens the item
the buffer shows: `octocat-pr-browse`, `octocat-issue-browse`,
`octocat-commit-browse`, `octocat-checks-browse`, `octocat-workflow-browse`,
`octocat-run-browse`, `octocat-job-browse`, `octocat-repo-browse`,
`octocat-vui-list-browse` and so on.  Each reads the buffer-local variables
set when the buffer was opened.

| Page | URL opened |
|---|---|
| PR | `gh pr view --web NUMBER --repo REPO` |
| Issue | `gh issue view --web NUMBER --repo REPO` |
| Commit | `https://github.com/REPO/commit/SHA` |
| Checks | `https://github.com/REPO/commit/SHA/checks` |
| Workflow | `https://github.com/REPO/actions/workflows/FILE` |
| Run | `https://github.com/REPO/actions/runs/ID` |
| Job | `https://github.com/REPO/actions/runs/RUN_ID/job/JOB_ID` |

### Using `gh` vs. `browse-url`

PRs and issues are opened via `gh pr view --web` / `gh issue view --web`
rather than a hard-coded URL.  This ensures the correct GitHub host is used
when `gh` is configured for GitHub Enterprise or an alternative host.  All
other items are opened with `octocat-browse-external` using a constructed
URL.

### Following links vs. opening in the browser

Octocat leans towards Emacs-native views: a link is opened in Emacs when
some package can show it there, and in the browser only when none can,
or when the user asks for the browser.

- **Following a link** (RET on a link in markdown, a check that is not
  an Actions run) calls `browse-url`.  It consults `browse-url-handlers`,
  so github.com links open in octocat (see below) and links to any other
  web app open in whatever Emacs package registered a handler for them.
- **"Open in browser" commands** (`C-c C-o` and friends) call
  `octocat-browse-external`, i.e. `browse-url-with-browser-kind
  'external`.  It skips handlers marked `internal`, octocat's included,
  so `C-c C-o` on a PR does not just reopen the PR page.

Octocat's handler is `octocat-browse-url`, registered in
`browse-url-handlers` with `octocat--github-url-target` as its
predicate, while `octocat-open-github-urls` is non-nil (the default).
The predicate maps a URL to a view and returns nil for pages octocat has
no view for (blobs, wikis, releases, …), which then fall through to the
browser.  A link names its own repository, so one to another owner's
commit or run opens in that repository; `#123` and bare commit hashes
are not links and still open in the buffer's repository.  When adding a
view that has a github.com page, add its URL to
`octocat--github-url-target` and `octocat-browse-url`.

---

## Alternative view (`C-c C-v`)

`C-c C-v` switches a page to its other way of showing the same content,
and back: rendered vs. raw markdown on pages with markdown, two-line vs.
one-line rows on the PR and issue lists.  Users learn one key for "show
this differently", so a page that gains a second view binds it to
`C-c C-v` (in the mode map and, for Evil, in octocat-evil.el) rather than
to a key of its own, and documents it in the README's keybinding table.
A page has at most one alternative view, so the key stays a plain
toggle.

Re-render the page in place with the new prop (`octocat-vui-update-page`),
not a remount; see [using vui.el](using-vui.md).  Remember the choice with
`octocat--setting-put` when it describes how the reader likes a page,
not just what they are looking at now, as the list pages' compact view
does.

## Windows: opening pages and `q`

Octocat follows Magit (`magit-display-buffer-traditional`,
`magit-mode-quit-window`), so its windows behave as the rest of Emacs
expects:

- **Open every page with `octocat-display-buffer`**, never `pop-to-buffer`
  or `switch-to-buffer`.  From an octocat page it shows the new page in the
  selected window, so RET drills down in place; from any other buffer it
  leaves the choice to `display-buffer`.  Both go through `display-buffer`,
  so users can override them in `display-buffer-alist`.
- **Bind `q` to `octocat-quit-window`.**  Like `quit-window`, it shows the
  window's previous buffer, so `q` steps back out page by page.  A window
  that octocat created (marked `octocat-dedicated` when it is first shown)
  is deleted once no other octocat page it showed is left.

`q` is not a history: it relies on the window's previous buffers, as in
Magit.  A real back/forward (as `help-mode`'s `l`/`r`) could be added
later, as an octocat history, if stacks get deep.

`pop-to-buffer` alone avoids the selected window, so pages used to
ping-pong between two windows and `q` restored the wrong one.

Doom's workspaces (persp-mode) set a frame `buffer-predicate` that hides
buffers outside the workspace from `quit-window`, and only Doom's "real"
buffers join one, so `q` skips octocat pages.  Users fix it in their
config (octocat must not call Doom):
`(add-hook 'doom-real-buffer-functions #'octocat-buffer-p)`.

---

## Indicating that a page is loading or refreshing

While fetching, only the mode line shows it: `(Octocat-PR:loading ▘)`,
as in `(Compilation:run)`.  No loading text in the buffer.  Components
call `octocat-vui-use-mode-line-loading`; other code sets
`octocat-vui-mode-line-busy`.

Anything that may load slowly holds its place with a **skeleton**: grey
bars (`octocat-vui-skeleton-bar`, face `octocat-skeleton`) shaped like
the content to come, so the layout doesn't jump when it arrives.  A
page with no cache shows one for its body (`octocat-vui-list-skeleton`,
`octocat-vui-detail-skeleton`); a page of rows being fetched shows one
under the list (see "Revealing more rows" below).  A cached paint needs
none: stale content stands in until fresh data replaces it.

---

## Never block the UI on the network

A command that writes to GitHub (merge, comment, state change) must not
leave the user waiting on `gh`: on a slow network or a slow GitHub that
can take many seconds.  Validate what can be checked locally, then close
any dialog at once and show the action as **in progress** on the page
itself, as github.com does ("Merging pull request…" in place of the
merge button).  When `gh` returns, refresh the page to show the result;
on failure, clear the in-progress state and report the error in the
echo area.

The in-progress state lives in a buffer-local variable passed to the
page as a prop, so a refresh (`g`) while the action runs still shows
it.  Change it with `octocat-vui-update-page`, which re-renders the page
in place, not with a remount (see docs/using-vui.md).  While it is set,
hide the buttons that would start the action again, and make their
commands refuse with a `user-error`.

Lead the in-progress line with the turning block spinner the mode line
shows while loading, `octocat-vui-spinner`: `▘ Merging pull request…`.
The mode line's `:loading` is for fetching the page; an action under way
is shown where its button was, so the spinner says it is still running.
The spinner animates through its `display` property, without
re-rendering the page.

A dialog whose text the user typed (a comment, a description) must not
lose it: if `gh` fails, reopen the dialog with the text.

Where each action shows:

- **Under the timeline**, in place of its `+ Add a comment` / Close row:
  posting or editing a comment or description, closing, reopening
  (`octocat-timeline--action`, drawn by
  `octocat-timeline-buttons-or-action`).  A dialog's submit function
  hands its `gh` call to `octocat-timeline-submit`, which closes the
  dialog, shows the action, refreshes, and reopens the dialog on
  failure.  `octocat-timeline-state-change` does the same for closing
  and reopening.
- **In the merge box**, in place of its buttons: merging, converting to
  draft, marking ready for review (`octocat-pr--merging`).
- **Under the review comments** on the PR's Files page: submitting a
  review (`octocat-pr-diff--submit-review`).
- **In the mode line**, for an action with no button on the page to
  replace, such as renaming the title: `octocat-vui-mode-line-action`
  shows `(Octocat-PR:saving ▘)`, ahead of `:loading`.

---

## Revealing more rows ("Load N more…")

Rows that a `[+] Load N more…` button brings in **unfold** one frame at a
time, the way the rest of a long PR body or comment does when its fold
marker is expanded: fast at first, easing out towards the end
(`octocat-vui-unfold-step`: a fraction, `octocat-vui-unfold-growth`, of
the distance left, capped at `octocat-vui-unfold-peak` of the whole,
every `octocat-vui-unfold-interval` seconds).  The list never jumps by a whole
page.

- Draw a pageable list with `octocat-vui-reveal-list` (ITEMS, ROW-FN,
  KEY-FN) instead of `vui-list`.  It shows everything on the first render
  -- cached paint, `gr` -- and only animates items that arrive afterwards.
- Compute shared column widths (author width, ...) from **all** the
  items *before* the call, so columns do not shift while rows appear.
- Keep the load-more button below the list, with its `:key`, so point stays
  on it while the rows unfold.
- While the page is fetched, pass the button LOADING -- that page is on
  the way, not merely a background refresh -- and a SKELETON shaped like
  the rows (`octocat-vui-list-skeleton`, `octocat-vui-line-skeleton`).
  The skeleton unfolds above the button, then folds away as the rows
  unfold: nothing → skeleton → rows, never a jump.
- Folded text uses the same constants through `octocat-vui-fold-rest`;
  tune the pace in `octocat-vui.el` and both follow.

---

## Buffer names

Name a buffer after what it shows, not its mode; the mode line already
shows the mode.  Keep each page's name unique: add a short suffix only
where the bare identity would collide.

| Page | Name |
|---|---|
| Repo | `*owner/repo*` |
| PR / issue | `*owner/repo#12*` |
| PR diff / commits | `*owner/repo#12 diff*`, `*owner/repo#12 commits*` |
| Commit / checks | `*owner/repo@abc1234*`, `*owner/repo@abc1234 checks*` |
| Run / job | `*owner/repo run 123*`, `*owner/repo job 456*` |
| Workflow | `*owner/repo/CI*` |
| Lists | `*owner/repo prs*`, `issues`, `actions` |
| Tree / file / file log | `*owner/repo tree*`, `*owner/repo:path*`, `*owner/repo:path log*` |
| User | `*@login*` |
| Edit | `*<title>*` |

---

## Repo name, brackets and the repo tab strip

### Brackets mean "button"

`vui-button` (and `buttonize`d labels) draw `[ ]` around their label.
Brackets therefore signal an *action*: `[State]`, `[Author]`, `[Load more]`,
the `[Code]` / `[Issues (N)]` tabs.  Plain, un-bracketed text is content or
a heading.

The **repo name is not an action**; it is the page's identity.  Render it
as plain text in the `octocat-repo` face, never as a `vui-button` -- so the
top line reads `owner/repo` (or `owner/repo#N`) on every page, with no
brackets.  It is RET-able to the repo page through `octocat-vui-row`, which makes the
whole text RET-able without brackets, with `help-echo` "RET: open
repository page".

### The tab strip

The repo page and the issue / PR / Actions list pages share
one strip, `octocat-vui-repo-tabs`, imitating GitHub's repository tabs:

```
owner/repo  [Code]  [Issues (N)]  [Pull requests (N)]  [Actions]
```

- Tabs are buttons (bracketed), so they follow the rule above.
- The tab of the page being shown is drawn as an un-bracketed
  `octocat-section-heading` and is not clickable.
- Code is the repo page itself, as on GitHub, so it is current there.
  The file tree is one key away, `C-c C-t`, rather than a tab.
- On list pages the counts are `(…)` until known; the repo page passes the
  open counts from its summary.
- Pages that show the strip put it on the top line, next to the repo name.
  Item counts
  ("N open · M closed") go on their own dimmed line.
- `octocat-vui-repo-tabs` reads `octocat--repo-tabs`, so labels and help
  text stay in one place.
- The commands behind the tabs, `octocat-issue-list`, `octocat-pr-list` and
  `octocat-actions`, take the repo as an optional argument: a buffer's
  repo is not derivable from its mode or `default-directory`.

### Tabs over content

Tabs that switch what is shown below them (a PR's Conversation / Commits / Files
changed, the repo page's README / License) use `octocat-vui-tab-row`: the
row is underlined across the page, like GitHub's tab bar, so it reads as
a header rather than the content's first line, with no blank line after.

### Detail pages

Detail pages (PR, issue, PR diff, commit, checks, workflow, run, job) do
not show the strip: it belongs to the top-level pages.  Their top line is
only the identity, RET-able to the repo page:

```
owner/repo#42
OPEN  The PR title  labels

owner/repo@abc1234
The commit subject
```

A commit (and its checks page) is identified as `owner/repo@sha`, the
short SHA in `octocat-commit-sha`, as an issue or PR is by `owner/repo#N`.
