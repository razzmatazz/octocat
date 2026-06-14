# Plan: Rename Root Mode to `octocat-repo` + Introduce `octocat` Dashboard

## Goal

Split the current entry point into two distinct commands:

| Command | What it opens |
|---|---|
| `M-x octocat` | (new) GitHub account dashboard — recent repos, activity feed |
| `M-x octocat-repo` | (renamed) Per-repo buffer — PRs, Issues, Workflows, Commits (current behaviour) |

The new `octocat` dashboard is implemented as part of this plan with
hardcoded/imaginary data as a scaffold for the real API calls later.

---

## Affected Files

| File | Kind of change |
|---|---|
| **`octocat-repo.el`** | **New file** — receives all repo-mode symbols moved out of `octocat.el` |
| `octocat.el` | Gutted to a thin loader; retains dashboard mode, shared commands (`octocat-visit`, `octocat-browse`), and `(provide 'octocat)` |
| `octocat-evil.el` | Update `declare-function` / `defvar` ref to `octocat-repo-mode-map`; add evil bindings for new dashboard `octocat-mode` |
| `test/octocat-tests.el` | Update any references to renamed symbols |
| `README.md` | Update usage docs |
| Sub-modules (`octocat-pr.el`, `octocat-issue.el`, `octocat-commit.el`, `octocat-run.el`, `octocat-workflow.el`, `octocat-pr-diff.el`, `octocat-checks.el`, `octocat-job.el`) | **No changes needed** — their `declare-function` stubs and keymap bindings for `octocat-visit`/`octocat-browse` are unaffected |

---

## Symbol Rename Map

All renamed symbols **move to `octocat-repo.el`** (new file) unless noted otherwise.
`octocat-visit`, `octocat-browse`, and the new dashboard symbols stay in `octocat.el`.

### Mode infrastructure

| Old name | New name |
|---|---|
| `octocat-mode` | `octocat-repo-mode` |
| `octocat-mode-map` | `octocat-repo-mode-map` |
| `"Octocat"` (modeline string) | `"Octocat-Repo"` |

### User-facing commands (public, autoloaded)

| Old name | New name | Notes |
|---|---|---|
| `octocat` *(entry point, autoloaded)* | `octocat-repo` *(entry point, autoloaded)* | |
| `octocat-refresh` | `octocat-repo-refresh` | |
| `octocat-visit` | **unchanged** | shared by both modes |
| `octocat-browse` | **unchanged** | shared by both modes |
| `octocat-load-more` | `octocat-repo-load-more` | |

`octocat-visit` and `octocat-browse` are general-purpose navigation commands
that work on any `magit-section` with the right section value — they are just
as useful in the dashboard as in the repo buffer. Keeping them as plain
`octocat-visit` / `octocat-browse` (defined in `octocat.el`, not prefixed with
`repo`) means sub-modules and the new dashboard mode can share them without
circular dependencies.

### Internal functions

| Old name | New name |
|---|---|
| `octocat--current-repo` | `octocat-repo--current-repo` |
| `octocat--disabled-feature-p` | `octocat-repo--disabled-feature-p` |
| `octocat--list-workflows` | `octocat-repo--list-workflows` |
| `octocat--list-workflow-runs` | `octocat-repo--list-workflow-runs` |
| `octocat--list-recent-runs` | `octocat-repo--list-recent-runs` |
| `octocat--list-commits` | `octocat-repo--list-commits` |
| `octocat--fetch-default-branch` | `octocat-repo--fetch-default-branch` |
| `octocat--hide-if-saved` *(macro)* | `octocat-repo--hide-if-saved` |
| `octocat--render-prs` | `octocat-repo--render-prs` |
| `octocat--render-issues` | `octocat-repo--render-issues` |
| `octocat--render-workflows` | `octocat-repo--render-workflows` |
| `octocat--render-workflow-runs` | `octocat-repo--render-workflow-runs` |
| `octocat--render-commits` | `octocat-repo--render-commits` |
| `octocat--render-loading` | `octocat-repo--render-loading` |
| `octocat--render` | `octocat-repo--render` |
| `octocat--save-section-state` | `octocat-repo--save-section-state` |
| `octocat--pageable-section-at-point` | `octocat-repo--pageable-section-at-point` |
| `octocat--evil-init` | `octocat-repo--evil-init` |

