# magit-section usage in octocat.el

This document describes how octocat.el uses `magit-section`, the gotchas we
have hit, and the patterns that work correctly.  Read this before touching any
buffer-rendering code.

---

## Section tree structure

Every octocat view is rendered inside a `magit-section-mode` buffer.
`magit-section-mode` maintains a single buffer-local `magit-root-section`
object that is the root of the section tree.

For the **dashboard** buffer the tree is:

```
magit-root-section  ← IS the octocat-root section (outermost magit-insert-section call)
  ├── pull-requests
  │     ├── pr
  │     └── pr  …
  ├── issues
  │     └── issue  …
  └── workflows
        └── workflow
              └── workflow-run  …
```

> **Gotcha — root is not a phantom wrapper.**  It is tempting to assume
> `magit-root-section` is an invisible container *above* the outermost
> `magit-insert-section` call.  It is not.  `magit-root-section` is set to the
> return value of the outermost `magit-insert-section` call, which in the
> dashboard is `(octocat-root)`.  Its direct children are therefore
> `pull-requests`, `issues`, and `workflows` — **not** an intermediate
> `octocat-root` node.  Walking one level too deep is a silent bug: the
> sections are never found.

---

## Hiding sections at creation time

### The broken pattern — `HIDE` argument

`magit-insert-section` accepts an optional `HIDE` argument (the third element
of the type/value/hide list):

```elisp
;; BROKEN — do not use
(magit-insert-section (my-section value t)   ; t = HIDE
  ...)
```

`HIDE` sets the `:hidden` slot on the section object but does **not** apply
a hiding overlay to the buffer text.  The section appears expanded on screen.
When the user presses TAB, `magit-section-toggle` sees `:hidden t`, calls
`magit-section-show` (which is a no-op because the content is already
visible), and the section never collapses.  The user must press TAB a second
time to trigger `magit-section-hide`.

### The correct pattern — wrap with `magit-section-hide`

`magit-insert-section` returns the newly created section object.  Pass it
immediately to `magit-section-hide`, which applies the overlay while the
section's end-marker is already placed:

```elisp
;; CORRECT
(magit-section-hide
 (magit-insert-section (my-section value)
   (magit-insert-heading ...)
   (insert ...)))
```

The overlay is created at construction time, so TAB works correctly on the
first press.

---

## Preserving collapse state across refreshes

### The problem

Every render call erases the buffer (`erase-buffer`) and rebuilds the entire
section tree from scratch via `magit-insert-section`.  All prior section
objects — and their `:hidden` state — are discarded.  Without intervention,
every refresh expands all sections regardless of what the user had collapsed.

### The broken pattern — hide after rendering

It is tempting to save the hidden types, render everything expanded, then
walk the new tree and call `magit-section-hide` on the relevant sections:

```elisp
;; BROKEN — do not do this
(erase-buffer)
(magit-insert-section (octocat-root)
  (octocat--render-prs prs)
  ...)
;; called after the whole tree is built:
(dolist (s (oref magit-root-section children))
  (when (memq (oref s type) saved-hidden)
    (magit-section-hide s)))
```

This leaves the toggle logic in an inconsistent state.  The overlay is
applied, but the section was not hidden *during* construction, so internal
bookkeeping is off.  TAB misbehaves: it may require multiple presses, or
other sections must be toggled first before the affected section responds
correctly.

### The correct pattern — hide at construction time

1. **Before** erasing the buffer, snapshot which top-level section types are
   currently hidden:

   ```elisp
   (defun octocat--save-section-state ()
     (setq octocat--section-hidden
           (when (and (boundp 'magit-root-section) magit-root-section)
             (delq nil
                   (mapcar (lambda (s)
                             (when (oref s hidden) (oref s type)))
                           (oref magit-root-section children))))))
   ```

