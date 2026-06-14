#!/usr/bin/env python3
"""
el-outline: Structural outline of Emacs Lisp files.

Parses parenthesis structure and prints an indented tree of forms with
line ranges.  Useful for spotting mismatched parentheses — especially
after editing where a removed expression accidentally drops a closing
paren and silently swallows the next top-level form.

Usage:
    python3 tools/el-outline.py [--depth N] FILE [FILE ...]
    python3 tools/el-outline.py --trace DEFUN FILE
    python3 tools/el-outline.py --trace-line N FILE
    python3 tools/el-outline.py --depth-at N FILE
    python3 tools/el-outline.py --close-map [--lines A-B] FILE

Options:
    --depth N           Maximum nesting depth to display (default: 4)
    --trace DEFUN       Depth-trace mode: print every source line of the
                        named top-level form with a running paren-depth
                        counter.  Looks for the first top-level defun/defvar
                        etc. whose NAME token matches (skips declare-function
                        stubs that share the same name).
    --trace-line N      Like --trace but selects the top-level form that
                        contains line N.  Useful when --trace finds the wrong
                        form (e.g. a declare-function stub) or the form has
                        no distinct name.
    --depth-at N        Print the absolute paren depth at each line in the
                        range around line N (±10 lines by default), then
                        print a summary of what forms are still open at N.
                        Use this to answer "what is open / unclosed at line X?"
    --close-map [A-B]   For every closing ')' in the file (or in the line
                        range A-B), print which opening '(' it matches and
                        at what line that '(' started.  Use this to spot the
                        ')' that is doing "double duty" — closing two forms
                        at once, or closing sooner than expected.
    --lines A-B         Restrict --depth-at or --close-map output to lines
                        A through B (inclusive).

Depth-trace output columns:
    L{n}  [{depth:+d}]  {source line}

    A line whose counter never returns to 0 at the expected closing paren,
    or drops below 1 before the body is finished, is where the bug lives.
    The final summary line shows whether the form closed cleanly.

Close-map output (one token per closing ')'):
    L{n}  closes  L{open}  {depth_before}→{depth_after}  {form head}

    Look for a line where depth goes from N to 0 EARLIER than you expect,
    or where a single ')' closes more levels than intended.

Outline output columns:
    L{start}-{end}   Line range of the form
    {indent}{head}   Form head (first token), indented by depth
    [UNCLOSED]       Form with no closing paren found before EOF
    [SPANS NEXT]     Form whose end_line >= start of the next sibling —
                     a strong sign of a missing ')' somewhere inside it

Exit code is 1 if any file has unbalanced parens at EOF (outline mode) or
if the traced defun is not found / not cleanly closed (trace mode).
"""

