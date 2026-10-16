# octocat.el

A GitHub client for Emacs, powered by the [`gh`](https://cli.github.com/) command-line tool.

> **Note:** This project was largely written with the assistance of LLMs (Claude).
> Source files carry an `Assisted-by:` header line per the [MELPA attribution convention](https://github.com/melpa/melpa/blob/master/CONTRIBUTING.org).

## Overview

`octocat.el` integrates GitHub workflows directly into Emacs by leveraging the official GitHub CLI (`gh`). It provides a convenient Emacs interface for common GitHub operations without leaving your editor.

## Requirements

- [Emacs](https://www.gnu.org/software/emacs/) 29.1 or later
- [GitHub CLI (`gh`)](https://cli.github.com/) — must be installed and authenticated
- [vui.el](https://melpa.org/#/vui) — declarative UI library every octocat buffer is drawn with, from MELPA

### Installing `gh`

```bash
# macOS
brew install gh

# Linux (Debian/Ubuntu)
sudo apt install gh

# Windows
winget install --id GitHub.cli
```

Then authenticate:

```bash
gh auth login
```

## Installation

Clone the repository and add it to your Emacs load path:

```emacs-lisp
(add-to-list 'load-path "/path/to/octocat.el")
(require 'octocat)
```

## Usage

### GitHub account dashboard (`M-x octocat`)

Run `M-x octocat` to open the GitHub account dashboard in a global
`*octocat*` buffer.  The dashboard shows two sections:

- **Recent Repositories** — your most-recently-pushed repos; press `RET`
  on a row to open its per-repository buffer, or `C-c C-o` to open
  it on GitHub.
- **Feed** — recent activity events across your account; press `RET` on
  an event to open the related commit, PR, issue or repo, and `+` to load
  more events.

### Per-repository view (`M-x octocat-repo`)

Run `M-x octocat-repo` inside any Git repository that has a GitHub `origin`
remote.  This opens a per-repo buffer listing Pull Requests, Issues,
Workflow Runs, and Commits.

Below the latest commits (`octocat-repo-commits-page-size`, 10 by
default, with a button to load more) the page shows the repository's
README, as GitHub does under its file list.  A selector above it offers
the other documents found at the root of the branch shown — Code of
conduct, Contributing, License and Security — and `RET` on one shows it
in place of the README.  Only the first `octocat-repo-doc-lines` (20)
lines show, the rest folded behind a "more lines" row that `RET`
expands.  Markdown files are rendered; `C-c C-v` shows them
raw.  Other files, such as a plain-text LICENSE, are shown as they are.

### Pull request and issue lists (`M-x octocat-pr-list`, `M-x octocat-issue-list`)

Each list shows a page of items, filtered by the query field above it,
with a button to load the next page.  An item takes two lines: its
state, title and labels, then its number, author, age, review, checks
and comments.  `C-c C-v` switches the page to a compact view of one line
per item — state, `#N`, title, labels and author — which fits more on
screen, so it loads `octocat-list-compact-page-size` (30) items at a time
against `octocat-list-page-size` (15) in the full view.  The choice is
remembered per repository and page in `octocat-settings-file`, so it
survives restarting Emacs; pages start in the full view.

### PR detail view (`octocat-pr-mode`)

Press `RET` on any PR row to open its detail buffer.  The buffer contains the
following collapsible sections (toggle with `TAB`):

| Section | Contents |
|---------|----------|
| **Info** | Title (editable), author, head→base branch, creation / merge / close date, diff stats |
| **Body** | The PR description (editable) |
| **Commits (N)** | One line per commit: short SHA · subject · author |
| **Checks (N)** | CI check name, workflow, and pass/fail/pending icon |
| **Reviews (N)** | Reviewer login and review state |
| **Comments (N)** | Commenter login and a truncated snippet (your own comments are editable) |

#### Tabs

Under the header, as on GitHub, a tab row switches between the PR's
pages: **Conversation** (this timeline), **Commits (N)** and **Files
changed (N)**.  `RET` on a tab opens that page in its own buffer.  The
Commits page lists the PR's commits oldest first, grouped under a
"Commits on <day>" heading per day; `RET` on one opens the commit and
`C-c C-o` opens the PR's commits on GitHub.  It reuses the PR page's
data, so it fetches nothing more.

#### Inline editing

`RET` is context-sensitive in the PR detail buffer:

| Point position | Action |
|----------------|--------|
| **Title** row in Info | Prompts in the minibuffer to rename the PR title |
| **Changes** row in Info | Opens the full diff view |
| Commit row | Opens the commit detail view |

Use `C-c C-e` to edit the body or a comment you authored.

#### Commit navigation

From the **Commits** section, press `RET` on a commit line to open the commit
detail view (see below).  Press `o` (or `C-c C-o`) on a commit line to open
it directly in your browser.

---

### Commit detail view (`octocat-commit-mode`)

Navigate to a commit from the PR detail view (press `RET` on a commit row).
The commit buffer:

```
owner/repo@a1b2c3d  [Code]  [Issues]  [Pull requests]  [Actions]
Commit subject line
Jane Doe  <jane@example.com> · @jane · 3 days ago
SHA a1b2c3d…

Message
  <optional multi-line commit body>

Checks (2)
  ✓  build                github-actions        1m 2s

Files (3)
  M src/foo.el  +12 -3
  @@ -10,6 +10,18 @@
   (context line)
  +(added line)
  -(removed line)
  A src/bar.el  +40 -0

Comments (1)
  …
```

Each file is collapsible.  The Comments section shows only when the
commit has comments.  `RET` on the top line opens the repo, on a
check opens the commit's checks.

---

### File tree browser (`octocat-tree-mode`)

From any per-repository buffer, press `C-c C-t` to open an interactive file
tree browser for the branch the repo page shows (the default branch unless
switched there).  The **[Code]** tab in the header of the list pages leads
to the repo page itself, as on GitHub.

```
owner/repo  ⎇[main ▾]  [Code]
▸ src/
▸ tests/
  .gitignore
  README.md
```

- **`RET`** on a directory fetches its children on first use (shown as
  "Loading…") and caches them; subsequent presses toggle expand/collapse
  without re-fetching.  `TAB` on a directory toggles it too, and moves to
  the next button elsewhere; `^` goes to the containing directory; `n` /
  `p` move between entries.
- Under Evil, as in treemacs-evil: `l` opens or toggles, `h` collapses or
  goes to the containing directory, and `TAB` walks the entries.
- **`RET`** on a file opens it in `octocat-file-mode` with syntax
  highlighting applied via the normal major-mode machinery.
- **`C-c C-f`** opens a fuzzy file finder (`completing-read`) over the full
  recursive file list of the repository.  The list is fetched on first use
  and cached for subsequent calls; pressing `C-c C-f` again is instant.  Selecting
  a path opens it directly in `octocat-file-mode` without navigating the
  tree manually.
- **`C-c C-b`** or `RET` on `[main ▾]` browses another branch.
- **`o` / `C-c C-o`** opens the selected file or directory on GitHub in
  the browser.
- **`gr`** re-fetches the root tree from scratch, clearing the subtree cache.
- **`q`** closes the buffer.

#### File viewer (`octocat-file-mode`)

`RET` on a file entry opens a read-only buffer showing the raw file content
with syntax highlighting inferred from the file extension.  Press `o` (or
`C-c C-o`) to open the file on GitHub, `C-c C-l` to open the file's commit
history, and `gr` to reload.

#### File commit log (`octocat-file-log-mode`)

Press `C-c C-l` from a file viewer buffer to open the commit history for that
file.  The log buffer lists up to 25 commits that touched the file, one per
row:

```
owner/repo  src/foo.el  (7 commits)
  a1b2c3d  2026-06-01       Jane Doe          Refactor parser logic
  f4e5d6c  2026-05-28       Bob Smith         Fix edge case in tokeniser
  …
```

- **`RET`** on a commit row opens its full commit detail view.
- **`o` / `C-c C-o`** opens the commit on GitHub in the browser.
- **`gr`** re-fetches the commit list from the API.
- **`q`** closes the buffer.

---

### Keybindings

| Key | Action |
|-----|--------|
| `RET` | Context-dependent: open detail view, navigate to commit, or inline-edit title / body / comment at point |
| `C-c C-o` | Open item at point in browser |
| `C-c C-a` | Add a comment (PR and issue detail views); submit a review (PR files changed view; `C-c C-t` picks Comment / Approve / Request changes) |
| `C-c C-e` | Edit body or comment at point (PR and issue detail views) |
| `C-c C-m` | Merge the PR (PR detail view): edit the commit message, `C-c C-t` picks Merge / Squash / Rebase, `C-c C-d` toggles deleting the branch, `C-c C-c` merges |
| `C-c C-v` | Toggle between rendered and raw markdown (repo page, PR, commit, and issue detail views); toggle the compact view (PR and issue lists) |
| `C-c C-t` | Open file tree browser (repo buffer) |
| `C-c C-b` | Pick the branch shown (repo buffer's commits, file tree); `[reset to main]` on the repo page goes back to the default branch |
| `C-c C-f` | Open fuzzy file finder — `completing-read` over the full recursive file list; works from both the repo buffer and the file tree browser (list is cached after first fetch) |
| `C-c C-l` | Open file commit log — shows the commit history for the file currently open in `octocat-file-mode` |
| `g` / `gr` | Refresh current buffer |
| `q` | Back to the previous page, or out of octocat (see below) |
| `TAB` | Expand / collapse section at point |
| `S-TAB` | Cycle visibility of all sections |

RET opens a page in the same window and `q` steps back, as in Magit (see
[UI conventions](docs/user-interface-conventions.md#windows-opening-pages-and-q)).
On Doom Emacs, let `q` reach octocat pages with
`(add-hook 'doom-real-buffer-functions #'octocat-buffer-p)`.

### github.com links

Following a github.com link anywhere in Emacs (`RET` on a link in a
comment, `browse-url`, Org links, …) opens it in octocat when there is a
view for it: users, repositories, PRs and their diffs, issues, commits,
workflows, runs, jobs, and a repository's PR, issue, Actions and file
tree pages.  Other links still open in the browser, and `C-c C-o` always
does.  Set `octocat-open-github-urls` to nil to turn this off.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions and guidelines.

## Development

### Running the linter

The `test` Makefile target runs `checkdoc` and
[`package-lint`](https://github.com/purcell/package-lint) inside an
Emacs 29 Docker container — no local Emacs install required.

```bash
make test
```

> **Requires:** Docker

The image used is [`silex/emacs:29.4`](https://hub.docker.com/r/silex/emacs).
Override it with `EMACS_IMAGE` if you need a different version:

```bash
make test EMACS_IMAGE=silex/emacs:29.1
```

### CI

GitHub Actions runs `make test` automatically on every push and pull request.
See [`.github/workflows/test.yml`](.github/workflows/test.yml).

## License

This project is licensed under the [GNU GENERAL PUBLIC LICENSE](LICENSE).