### User options (defcustom)

The four per-section limit vars collapse into **one**:

| Old names | New name |
|---|---|
| `octocat-prs-limit` | (removed) |
| `octocat-issues-limit` | (removed) |
| `octocat-runs-limit` | (removed) |
| `octocat-commits-limit` | (removed) |
| *(new)* | `octocat-section-limit` |

`octocat-section-limit` (default `15`) is the single page size used for every
section in the repo buffer. All four sections (PRs, Issues, Runs, Commits) start
with this many items and increment by this amount on each `load-more`.

The name is intentionally un-prefixed with `repo-` so it can be shared with
dashboard sections in the future without a rename.

> `octocat-workflow-runs-limit` in `octocat-workflow.el` is a separate
> per-mode limit that belongs to the workflow detail view — it is **not**
> collapsed here and stays as-is (or follows its own rename convention).

### Buffer-local variables (defvar-local)

| Old name | New name |
|---|---|
| `octocat--repo` | `octocat-repo--repo` |
| `octocat--current-branch` | `octocat-repo--current-branch` |
| `octocat--section-hidden` | `octocat-repo--section-hidden` |
| `octocat--prs-count` | (removed — see below) |
| `octocat--issues-count` | (removed — see below) |
| `octocat--commits-count` | (removed — see below) |
| `octocat--runs-count` | (removed — see below) |
| *(new)* | `octocat-repo--counts` |

The four separate per-section count vars collapse into a single alist
`octocat-repo--counts`, initialized to `nil` and populated on first refresh:

