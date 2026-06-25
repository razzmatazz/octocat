# User Interface Conventions

This document captures the visual and interaction conventions used across
octocat.el buffers, and the research behind them.

---

## Indicating that a line or section is interactive (RET-able)

### Background: what magit-section does

`magit-insert-heading` applies exactly one affordance to a heading: the
`magit-section-heading` face (bold + golden colour).  It adds **no**
`mouse-face`, `help-echo`, or `cursor-type` text property.  RET dispatches
through the major-mode keymap — `magit-section-mode-map` → the mode's own
map — with no per-line visual signal that any particular heading is
actionable.  This is the norm for *all* headings in a magit buffer; the bold
colour is the sole convention.

Where magit *does* add richer cues — its xref Back/Forward buttons and the
mode-line process indicator — it consistently uses:

```
mouse-face  'magit-section-highlight   ; highlight on hover
help-echo   "mouse-2, RET: <action>"   ; tooltip
```

Standard Emacs `buttonize` (available since Emacs 29) does the same via the
`button` face (`link`-inherited → underline + colour), `mouse-face
'highlight`, and an inline `button-map` that routes `RET` and `mouse-2` to a
callback.

### The pattern octocat.el uses

For a **`magit-insert-section` heading** that is RET-able, add `mouse-face`
and `help-echo` directly on the propertized string passed to
`magit-insert-heading`.  Do **not** use `buttonize` inside a section heading
— the button keymap would conflict with the section keymap and `mouse-face
'highlight` would clash with the existing section-highlight face.

```elisp
(magit-insert-section (pr-changes)
  (magit-insert-heading
    (concat "  Changes  "
            (propertize (format "+%d" additions)
                        'face      'diff-added
                        'mouse-face 'magit-section-highlight
                        'help-echo  "RET: open diff view")
            " "
            (propertize (format "-%d" deletions)
                        'face      'diff-removed
                        'mouse-face 'magit-section-highlight
                        'help-echo  "RET: open diff view")
            (propertize (format "  across %d file(s)" files)
                        'mouse-face 'magit-section-highlight
                        'help-echo  "RET: open diff view"))))
```

Apply `mouse-face` + `help-echo` to **every span** of the heading text,
because text properties only apply to the characters that carry them.  A gap
with no `mouse-face` would drop the highlight mid-hover.

For an **inline value on an info line** that should be independently
clickable (not the whole section), `buttonize` is the right tool:

```elisp
(insert "  URL  ")
(insert (buttonize url #'browse-url url "mouse-2, RET: open in browser"))
(insert "\n")
```

### Decision table

| Situation | Approach |
|---|---|
| Whole `magit-insert-section` heading is RET-able | `mouse-face 'magit-section-highlight` + `help-echo` on every text span |
| Inline value on a plain `insert` line is independently clickable | `buttonize` with `help-echo` |
| All headings in a view are navigable (standard magit) | No extra markers — bold face is sufficient |

---

## Editing fields: edit buffer vs. minibuffer

Two distinct mechanisms are used depending on whether the field is
single-line or multi-line:

### Multi-line fields → `octocat--open-edit-buffer`

Used for PR/issue **bodies** and **comments** — content where the user
may need multiple lines, markdown preview, and the ability to abandon
their work mid-edit.  The edit buffer derives from `gfm-mode` and
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

Three helpers in `octocat-core.el` cover every timestamp display context.
All accept an ISO-8601 UTC string (e.g. `"2026-06-08T05:47:21Z"`) and
return an empty string for `nil`, `:null`, or `""`.

### `octocat--format-ts (ts)`

Returns `"YYYY-MM-DD HH:MM"` in local time.  Use this in **compact list
rows** where horizontal space is limited and the relative age is visible at
a glance from the date alone.

```
2026-06-08 14:23
```

### `octocat--format-ts-full (ts)`

Returns `"YYYY-MM-DD HH:MM (relative)"` — the absolute timestamp followed
by a human-readable relative age in parentheses.  Use this in **detail-view
info sections** (PR, issue, commit, workflow, run, job) where there is ample
horizontal space and the relative age adds meaningful context.

```
2026-06-08 14:23 (3 days ago)
```

### `octocat--relative-ts (ts)`

Returns only the relative string (`"just now"`, `"5 minutes ago"`,
`"3 days ago"`, `"2 years ago"`, etc.).  This is the building block used
internally by `octocat--format-ts-full`.  Call it directly only when you
need the relative portion in isolation.

### Decision table

| Context | Helper | Example output |
|---|---|---|
| Compact list row (dashboard, inline sub-lists) | `octocat--relative-ts` | `3 days ago` |
| Detail-view info section (PR, issue, commit, workflow, run, job) | `octocat--format-ts-full` | `2026-06-08 14:23 (3 days ago)` |
| Absolute timestamp only (not currently used) | `octocat--format-ts` | `2026-06-08 14:23` |

### Implementation note

