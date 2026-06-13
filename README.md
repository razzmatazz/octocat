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

### Opening the dashboard

Run `M-x octocat` inside any Git repository that has a GitHub `origin` remote.
This opens a front-page buffer listing Pull Requests, Issues, and Workflows.

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
| **Body** section | Opens a markdown edit buffer (`C-c C-c` submit, `C-c C-k` discard) |
| **Comment** you authored | Opens a markdown edit buffer to edit the comment |
| **Changes** row in Info | Opens the full diff view |
| Commit row | Opens the commit detail view |

#### Commit navigation

From the **Commits** section, press `RET` on a commit line to open the commit
detail view (see below).  Press `o` (or `C-c C-o`) on a commit line to open
it directly in your browser.

#### PR detail keybindings

| Key | Action |
|-----|--------|
| `RET` | Open item at point (commit → commit view) |
| `o` / `C-c C-o` | Open item at point in browser |
| `g` | Refresh PR data |
| `q` | Close buffer |

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

#### Commit view keybindings

| Key | Action |
|-----|--------|
| `o` / `C-c C-o` | Open commit in browser |
| `g` | Refresh commit data |
| `q` | Close buffer |

---

### Global keybindings (all octocat buffers)

| Key | Action |
|-----|--------|
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

This project is licensed under the [MIT License](LICENSE).
