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