import sys
import os
import re
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
    """Yield (kind, value, line, col) tuples.

    Kinds: OPEN  CLOSE  OPEN_VEC  CLOSE_VEC  ATOM
    Strings, line comments, and character literals are consumed silently —
    they carry no parenthesis structure.
    col is 0-based character offset within the line.
    """
    i = 0
    line = 1
    line_start = 0
    n = len(text)

    while i < n:
        c = text[i]

        # ── whitespace ───────────────────────────────────────────────────
        if c == '\n':
            line += 1
            line_start = i + 1
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
                        line_start = i + 2
                    i += 2
                    continue
                if ch == '\n':
                    line += 1
                    line_start = i + 1
                if ch == '"':
                    i += 1
                    break
                i += 1
            continue

        # ── character literal  ?x  ?\n  ?\(  ?\s  etc. ──────────────────
        if c == '?' and i + 1 < n and text[i + 1] not in ' \t\n\r':
            i += 1
            if i < n and text[i] == '\\':
                i += 2
            else:
                i += 1
            continue

        # ── block comment  #| … |#  ──────────────────────────────────────
        if c == '#' and i + 1 < n and text[i + 1] == '|':
            i += 2
            while i + 1 < n:
                if text[i] == '\n':
                    line += 1
                    line_start = i + 1
                if text[i] == '|' and text[i + 1] == '#':
                    i += 2
                    break
                i += 1
            continue

        col = i - line_start

        # ── parens ───────────────────────────────────────────────────────
        if c == '(':
            yield ('OPEN', c, line, col)
            i += 1
            continue
        if c == ')':
            yield ('CLOSE', c, line, col)
            i += 1
            continue

        # ── vectors  [ ] ─────────────────────────────────────────────────
        if c == '[':
            yield ('OPEN_VEC', c, line, col)
            i += 1
            continue
        if c == ']':
            yield ('CLOSE_VEC', c, line, col)
            i += 1
            continue

        # ── reader macros  ' ` , ,@ #' ───────────────────────────────────
        if c in ("'", '`', ','):
            if c == ',' and i + 1 < n and text[i + 1] == '@':
                i += 2
            else:
                i += 1
            continue
        if c == '#' and i + 1 < n and text[i + 1] == "'":
            i += 2
            continue

        # ── atom ─────────────────────────────────────────────────────────
        j = i
        while i < n and text[i] not in ' \t\n\r()[]";':
            i += 1
        if i > j:
            yield ('ATOM', text[j:i], line, col)
        else:
            i += 1


# ---------------------------------------------------------------------------
# Form tree
# ---------------------------------------------------------------------------

@dataclass
class Form:
    kind: str           # 'list' or 'vec'
    start_line: int
    end_line: int = 0
    tokens: list = field(default_factory=list)
    children: list = field(default_factory=list)
    # is this a defining form (defun/defvar/…)?
    is_defining: bool = False

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
    stack = []
    roots = []
    depth = 0

    for kind, value, line, col in token_iter:

        if kind in ('OPEN', 'OPEN_VEC'):
            form_kind = 'list' if kind == 'OPEN' else 'vec'
            f = Form(kind=form_kind, start_line=line)
            stack.append((f, kind))
            depth += 1

        elif kind in ('CLOSE', 'CLOSE_VEC'):
            depth -= 1
            if stack:
                f, _open_kind = stack.pop()
                f.end_line = line
                f.is_defining = (f.head in _DEFINING)
                if stack:
                    stack[-1][0].children.append(f)
                else:
                    roots.append(f)

        elif kind == 'ATOM':
            if stack:
                parent = stack[-1][0]
                if len(parent.tokens) < 2:
                    parent.tokens.append(value)

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

_RANGE_COL = 14
_INDENT     = 2


def _label(form):
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
    out = file or sys.stdout
    indent   = ' ' * (_INDENT * depth)
    range_s  = _range_str(form).ljust(_RANGE_COL)
    label    = _label(form)

    if form.end_line == 0:
        warn = '  ← UNCLOSED'
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
        inner = ' ' * (_INDENT * (depth + 1))
        print(f"  {'…'.ljust(_RANGE_COL)}  {inner}…", file=out)


# ---------------------------------------------------------------------------
# Depth-at query: what is open at line N?
# ---------------------------------------------------------------------------