```elisp
(defvar-local octocat-repo--counts nil
  "Alist mapping section-type symbol to current item count.
Keys: prs, issues, commits, recent-runs.
Nil until first refresh; each key is then initialised from
`octocat-section-limit' and incremented by `octocat-repo-load-more'.")
```

Usage pattern:

```elisp
;; init on first refresh (instead of four separate unless blocks):
(dolist (key '(prs issues commits recent-runs))
  (unless (alist-get key octocat-repo--counts)
    (setf (alist-get key octocat-repo--counts) octocat-section-limit)))

;; fetch count for a section:
(alist-get 'prs octocat-repo--counts)

;; increment on load-more:
(cl-incf (alist-get 'prs octocat-repo--counts) octocat-section-limit)
```

The "at defaults" check in `octocat-repo-refresh` (currently four `=` comparisons)
becomes a single `seq-every-p`:

```elisp
(seq-every-p (lambda (pair) (= (cdr pair) octocat-section-limit))
             octocat-repo--counts)
```

### Buffer name pattern

| Old | New |
|---|---|
| `"*octocat: %s*"` | `"*octocat-repo: %s*"` |

### Feature / provide

| File | Feature provided |
|---|---|
| `octocat-repo.el` | `(provide 'octocat-repo)` — new |
| `octocat.el` | `(provide 'octocat)` — unchanged |

`octocat.el` `(require 'octocat-repo)` near the top, just as it currently
requires the other sub-modules. The `octocat-repo.el` file in turn requires
`octocat-core` and the sub-modules it renders (same list `octocat.el` required
before: `octocat-pr`, `octocat-issue`, etc.).

---

## Cross-File `declare-function` Updates

### Sub-modules → no changes

`octocat-visit` and `octocat-browse` are not renamed and remain in `octocat.el`,
so the `declare-function` stubs in every sub-module (`octocat-pr.el`,
`octocat-issue.el`, etc.) are unaffected.

### `octocat-repo.el` → needs stubs for shared commands

`octocat-repo.el` binds `#'octocat-visit` and `#'octocat-browse` in its
keymap, but cannot `require 'octocat` (that would be circular — `octocat.el`
requires `octocat-repo`). Add `declare-function` stubs at the top of
`octocat-repo.el`, exactly as sub-modules do today:

```elisp
(declare-function octocat-visit  "octocat" ())
(declare-function octocat-browse "octocat" ())
```

### `octocat-evil.el` → rename load-more stub only

```elisp
;; Old
(declare-function octocat-load-more "octocat" ())

;; New — function now lives in octocat-repo.el but declare-function
;; source string should point to the file that defines it:
(declare-function octocat-repo-load-more "octocat-repo" ())
```

---

## `octocat-evil.el` Specifics

`octocat-evil.el` references the old names in several ways:

1. `(declare-function octocat-visit …)` — **no change**
2. `(declare-function octocat-browse …)` — **no change**
3. `(declare-function octocat-load-more "octocat" ())` → `(declare-function octocat-repo-load-more "octocat-repo" ())`
4. `(defvar octocat-mode-map)` forward declaration → `(defvar octocat-repo-mode-map)` (source `"octocat-repo"`)
5. All `evil-define-key*` calls against `octocat-mode-map` → `octocat-repo-mode-map`;
   bindings to `#'octocat-visit` and `#'octocat-browse` stay; only
   `#'octocat-load-more` → `#'octocat-repo-load-more`.
6. A new binding block for the dashboard `octocat-mode-map` must be added
   (the map is defined in `octocat.el`; `octocat-evil.el` can reference it
   directly since `octocat.el` is already loaded by the time evil setup runs),
   binding at minimum `q`, `RET` (`octocat-visit`), `o` / `C-c C-o`
   (`octocat-browse`).

---

## New `octocat` Dashboard (stays in `octocat.el`)

After the rename, `M-x octocat` becomes a new, separate command backed by a
new `octocat-mode`. The dashboard is implemented with **hardcoded/imaginary
data** as a scaffold; the real `gh` API calls are wired up in a follow-up.

```
octocat-mode          ← new; parent: magit-section-mode
octocat-mode-map      ← new keymap (q, RET, o, C-c C-o at minimum)
octocat (defun)       ← autoloaded entry point; opens *octocat* buffer
octocat-refresh       ← renders dashboard sections (calls gh, falls back to stubs)
```

### Buffer name

`*octocat*` — a single global buffer (no per-repo qualifier).

### Sections

#### 1. Recent Repositories

A collapsible `magit-section` headed **Recent Repositories**, listing the
most-recently-pushed repos for the authenticated user.

- **API**: `gh api user/repos --jq 'sort_by(.pushed_at) | reverse | .[:10]'`
  returning fields: `full_name`, `description`, `pushed_at`, `language`.
- **Stub data**: a hardcoded list of 3–5 imaginary repo entries so the buffer
  renders correctly before the API call is wired up.
- Each row is a clickable section value of type `repo`; `RET` calls
  `octocat-visit` (opens `octocat-repo` for that repo); `o` / `C-c C-o` calls
  `octocat-browse` (opens it in the browser).

#### 2. Feed (Activity)

A collapsible `magit-section` headed **Feed**, showing recent activity
events for the authenticated user (what you see on github.com home).

- **API**: `gh api /users/{username}/received_events --jq '.[:20]'`
  — available only for the authenticated user's own feed (public API).
  If the call fails or returns empty, the section is hidden/omitted rather
  than showing an error.
- **Stub data**: a hardcoded list of 3–4 imaginary events (e.g. push to
  `owner/repo`, PR opened in `owner/other-repo`) covering a representative
  mix of event types.
- Each row displays: event type icon/label, actor, repo, timestamp.
- Sections are read-only display items (no RET action needed for the stub;
  add visit/browse behaviour when real data lands).

### Rendering approach

Mirror the existing async pattern used in `octocat-repo-refresh`:

1. Insert stub/loading placeholders synchronously on first render.
2. Kick off `gh` calls asynchronously via `octocat-core`'s runner.
3. In the callback, re-render the affected section in-place (or call
   `octocat-refresh` to redraw the whole buffer).

For the stub implementation it is acceptable to render the hardcoded data
synchronously with no async step — the structure is what matters.

---

## Implementation Order

Steps are sequential. Sub-module files need no edits at all.

1. **Create `octocat-repo.el`** — new file containing all the renamed repo-mode
   symbols (moved verbatim from `octocat.el`, then renamed per the symbol map
   above). Must include:
   - File header (`;;; octocat-repo.el --- …`)
   - `(require 'octocat-core)` and all sub-module requires that `octocat.el`
     currently holds (`octocat-pr`, `octocat-issue`, `octocat-commit`,
     `octocat-run`, `octocat-workflow`, `octocat-pr-diff`, `octocat-checks`,
     `octocat-job`)
   - `(declare-function octocat-visit "octocat" ())` and
     `(declare-function octocat-browse "octocat" ())` stubs (can't require
     `octocat` — circular)
   - All renamed `defcustom`, `defvar-local`, `defvar` (forward decls for
     sub-module buffer-locals), macro, and `defun` forms
   - `;;;###autoload` cookie on `octocat-repo`
   - `(provide 'octocat-repo)` at the bottom

2. **Gut and rewrite `octocat.el`** — remove all content that moved to
   `octocat-repo.el`; what remains:
   - File header and `Package-Requires`
   - All `require` calls (add `(require 'octocat-repo)`)
   - `octocat-visit` and `octocat-browse` (shared commands — stay here)
   - New `octocat-mode`, `octocat-mode-map`, `octocat-refresh`, `octocat`
     dashboard entry point (see dashboard section above)
   - `octocat--evil-init` call at the bottom (if it stays in `octocat.el`)
   - `(provide 'octocat)` at the very end

3. **`octocat-evil.el`** — update `declare-function` / `defvar` refs and all
   `evil-define-key*` call sites; add a new binding block for `octocat-mode-map`.

4. **`test/octocat-tests.el`** — search for references to any renamed symbol
   and update.

5. **`README.md`** — update usage section to document both `M-x octocat` and
   `M-x octocat-repo`.

6. **Update `AGENTS.md` reload sequence** — add `(load-file "octocat-repo.el")`
   between `octocat-checks.el` and `octocat-evil.el`; update the
   `unload-feature` sequence to include `(ignore-errors (unload-feature
   'octocat-repo t))` in the right position.

7. **Verify** — run `make ci`; fix any byte-compiler warnings about undefined
   functions introduced by the rename.

---

## What Does NOT Change

- `octocat.el` keeps its name and `(provide 'octocat)`.
- The `octocat` customization group stays named `octocat`.
- All sub-module files (`octocat-pr.el`, `octocat-issue.el`, …) keep their
  names, their own mode names, their `declare-function` stubs, and their
  keymap bindings — **zero edits needed in sub-modules**.
- `octocat-visit` and `octocat-browse` keep their names and stay in `octocat.el`.
- The forward `defvar` declarations that silence the compiler for sub-module
  buffer-locals (e.g. `octocat--pr-repo`) move to `octocat-repo.el` alongside
  the repo-mode code that uses them.

---

## Decisions Made

| Question | Decision |
|---|---|
| Dashboard content | **Recent Repositories** + **Feed** sections with hardcoded stub data; see dashboard section above. |
| Obsolete aliases for `octocat-visit` / `octocat-browse` | Not needed — both functions stay as `octocat-visit` / `octocat-browse` (shared, not renamed). No aliases required. |
| Live-buffer migration on rename | **Restart Emacs.** No migration shim needed. |