`octocat--relative-ts` is implemented entirely in Emacs Lisp using
`float-time` and `current-time`.  It does not call into magit, `ts.el`,
or any other external package — see the dependency rule in `AGENTS.md`.

---

## Indicating the active (currently checked-out) branch

### Background: Magit's convention

Magit marks the currently checked-out branch in its branch lists with a
combination of bold weight and an underline, using the `magit-branch-current`
face (which inherits `magit-branch-local` and adds `:underline t`).  It also
prepends a `*` glyph in some views.  The core signal is: **bold + underline
on the branch name itself**, no extra column or prefix character required.

`magit-branch-current` lives in the full `magit` package, not in
`magit-section`.  octocat.el must not depend on it directly.

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

## Opening items in the browser (`o` / `C-c C-o`)

`octocat-browse` is the single entry point for opening any item in the
browser.  It is bound to `o` and `C-c C-o` in every octocat mode.

### Dispatch order

The function dispatches in two phases:

1. **Section type** — inspects the magit section at point.  If the section
   type has a known GitHub URL, open it immediately.
2. **Major-mode fallback** — if the section type has no URL of its own
   (e.g. point is on a title/header line, a metadata label, or the root
   heading of a detail buffer), fall back to the current major mode and
   open the URL for the *item the buffer represents as a whole*.

This means `o` always does something useful regardless of where point is
within a detail view.

### Section-type dispatch table

| Section type | URL / command |
|---|---|
| `repo` | `https://github.com/OWNER/REPO` |
| `pr` | `gh pr view --web NUMBER --repo REPO` |
| `issue` | `gh issue view --web NUMBER --repo REPO` |
| `octocat-commit` | `https://github.com/REPO/commit/SHA` (uses `"oid"` key, falls back to `"sha"` for REST-API commits) |
| `workflow` | `https://github.com/REPO/actions/workflows/FILENAME` (derived from `"path"`) |
| `workflow-run` | `https://github.com/REPO/actions/runs/ID` |
| `check-run` | `html_url` from the GitHub Checks REST API response |
| `comment` | `url` from the GitHub comment object |
| `octocat-root` | `https://github.com/REPO` |

### Major-mode fallback table

| Major mode | URL opened |
|---|---|
| `octocat-pr-mode` | `gh pr view --web NUMBER --repo REPO` |
| `octocat-issue-mode` | `gh issue view --web NUMBER --repo REPO` |
| `octocat-commit-mode` | `https://github.com/REPO/commit/SHA` |
| `octocat-workflow-mode` | `https://github.com/REPO/actions/workflows/ID` |
| `octocat-run-mode` | `https://github.com/REPO/actions/runs/ID` |
| `octocat-job-mode` | `https://github.com/REPO/actions/runs/RUN_ID/job/JOB_ID` |
| `octocat-checks-mode` | `https://github.com/REPO/commit/SHA/checks` |

Each fallback reads the buffer-local variables set when the detail buffer
was opened (e.g. `octocat--pr-repo`, `octocat--pr-number`).  If those
variables are somehow unset the fallback silently does nothing.

### Using `gh` vs. `browse-url`

PRs and issues are opened via `gh pr view --web` / `gh issue view --web`
rather than a hard-coded URL.  This ensures the correct GitHub host is used
when `gh` is configured for GitHub Enterprise or an alternative host.  All
other items are opened with `browse-url` using a constructed URL.

### Implementation note

The `pcase` arms for section types return the result of their action (a
process object, `t` from `browse-url`, etc.) which is truthy.  The outer
`(or (pcase …) (cond …))` short-circuits to the `cond` fallback only when
the `pcase` falls through with `nil` — i.e. the section type was not
matched.  Both `(pcase … (_ nil))` and an explicit fall-through produce
`nil`; the fallback `cond` then checks `derived-mode-p` in order.

---

## Navigating back to the parent repo view

Every detail view (PR, issue, commit, workflow, run, job, PR diff, checks)
belongs to a GitHub repository.  A **`Repo` line** at the top of the Info
section is the breadcrumb back to the repo view for that repository.

The line is RET-able (and mouse-hoverable) — pressing RET on it opens the
`*octocat-repo: owner/repo*` buffer for that repository, exactly as if the
user had navigated there from the dashboard.

The repo name is rendered with the `octocat-repo` face and follows the same
`mouse-face` + `help-echo` convention as all other RET-able Info rows.  It
sits first in the Info section — above Title, Author, and all other fields —
so it reads as a breadcrumb rather than a metadata field.

### Placement

| View | Where the Repo line sits |
|---|---|
| PR | First in `pr-meta` section (before Title) |
| Issue | First in `issue-meta` section (before Title) |
| Commit | First in `commit-meta` section (before Author) |
| Workflow | First in `workflow-info` section (before State) |
| Run | First in `run-info` section (before Workflow) |
| Job | First in `job-info` section (before Status) |
| PR diff | First line of root section body (before Files) |
| Checks | First line of root section body (before Check Runs) |

The same line appears in both the loading skeleton and the fully-rendered
view so the breadcrumb is always visible from the moment the buffer opens.