2. **During** construction, wrap each top-level section with
   `magit-section-hide` if its type was saved:

   ```elisp
   (defmacro octocat--hide-if-saved (type section)
     `(let ((s ,section))
        (when (memq ,type (buffer-local-value 'octocat--section-hidden
                                              (current-buffer)))
          (magit-section-hide s))
        s))
   ```

3. Use the macro at each call site:

   ```elisp
   (octocat--save-section-state)
   (erase-buffer)
   (magit-insert-section (octocat-root)
     ...
     (octocat--hide-if-saved 'pull-requests (octocat--render-prs prs))
     (octocat--hide-if-saved 'issues        (octocat--render-issues issues))
     (octocat--hide-if-saved 'workflows     (octocat--render-workflows workflows)))
   ```

This ensures `magit-section-hide` is always called at section-construction
time, keeping the overlay and toggle state fully consistent.

---

## Preserving point across refreshes

### The problem

`erase-buffer` discards all buffer content and all magit-section objects.
The section pointer held by the cursor before the erase is gone.  Without
intervention, every refresh either leaves point at an arbitrary byte offset
(which may now be mid-word in completely different content) or jumps it to
the top via `(goto-char (point-min))`.

### The magit-section API

magit-section provides three building blocks:

| Function | What it does |
|---|---|
| `(magit-section-ident section)` | Returns a stable `((type . value) …)` chain walking up to the root.  The `value` for each node comes from `magit-section-ident-value`. |
| `(magit-section-get-relative-position section)` | Returns `(LINE CHAR)` — point's offset from the section's start marker, in lines and characters. |
| `(magit-section-goto-successor section line char)` | After re-render: looks up the section by its identity in the new tree via `magit-get-section`, moves point to its `:start`, then replays `forward-line LINE` + `forward-char CHAR`.  Falls back to the nearest sibling or parent if the exact section is gone. |

### The `magit-section-ident-value` override

By default `magit-section-ident-value` returns the section's `:value` slot
unchanged.  For GitHub entity hash-tables this means two hash-table objects
representing the same PR or run are never `equal` across renders, so
`magit-get-section` always fails to find a match.

`octocat-core.el` adds a method that extracts a stable scalar key:

```elisp
(cl-defmethod magit-section-ident-value ((ht hash-table))
  (or (gethash "databaseId" ht)
      (gethash "number"     ht)
      (gethash "oid"        ht)
      (gethash "id"         ht)
      (gethash "name"       ht)))
```

Priority order: numeric run/job ID → PR/issue number → commit SHA → workflow
ID → name.  Whichever field is present is returned; sections whose values are
plain symbols (e.g. `pull-requests`, `octocat-root`) fall through to the
default method which returns the symbol itself — stable by definition.

### The helper functions

Two thin wrappers in `octocat-core.el`:

```elisp
(defun octocat--save-point ()
  "Capture point relative to the current section.
Returns (:section SECTION :line LINE :char CHAR) or nil."
  ...)

(defun octocat--restore-point (saved)
  "Restore point using SAVED plist from `octocat--save-point'.
Calls `magit-section-goto-successor'; silently does nothing on nil."
  ...)
```

### The call pattern

Capture once **before any render fires**; restore after **every** render
call (both the synchronous cache render and the asynchronous live render),
so the cursor snaps back regardless of which render the user sees:

```elisp
(defun octocat-foo-refresh (...)
  ...
  (let* ((buf         (current-buffer))
         ...
         (saved-point (octocat--save-point)))   ; capture before first render
    ;; synchronous cache render
    (when cache
      (octocat--render-foo cache)
      (octocat--restore-point saved-point))     ; restore after cache render
    ...
    (octocat--fetch-foo repo id
      (lambda (result)
        (with-current-buffer buf
          ...
          (octocat--render-foo result)
          (octocat--restore-point saved-point))))))  ; restore after live render
```

**Important**: `octocat--save-point` returns `nil` when there is no live
section tree (e.g. the very first open of a buffer).  `octocat--restore-point`
is a no-op on `nil`, so the pattern is safe to apply unconditionally.

Do **not** call `(goto-char (point-min))` inside render functions — that
unconditionally fights the restore.  Remove any such calls when adding the
pattern to a view.

---

## Summary of rules

| Situation | Do | Don't |
|---|---|---|
| Collapse a section on first render | `(magit-section-hide (magit-insert-section …))` | Pass `t` as the `HIDE` argument |
| Preserve collapse state across refreshes | Save types before erase; wrap with `magit-section-hide` during construction | Call `magit-section-hide` after the full tree is built |
| Walk top-level dashboard sections | `(oref magit-root-section children)` | `(oref (car (oref magit-root-section children)) children)` |
| Preserve cursor position across refreshes | `octocat--save-point` before first render; `octocat--restore-point` after each render | `(goto-char (point-min))` inside render functions |
