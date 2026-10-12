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
| A foldable block | `vui-collapsible` for a plain title; `octocat-vui-fold` with `octocat-vui-fold-header` when the title has its own faces or the body should be built only once unfolded (see "Folds") |

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

Text a user may copy out verbatim (diff lines, code, job logs) starts at column 0,
so it pastes as-is.  Decoration (headings, comment boxes) may indent.

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
other items are opened with `browse-url` using a constructed URL.

---

## Navigating back to the parent repo view

Every detail view belongs to a GitHub repository.  Its top line starts with
the item's identity, RET-able to the repo view: `owner/repo#N` for a PR,
its diff and an issue, `owner/repo@sha` for a commit and its checks, and
`owner/repo` for a workflow, run or job (`octocat-vui-actions-top-row`).
The line shows from the moment the buffer opens, before any data arrives.

---

## Indicating that a page is loading or refreshing

While anything is being fetched (open, `gr`, `Load N more…`), the mode
line shows `(Octocat-PR:loading)`: `mode-line-process`, as in
`(Compilation:run)`.  It never reflows the page.

- Any component whose fetch is pending or `:refreshing` calls
  `octocat-vui-use-mode-line-loading`; no need to lift the state up.
- A first-load `(loading…)` placeholder in place of content is fine.

---

## Revealing more rows ("Load N more…")

Rows that a `[+] Load N more…` button brings in **unfold** one frame at a
time, the way the rest of a long PR body or comment does when its fold
marker is expanded: slowly at first, then faster, a fraction of what is
already shown per frame (`octocat-vui-unfold-growth`, every
`octocat-vui-unfold-interval` seconds).  The list never jumps by a whole
page.

- Draw a pageable list with `octocat-vui-reveal-list` (ITEMS, ROW-FN,
  KEY-FN) instead of `vui-list`.  It shows everything on the first render
  -- cached paint, `gr` -- and only animates items that arrive afterwards.
- Compute shared column widths (`octocat-repo-vui--layout`, author
  width, ...) from **all** the items *before* the call, so columns do not
  shift while rows appear.
- Keep the load-more button below the list, with its `:key`, so point stays
  on it while the rows unfold.
- Folded text uses the same constants through `octocat-timeline-fold`;
  tune the pace in `octocat-vui.el` and both follow.

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

The repo page, the issue / PR / Actions list pages and the file tree share
one strip, `octocat-vui-repo-tabs`, imitating GitHub's repository tabs:

```
owner/repo  [Code]  [Issues (N)]  [Pull requests (N)]  [Actions]
```

- Tabs are buttons (bracketed), so they follow the rule above.
- The tab of the page being shown is drawn as an un-bracketed
  `octocat-section-heading` and is not clickable.
- The repo page itself is home: no tab is current there.
- On list pages the counts are `(…)` until known; the repo page passes the
  open counts from its summary.
- Pages that show the strip put it on the top line, next to the repo name.
  Item counts
  ("N open · M closed") go on their own dimmed line.

### Detail pages

Detail pages (PR, issue, PR diff, commit, checks, workflow, run, job) carry
the same strip on their top line, right after `owner/repo#N`, so every page of a
repository has one header and a way back to the lists and the tree.

The top line holds only the identity and the strip.
The item's title goes on the row below it:

```
owner/repo#42  [Code]  [Issues]  [Pull requests]  [Actions]
OPEN  The PR title  labels

owner/repo@abc1234  [Code]  [Issues]  [Pull requests]  [Actions]
The commit subject
```

A commit (and its checks page) is identified as `owner/repo@sha`, the
short SHA in `octocat-commit-sha`, as an issue or PR is by `owner/repo#N`.

- The tab the page belongs to (Pull requests for a PR and its diff, Issues
  for an issue, Actions for workflow / run / job, Code for a commit and
  its checks) is drawn in `octocat-section-heading`, but stays a button:
  it opens the list, not the page itself.
- Pages use `octocat-vui-repo-tabs` with its HIGHLIGHT argument.  It reads
  `octocat--repo-tabs`, so labels and help text stay in one place.
- Counts are shown only where they are known (the repo page).
- The commands behind the tabs, `octocat-issues`, `octocat-prs` and
  `octocat-actions`, take the repo as an optional argument: a detail
  buffer's repo is not derivable from its mode or `default-directory`.
