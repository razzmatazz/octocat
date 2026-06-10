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

## Summary of rules

| Situation | Do | Don't |
|---|---|---|
| Collapse a section on first render | `(magit-section-hide (magit-insert-section …))` | Pass `t` as the `HIDE` argument |
| Preserve collapse state across refreshes | Save types before erase; wrap with `magit-section-hide` during construction | Call `magit-section-hide` after the full tree is built |
| Walk top-level dashboard sections | `(oref magit-root-section children)` | `(oref (car (oref magit-root-section children)) children)` |
