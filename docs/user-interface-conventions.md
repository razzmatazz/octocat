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
