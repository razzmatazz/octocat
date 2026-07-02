# Octocat: RET does nothing in `octocat-repo-mode` when Evil is active

## Status (2026-07-02) — FIXED, verified via `make ci`

Worked test-first throughout: the bug was captured in an automated
regression test *before* any source fix, confirmed failing (via the real
containerized `make test` pipeline, podman), reviewed, then fixed and
re-verified. Final state:

- `test/octocat-tests.el` (existing suite): 11/11 passed throughout,
  unaffected by any of this work.
- `test/octocat-evil-repo-tests.el` (new, single test
  `octocat-evil-test-repo-entry-point-funnels-through-octocat`): failed
  pre-fix on `(should-not (fboundp 'octocat-repo))` (it was fbound — the
  command still lived in `octocat-repo.el`), now **passes** after the
  "Chosen fix design" below was implemented.
- `make ci` (compile + lint + test, full containerized pipeline): **all
  green** — 14/14 files compiled with `--strict`, 14/14 clean under both
  `checkdoc` and `package-lint`, both test suites passing.
- Reloaded live into the running Emacs session (per AGENTS.md's "Reloading
  into Emacs" workflow) and confirmed by hand: `(fboundp 'octocat-repo)` is
  `t`, and `octocat-repo-mode-map`'s normal/motion Evil aux keymaps both
  resolve `RET` to `octocat-visit`.
- Documented the new entry-point convention in `CONTRIBUTING.md` (new
  "Entry points (`;;;###autoload` commands)" section under "Code
  conventions") and corrected the outdated invariant note in `AGENTS.md`'s
  "Byte-compiler warnings" section.

Deviations from the original "Fix design" (superseded — see "Chosen fix
design" below) and from the test's first draft, in the order they came up:

- **Design pivot:** rather than relocating `octocat--evil-init` and
  duplicating its trigger across two entry-point files (the original "Fix
  design"), the actual fix centralizes *all* `;;;###autoload` commands in
  `octocat.el` (the "Chosen fix design"). This is structurally simpler —
  no relocation, no duplicated trigger, no `boundp` guard — and forecloses
  the entire bug class for any future entry point, not just this one.
- The regression test lives in its own new file,
  `test/octocat-evil-repo-tests.el`, **not** appended to
  `test/octocat-tests.el`, because that file does `(require 'octocat)` at
  load time, which would mask the bug under test. It requires only
  `octocat-repo` at the top level.
- Because `eask test ert file1.el file2.el` loads all given files into one
  shared Emacs process, the two suites run as **separate `eask test ert`
  invocations** (separate processes) — wired into the Makefile's `test`
  target.
- `evil` was added as a **development-only** dependency in `Eask` via
  `(development (depends-on "evil"))` — never a runtime dependency, kept
  out of `octocat.el`'s `Package-Requires`, matching `octocat-evil.el`'s
  existing `declare-function`-only treatment of it.
- **Test design pitfall (caught and fixed):** the first version of the new
  test split the "before" and "after" assertions into two separate
  `ert-deftest` forms, with a top-level `(require 'octocat)` placed
  between them. This silently didn't work: `eask test ert` fully loads a
  file — executing *every* top-level form — before running any test, so
  the "between the tests" `require` had actually already executed before
  either test body ran, making the intended comparison meaningless (and
  ERT does not guarantee execution order across separate `ert-deftest`
  forms besides). Fixed by combining both phases into one `ert-deftest`
  body with an explicit, guaranteed sequence.
- **Unrelated environmental gotcha hit along the way:** stale `.elc` files
  left over in the project root from an earlier, unrelated compile
  (`Jun 26`, predating this session's edits) were shadowing the freshly
  edited `.el` sources during local `eask test` runs, producing a
  confusing false signal (`(featurep 'octocat)` appearing `t` when it
  should not have been). Deleted via `find . -maxdepth 1 -name '*.elc'
  -delete` (same as the Makefile's own `clean` target) before re-testing.

## Context

In Doom Emacs, with `(:editor (evil +everywhere) ...)` and `(:tools magit ...)`
enabled, pressing `RET` in an `octocat-repo-mode` buffer (opened via
`SPC g h` → `octocat-repo`, bound in `~/.config/doom/config.el` as
`(:leader "g h" #'octocat-repo)`) does nothing — even though `describe-mode`
correctly reports:

```
RET    octocat-visit
```

The same setup works fine on another machine. The difference is not the
octocat package version (both machines run a byte-identical copy, commit
`c4257aa4da0bc8ebc19e821dfa2060ffb2642409`), but *session history*: on the
working machine, `M-x octocat` (the dashboard) had been invoked at some
point, which happens to load `octocat.el` and, as a side effect, wire up
Evil bindings for **every** octocat mode for the rest of the session. On the
broken machine, `octocat-repo` was the very first octocat command run in
that session, so that wiring never happened.

## Root cause

- `octocat-repo-mode-map` binds `RET` to `octocat-visit` directly (via
  `define-key`), with `magit-section-mode-map` as its parent. This binding
  is real and correct — hence `describe-mode` shows it.
- With Evil active, `evil-motion-state-map` (consulted through
  `emulation-mode-map-alists`, which has *higher* priority than any
  major-mode local keymap) is what actually receives `RET` unless something
  installs an aux-keymap override on `octocat-repo-mode-map` for the
  `normal`/`motion` Evil states. That override is installed by
  `octocat-evil-setup` (`octocat-evil.el`), but only if `octocat--evil-init`
  has run.
- `octocat--evil-init` is defined at the very bottom of `octocat.el`
  (lines 1037–1047, right before `(provide 'octocat)`):

  ```elisp
  (defun octocat--evil-init ()
    "Load and activate `octocat-evil' when Evil mode is enabled."
    (require 'octocat-evil)
    (octocat-evil-setup))

  ;; Run immediately if Evil is already active, otherwise hook into evil-mode.
  (if (bound-and-true-p evil-mode)
      (octocat--evil-init)
    (add-hook 'evil-mode-hook #'octocat--evil-init))

  (provide 'octocat)
  ```

  This trigger only runs when `octocat.el` itself is loaded.
- `octocat-repo.el` requires every submodule it needs
  (`octocat-core`, `octocat-pr`, `octocat-commit`, `octocat-pr-diff`,
  `octocat-issue`, `octocat-workflow`, `octocat-run`, `octocat-job`,
  `octocat-checks`, `octocat-tree`) **except `octocat.el`** — by design, to
  avoid a circular dependency (`octocat.el` requires `octocat-repo`). Its own
  comment says: *"we cannot require that file here (circular dependency), so
  declare them for the compiler."*
- Consequence: calling `octocat-repo` directly never loads `octocat.el`,
  so `octocat--evil-init` never runs, `octocat-evil-setup` is never called,
  and no Evil aux-keymap override for `RET` is ever installed on
  `octocat-repo-mode-map`. Evil's default `evil-ret` wins instead.
- `octocat-evil-setup` itself cannot simply be re-triggered as-is from
  `octocat-repo.el`, because its first block binds keys on
  `octocat-mode-map` — the **dashboard** mode's keymap, defined only in
  `octocat.el` (line 610) — which is not yet bound when `octocat-repo.el`
  loads standalone. Calling `octocat-evil-setup` from that entry point today
  would raise a `void-variable octocat-mode-map` error before it ever
  reaches the `octocat-repo-mode` bindings.

## Confirmed workaround (live session)

Verified directly on the affected machine: evaluating the following in a
scratch buffer, in an already-broken session (an `octocat-repo-mode` buffer
already open with `RET` not working), fixes `RET` immediately in that
buffer with no revert/reopen/restart required:

```elisp
(require 'octocat)
```

This confirms the root cause precisely: loading `octocat.el` is both
necessary and sufficient to install the missing Evil binding, because it
runs the dormant `octocat--evil-init` → `octocat-evil-setup` trigger, which
ends with `(evil-normalize-keymaps)` and therefore refreshes keymaps in
already-open buffers.

This is a valid **interim, session-local stopgap** (does not survive an
Emacs restart, and does not fix the upstream package) — e.g. worth noting
in `~/.config/doom/config.el` as a temporary `(after! octocat-repo (require
'octocat))`-style nudge, or simply running `M-x octocat` once per session
before `octocat-repo`, until the permanent fix below is applied.

## Findings (confirmed)

- `$HOME/.config/doom/init.el` has `(doom! ... :editor (evil +everywhere) ... :tools magit ...)`.
- `$HOME/.config/doom/packages.el`: `(package! octocat :recipe (:host github :repo "razzmatazz/octocat" :files ("*.el")))` — no `:pin`, so the two machines can silently drift to different upstream commits at `doom sync` time.
- `$HOME/.config/doom/config.el`: `(:leader "g h" #'octocat-repo)` and `(after! octocat (setq octocat-debug t))` — the latter is gated on the `octocat` feature, which is also never provided on this code path.
- No `evil-collection-octocat.el` exists anywhere in `evil-collection` — evil-collection has no knowledge of this package, so it is not a factor.
- `evil-collection-magit-section.el` does **not** bind `RET` at all (only fold/navigation keys) — ruled out as a shadowing source.
- `evil-define-key*` already passes `ignore-parent = t` internally (verified in `evil-core.el`) — the aux-keymap mechanism itself is sound; it just never runs.
- The straight package cache (`/Users/saulius/.config/emacs/.local/straight/repos/octocat/octocat.el`) and the local checkout (`/Users/saulius/src/razzmatazz--octocat/octocat.el`, git `main` @ `c4257aa`, clean tree) are byte-identical at the relevant lines (1037–1047) — same bug present in both.
- `/Users/saulius/src/razzmatazz--octocat/AGENTS.md` documents the very assumption that breaks here, in the "Byte-compiler warnings" section: *"At runtime all files are already loaded by `octocat.el`, so there is no actual missing-definition risk."* This is true only when `octocat.el` (dashboard) is the first entry point used in a session — not true for `octocat-repo`.

## Fix design (SUPERSEDED — see "Chosen fix design" below)

1. **`octocat-core.el`** — relocate the `octocat--evil-init` *function definition* here (it's required first by both `octocat.el` and `octocat-repo.el`, so it's available to both without introducing a new circular dependency). This only defines the function; it has no side effect at load time.
2. **`octocat.el`** — keep the existing trigger at the bottom (unchanged behavior):
   ```elisp
   (if (bound-and-true-p evil-mode)
       (octocat--evil-init)
     (add-hook 'evil-mode-hook #'octocat--evil-init))
   ```
3. **`octocat-repo.el`** — add the identical trigger at the bottom of the file, before `(provide 'octocat-repo)`.
4. **`octocat-evil.el`** — guard the dashboard block in `octocat-evil-setup`:
   ```elisp
   (when (boundp 'octocat-mode-map)
     (evil-define-key* 'normal octocat-mode-map ...)
     (evil-define-key* 'motion octocat-mode-map ...))
   ```
   This is the only keymap in `octocat-evil-setup` not guaranteed to exist when entering via `octocat-repo` alone; everything else the function touches is already required transitively by `octocat-repo.el`.
5. **`test/octocat-evil-repo-tests.el`** (new file, done — see "Status"
   above for why it is separate from `test/octocat-tests.el`) — an ERT
   regression test that loads only `octocat-repo` (not `octocat`) with real
   `evil-mode` active (not simulated — `evil` added as a `(development
   ...)`-only dependency in `Eask`), and asserts that `RET` in
   `octocat-repo-mode-map`'s normal-state Evil aux keymap resolves to
   `octocat-visit`. Wired into `make ci` via a second `eask test ert`
   invocation in the `test` target of `Makefile`. Currently fails, as
   expected pre-fix (see "Status").
6. **`AGENTS.md`** — correct the now-inaccurate "all files already loaded by `octocat.el`" note to describe the actual invariant (loaded by whichever of `octocat.el` / `octocat-repo.el` was the entry point).

This design worked around the fact that two different files
(`octocat.el`, `octocat-repo.el`) each carry their own `;;;###autoload`
entry command, and therefore each need their own independent trigger +
guard. The "Chosen fix design" below removes the *cause* of that
duplication instead of patching around it.

## Chosen fix design — centralize entry points in `octocat.el`

**Key realization:** there are only two `;;;###autoload` commands in the
whole package: `octocat` (`octocat.el`) and `octocat-repo`
(`octocat-repo.el`). `octocat.el` already `(require 'octocat-repo)`
unconditionally at its top — the circular-dependency constraint only blocks
the *other* direction. The `octocat-repo` command's body calls nothing that
isn't already defined in `octocat-repo.el` and reachable from `octocat.el`
(`octocat-repo--current-repo`, `octocat-repo-mode`, `octocat-repo-refresh`,
etc.). No code anywhere calls `(octocat-repo)` directly — it is only ever
invoked via `M-x` / its autoload stub.

Moving *only the autoloaded command itself* (not the mode, not its logic)
into `octocat.el` makes `octocat.el` the single funnel every user-facing
entry point must pass through — by construction, not by convention that has
to be remembered per-file:

1. **`octocat.el`** — add the `(defun octocat-repo () ...)` command
   (unchanged body), with its `;;;###autoload` cookie, right after the
   existing `octocat` entry point, under a shared "Entry points" section.
2. **`octocat-repo.el`** — remove the command and its autoload cookie.
   Everything else (mode definition, mode-map, refresh logic, internal
   `octocat-repo--*` helpers) stays; the file becomes a plain supporting
   file with no autoload cookie of its own, exactly like `octocat-pr.el`,
   `octocat-issue.el`, etc. already are.
3. **`octocat--evil-init`** — stays exactly where it is today, at the
   bottom of `octocat.el`. No relocation, no duplicate trigger in
   `octocat-repo.el`, no `boundp 'octocat-mode-map` guard in
   `octocat-evil.el` — by the time that trigger runs, `octocat.el` has
   already defined `octocat-mode-map` for itself and required every file
   that defines every other mode-map, including `octocat-repo-mode-map`.
4. **`test/octocat-evil-repo-tests.el`** — the bug scenario this test
   guards against ("`M-x octocat-repo` is the first octocat command run in
   a session") becomes structurally impossible once `octocat-repo` no
   longer exists as a standalone command in `octocat-repo.el`. Re-target
   the test at that structural invariant instead:
   - After `(require 'octocat-repo)` alone: `(should-not (fboundp
     'octocat-repo))` — proves the entry point genuinely lives elsewhere.
   - After the subsequent `(require 'octocat)`: `(should (fboundp
     'octocat-repo))`, and the existing assertion that `RET` in
     `octocat-repo-mode-map`'s normal-state Evil aux keymap resolves to
     `octocat-visit`.
   Still needs its own process, separate from `test/octocat-tests.el` (same
   reasoning as before: that file's top-level `(require 'octocat)` would
   make the first assertion false if sharing a process).
5. **`CONTRIBUTING.md`** — document the convention: all
   `;;;###autoload` / `M-x`-invokable commands must be defined in
   `octocat.el`, even when the mode/logic they open lives in another file.
   (Done — see the new "Entry points" section.)
6. **`AGENTS.md`** — same update as design item 6 above: correct the
   "all files already loaded by `octocat.el`" note, this time to state it
   as a now-*guaranteed* invariant (single entry-point file) rather than a
   caveat about load order.

### Why this is simpler than the superseded design

No relocated function, no duplicated trigger, no `boundp` guard, and the
invariant ("first M-x command always loads `octocat.el`") is enforced by
the file *structure* itself rather than by every entry-point file
remembering to re-wire Evil. It also forecloses this entire bug class for
any *future* entry point, which the superseded design did not: a
hypothetical third `M-x octocat-issue`-style top-level command added later
would have needed its own copy of the guard/trigger dance under the old
design, but simply won't compile/lint cleanly under the new one without
living in `octocat.el` in the first place (enforced by the `CONTRIBUTING.md`
convention, not by the type system — still requires review discipline, but
now there is exactly one place to look).

## Alternatives considered

| Alternative | Why not chosen |
|---|---|
| Guard *every* per-mode block in `octocat-evil-setup` with `boundp` | More invasive than needed; only `octocat-mode-map` is at risk given the two documented entry points (`octocat`, `octocat-repo`) |
| Merge `octocat.el`/`octocat-repo.el` into one file | Large, unrelated restructuring; the circular-dependency split is intentional and documented elsewhere in `AGENTS.md` |
| Fix only in the user's Doom config (e.g. `(require 'octocat)` before binding `octocat-repo`) | Papers over the symptom for one machine; leaves the upstream package broken for anyone else using `octocat-repo` as their first entry point |

## Local validation

Using the project's own documented reload workflow (`AGENTS.md` → "Reloading into Emacs"), verify the fix live without restarting Emacs:

1. Kill stale `*octocat...*` buffers and any visited `.el`/`.elc` buffers for the package.
2. Reload files in dependency order: `octocat-core.el` → ... → `octocat-repo.el` → `octocat-evil.el` → `octocat.el`.
3. In a scratch buffer, simulate the bug scenario directly: with only `octocat-core`/`octocat-repo` (not `octocat`) loaded and `evil-mode` bound-and-true, confirm `octocat--evil-init` is now defined (from `octocat-core.el`) and that calling `octocat-repo` installs the `RET` → `octocat-visit` Evil binding without error.
4. Then also load `octocat.el` afterwards in the same session and confirm the dashboard (`octocat-mode-map`) bindings still get installed (idempotency check — no errors on second `octocat-evil-setup` invocation).

Also run from `/Users/saulius/src/razzmatazz--octocat`:

```bash
make compile   # eask compile --strict
make lint      # eask lint checkdoc && eask lint package
make test      # eask test ert test/octocat-tests.el
# make ci      # full pipeline via docker/podman, if available
```

## Doom integration

1. Edit `/Users/saulius/.config/doom/packages.el`, replacing:
   ```elisp
   (package! octocat :recipe (:host github :repo "razzmatazz/octocat" :files ("*.el")))
   ```
   with:
   ```elisp
   (package! octocat :recipe (:local-repo "~/src/razzmatazz--octocat" :files ("*.el")))
   ```
2. Run `~/.config/emacs/bin/doom sync`.
3. Restart Emacs (fresh session, so nothing has pre-loaded `octocat.el`).
4. Run `M-x octocat-repo` as the **first** octocat command in that session (the exact repro condition) and confirm `RET` now dispatches to `octocat-visit`.
5. Separately, in another fresh session, confirm `M-x octocat` (dashboard) still works correctly and its own `RET` binding still functions (regression check for step 4 of Fix design).

## Rollback

If the `:local-repo` recipe causes friction (e.g. straight refusing to manage/update a dirty local work tree, or Doom complaining about the package during `doom sync`), revert `packages.el` to the original GitHub recipe and run `doom sync` again:

```elisp
(package! octocat :recipe (:host github :repo "razzmatazz/octocat" :files ("*.el")))
```

## Action plan

- [x] Add `evil` as a development-only dependency in `Eask` (`(development (depends-on "evil"))`)
- [x] Add ERT regression test for the `octocat-repo`-only load path, in its own isolated file (`test/octocat-evil-repo-tests.el`, not `test/octocat-tests.el` — see "Status")
- [x] Wire the new test file into `make ci` as a separate `eask test ert` invocation (`Makefile`)
- [x] Confirm the new test fails pre-fix, and the existing suite still passes, via the real containerized `make test` (podman)
- [x] Evaluate centralizing all `;;;###autoload` entry commands in `octocat.el` as a simpler alternative fix — adopted as the "Chosen fix design" (see above)
- [x] Document the entry-point convention in `CONTRIBUTING.md`
- [x] Get explicit user confirmation before implementing the "Chosen fix design"
- [x] Move `(defun octocat-repo () ...)` (and its `;;;###autoload` cookie) from `octocat-repo.el` to `octocat.el`
- [x] Simplify `test/octocat-evil-repo-tests.el` to the structural invariant (`octocat-repo` unbound after requiring only `octocat-repo`; bound + correctly wired after requiring `octocat`), combined into one order-safe `ert-deftest`
- [x] Confirm `test/octocat-evil-repo-tests.el` now passes (fix verified against the regression test written first)
- [x] Update `AGENTS.md`'s outdated "all files already loaded by octocat.el" note
- [x] Reload live into the running Emacs session and verify by hand (`fboundp`, Evil `RET` binding in both normal/motion aux keymaps)
- [x] Run `make ci` (compile + lint + test) — all green
- [ ] Validate live via the documented Emacs reload workflow (no errors, RET resolves correctly in both load orders)
- [ ] Run `make compile`, `make lint`, `make test` (and `make ci` if docker/podman available) in `~/src/razzmatazz--octocat`
- [ ] Point `~/.config/doom/packages.el` at `:local-repo "~/src/razzmatazz--octocat"`
- [ ] `~/.config/emacs/bin/doom sync`
- [ ] Fresh-session test: `M-x octocat-repo` first, confirm RET works
- [ ] Fresh-session test: `M-x octocat` first, confirm dashboard RET still works
- [ ] Once validated, consider pushing the fix upstream (`git push origin main` from `~/src/razzmatazz--octocat`) and re-pinning `packages.el` back to the GitHub recipe at the fixed commit