def depth_at(path, target_line, context=10, file=None):
    """Show paren depth around TARGET_LINE and list open forms at that line.

    Prints depth per line for the context window, then summarises what
    forms are unclosed going into TARGET_LINE.  Useful for answering
    "what is still open / unclosed at line N?"
    """
    out = file or sys.stdout

    try:
        text = open(path, encoding='utf-8').read()
    except OSError as e:
        print(f"el-outline: {e}", file=sys.stderr)
        return False

    lines = text.splitlines()
    total = len(lines)

    # Build per-line depth delta and open-form stack snapshot.
    # We need to know what forms are still on the stack AT target_line.
    line_delta = {}       # line -> net delta
    # For each OPEN token we record (line, head_token_so_far).
    open_events = []      # list of [open_line, close_line_or_None, head]
    stack = []            # stack of index into open_events

    for kind, value, ln, col in _tokenise(text):
        if kind == 'OPEN':
            idx = len(open_events)
            open_events.append([ln, None, ''])
            stack.append(idx)
            line_delta[ln] = line_delta.get(ln, 0) + 1
        elif kind == 'CLOSE':
            line_delta[ln] = line_delta.get(ln, 0) - 1
            if stack:
                idx = stack.pop()
                open_events[idx][1] = ln
        elif kind == 'ATOM':
            if stack:
                ev = open_events[stack[-1]]
                if not ev[2]:
                    ev[2] = value  # first atom = head token

    # Compute cumulative depth at each line.
    depth = 0
    depth_before = {}  # depth at start of line (before processing it)
    for ln in range(1, total + 1):
        depth_before[ln] = depth
        depth += line_delta.get(ln, 0)

    # Lines to show.
    lo = max(1, target_line - context)
    hi = min(total, target_line + context)
    ln_w = len(str(hi))

    print(f"\n{'=' * 62}", file=out)
    print(f"  {os.path.basename(path)}  —  depth at L{target_line}", file=out)
    print(f"{'=' * 62}", file=out)

    for ln in range(lo, hi + 1):
        d_before = depth_before[ln]
        d_after  = d_before + line_delta.get(ln, 0)
        src      = lines[ln - 1] if ln <= total else ''
        marker   = '>>>' if ln == target_line else '   '
        print(f"  {marker} L{str(ln).ljust(ln_w)}  [{d_after:+d}]  {src}", file=out)

    # Summarise what is open going into target_line.
    open_at_target = [
        ev for ev in open_events
        if ev[0] < target_line and (ev[1] is None or ev[1] >= target_line)
    ]

    print(f"\n  Open forms at L{target_line} (innermost last):", file=out)
    if not open_at_target:
        print(f"    (none — at top level)", file=out)
    else:
        for ev in open_at_target:
            close_s = f"L{ev[1]}" if ev[1] else "UNCLOSED"
            head    = ev[2] or '('
            print(f"    opened L{ev[0]}  closes {close_s}  head={head!r}", file=out)

    return True


# ---------------------------------------------------------------------------
# Close-map: which ')' closes which '('?
# ---------------------------------------------------------------------------

def close_map(path, lo=None, hi=None, file=None):
    """For every ')' in PATH (or within lines LO..HI), show what it closes.

    Output columns:
        L{close}  closes  L{open}  depth {before}→{after}  head={head}

    The 'head' is the first atom inside the opening '(' (e.g. 'defun',
    'let*', 'magit-insert-section', etc.).

    This makes it easy to spot:
      - A ')' that closes at depth 1→0 earlier than expected (function ends
        too soon).
      - A ')' that was intended to close one form but actually closes two
        (the "double duty" bug from a missing ')' above it).
    """
    out = file or sys.stdout

    try:
        text = open(path, encoding='utf-8').read()
    except OSError as e:
        print(f"el-outline: {e}", file=sys.stderr)
        return False

    # Build close events.
    stack  = []   # stack of [open_line, head]
    events = []   # list of (close_line, open_line, depth_before, depth_after, head)
    depth  = 0

    for kind, value, ln, col in _tokenise(text):
        if kind == 'OPEN':
            depth += 1
            stack.append([ln, '', depth])
        elif kind == 'CLOSE':
            d_before = depth
            depth -= 1
            if stack:
                open_ln, head, _od = stack.pop()
            else:
                open_ln, head = 0, '?'
            events.append((ln, open_ln, d_before, depth, head))
        elif kind == 'ATOM':
            if stack and not stack[-1][1]:
                stack[-1][1] = value

    # Filter and print.
    if lo is not None or hi is not None:
        lo = lo or 1
        hi = hi or 10**9
        events = [e for e in events if lo <= e[0] <= hi]

    if not events:
        print(f"  (no closing parens in range)", file=out)
        return True

    max_close = max(e[0] for e in events)
    max_open  = max(e[1] for e in events)
    ln_w = len(str(max(max_close, max_open)))

    print(f"\n{'=' * 62}", file=out)
    title = os.path.basename(path)
    if lo or hi:
        title += f"  L{lo or 1}–{hi or '?'}"
    print(f"  {title}  —  close map", file=out)
    print(f"{'=' * 62}", file=out)

    for close_ln, open_ln, d_before, d_after, head in events:
        open_s  = f"L{str(open_ln).ljust(ln_w)}"
        close_s = f"L{str(close_ln).ljust(ln_w)}"
        depth_s = f"{d_before}→{d_after}"
        # Highlight depth transitions to/through 0 — these are the
        # candidates for the "double duty" or "too early close" bug.
        flag = '  ← TOP LEVEL' if d_after == 0 else ''
        flag = '  ← GOES NEGATIVE' if d_after < 0 else flag
        print(f"  {close_s}  closes  {open_s}  depth {depth_s}  "
              f"head={head!r}{flag}", file=out)

    return True


