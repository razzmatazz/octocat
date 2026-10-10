;;; octocat-markdown.el --- GitHub markdown renderer  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

;; Copyright (C) 2026 Saulius Menkevicius
;; Assisted-by: Claude:claude-sonnet-5-5

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Renders GitHub-flavoured markdown for display in octocat buffers.
;;
;; This module has no dependencies on the rest of octocat (or on any
;; markdown package), so `octocat-core' can require it.  The renderer
;; turns markdown source into a propertized string, one source line per
;; row (GitHub shows single newlines in comments as line breaks), with
;; the markup characters removed and faces applied instead.
;;
;; Block level: ATX headings, horizontal rules, fenced code, block
;; quotes (including `> [!NOTE]' alerts), bullet, numbered and task
;; lists with nesting, and tables.  Inline: `code', **bold**, *italic*,
;; ~~strike~~, links, images, autolinks, @mentions and #123 references.
;; HTML comments are dropped and other HTML tags are stripped, keeping
;; their content.
;;
;; Entry points: `octocat-markdown-render' and
;; `octocat-markdown-render-verbatim'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; Faces

(defgroup octocat-markdown nil
  "Markdown rendering in octocat buffers."
  :group 'tools
  :prefix "octocat-markdown-")

(defface octocat-markdown-heading
  '((t :weight bold))
  "Face for markdown headings."
  :group 'octocat-markdown)

(defface octocat-markdown-heading-1
  '((t :inherit octocat-markdown-heading :height 1.3))
  "Face for first-level markdown headings."
  :group 'octocat-markdown)

(defface octocat-markdown-heading-2
  '((t :inherit octocat-markdown-heading :height 1.15))
  "Face for second-level markdown headings."
  :group 'octocat-markdown)

(defface octocat-markdown-code
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Face for inline code and code blocks."
  :group 'octocat-markdown)

(defface octocat-markdown-code-block
  '((((class color) (background dark))  :inherit fixed-pitch :background "grey20")
    (((class color) (background light)) :inherit fixed-pitch :background "grey92")
    (t :inherit fixed-pitch))
  "Face for the lines of a fenced code block."
  :group 'octocat-markdown)

(defface octocat-markdown-link
  '((t :inherit link))
  "Face for markdown links."
  :group 'octocat-markdown)

(defface octocat-markdown-mention
  '((t :inherit font-lock-keyword-face))
  "Face for @mentions and #123 references."
  :group 'octocat-markdown)

(defface octocat-markdown-strike
  '((t :strike-through t))
  "Face for ~~struck~~ text."
  :group 'octocat-markdown)

(defface octocat-markdown-dimmed
  '((t :inherit shadow))
  "Face for markdown decoration: quote bars, rules, table borders."
  :group 'octocat-markdown)

;;;; Inline

(defconst octocat-markdown--entities
  '(("amp" . "&") ("lt" . "<") ("gt" . ">") ("quot" . "\"")
    ("apos" . "'") ("nbsp" . " "))
  "Named character references understood by the inline renderer.")

(defun octocat-markdown--face (string &rest faces)
  "Return STRING with FACES added on top of any faces it already has."
  (let ((s (copy-sequence string)))
    (dolist (f faces)
      (add-face-text-property 0 (length s) f t s))
    s))

(defun octocat-markdown--link (label url)
  "Return LABEL as a link to URL."
  (let ((s (octocat-markdown--face label 'octocat-markdown-link)))
    (add-text-properties 0 (length s)
                         (list 'help-echo url
                               'mouse-face 'highlight
                               'octocat-markdown-url url)
                         s)
    s))

(defvar octocat-markdown--inline-rules
  `(;; Code spans bind tighter than anything else.
    (,"``\\(.+?\\)``"
     ,(lambda (m) (octocat-markdown--face (nth 1 m) 'octocat-markdown-code)))
    (,"`\\([^`\n]+\\)`"
     ,(lambda (m) (octocat-markdown--face (nth 1 m) 'octocat-markdown-code)))
    (,"\\\\\\([][\\`*_{}()#+.!<>~|-]\\)"
     ,(lambda (m) (nth 1 m)))
    (,"<!--.*?-->" ,(lambda (_m) ""))
    (,"<\\(https?://[^>[:space:]]+\\)>"
     ,(lambda (m) (octocat-markdown--link (nth 1 m) (nth 1 m))))
    (,"<br */?>" ,(lambda (_m) " "))
    (,"</?[a-zA-Z][^<>\n]*>" ,(lambda (_m) ""))
    (,"&\\(#?[a-zA-Z0-9]+\\);"
     ,(lambda (m)
          (let ((name (nth 1 m)) (whole (nth 0 m)))
            (cond ((assoc name octocat-markdown--entities)
                   (cdr (assoc name octocat-markdown--entities)))
                  ((string-match "\\`#\\([0-9]+\\)\\'" name)
                   (string (string-to-number (match-string 1 name))))
                  (t whole)))))
    ;; Images show their alt text; links their label.
    (,"!\\[\\([^]\n]*\\)\\](\\([^)[:space:]]+\\)\\(?: +\"[^\"]*\"\\)?)"
     ,(lambda (m)
          (octocat-markdown--link
           (format "[image%s]" (if (string-empty-p (nth 1 m)) ""
                                 (concat ": " (nth 1 m))))
           (nth 2 m))))
    (,"\\[\\([^]\n]+\\)\\](\\([^)[:space:]]+\\)\\(?: +\"[^\"]*\"\\)?)"
     ,(lambda (m)
          (octocat-markdown--link (octocat-markdown--inline (nth 1 m))
                                  (nth 2 m))))
    (,"https?://[^[:space:]<>]*[^[:space:]<>.,;:!?)\"']"
     ,(lambda (m) (octocat-markdown--link (nth 0 m) (nth 0 m))))
    (,"\\*\\*\\*\\([^[:space:]]\\(?:.*?[^[:space:]]\\)?\\)\\*\\*\\*"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 1 m))
                                           'bold 'italic)))
    (,"\\*\\*\\([^[:space:]]\\(?:.*?[^[:space:]]\\)?\\)\\*\\*"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 1 m))
                                           'bold)))
    ;; Underscore emphasis needs non-word neighbours (snake_case stays).
    (,"\\(?:\\`\\|[^[:alnum:]_]\\)\\(__\\([^[:space:]_]\\(?:.*?[^[:space:]_]\\)?\\)__\\)\\(?:[^[:alnum:]_]\\|\\'\\)"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m))
                                           'bold))
     1)
    (,"\\*\\([^*[:space:]]\\(?:[^*]*?[^*[:space:]]\\)?\\)\\*"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 1 m))
                                           'italic)))
    (,"\\(?:\\`\\|[^[:alnum:]_]\\)\\(_\\([^_[:space:]]\\(?:[^_]*?[^_[:space:]]\\)?\\)_\\)\\(?:[^[:alnum:]_]\\|\\'\\)"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 2 m))
                                           'italic))
     1)
    (,"~~\\([^[:space:]~]\\(?:.*?[^[:space:]~]\\)?\\)~~"
     ,(lambda (m) (octocat-markdown--face (octocat-markdown--inline (nth 1 m))
                                           'octocat-markdown-strike)))
    (,"\\(?:\\`\\|[^[:alnum:]_/]\\)\\(@[A-Za-z0-9][A-Za-z0-9-]*\\(?:/[A-Za-z0-9_.-]+\\)?\\)"
     ,(lambda (m) (octocat-markdown--face (nth 1 m) 'octocat-markdown-mention))
     1)
    (,"\\(?:\\`\\|[^[:alnum:]_&]\\)\\(\\(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\)?#[0-9]+\\)\\b"
     ,(lambda (m) (octocat-markdown--face (nth 1 m) 'octocat-markdown-mention))
     1))
  "Inline rules: each is (REGEXP HANDLER) or (REGEXP HANDLER GROUP).
HANDLER is called with the list of the match's group strings (group 0
first) and returns the replacement string.  With GROUP, only that group
of the match is replaced and the rest (a leading boundary character) is
kept.")

(defun octocat-markdown--inline (text)
  "Return TEXT (a single line) with inline markdown rendered."
  (let ((pos 0) (out nil) (len (length text)))
    (while (< pos len)
      (let (best)                       ; (BEG END DATA RULE)
        (dolist (rule octocat-markdown--inline-rules)
          (when (string-match (car rule) text pos)
            (let ((group (or (nth 2 rule) 0)))
              (when (or (null best) (< (match-beginning group) (car best)))
                (setq best (list (match-beginning group) (match-end group)
                                 (cl-loop for i from 0 to 3
                                          collect (match-string i text))
                                 rule))))))
        (if (not best)
            (progn (push (substring text pos) out) (setq pos len))
          (pcase-let ((`(,beg ,end ,groups ,rule) best))
            (push (substring text pos beg) out)
            (push (funcall (cadr rule) groups) out)
            (setq pos end)))))
    (apply #'concat (nreverse out))))

;;;; Blocks
;;
;; Blocks render to a list of lines, each (STRING . HANG): the text of
;; the row and the number of extra columns its wrapped continuation
;; lines are indented by.

(defconst octocat-markdown--fence-re "^ \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)\\(.*\\)$")
(defconst octocat-markdown--hr-re "^ \\{0,3\\}\\([-*_]\\)\\(?: *\\1\\)\\{2,\\} *$")
(defconst octocat-markdown--heading-re "^ \\{0,3\\}\\(#\\{1,6\\}\\)\\(?: +\\(.*?\\)\\)?\\(?: +#+\\)? *$")
(defconst octocat-markdown--quote-re "^ \\{0,3\\}>")
(defconst octocat-markdown--item-re "^\\( *\\)\\([-*+]\\|[0-9]+[.)]\\)\\(?: +\\(.*\\)\\|\\(\\)\\)$")
(defconst octocat-markdown--table-delim-re
  "^ *|? *:?-+:? *\\(?:| *:?-+:? *\\)*|? *$")

(defun octocat-markdown--indentation (line)
  "Return the number of leading spaces of LINE."
  (string-match "[^ ]" line)
  (or (match-beginning 0) (length line)))

(defun octocat-markdown--blank-p (line)
  "Return non-nil if LINE is empty or whitespace."
  (string-match-p "\\`[ \t]*\\'" line))

(defun octocat-markdown--split-row (line)
  "Return the trimmed cells of table row LINE."
  (let* ((line (string-trim line))
         (line (string-remove-prefix "|" line))
         (line (if (and (string-suffix-p "|" line) (not (string-suffix-p "\\|" line)))
                   (substring line 0 -1)
                 line)))
    (mapcar (lambda (c) (string-trim (replace-regexp-in-string "\0" "|" c)))
            (split-string (replace-regexp-in-string "\\\\|" "\0" line) "|"))))

(defun octocat-markdown--pad (cell width align)
  "Pad CELL to WIDTH columns according to ALIGN (`left', `right', `center')."
  (let ((gap (max 0 (- width (string-width cell)))))
    (pcase align
      ('right  (concat (make-string gap ?\s) cell))
      ('center (concat (make-string (/ gap 2) ?\s) cell
                       (make-string (- gap (/ gap 2)) ?\s)))
      (_       (concat cell (make-string gap ?\s))))))

(defvar octocat-markdown--avail nil
  "Columns available to the block being rendered, or nil for no limit.
Bound by `octocat-markdown-render' and narrowed inside quotes and lists.")

(defconst octocat-markdown--min-column 6
  "Narrowest a table column is squeezed to before the table overflows instead.")

(defun octocat-markdown--fit-widths (natural avail)
  "Return column widths for a table of NATURAL widths fitting AVAIL columns.
Each column costs 3 columns of borders and padding, plus one for the
last border.  Columns narrower than their fair share keep their natural
width and the wide ones split what is left.  When even that would squeeze
a column below `octocat-markdown--min-column', or AVAIL is nil, NATURAL is
returned and the table is left to overflow."
  (let* ((n      (length natural))
         (budget (and avail (- avail (* 3 n) 1))))
    (if (or (null budget) (<= (apply #'+ natural) budget)
            (< budget (* n octocat-markdown--min-column)))
        natural
      (let ((fixed (make-vector n nil)) (left budget) (open n) share changed)
        (setq changed t)
        (while (and changed (> open 0))
          (setq changed nil share (/ left open))
          (dotimes (i n)
            (when (and (not (aref fixed i)) (<= (nth i natural) share))
              (aset fixed i (nth i natural))
              (setq left (- left (nth i natural)) open (1- open) changed t))))
        (let ((share (if (> open 0) (/ left open) 0))
              (extra (if (> open 0) (% left open) 0)))
          (cl-loop for i below n
                   collect (or (aref fixed i)
                               (prog1 (+ share (if (> extra 0) 1 0))
                                 (when (> extra 0) (setq extra (1- extra)))))))))))

(defun octocat-markdown--wrap (string width)
  "Return STRING broken into lines of at most WIDTH columns, as a list.
Lines break at spaces; a word wider than WIDTH is cut.  Text properties
are kept.  An empty STRING gives one empty line."
  (let ((pos 0) (lines nil) (cur nil))   ; CUR is (BEG . END) of the open line
    (while (string-match "[^ ]+" string pos)
      (let ((beg (match-beginning 0)) (end (match-end 0)))
        (setq pos end)
        ;; Cut a word that cannot fit a line of its own.
        (while (> (string-width (substring string beg end)) width)
          (let ((cut (1+ beg)))
            (while (and (< cut end)
                        (<= (string-width (substring string beg (1+ cut))) width))
              (setq cut (1+ cut)))
            (when cur (push (substring string (car cur) (cdr cur)) lines) (setq cur nil))
            (push (substring string beg cut) lines)
            (setq beg cut)))
        (cond ((= beg end))
              ((null cur) (setq cur (cons beg end)))
              ((<= (string-width (substring string (car cur) end)) width)
               (setcdr cur end))
              (t (push (substring string (car cur) (cdr cur)) lines)
                 (setq cur (cons beg end))))))
    (when cur (push (substring string (car cur) (cdr cur)) lines))
    (or (nreverse lines) (list ""))))

(defun octocat-markdown--table (header delim rows)
  "Return the lines of a table with HEADER and body ROWS.
DELIM is the delimiter row, which gives the column alignments.  A table
wider than `octocat-markdown--avail' squeezes its columns and wraps cell
text onto several lines, with a rule between rows to keep them apart."
  (let* ((head   (mapcar #'octocat-markdown--inline (octocat-markdown--split-row header)))
         (ncols  (length head))
         (aligns (mapcar (lambda (d)
                           (cond ((string-match-p "\\`:.*:\\'" d) 'center)
                                 ((string-suffix-p ":" d) 'right)
                                 (t 'left)))
                         (octocat-markdown--split-row delim)))
         (body   (mapcar (lambda (r)
                           (let ((cells (mapcar #'octocat-markdown--inline
                                                (octocat-markdown--split-row r))))
                             ;; Ragged rows are cut or padded to the header.
                             (take ncols (append cells (make-list ncols "")))))
                         rows))
         (natural (apply #'cl-mapcar (lambda (&rest cells)
                                       (apply #'max 1 (mapcar #'string-width cells)))
                         head body))
         (widths (octocat-markdown--fit-widths natural octocat-markdown--avail))
         (wrapped (cl-some #'< widths natural))
         (bar    (lambda (s) (propertize s 'face 'octocat-markdown-dimmed)))
         (rule   (lambda (l m r)
                   (funcall bar (concat l (mapconcat (lambda (w) (make-string (+ w 2) ?─))
                                                     widths m)
                                        r))))
         ;; One logical row as its physical lines (several when wrapped).
         (row    (lambda (cells face)
                   (let* ((cols   (cl-mapcar #'octocat-markdown--wrap cells widths))
                          (height (apply #'max 1 (mapcar #'length cols)))
                          (specs  (cl-mapcar #'list cols widths
                                             (take ncols (append aligns
                                                                 (make-list ncols 'left))))))
                     (cl-loop
                      for i below height
                      collect (concat
                               (funcall bar "│")
                               (mapconcat
                                (lambda (c)
                                  (let ((cell (or (nth i (cl-first c)) "")))
                                    (concat " " (octocat-markdown--pad
                                                 (if face (octocat-markdown--face cell face) cell)
                                                 (cl-second c) (cl-third c))
                                            " ")))
                                specs (funcall bar "│"))
                               (funcall bar "│")))))))
    (mapcar (lambda (s) (cons s 0))
            (append
             (list (funcall rule "┌" "┬" "┐"))
             (funcall row head 'bold)
             (list (funcall rule "├" "┼" "┤"))
             (cl-loop for (r . more) on body
                      append (funcall row r nil)
                      when (and wrapped more)
                      collect (funcall rule "├" "┼" "┤"))
             (list (funcall rule "└" "┴" "┘"))))))

(defun octocat-markdown--code-block (code)
  "Return the lines of fenced CODE (a list of strings) as a padded block."
  (let ((width (apply #'max 0 (mapcar #'string-width code))))
    (mapcar (lambda (l)
              (cons (propertize (concat " " l (make-string (- width (string-width l)) ?\s) " ")
                                'face 'octocat-markdown-code-block)
                    0))
            (or code '("")))))

(defun octocat-markdown--alert (label)
  "Return the heading line for the GitHub alert LABEL, or nil."
  (when (string-match "\\`\\[!\\(NOTE\\|TIP\\|IMPORTANT\\|WARNING\\|CAUTION\\)\\] *\\'" label)
    (octocat-markdown--face (capitalize (match-string 1 label)) 'bold)))

(defun octocat-markdown--blocks (lines &optional depth)
  "Return the rendered rows of markdown LINES (a list of strings).
DEPTH is the list nesting depth, which picks the bullet."
  (let ((depth (or depth 0)) out)
    (while lines
      (let ((line (pop lines)))
        (cond
         ((octocat-markdown--blank-p line)
          (push (cons "" 0) out))
         ;; HTML comment, possibly spanning lines.
         ((string-match-p "\\`[ \t]*<!--" line)
          (while (and (not (string-match-p "-->" line)) lines)
            (setq line (pop lines))))
         ((string-match octocat-markdown--fence-re line)
          (let ((fence (match-string 1 line)) code)
            (while (and lines
                        (not (string-match-p
                              (concat "^ \\{0,3\\}" (regexp-quote (substring fence 0 1))
                                      "\\{" (number-to-string (length fence)) ",\\} *$")
                              (car lines))))
              (push (pop lines) code))
            (pop lines)
            (dolist (l (octocat-markdown--code-block (nreverse code)))
              (push l out))))
         ((string-match-p octocat-markdown--hr-re line)
          (push (octocat-markdown--standout
                 (cons (propertize (make-string 40 ?─) 'face 'octocat-markdown-dimmed) 0))
                out))
         ((string-match octocat-markdown--heading-re line)
          (let ((level (length (match-string 1 line))))
            (push (octocat-markdown--standout
                   (cons (octocat-markdown--face
                          (octocat-markdown--inline (or (match-string 2 line) ""))
                          (pcase level (1 'octocat-markdown-heading-1)
                                 (2 'octocat-markdown-heading-2)
                                 (_ 'octocat-markdown-heading)))
                         0))
                  out)))
         ((string-match-p octocat-markdown--quote-re line)
          (let ((quoted (list line)))
            (while (and lines (string-match-p octocat-markdown--quote-re (car lines)))
              (push (pop lines) quoted))
            (setq quoted (mapcar (lambda (l) (replace-regexp-in-string "^ \\{0,3\\}> ?" "" l))
                                 (nreverse quoted)))
            (when-let* ((alert (octocat-markdown--alert (car quoted))))
              (setq quoted (cons (concat "**" (substring-no-properties alert) "**")
                                 (cdr quoted))))
            (let ((bar (propertize "│ " 'face 'octocat-markdown-dimmed)))
              (dolist (l (let ((octocat-markdown--avail
                                (and octocat-markdown--avail (- octocat-markdown--avail 2))))
                           (octocat-markdown--blocks quoted depth)))
                (push (octocat-markdown--standout
                       (cons (concat bar (car l)) (+ 2 (cdr l))))
                      out)))))
         ((string-match octocat-markdown--item-re line)
          (let* ((indent  (length (match-string 1 line)))
                 (marker  (match-string 2 line))
                 (first   (or (match-string 3 line) ""))
                 (ordered (not (string-match-p "\\`[-*+]\\'" marker)))
                 (width   (+ (length marker) 1))
                 (content (list first)))
            ;; Continuation: indented lines, and blanks leading into them.
            (while (and lines
                        (or (> (octocat-markdown--indentation (car lines)) indent)
                            (and (octocat-markdown--blank-p (car lines))
                                 (let ((next (seq-find (lambda (l) (not (octocat-markdown--blank-p l)))
                                                       lines)))
                                   (and next (> (octocat-markdown--indentation next) indent))))))
              (let ((l (pop lines)))
                (push (substring l (min (length l) (min (octocat-markdown--indentation l)
                                                        (+ indent width))))
                      content)))
            (setq content (nreverse content))
            (let* ((task (and (string-match "\\`\\[\\([ xX]\\)\\] +" first)
                              (cons (equal (match-string 1 first) " ") (match-end 0))))
                   (label (cond (task (propertize (if (car task) "☐" "☑")
                                                  'face (if (car task) 'octocat-markdown-dimmed 'success)))
                                (ordered (propertize marker 'face 'octocat-markdown-dimmed))
                                (t (propertize (if (cl-evenp depth) "•" "◦")
                                               'face 'octocat-markdown-dimmed))))
                   (pad (+ (if (and (not task) ordered) (length marker) 1) 1))
                   (rows (let ((octocat-markdown--avail
                                (and octocat-markdown--avail (- octocat-markdown--avail pad))))
                           (octocat-markdown--blocks
                            (if task (cons (substring first (cdr task)) (cdr content)) content)
                            (1+ depth)))))
              (when (null rows) (setq rows (list (cons "" 0))))
              (let ((firstp t))
                (dolist (r rows)
                  (push (cons (if firstp
                                  (concat label " " (car r))
                                (concat (make-string pad ?\s) (car r)))
                              (+ pad (cdr r)))
                        out)
                  (setq firstp nil))))
            ;; Items of one list sit together: no blank row between them.
            (while (and lines (octocat-markdown--blank-p (car lines))
                        (cdr lines) (string-match-p octocat-markdown--item-re (cadr lines)))
              (pop lines))))
         ;; Table: a header row followed by a delimiter row.
         ((and (string-match-p "|" line) lines
               (string-match-p octocat-markdown--table-delim-re (car lines))
               (string-match-p "|" (car lines)))
          (let ((delim (pop lines)) rows)
            (while (and lines (not (octocat-markdown--blank-p (car lines)))
                        (string-match-p "|" (car lines)))
              (push (pop lines) rows))
            (dolist (l (octocat-markdown--table line delim (nreverse rows)))
              (push (octocat-markdown--standout l) out))))
         (t
          (push (cons (octocat-markdown--inline (string-trim line)) 0) out)))))
    (nreverse out)))

(defun octocat-markdown--standout (row)
  "Return ROW marked as a block that needs no blank row beside it."
  (let ((s (copy-sequence (car row))))
    (put-text-property 0 (length s) 'octocat-markdown-standout t s)
    (cons s (cdr row))))

(defun octocat-markdown--standout-p (row)
  "Return non-nil if ROW is marked by `octocat-markdown--standout'."
  (and row (> (length (car row)) 0)
       (get-text-property 0 'octocat-markdown-standout (car row))))

(defun octocat-markdown--tidy (rows)
  "Return ROWS packed tightly, to save vertical space.
Blank rows at either end, doubled blank rows, and blank rows next to a
block that stands out by itself (rule, table, heading, quote) are
dropped.  Blank rows beside a code box or between paragraphs are kept."
  (let (out)
    (dolist (r rows)
      (unless (and (string-empty-p (car r))
                   (or (null out) (string-empty-p (caar out))))
        (push r out)))
    (when (and out (string-empty-p (caar out))) (pop out))
    (setq out (nreverse out))
    (let (tight prev)
      (while out
        (let ((r (pop out)))
          (unless (and (string-empty-p (car r))
                       (or (octocat-markdown--standout-p prev)
                           (octocat-markdown--standout-p (car out))))
            (push r tight))
          (setq prev r)))
      (nreverse tight))))

;;;; Entry points

(defun octocat-markdown--lines (text)
  "Return TEXT as a list of lines with CR characters stripped."
  (split-string (replace-regexp-in-string "\r" "" text) "\n"))

(defun octocat-markdown--finish (rows indent)
  "Join ROWS (see `octocat-markdown--blocks') into a string prefixed by INDENT.
Wrapped continuation lines repeat INDENT, plus each row's hang."
  (mapconcat (lambda (row)
               (let ((full (concat indent (car row) "\n")))
                 (put-text-property 0 (length full) 'wrap-prefix
                                    (concat indent (make-string (cdr row) ?\s)) full)
                 full))
             rows ""))

(defun octocat-markdown-render-verbatim (text &optional indent)
  "Return markdown TEXT unrendered, one line per row.
Each line is prefixed with INDENT (a string, default \"  \") and ends in
a newline; INDENT is also repeated on the wrapped continuation lines of
long lines.  Windows-style CR characters are stripped first."
  (octocat-markdown--finish
   (mapcar (lambda (l) (cons l 0)) (octocat-markdown--lines text))
   (or indent "  ")))

(defun octocat-markdown-render (text &optional indent width)
  "Return markdown TEXT rendered for display, one line per row.
INDENT is as for `octocat-markdown-render-verbatim'.

WIDTH is the number of columns the output, INDENT included, should fit,
or nil for no limit.  Only tables use it: one that would be wider
squeezes its columns and wraps its cells over several lines, since Emacs
wrapping a table at the window edge breaks its borders.  A table that
cannot fit even squeezed is left at its natural width.

Markup is replaced by faces; see the Commentary for what is understood."
  (let* ((indent (or indent "  "))
         (octocat-markdown--avail (and width (- width (string-width indent)))))
    (octocat-markdown--finish
     (or (octocat-markdown--tidy
          (octocat-markdown--blocks (octocat-markdown--lines text)))
         (list (cons "" 0)))
     indent)))

(provide 'octocat-markdown)
;;; octocat-markdown.el ends here
