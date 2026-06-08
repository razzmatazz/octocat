# CI Improvement Plan: Migrating to Eask

## Current State

`make test` in the current `Makefile`:

- Builds a local Docker image on **every run** (slow, ~1–2 min before any tests)
- Installs `package-lint` and `magit-section` from MELPA **at runtime** (network-dependent, slow)
- All orchestration is a long chain of `--eval` flags passed directly to `emacs --batch`
- Only tests against one Emacs version (`silex/emacs:29.4`)
- No test runner — only byte-compile, `checkdoc`, and `package-lint`

## Proposed: Eask + `silex/emacs` CI Images

### Why Eask

- Replaces the ad-hoc `--eval` chain with clean CLI commands (`eask compile`, `eask lint checkdoc`, `eask lint package`, `eask test ert`)
- Handles dependency installation into a sandboxed `.eask/` directory automatically
- Pre-built `silex/emacs:<version>-ci-eask` images have Eask already on `$PATH` — no local image build step needed
- Makes it trivial to test against multiple Emacs versions by swapping the image tag

### The `silex/emacs` eask image family

Tags follow the pattern `<version>-ci-eask` (Debian, CI-optimised):

```
silex/emacs:28.2-ci-eask
silex/emacs:29.4-ci-eask   ← current baseline
silex/emacs:30.2-ci-eask
silex/emacs:snapshot-ci-eask
```

`eask` is on `$PATH` in all of these. No local `Dockerfile` or `docker build` needed.

---

## The `Eask` File

Based on `octocat.el`'s `Package-Requires` header (`(emacs "29.1") (magit-section "3.0") (transient "0.4")`):

```scheme
;; -*- mode: eask; lexical-binding: t -*-

(package "octocat"
         "0.1.0"
         "GitHub Client powered by the gh CLI")

(website-url "https://github.com/octocat.el/octocat.el")
(keywords "tools" "vc" "github")

(package-file "octocat.el")

(source "gnu")
(source "melpa")

(depends-on "emacs"         "29.1")
(depends-on "magit-section" "3.0")
(depends-on "transient"     "0.4")
```

No need to add `package-lint` as a dev dependency — `eask lint package` auto-installs it into the sandbox on first use.

---

## New `Makefile`

```makefile
EMACS_VERSION ?= 29.4-ci-eask
IMAGE         := silex/emacs:$(EMACS_VERSION)
SRC           := /src

DOCKER := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
ifeq ($(DOCKER),)
  $(error Neither docker nor podman found on PATH)
endif

DOCKER_RUN = $(DOCKER) run --rm \
               -v "$(CURDIR)":$(SRC) \
               -w $(SRC) \
               $(IMAGE)

.PHONY: compile lint test ci

compile:
	$(DOCKER_RUN) eask compile

lint:
	$(DOCKER_RUN) sh -c "eask install-deps --dev && eask lint checkdoc && eask lint package"

test:
	$(DOCKER_RUN) sh -c "eask install-deps --dev && eask test ert"

ci: compile lint test
```

Key changes vs. current:
- No `docker build` step — uses pre-built `silex/emacs:29.4-ci-eask` directly
- `EMACS_VERSION` is overridable: `make ci EMACS_VERSION=28.2-ci-eask`
- Source directory is mounted as a volume; `.eask/` will be written there (add to `.gitignore`)

---

## GitHub Actions CI

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        emacs-version: [29.1, 29.4, 30.2, snapshot]

    steps:
      - uses: actions/checkout@v4

      - uses: jcs090218/setup-emacs@master
        with:
          version: ${{ matrix.emacs-version }}

      - uses: emacs-eask/setup-eask@master
        with:
          version: snapshot

      - name: Install dependencies
        run: eask install-deps --dev

      - name: Byte-compile
        run: eask compile

      - name: Lint checkdoc
        run: eask lint checkdoc

      - name: Lint package-lint
        run: eask lint package

      - name: Run ERT tests
        run: eask test ert
```

Notes:
- Uses `jcs090218/setup-emacs` (not `purcell/setup-emacs`) — supports Windows if we ever add it
- Matrix starts at `29.1` to match `Package-Requires` minimum
- `eask install-deps --dev` is a separate step so its output is visible in CI logs
- `eask test ert` will be a no-op (exits 0) until we add test files — safe to include now

---

## Eask Lint Commands Reference

| Command | What it checks | Dep needed? |
|---|---|---|
| `eask lint checkdoc` | Docstring format, punctuation, completeness | Built-in |
| `eask lint package` | MELPA/ELPA packaging rules via `package-lint` | Auto-installed |
| `eask lint declare` | `declare-function` correctness | Built-in |
| `eask lint elint` | Elisp syntax / undefined variables | Built-in |
| `eask lint regexps` | Suspicious regexps via `relint` | Auto-installed |
| `eask lint indent` | Indentation consistency | Auto-installed |
| `eask lint keywords` | Validates `Keywords:` header | Built-in |

Start with `checkdoc` + `package` (what we have now). Add `declare` and `regexps` later.

---

## Migration Steps

1. Create `Eask` file (see above)
2. Update `Makefile` (see above) — remove `Dockerfile` and old `image:` target
3. Add `.eask/` to `.gitignore`
4. Add `.github/workflows/ci.yml` (see above)
5. Delete `Dockerfile` (no longer needed)
6. Run `make ci` locally to verify

---

## What We Lose / Trade-offs

| Current | After |
|---|---|
| Hermetic: deps always installed fresh | `.eask/` cache persists on local runs (faster) |
| Single Emacs version tested | Matrix over 29.1 / 29.4 / 30.2 / snapshot |
| No ERT tests wired up | ERT command in place, ready for test files |
| `Dockerfile` in repo | No `Dockerfile` needed |
| `make image` separate step | No image build step at all |
