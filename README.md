# octocat.el

A GitHub client for Emacs, powered by the [`gh`](https://cli.github.com/) command-line tool.

## Overview

`octocat.el` integrates GitHub workflows directly into Emacs by leveraging the official GitHub CLI (`gh`). It provides a convenient Emacs interface for common GitHub operations without leaving your editor.

## Requirements

- [Emacs](https://www.gnu.org/software/emacs/) 29.1 or later
- [GitHub CLI (`gh`)](https://cli.github.com/) — must be installed and authenticated

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
`*octocat*` buffer.  The dashboard shows two collapsible sections:

- **Recent Repositories** — your most-recently-pushed repos; press `RET`
  on a row to open its per-repository buffer, or `C-c C-o` to open
  it on GitHub.
- **Feed** — recent activity events across your account.

### Per-repository view (`M-x octocat-repo`)

Run `M-x octocat-repo` inside any Git repository that has a GitHub `origin`
remote.  This opens a per-repo buffer listing Pull Requests, Issues,
Workflow Runs, and Commits.

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
The commit buffer mirrors Magit's commit layout:

```
owner/repo  commit a1b2c3d  Commit subject line
├── Info
│     Author   Jane Doe
│     Date     2026-06-01
│     SHA      a1b2c3d…
│     <optional multi-line commit body>
└── Files (3)
      M  src/foo.el       +12 -3
         @@ -10,6 +10,18 @@
          (context line)
         +(added line)
         -(removed line)
      A  src/bar.el       +40 -0
      D  src/old.el       +0  -15
```

Each file entry is a collapsible section.  The diff hunks are rendered with
`diff-added` / `diff-removed` faces, and hunk headers (`@@…@@`) use the
`magit-diff-hunk-heading` face.

---

### File tree browser (`octocat-tree-mode`)

From any per-repository buffer, press `T` or `RET` on the **[Browse files]**
token in the header to open an interactive file tree browser for the current
branch.

```
owner/repo  ⎇  main  [Browse files]
▸ src/
▸ tests/
  .gitignore
  README.md
```

- **`TAB`** on a directory fetches its children on first use (shown as
  "Loading…") and caches them; subsequent presses toggle expand/collapse
  without re-fetching.
- **`RET`** on a file opens it in `octocat-file-mode` with syntax
  highlighting applied via the normal major-mode machinery.
- **`o` / `C-c C-o`** opens the selected file or directory on GitHub in
  the browser.
- **`gr`** re-fetches the root tree from scratch, clearing the subtree cache.
- **`q`** closes the buffer.

#### File viewer (`octocat-file-mode`)

`RET` on a file entry opens a read-only buffer showing the raw file content
with syntax highlighting inferred from the file extension.  Press `o` (or
`C-c C-o`) to open the file on GitHub, and `gr` to reload.

---

### Keybindings

| Key | Action |
|-----|--------|
| `RET` | Context-dependent: open detail view, navigate to commit, or inline-edit title / body / comment at point |
| `C-c C-o` | Open item at point in browser |
| `C-c C-a` | Add a comment (PR and issue detail views) |
| `C-c C-e` | Edit body or comment at point (PR and issue detail views) |
| `C-c C-v` | Toggle between rendered and raw markdown (PR, commit, and issue detail views) |
| `C-c C-t` | Open file tree browser (repo buffer) |
| `g` / `gr` | Refresh current buffer |
| `q` | Close buffer |
| `TAB` | Expand / collapse section at point |
| `S-TAB` | Cycle visibility of all sections |

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