# ---------------------------------------------------------------------------
# Depth tracer
# ---------------------------------------------------------------------------

def _find_target_form(roots, name=None, line=None):
    """Return the top-level Form matching by name or by containing line."""
    if name is not None:
        # Skip declare-function stubs: prefer actual defining forms.
        candidates = [f for f in roots if f.name == name]
        defining   = [f for f in candidates if f.is_defining]
        return (defining or candidates or [None])[0]
    if line is not None:
        for f in roots:
            end = f.end_line if f.end_line else 10**9
            if f.start_line <= line <= end:
                return f
    return None


def trace(path, defun_name=None, target_line=None, file=None):
    """Depth-trace a top-level form in PATH.

    Either DEFUN_NAME (look up by name, preferring actual defun over
    declare-function stubs) or TARGET_LINE (find whichever form contains
    that line) must be supplied.

    Returns True if the form closed cleanly.
    """
    out = file or sys.stdout

    try:
        text = open(path, encoding='utf-8').read()
    except OSError as e:
        print(f"el-outline: {e}", file=sys.stderr)
        return False

    lines = text.splitlines()
    roots, _depth = _parse(_tokenise(text))

    target = _find_target_form(roots, name=defun_name, line=target_line)

    if target is None:
        desc = (f"'{defun_name}' as a top-level form" if defun_name
                else f"a form containing L{target_line}")
        print(f"el-outline: could not find {desc} in "
              f"{os.path.basename(path)}", file=sys.stderr)
        return False

    # Use found form's name for the header if we searched by line.
    display_name = target.name or target.head or '(?)'

    start    = target.start_line
    end      = target.end_line if target.end_line else len(lines)
    unclosed = (target.end_line == 0)

    print(f"\n{'=' * 62}", file=out)
    print(f"  {os.path.basename(path)}  —  depth trace: {display_name}  "
          f"(L{start}–{'?' if unclosed else end})", file=out)
    print(f"{'=' * 62}", file=out)

    line_delta = {}
    for kind, _value, ln, _col in _tokenise(text):
        if start <= ln <= end:
            if kind == 'OPEN':
                line_delta[ln] = line_delta.get(ln, 0) + 1
            elif kind == 'CLOSE':
                line_delta[ln] = line_delta.get(ln, 0) - 1

    ln_w  = len(str(end))
    depth = 0
    ok    = True

    for ln in range(start, end + 1):
        delta  = line_delta.get(ln, 0)
        depth += delta
        src    = lines[ln - 1] if ln <= len(lines) else ''

        note = ''
        if ln == start and depth != 1:
            note = f'  ← expected depth +1 after opening, got {depth:+d}'
        elif ln == end and depth != 0:
            note = f'  ← UNCLOSED: depth {depth:+d} (expected 0)'
            ok = False
        elif depth < 0:
            note = f'  ← depth went negative!'
            ok = False
        elif depth == 0 and ln != end:
            note = f'  ← closes to 0 before end of form!'
            ok = False

        print(f"  L{str(ln).ljust(ln_w)}  [{depth:+d}]  {src}{note}", file=out)

    if unclosed:
        print(f"\n  ✗  form is UNCLOSED (no matching ')' before EOF)", file=out)
        ok = False
    elif ok:
        print(f"\n  ✓  form closes cleanly at L{end}", file=out)

    return ok


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def outline(path, max_depth=4, file=None):
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

