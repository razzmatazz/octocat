#!/usr/bin/env python3
"""
el-outline: Structural outline of Emacs Lisp files.

Parses parenthesis structure and prints an indented tree of forms with
line ranges.  Useful for spotting mismatched parentheses — especially
after editing where a removed expression accidentally drops a closing
paren and silently swallows the next top-level form.

Usage:
    python3 tools/el-outline.py [--depth N] FILE [FILE ...]

Options:
    --depth N   Maximum nesting depth to display (default: 4)

Output columns:
    L{start}-{end}   Line range of the form
    {indent}{head}   Form head (first token), indented by depth
    [UNCLOSED]       Form with no closing paren found before EOF
    [SPANS NEXT]     Form whose end_line >= start of the next sibling —
                     a strong sign of a missing ')' somewhere inside it

Exit code is 1 if any file has unbalanced parens at EOF.
"""

import sys
import os
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Tokeniser
# ---------------------------------------------------------------------------

# Defining forms whose second token is the name we want in the label.
_DEFINING = frozenset({
    'defun', 'defmacro', 'defsubst', 'cl-defun', 'cl-defmethod',
    'cl-defgeneric', 'defvar', 'defvar-local', 'defcustom', 'defconst',
    'defface', 'defgroup', 'defalias',
    'define-derived-mode', 'define-minor-mode', 'define-generic-mode',
})


def _tokenise(text):
    """Yield (kind, value, line) triples.

    Kinds: OPEN  CLOSE  OPEN_VEC  CLOSE_VEC  ATOM
    Strings, line comments, and character literals are consumed silently —
    they carry no parenthesis structure.
    """
    i = 0
    line = 1
    n = len(text)

    while i < n:
        c = text[i]

        # ── whitespace ───────────────────────────────────────────────────
        if c == '\n':
            line += 1
            i += 1
            continue
        if c in ' \t\r':
            i += 1
            continue

        # ── line comment ─────────────────────────────────────────────────
        if c == ';':
            while i < n and text[i] != '\n':
                i += 1
            continue

        # ── string literal ───────────────────────────────────────────────
        if c == '"':
            i += 1
            while i < n:
                ch = text[i]
                if ch == '\\':
                    if i + 1 < n and text[i + 1] == '\n':
                        line += 1
                    i += 2
                    continue
                if ch == '\n':
                    line += 1
                if ch == '"':
                    i += 1
                    break
                i += 1
            continue

        # ── character literal  ?x  ?\n  ?\(  ?\s  etc. ──────────────────
        # Only treat as char-literal when the next char is non-space
        # (bare '?' before a space is an atom).
        if c == '?' and i + 1 < n and text[i + 1] not in ' \t\n\r':
            i += 1              # skip '?'
            if i < n and text[i] == '\\':
                i += 2          # skip '\' + escaped char
            else:
                i += 1          # skip plain char
            continue

        # ── block comment  #| … |#  (rare but valid in ELisp) ────────────
        if c == '#' and i + 1 < n and text[i + 1] == '|':
            i += 2
            while i + 1 < n:
                if text[i] == '\n':
                    line += 1
                if text[i] == '|' and text[i + 1] == '#':
                    i += 2
                    break
                i += 1
            continue

        # ── parens ───────────────────────────────────────────────────────
        if c == '(':
            yield ('OPEN', c, line)
            i += 1
            continue
        if c == ')':
            yield ('CLOSE', c, line)
            i += 1
            continue

        # ── vectors  [ ] ─────────────────────────────────────────────────
        if c == '[':
            yield ('OPEN_VEC', c, line)
            i += 1
            continue
        if c == ']':
            yield ('CLOSE_VEC', c, line)
            i += 1
            continue

        # ── reader macros that prefix the next form  ' ` , ,@ #' ─────────
        # Consume them without emitting; they don't affect paren depth.
        if c in ("'", '`', ','):
            if c == ',' and i + 1 < n and text[i + 1] == '@':
                i += 2
            else:
                i += 1
            continue
        if c == '#' and i + 1 < n and text[i + 1] == "'":
            i += 2
            continue

        # ── atom (symbol, number, keyword …) ─────────────────────────────
        j = i
        while i < n and text[i] not in ' \t\n\r()[]";':
            i += 1
        if i > j:
            yield ('ATOM', text[j:i], line)
        else:
            i += 1  # skip any unrecognised character


# ---------------------------------------------------------------------------
# Form tree
# ---------------------------------------------------------------------------

@dataclass
class Form:
    """A parenthesised (or bracketed) form in the source."""
    kind: str           # 'list' or 'vec'
    start_line: int
    end_line: int = 0   # filled in at closing paren; 0 means unclosed
    # First two atoms inside the form; enough to label defining forms.
    tokens: list = field(default_factory=list)
    children: list = field(default_factory=list)

    @property
    def head(self):
        return self.tokens[0] if self.tokens else ''

    @property
    def name(self):
        return self.tokens[1] if len(self.tokens) > 1 else ''


