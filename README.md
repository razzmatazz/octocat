# octocat.el

A GitHub client for Emacs, powered by the [`gh`](https://cli.github.com/) command-line tool.

## Overview

`octocat.el` integrates GitHub workflows directly into Emacs by leveraging the official GitHub CLI (`gh`). It provides a convenient Emacs interface for common GitHub operations without leaving your editor.

## Requirements

- [Emacs](https://www.gnu.org/software/emacs/) 27.1 or later
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

_Usage instructions and key bindings will be documented here as the project develops._

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