def _parse_range(s):
    """Parse 'A-B' into (A, B) ints, or raise ValueError."""
    m = re.match(r'^(\d+)-(\d+)$', s)
    if not m:
        raise ValueError(f"expected A-B, got {s!r}")
    return int(m.group(1)), int(m.group(2))


def main():
    args = sys.argv[1:]
    max_depth   = 4
    trace_name  = None
    trace_line  = None
    depth_at_n  = None
    close_map_f = False
    lines_range = None
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

        elif a in ('--trace', '-t') and i + 1 < len(args):
            trace_name = args[i + 1]
            i += 2

        elif a.startswith('--trace='):
            trace_name = a.split('=', 1)[1]
            i += 1

        elif a == '--trace-line' and i + 1 < len(args):
            try:
                trace_line = int(args[i + 1])
            except ValueError:
                sys.exit("el-outline: --trace-line requires an integer")
            i += 2

        elif a.startswith('--trace-line='):
            try:
                trace_line = int(a.split('=', 1)[1])
            except ValueError:
                sys.exit("el-outline: --trace-line requires an integer")
            i += 1

        elif a == '--depth-at' and i + 1 < len(args):
            try:
                depth_at_n = int(args[i + 1])
            except ValueError:
                sys.exit("el-outline: --depth-at requires an integer")
            i += 2

        elif a.startswith('--depth-at='):
            try:
                depth_at_n = int(a.split('=', 1)[1])
            except ValueError:
                sys.exit("el-outline: --depth-at requires an integer")
            i += 1

        elif a == '--close-map':
            close_map_f = True
            i += 1

        elif a == '--lines' and i + 1 < len(args):
            try:
                lines_range = _parse_range(args[i + 1])
            except ValueError as e:
                sys.exit(f"el-outline: --lines: {e}")
            i += 2

        elif a.startswith('--lines='):
            try:
                lines_range = _parse_range(a.split('=', 1)[1])
            except ValueError as e:
                sys.exit(f"el-outline: --lines: {e}")
            i += 1

        elif a in ('-h', '--help'):
            print(__doc__)
            sys.exit(0)

        else:
            files.append(a)
            i += 1

    if not files:
        files = sorted(f for f in os.listdir('.') if f.endswith('.el'))
        if not files:
            sys.exit("el-outline: no .el files found")

    # ── dispatch ─────────────────────────────────────────────────────────
    if trace_name or trace_line is not None:
        if len(files) != 1:
            sys.exit("el-outline: --trace / --trace-line requires exactly one FILE")
        ok = trace(files[0], defun_name=trace_name, target_line=trace_line)
        sys.exit(0 if ok else 1)

    if depth_at_n is not None:
        if len(files) != 1:
            sys.exit("el-outline: --depth-at requires exactly one FILE")
        context = (lines_range[1] - lines_range[0]) // 2 if lines_range else 10
        depth_at(files[0], depth_at_n, context=context)
        sys.exit(0)

    if close_map_f:
        if len(files) != 1:
            sys.exit("el-outline: --close-map requires exactly one FILE")
        lo, hi = lines_range if lines_range else (None, None)
        close_map(files[0], lo=lo, hi=hi)
        sys.exit(0)

    all_ok = all(outline(path, max_depth=max_depth) for path in files)
    sys.exit(0 if all_ok else 1)


if __name__ == '__main__':
    main()