def _parse(token_iter):
    """Build top-level Form list from a token iterable.

    Returns (roots, final_depth).  final_depth != 0 means unbalanced file.
    """
    stack = []      # list of (Form, expected_close_kind)
    roots = []
    depth = 0

    for kind, value, line in token_iter:

        if kind in ('OPEN', 'OPEN_VEC'):
            form_kind = 'list' if kind == 'OPEN' else 'vec'
            expected_close = 'CLOSE' if kind == 'OPEN' else 'CLOSE_VEC'
            f = Form(kind=form_kind, start_line=line)
            stack.append((f, expected_close))
            depth += 1

        elif kind in ('CLOSE', 'CLOSE_VEC'):
            depth -= 1
            if stack:
                f, _expected = stack.pop()
                f.end_line = line
                if stack:
                    stack[-1][0].children.append(f)
                else:
                    roots.append(f)
            # extra / mismatched ')': ignore

        elif kind == 'ATOM':
            if stack:
                parent = stack[-1][0]
                # Capture only the first two atoms per form — head and name.
                if len(parent.tokens) < 2:
                    parent.tokens.append(value)

    # Any forms still open at EOF: unclosed — surface them.
    while stack:
        f, _ = stack.pop()
        if stack:
            stack[-1][0].children.append(f)
        else:
            roots.append(f)

    return roots, depth


# ---------------------------------------------------------------------------
# Printer
# ---------------------------------------------------------------------------

_RANGE_COL = 14   # fixed width of the "L{start}-{end}" column
_INDENT     = 2   # spaces per depth level


def _label(form):
    """Human-readable label for a form."""
    h = form.head
    if not h:
        return '(' if form.kind == 'list' else '['
    if h in _DEFINING and form.name:
        return f"{h} {form.name}"
    return h


def _range_str(form):
    if form.end_line and form.end_line != form.start_line:
        return f"L{form.start_line}-{form.end_line}"
    return f"L{form.start_line}"


def _print_form(form, depth, max_depth, next_start=None, file=None):
    """Print one form and recurse into children up to max_depth."""
    out = file or sys.stdout

    indent   = ' ' * (_INDENT * depth)
    range_s  = _range_str(form).ljust(_RANGE_COL)
    label    = _label(form)

    # ── warnings ─────────────────────────────────────────────────────────
    # UNCLOSED: never received a closing paren
    if form.end_line == 0:
        warn = '  ← UNCLOSED'
    # SPANS NEXT: a multi-line form whose end_line reaches the next sibling.
    # Skip single-line forms (start == end) — they can share a line legitimately.
    elif (next_start is not None
          and form.end_line >= next_start
          and form.end_line != form.start_line):
        warn = (f"  ← SPANS INTO NEXT FORM "
                f"(ends L{form.end_line}, next starts L{next_start})")
    else:
        warn = ''

    print(f"  {range_s}  {indent}{label}{warn}", file=out)

    if depth < max_depth:
        kids = form.children
        for idx, child in enumerate(kids):
            nxt = kids[idx + 1].start_line if idx + 1 < len(kids) else None
            _print_form(child, depth + 1, max_depth, nxt, file=out)
    elif form.children:
        # Show an ellipsis hint so the reader knows there is more.
        inner = ' ' * (_INDENT * (depth + 1))
        print(f"  {'…'.ljust(_RANGE_COL)}  {inner}…", file=out)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def outline(path, max_depth=4, file=None):
    """Print the structural outline for one file.

    Returns True if the file is parenthesis-balanced, False otherwise.
    """
    out = file or sys.stdout

    try:
        text = open(path, encoding='utf-8').read()
    except OSError as e:
        print(f"el-outline: {e}", file=sys.stderr)
        return False

    roots, depth = _parse(_tokenise(text))

    balanced = (depth == 0)
    status   = '✓ balanced' if balanced else f'✗ UNBALANCED (depth {depth:+d} at EOF)'

    print(f"\n{'=' * 62}", file=out)
    print(f"  {os.path.basename(path)}  [{status}]", file=out)
    print(f"{'=' * 62}", file=out)

    for idx, form in enumerate(roots):
        nxt = roots[idx + 1].start_line if idx + 1 < len(roots) else None
        _print_form(form, depth=0, max_depth=max_depth, next_start=nxt, file=out)

    return balanced


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    max_depth = 4
    files = []

    i = 0
    while i < len(args):
        a = args[i]
        if a in ('--depth', '-d') and i + 1 < len(args):
            try:
                max_depth = int(args[i + 1])
            except ValueError:
                sys.exit("el-outline: --depth requires an integer")
            i += 2
        elif a.startswith('--depth='):
            try:
                max_depth = int(a.split('=', 1)[1])
            except ValueError:
                sys.exit("el-outline: --depth requires an integer")
            i += 1
        elif a in ('-h', '--help'):
            print(__doc__)
            sys.exit(0)
        else:
            files.append(a)
            i += 1

    if not files:
        # Default: all *.el files in the current directory.
        files = sorted(f for f in os.listdir('.') if f.endswith('.el'))
        if not files:
            sys.exit("el-outline: no .el files found")

    all_ok = all(outline(path, max_depth=max_depth) for path in files)
    sys.exit(0 if all_ok else 1)


if __name__ == '__main__':
    main()
