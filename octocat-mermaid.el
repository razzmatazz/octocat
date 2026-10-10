;;; octocat-mermaid.el --- Draw mermaid diagrams as text  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Draws the common kinds of mermaid diagram with box-drawing characters,
;; for `octocat-markdown' to show in place of a ```mermaid fence.  This
;; module has no dependencies on the rest of octocat.
;;
;; Supported: `flowchart'/`graph' (TD, TB, BT, LR, RL; box, rounded,
;; circle and diamond nodes; solid, dotted and thick edges with arrows and
;; labels; `A & B --> C' fan-out), `sequenceDiagram' (participants,
;; messages, notes, loop/alt/opt/par blocks, autonumber), `stateDiagram'
;; (transitions only) and `pie'.
;;
;; The one entry point is `octocat-mermaid-render'.  It is given the width
;; it may use and reacts to it: labels are wrapped, a left-to-right
;; flowchart is turned top-down, sequence diagrams are squeezed.  It
;; returns nil for anything it cannot draw, or draw within the width, so
;; the caller can show the source instead.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; Canvas

(cl-defstruct (octocat-mermaid--canvas (:constructor octocat-mermaid--canvas ())
                                       (:copier nil))
  (cells (make-hash-table :test #'equal))
  (width 0)
  (height 0))

(defun octocat-mermaid--put (cv x y string)
  "Write STRING into canvas CV from column X of row Y, one character per cell."
  (when (and (>= x 0) (>= y 0))
    (let ((cells (octocat-mermaid--canvas-cells cv)))
      (dolist (ch (string-to-list string))
        (let ((cw (max 1 (char-width ch))))
          (puthash (cons x y) (string ch) cells)
          (when (> cw 1) (puthash (cons (1+ x) y) "" cells))
          (setf (octocat-mermaid--canvas-width cv)
                (max (octocat-mermaid--canvas-width cv) (+ x cw))
                (octocat-mermaid--canvas-height cv)
                (max (octocat-mermaid--canvas-height cv) (1+ y)))
          (setq x (+ x cw)))))))

(defun octocat-mermaid--get (cv x y)
  "Return the string in canvas CV at X,Y, or nil if the cell is untouched."
  (gethash (cons x y) (octocat-mermaid--canvas-cells cv)))

(defun octocat-mermaid--blank-p (cv x y)
  "Return non-nil if the cell of CV at X,Y is empty."
  (member (octocat-mermaid--get cv x y) '(nil " ")))

(defun octocat-mermaid--lines (cv)
  "Return the rows of canvas CV as strings, without trailing blanks.
Empty rows at the top and bottom are left out."
  (let ((rows (cl-loop for y below (octocat-mermaid--canvas-height cv)
                       collect (string-trim-right
                                (mapconcat (lambda (x) (or (octocat-mermaid--get cv x y) " "))
                                           (number-sequence 0 (1- (octocat-mermaid--canvas-width cv)))
                                           "")))))
    (nreverse (seq-drop-while #'string-empty-p
                              (nreverse (seq-drop-while #'string-empty-p rows))))))

(defun octocat-mermaid--dedent (lines)
  "Return LINES less the leading spaces they all share."
  (let ((indents (cl-loop for l in lines
                          unless (string-empty-p l) collect (string-match "[^ ]" l))))
    (if (null indents)
        lines
      (let ((n (apply #'min indents)))
        (mapcar (lambda (l) (if (string-empty-p l) l (substring l n))) lines)))))

(defconst octocat-mermaid--line-bits
  '((?─ . 10) (?│ . 5) (?┌ . 6) (?┐ . 12) (?└ . 3) (?┘ . 9) (?├ . 7) (?┤ . 13)
    (?┬ . 14) (?┴ . 11) (?┼ . 15) (?╭ . 6) (?╮ . 12) (?╰ . 3) (?╯ . 9)
    (?━ . 10) (?┃ . 5) (?┄ . 10) (?┆ . 5))
  "Connections (N=1, E=2, S=4, W=8) of the line-drawing characters.")

(defconst octocat-mermaid--bits-char
  '((1 . ?│) (2 . ?─) (3 . ?└) (4 . ?│) (5 . ?│) (6 . ?┌) (7 . ?├) (8 . ?─)
    (9 . ?┘) (10 . ?─) (11 . ?┴) (12 . ?┐) (13 . ?┤) (14 . ?┬) (15 . ?┼))
  "The line-drawing character for each set of connections.")

(defun octocat-mermaid--add-bits (cv x y bits &optional glyph)
  "Join a line with connections BITS into the cell of CV at X,Y.
An empty cell gets GLYPH if given and BITS are a straight line, else the
character for BITS.  A line character is merged with them (a corner and a
line make a junction); any other character stays."
  (when (and (>= x 0) (>= y 0))
    (let* ((old (octocat-mermaid--get cv x y))
           (old-bits (and old (= (length old) 1)
                          (cdr (assq (aref old 0) octocat-mermaid--line-bits)))))
      (cond ((member old '(nil " "))
             (octocat-mermaid--put
              cv x y (string (if (and glyph (memq bits '(5 10)))
                                 glyph
                               (cdr (assq bits octocat-mermaid--bits-char))))))
            (old-bits
             (octocat-mermaid--put
              cv x y (string (cdr (assq (logior old-bits bits)
                                        octocat-mermaid--bits-char)))))))))

(defun octocat-mermaid--draw-line (cv points &optional glyphs)
  "Draw the polyline POINTS, a list of (X . Y), into CV.
Consecutive points are on a common row or column.  GLYPHS is nil, or a
cons of the horizontal and vertical characters for straight stretches."
  (let ((bits (make-hash-table :test #'equal)))
    (cl-loop for (p q) on points while q
             do (let* ((dx (cl-signum (- (car q) (car p))))
                       (dy (cl-signum (- (cdr q) (cdr p))))
                       (d  (cond ((> dx 0) 2) ((< dx 0) 8) ((> dy 0) 4) (t 1)))
                       (opp (pcase d (1 4) (4 1) (2 8) (_ 2)))
                       (x (car p)) (y (cdr p))
                       ;; Empty and diagonal segments are skipped.
                       (done (or (and (= dx 0) (= dy 0)) (and (/= dx 0) (/= dy 0)))))
                  (while (not done)
                    (let ((key (cons x y))
                          (at-q (and (= x (car q)) (= y (cdr q))))
                          (at-p (and (= x (car p)) (= y (cdr p)))))
                      (unless at-q
                        (puthash key (logior (gethash key bits 0) d) bits))
                      (unless at-p
                        (puthash key (logior (gethash key bits 0) opp) bits))
                      (if at-q
                          (setq done t)
                        (setq x (+ x dx) y (+ y dy)))))))
    (maphash (lambda (key b)
               (octocat-mermaid--add-bits
                cv (car key) (cdr key) b
                (and glyphs (if (= b 10) (car glyphs) (cdr glyphs)))))
             bits)))

(defun octocat-mermaid--draw-box (cv x y w h lines shape)
  "Draw into CV a box of SHAPE at X,Y, W by H cells, holding LINES centred."
  (pcase-let ((`(,tl ,tr ,bl ,br)
               (pcase shape
                 ((or 'round 'circle) '(?╭ ?╮ ?╰ ?╯))
                 (_ '(?┌ ?┐ ?└ ?┘))))
              (inner (- w 2)))
    (octocat-mermaid--put cv x y (concat (string tl) (make-string inner ?─) (string tr)))
    (octocat-mermaid--put cv x (+ y h -1)
                          (concat (string bl) (make-string inner ?─) (string br)))
    (dotimes (i (- h 2))
      (let* ((line (or (nth i lines) ""))
             (pad  (max 0 (- inner (string-width line))))
             (left (/ pad 2)))
        (octocat-mermaid--put cv x (+ y 1 i) "│")
        (octocat-mermaid--put cv (+ x w -1) (+ y 1 i) "│")
        (octocat-mermaid--put cv (1+ x) (+ y 1 i)
                              (concat (make-string left ?\s) line
                                      (make-string (- pad left) ?\s)))))
    ;; A decision points outwards from the middle of its sides.
    (when (eq shape 'diamond)
      (octocat-mermaid--put cv x (+ y (/ (1- h) 2)) "<")
      (octocat-mermaid--put cv (+ x w -1) (+ y (/ (1- h) 2)) ">"))))

;;;; Text helpers

(defun octocat-mermaid--wrap-line (line width)
  "Break LINE at spaces into lines of at most WIDTH columns, as a list."
  (let (lines cur)
    (dolist (w (split-string line))
      (while (> (string-width w) width)
        (when cur (push cur lines) (setq cur nil))
        (let ((cut (truncate-string-to-width w width)))
          (push cut lines)
          (setq w (substring w (length cut)))))
      (cond ((null cur) (setq cur w))
            ((<= (+ (string-width cur) 1 (string-width w)) width)
             (setq cur (concat cur " " w)))
            (t (push cur lines) (setq cur w))))
    (when (or cur (null lines)) (push (or cur "") lines))
    (nreverse lines)))

(defun octocat-mermaid--wrap (text width)
  "Return TEXT as a list of lines of at most WIDTH columns, keeping newlines."
  (cl-loop for para in (split-string text "\n")
           append (octocat-mermaid--wrap-line para width)))

(defun octocat-mermaid--clean-label (label)
  "Return LABEL as the plain text of a mermaid node or message."
  (let* ((s (string-trim label))
         (s (if (string-match "\\`\"\\(.*\\)\"\\'" s) (match-string 1 s) s))
         (s (replace-regexp-in-string "<br */?>\\|\\\\n" "\n" s))
         (s (replace-regexp-in-string "</?[a-zA-Z][^<>]*>" "" s))
         (s (replace-regexp-in-string "&quot;" "\"" s))
         (s (replace-regexp-in-string "&lt;" "<" s))
         (s (replace-regexp-in-string "&gt;" ">" s)))
    (replace-regexp-in-string "&amp;" "&" s)))

(defun octocat-mermaid--lines-width (lines)
  "Return the width of the widest of LINES."
  (apply #'max 0 (mapcar #'string-width lines)))

(defun octocat-mermaid--fits-p (lines width)
  "Return non-nil if LINES fit WIDTH columns (nil means no limit)."
  (or (null width) (<= (octocat-mermaid--lines-width lines) width)))

;;;; Flowcharts: parsing

(defconst octocat-mermaid--shapes
  '(("((" "))" circle) ("([" "])" round) ("[(" ")]" box) ("[[" "]]" box)
    ("{{" "}}" box) ("[/" "/]" box) ("[\\" "\\]" box) ("[/" "\\]" box)
    ("[\\" "/]" box) ("[" "]" box) ("(" ")" round) ("{" "}" diamond)
    (">" "]" box))
  "Node delimiters (OPEN CLOSE SHAPE), the longest first.")

(defun octocat-mermaid--parse-flow (lines)
  "Parse flowchart LINES into (DIRECTION NODES EDGES GROUPS), or nil.
Return nil if the chart is unsupported.  NODES are (ID LABEL SHAPE) and
EDGES (FROM TO STYLE HEAD TAIL TEXT), in the order they appear.  STYLE is
`solid', `dotted' or `thick'; HEAD and TAIL are nil, `arrow', `cross' or
`circle'.  GROUPS are the subgraphs, (ID TITLE MEMBER-IDS): a node belongs
to the first subgraph it is mentioned in.  Subgraphs do not nest."
  (let ((dir 'TD) (table (make-hash-table :test #'equal))
        (owner (make-hash-table :test #'equal))
        order edges header groups current)
    (catch 'fail
      (cl-labels
          ((register (id label shape)
             (let ((spec (gethash id table)))
               (unless spec
                 (setq spec (list id id 'box))
                 (puthash id spec table)
                 (push id order))
               (when (and current (not (gethash id owner)))
                 (puthash id current owner)
                 (push id (nth 2 current)))
               (when label
                 (setf (nth 1 spec) (octocat-mermaid--clean-label label)
                       (nth 2 spec) shape))))
           (open-group (rest)
             (when current (throw 'fail nil))
             (let ((rest (string-trim rest)))
               (setq current
                     (cond ((string-match "\\`\\([[:alnum:]_]+\\)[ \t]*\\[\\(.*\\)\\]\\'" rest)
                            (list (match-string 1 rest)
                                  (octocat-mermaid--clean-label (match-string 2 rest))
                                  nil))
                           ((string-empty-p rest) (throw 'fail nil))
                           (t (let ((name (octocat-mermaid--clean-label rest)))
                                (list name name nil))))))
             (push current groups))
           (parse-node ()
             (when (looking-at "[[:alnum:]_]+")
               (let ((id (match-string 0)) label shape)
                 (goto-char (match-end 0))
                 (catch 'done
                   (dolist (s octocat-mermaid--shapes)
                     (when (looking-at (concat (regexp-quote (nth 0 s))
                                               "\\(\"[^\"]*\"\\|.*?\\)"
                                               (regexp-quote (nth 1 s))))
                       (setq label (match-string 1) shape (nth 2 s))
                       (goto-char (match-end 0))
                       (throw 'done nil))))
                 (when (looking-at ":::[[:alnum:]_-]+") (goto-char (match-end 0)))
                 (register id label shape)
                 id)))
           (parse-group ()
             (let ((first (parse-node)) ids)
               (when first
                 (push first ids)
                 (while (looking-at "[ \t]*&[ \t]*")
                   (goto-char (match-end 0))
                   (let ((id (parse-node)))
                     (unless id (throw 'fail nil))
                     (push id ids)))
                 (nreverse ids))))
           (parse-edge ()
             (skip-chars-forward " \t")
             (cond
              ;; Text inside the dashes: A -- text --> B
              ((looking-at (concat "\\(<\\)?\\(--\\|==\\|-\\.\\)[ \t]+\\([^|\n]+?\\)[ \t]+"
                                   "\\(-+>?\\|=+>?\\|\\.+-+>?\\)\\(?:[ \t]\\|\\'\\)"))
               (let ((tail (match-string 1)) (op (match-string 2))
                     (text (match-string 3)) (close (match-string 4)))
                 (goto-char (match-end 4))
                 (list (cond ((equal op "==") 'thick) ((equal op "-.") 'dotted) (t 'solid))
                       (and (string-suffix-p ">" close) 'arrow)
                       (and tail 'arrow)
                       text)))
              ((looking-at "\\(<\\)?\\(-\\{2,\\}\\|=\\{2,\\}\\|-\\.+-*\\)\\(>\\)?")
               (let ((tail (match-string 1)) (op (match-string 2))
                     (head (and (match-string 3) 'arrow)) text)
                 (goto-char (match-end 0))
                 (when (and (not head) (looking-at "\\([xo]\\)\\(?:[ \t]\\|\\'\\)"))
                   (setq head (if (equal (match-string 1) "x") 'cross 'circle))
                   (goto-char (match-end 1)))
                 (when (looking-at "[ \t]*|\\([^|]*\\)|")
                   (setq text (match-string 1))
                   (goto-char (match-end 0)))
                 (list (cond ((string-search "." op) 'dotted)
                             ((string-search "=" op) 'thick)
                             (t 'solid))
                       head (and tail 'arrow) text)))))
           (parse-statement (stmt)
             (with-temp-buffer
               (insert stmt)
               (goto-char (point-min))
               (let ((prev (parse-group)))
                 (unless prev (throw 'fail nil))
                 (while (progn (skip-chars-forward " \t") (not (eobp)))
                   (let ((edge (parse-edge)))
                     (unless edge (throw 'fail nil))
                     (skip-chars-forward " \t")
                     (let ((next (parse-group)))
                       (unless next (throw 'fail nil))
                       (dolist (a prev)
                         (dolist (b next)
                           (push (append (list a b) edge) edges)))
                       (setq prev next))))))))
        (dolist (raw lines)
          (let ((line (string-trim (string-remove-suffix ";" (string-trim raw)))))
            (cond
             ((or (string-empty-p line) (string-prefix-p "%%" line)))
             ((not header)
              (unless (string-match "\\`\\(?:flowchart\\|graph\\)\\(?:[ \t]+\\(TD\\|TB\\|BT\\|LR\\|RL\\)\\)?[ \t]*\\'"
                                    line)
                (throw 'fail nil))
              (setq header t
                    dir (intern (or (match-string 1 line) "TD")))
              (when (eq dir 'TB) (setq dir 'TD)))
             ((string-match-p "\\`\\(?:style\\|classDef\\|class\\|linkStyle\\|click\\|direction\\)\\b"
                              line))
             ((string-match "\\`subgraph\\b\\(.*\\)\\'" line)
              (open-group (match-string 1 line)))
             ((string-match-p "\\`end\\'" line)
              (unless current (throw 'fail nil))
              (setq current nil))
             (t (parse-statement line)))))
        ;; An edge to a subgraph itself, or a block left open, is not drawn.
        (when (or current (cl-some (lambda (g) (gethash (car g) table)) groups))
          (throw 'fail nil))
        (and header order
             (list dir
                   (mapcar (lambda (id) (gethash id table)) (nreverse order))
                   (nreverse edges)
                   (cl-loop for g in (nreverse groups)
                            when (nth 2 g)
                            collect (list (nth 0 g) (nth 1 g) (reverse (nth 2 g))))))))))

;;;; Flowcharts: layout

(defvar octocat-mermaid--vertical t
  "Non-nil while laying out a chart whose layers stack downwards.
Otherwise they run left to right.  The \"main\" axis is the one the layers
follow, the \"cross\" axis the one nodes of a layer are spread along.")

(cl-defstruct (octocat-mermaid--n (:constructor octocat-mermaid--n) (:copier nil))
  id lines shape (w 1) (h 1) virtual layer (cross 0) (main 0) group)

(cl-defstruct (octocat-mermaid--e (:constructor octocat-mermaid--e) (:copier nil))
  from to style head tail text reversed path start-c end-c)

(defun octocat-mermaid--msize (n)
  "Return the size of node N along the main axis."
  (if octocat-mermaid--vertical (octocat-mermaid--n-h n) (octocat-mermaid--n-w n)))

(defun octocat-mermaid--csize (n)
  "Return the size of node N along the cross axis."
  (if octocat-mermaid--vertical (octocat-mermaid--n-w n) (octocat-mermaid--n-h n)))

(defun octocat-mermaid--center (n)
  "Return the middle of node N on the cross axis."
  (+ (octocat-mermaid--n-cross n) (/ (octocat-mermaid--csize n) 2.0)))

(defun octocat-mermaid--gap (a b)
  "Return the space left between neighbouring nodes A and B of a layer.
Nodes of different subgraphs are kept further apart, to fit their frames."
  (let ((base (cond ((or (octocat-mermaid--n-virtual a) (octocat-mermaid--n-virtual b)) 2)
                    (octocat-mermaid--vertical 3)
                    (t 2)))
        (ga (octocat-mermaid--n-group a))
        (gb (octocat-mermaid--n-group b)))
    (cond ((equal ga gb) base)
          ((and ga gb) (+ base 3))
          (t (+ base 2)))))

(defun octocat-mermaid--group-layer (layer)
  "Return LAYER with the nodes of each subgraph next to each other.
They gather where the first of them stands."
  (let (out done)
    (dolist (n layer)
      (let ((g (octocat-mermaid--n-group n)))
        (cond ((null g) (push n out))
              ((member g done))
              (t (push g done)
                 (dolist (m layer)
                   (when (equal (octocat-mermaid--n-group m) g) (push m out)))))))
    (nreverse out)))

(defun octocat-mermaid--edge-label (e)
  "Return the text shown on edge E, on one line, or nil."
  (when-let* ((text (octocat-mermaid--e-text e)))
    (let ((s (string-join (split-string (octocat-mermaid--clean-label text)) " ")))
      (unless (string-empty-p s)
        (truncate-string-to-width s 30 nil nil "…")))))

(defun octocat-mermaid--make-node (spec maxlabel)
  "Return the node for SPEC (ID LABEL SHAPE), its label wrapped to MAXLABEL."
  (let* ((lines (octocat-mermaid--wrap (nth 1 spec) maxlabel))
         (tw (max 1 (octocat-mermaid--lines-width lines))))
    (octocat-mermaid--n :id (nth 0 spec) :lines lines :shape (nth 2 spec)
                        :w (max 5 (+ tw 4)) :h (+ 2 (length lines)))))

(defun octocat-mermaid--break-cycles (nodes edges)
  "Mark as reversed the edges of EDGES that close a cycle among NODES."
  (let ((state (make-hash-table :test #'eq)))
    (cl-labels ((visit (n)
                  (puthash n 1 state)
                  (dolist (e edges)
                    (when (eq (octocat-mermaid--e-from e) n)
                      (let ((m (octocat-mermaid--e-to e)))
                        (cond ((eq (gethash m state) 1)
                               (setf (octocat-mermaid--e-reversed e) t))
                              ((null (gethash m state)) (visit m))))))
                  (puthash n 2 state)))
      (dolist (n nodes)
        (unless (gethash n state) (visit n))))))

(defun octocat-mermaid--assign-layers (nodes edges flip)
  "Give each of NODES a layer so every edge of EDGES points downwards.
Each edge's path becomes (TOP BOTTOM).  With FLIP the edges point upwards."
  (dolist (e edges)
    (let ((r (and (octocat-mermaid--e-reversed e) t))
          (f (and flip t)))
      (setf (octocat-mermaid--e-path e)
            (if (eq r f)
                (list (octocat-mermaid--e-from e) (octocat-mermaid--e-to e))
              (list (octocat-mermaid--e-to e) (octocat-mermaid--e-from e))))))
  (dolist (n nodes) (setf (octocat-mermaid--n-layer n) 0))
  (cl-loop repeat (1+ (length nodes))
           for changed = nil
           do (dolist (e edges)
                (let ((a (car (octocat-mermaid--e-path e)))
                      (b (cadr (octocat-mermaid--e-path e))))
                  (when (<= (octocat-mermaid--n-layer b) (octocat-mermaid--n-layer a))
                    (setf (octocat-mermaid--n-layer b) (1+ (octocat-mermaid--n-layer a))
                          changed t))))
           while changed))

(defun octocat-mermaid--add-virtuals (edges)
  "Break the paths of EDGES that skip layers with virtual nodes.
Return the new nodes."
  (let (virtuals)
    (dolist (e edges)
      (let* ((top (car (octocat-mermaid--e-path e)))
             (bot (cadr (octocat-mermaid--e-path e)))
             (chain (list top)))
        (cl-loop for l from (1+ (octocat-mermaid--n-layer top))
                 below (octocat-mermaid--n-layer bot)
                 do (let ((v (octocat-mermaid--n :virtual t :layer l)))
                      (push v virtuals)
                      (push v chain)))
        (setf (octocat-mermaid--e-path e) (nreverse (cons bot chain)))))
    (nreverse virtuals)))

(defun octocat-mermaid--order-layer (layer ref neighbours)
  "Return LAYER reordered by where NEIGHBOURS of each node sit in layer REF.
NEIGHBOURS is a hash table from a node to its neighbours."
  (let ((pos (make-hash-table :test #'eq)) (i 0))
    (dolist (n ref) (puthash n i pos) (cl-incf i))
    (mapcar #'cdr
            (sort (cl-loop for n in layer for k from 0
                           collect (let ((ps (delq nil (mapcar (lambda (m) (gethash m pos))
                                                               (gethash n neighbours)))))
                                     (cons (if ps (/ (float (apply #'+ ps)) (length ps)) (float k))
                                           n)))
                  (lambda (a b) (< (car a) (car b)))))))

(defun octocat-mermaid--pack-layer (layer start)
  "Set the cross positions of LAYER left to right from START; return the end."
  (let ((x start) prev)
    (dolist (n layer)
      (when prev (setq x (+ x (octocat-mermaid--gap prev n))))
      (setf (octocat-mermaid--n-cross n) x)
      (setq x (+ x (octocat-mermaid--csize n)) prev n))
    x))

(defun octocat-mermaid--refine-layer (layer neighbours)
  "Move the nodes of LAYER towards the mean centre of their NEIGHBOURS."
  (let (prev prev-end)
    (dolist (n layer)
      (let* ((ns (gethash n neighbours))
             (desired (if ns
                          (/ (apply #'+ (mapcar #'octocat-mermaid--center ns))
                             (float (length ns)))
                        (octocat-mermaid--center n)))
             (start (round (- desired (/ (octocat-mermaid--csize n) 2.0)))))
        (setf (octocat-mermaid--n-cross n)
              (if prev (max start (+ prev-end (octocat-mermaid--gap prev n))) start))
        (setq prev n
              prev-end (+ (octocat-mermaid--n-cross n) (octocat-mermaid--csize n)))))))

(defun octocat-mermaid--place-cross (layers ups downs margin)
  "Set the cross positions of the nodes of the vector LAYERS, from MARGIN on.
UPS and DOWNS map a node to its neighbours in the layer above and below."
  (let* ((nl (length layers))
         (totals (cl-loop for l below nl
                          collect (octocat-mermaid--pack-layer (aref layers l) 0)))
         (widest (apply #'max 0 totals)))
    (cl-loop for l below nl for total in totals
             do (octocat-mermaid--pack-layer (aref layers l) (/ (- widest total) 2)))
    (dotimes (_ 3)
      (cl-loop for l from 1 below nl
               do (octocat-mermaid--refine-layer (aref layers l) ups))
      (cl-loop for l from (- nl 2) downto 0
               do (octocat-mermaid--refine-layer (aref layers l) downs)))
    (let ((low (apply #'min (cl-loop for l below nl
                                     append (mapcar #'octocat-mermaid--n-cross
                                                    (aref layers l))))))
      (dotimes (l nl)
        (dolist (n (aref layers l))
          (cl-decf (octocat-mermaid--n-cross n) (- low margin)))))))

(defun octocat-mermaid--place-main (layers edges margin)
  "Set the main positions of the nodes of LAYERS, from MARGIN on.
Leave room for the labels of EDGES.  Return (STARTS SIZES TOTAL): the
first row (column) and extent of each layer, and the extent of the whole
chart."
  (let* ((nl (length layers))
         (sizes (make-vector nl 1))
         (starts (make-vector nl margin))
         (gaps (make-vector nl (if octocat-mermaid--vertical 3 5))))
    (dotimes (l nl)
      (aset sizes l (apply #'max 1 (mapcar (lambda (n)
                                             (if (octocat-mermaid--n-virtual n)
                                                 1
                                               (octocat-mermaid--msize n)))
                                           (aref layers l)))))
    ;; Side by side, a gap must hold the labels of the edges leaving it.
    (unless octocat-mermaid--vertical
      (dolist (e edges)
        (when-let* ((label (octocat-mermaid--edge-label e)))
          (let ((l (octocat-mermaid--n-layer (car (octocat-mermaid--e-path e)))))
            (aset gaps l (max (aref gaps l) (+ 4 (string-width label))))))))
    (dotimes (l nl)
      (when (> l 0)
        (aset starts l (+ (aref starts (1- l)) (aref sizes (1- l)) (aref gaps (1- l)))))
      (dolist (n (aref layers l))
        (setf (octocat-mermaid--n-main n)
              (if (octocat-mermaid--n-virtual n)
                  (aref starts l)
                (+ (aref starts l) (/ (- (aref sizes l) (octocat-mermaid--msize n)) 2))))))
    (list starts sizes (+ (aref starts (1- nl)) (aref sizes (1- nl))))))

(defun octocat-mermaid--spread (n j k)
  "Return the cross position of attachment J of K on the side of node N."
  (let ((inner (max 1 (- (octocat-mermaid--csize n) 2))))
    (+ (octocat-mermaid--n-cross n) 1 (floor (* (+ j 0.5) inner) k))))

(defun octocat-mermaid--attach (nodes edges)
  "Choose where the edges of EDGES meet the nodes of NODES.
Edges leaving or entering a side are spread along it, in the order of the
nodes at their other ends.  A single edge between two nodes that are
each its only one on that side is made straight when it can be."
  (dolist (n nodes)
    (let* ((outs (seq-filter (lambda (e) (eq (car (octocat-mermaid--e-path e)) n)) edges))
           (ins  (seq-filter (lambda (e) (eq (car (last (octocat-mermaid--e-path e))) n)) edges))
           (outs (sort outs (lambda (a b)
                              (< (octocat-mermaid--center (cadr (octocat-mermaid--e-path a)))
                                 (octocat-mermaid--center (cadr (octocat-mermaid--e-path b)))))))
           (ins  (sort ins (lambda (a b)
                             (< (octocat-mermaid--center (car (last (octocat-mermaid--e-path a) 2)))
                                (octocat-mermaid--center (car (last (octocat-mermaid--e-path b) 2))))))))
      (cl-loop for e in outs for j from 0
               do (setf (octocat-mermaid--e-start-c e)
                        (octocat-mermaid--spread n j (length outs))))
      (cl-loop for e in ins for j from 0
               do (setf (octocat-mermaid--e-end-c e)
                        (octocat-mermaid--spread n j (length ins))))))
  ;; Straighten lone edges between two nodes when their sides overlap.
  (dolist (e edges)
    (let* ((path (octocat-mermaid--e-path e))
           (a (car path)) (b (cadr path)))
      (when (and (= (length path) 2)
                 (= 1 (cl-count-if (lambda (x) (eq (car (octocat-mermaid--e-path x)) a)) edges))
                 (= 1 (cl-count-if (lambda (x) (eq (car (last (octocat-mermaid--e-path x))) b))
                                   edges)))
        (let ((low  (max (+ (octocat-mermaid--n-cross a) 1) (+ (octocat-mermaid--n-cross b) 1)))
              (high (min (+ (octocat-mermaid--n-cross a) (octocat-mermaid--csize a) -2)
                         (+ (octocat-mermaid--n-cross b) (octocat-mermaid--csize b) -2))))
          (when (<= low high)
            (let ((c (max low (min high (round (/ (+ (octocat-mermaid--center a)
                                                     (octocat-mermaid--center b))
                                                  2.0))))))
              (setf (octocat-mermaid--e-start-c e) c
                    (octocat-mermaid--e-end-c e) c))))))))

;;;; Flowcharts: drawing

(defun octocat-mermaid--xy (m c)
  "Return the (X . Y) cell of main position M and cross position C."
  (if octocat-mermaid--vertical (cons c m) (cons m c)))

(defun octocat-mermaid--route (e starts sizes)
  "Return (POINTS START-MARK END-MARK) for edge E.
POINTS are (MAIN . CROSS).  The marks are what the ends of the edge
carry (`arrow', `cross', `circle' or nil).  STARTS and SIZES are the
layer extents from `octocat-mermaid--place-main'."
  (let* ((path (octocat-mermaid--e-path e))
         (top (car path))
         (bot (car (last path)))
         (smark (if (eq top (octocat-mermaid--e-to e))
                    (octocat-mermaid--e-head e)
                  (octocat-mermaid--e-tail e)))
         (emark (if (eq bot (octocat-mermaid--e-to e))
                    (octocat-mermaid--e-head e)
                  (octocat-mermaid--e-tail e)))
         (cur (octocat-mermaid--e-start-c e))
         (pts (list (cons (+ (octocat-mermaid--n-main top) (octocat-mermaid--msize top) -1
                             (if smark 1 0))
                          cur))))
    (cl-loop for (a b) on path while b
             do (let ((bus (+ (aref starts (octocat-mermaid--n-layer a))
                              (aref sizes (octocat-mermaid--n-layer a))))
                      (next (if (eq b bot)
                                (octocat-mermaid--e-end-c e)
                              (octocat-mermaid--n-cross b))))
                  (push (cons bus cur) pts)
                  (push (cons bus next) pts)
                  (setq cur next)))
    (push (cons (- (octocat-mermaid--n-main bot) (if emark 1 0)) cur) pts)
    (list (nreverse pts) smark emark)))

(defun octocat-mermaid--mark-glyph (mark startp)
  "Return the character for MARK at the start (STARTP) or end of an edge."
  (pcase mark
    ('arrow (if octocat-mermaid--vertical
                (if startp "▲" "▼")
              (if startp "◄" "►")))
    ('cross "✕")
    ('circle "○")))

(defun octocat-mermaid--place-label (cv e starts sizes)
  "Write the label of edge E onto CV, if there is room."
  (when-let* ((label (octocat-mermaid--edge-label e)))
    (let* ((path (octocat-mermaid--e-path e))
           (a (car path)) (b (cadr path))
           (bus (+ (aref starts (octocat-mermaid--n-layer a))
                   (aref sizes (octocat-mermaid--n-layer a))))
           (next (if (eq b (car (last path)))
                     (octocat-mermaid--e-end-c e)
                   (octocat-mermaid--n-cross b)))
           (w (string-width label)))
      (if octocat-mermaid--vertical
          ;; Beside the line, on the row below the bus: right, else left,
          ;; else across the line itself.
          (let ((y (1+ bus))
                (centred (- next (/ w 2))))
            (cl-flet ((free-p (x &optional line)
                        (cl-every (lambda (i)
                                    (let ((s (octocat-mermaid--get cv (+ x i) y)))
                                      (or (member s '(nil " "))
                                          (and line (= (+ x i) next)
                                               (member s '("│" "┃" "┆"))))))
                                  (number-sequence 0 (1- w)))))
              (cond ((free-p (+ next 2)) (octocat-mermaid--put cv (+ next 2) y label))
                    ((and (>= (- next w 1) 0) (free-p (- next w 1)))
                     (octocat-mermaid--put cv (- next w 1) y label))
                    ((and (>= centred 0) (free-p centred t))
                     (octocat-mermaid--put cv centred y label)))))
        ;; On the line, which runs from the bus on.
        (let ((x (1+ bus)))
          (when (cl-every (lambda (i)
                            (let ((s (octocat-mermaid--get cv (+ x i) next)))
                              (or (member s '(nil " "))
                                  (and (= (length s) 1)
                                       (assq (aref s 0) octocat-mermaid--line-bits)))))
                          (number-sequence 0 (+ w 1)))
            (octocat-mermaid--put cv x next (concat " " label " "))))))))

(defun octocat-mermaid--node-rect (n)
  "Return (X0 Y0 X1 Y1), the cells covered by node N."
  (let ((xy (octocat-mermaid--xy (octocat-mermaid--n-main n) (octocat-mermaid--n-cross n))))
    (list (car xy) (cdr xy)
          (+ (car xy) (octocat-mermaid--n-w n) -1)
          (+ (cdr xy) (octocat-mermaid--n-h n) -1))))

(defun octocat-mermaid--rects-meet-p (a b)
  "Return non-nil if the rectangles A and B, each (X0 Y0 X1 Y1 ...), overlap."
  (and (<= (nth 0 a) (nth 2 b)) (<= (nth 0 b) (nth 2 a))
       (<= (nth 1 a) (nth 3 b)) (<= (nth 1 b) (nth 3 a))))

(defvar octocat-mermaid--frame-widen '(8 0 nil)
  "How far frames are widened for their titles, in order of preference.
Each is as for the WIDEN argument of `octocat-mermaid--frames-1'.")

(defun octocat-mermaid--frames-1 (groups nodes widen)
  "Return the frames of GROUPS around their NODES, as (X0 Y0 X1 Y1 TITLE ID).
WIDEN is the extra columns, beyond what its title needs, a frame is made
wide, or nil to leave frames as wide as their nodes make them."
  (let (frames)
    (dolist (g groups)
      (when-let* ((members (seq-filter (lambda (n) (equal (octocat-mermaid--n-group n) (car g)))
                                       nodes)))
        (let* ((rects (mapcar #'octocat-mermaid--node-rect members))
               (x0 (- (apply #'min (mapcar #'car rects)) 2))
               (x1 (+ (apply #'max (mapcar (lambda (r) (nth 2 r)) rects)) 2)))
          (push (list x0
                      (- (apply #'min (mapcar #'cadr rects)) 2)
                      (let ((need (+ x0 (string-width (nth 1 g)) 5)))
                        (if (and widen (> need x1)) (+ need widen) x1))
                      (+ (apply #'max (mapcar (lambda (r) (nth 3 r)) rects)) 2)
                      (nth 1 g) (car g))
                frames))))
    (nreverse frames)))

(defun octocat-mermaid--frames-ok-p (frames nodes)
  "Return non-nil if FRAMES take in no foreign node of NODES or overlap."
  (not (or (cl-some (lambda (f)
                      (cl-some (lambda (n)
                                 (and (not (equal (octocat-mermaid--n-group n) (nth 5 f)))
                                      (octocat-mermaid--rects-meet-p f (octocat-mermaid--node-rect n))))
                               nodes))
                    frames)
           (cl-loop for (a . rest) on frames
                    thereis (cl-some (lambda (b) (octocat-mermaid--rects-meet-p a b)) rest)))))

(defun octocat-mermaid--frames (groups nodes)
  "Return the frames of GROUPS around their NODES, as (X0 Y0 X1 Y1 TITLE ID).
Frames are widened to fit their titles where that leaves them clear of
other nodes.  Return `bad' if a frame would take in a node of another
group, or overlap another frame: the layout cannot show the subgraphs."
  (if (null groups)
      nil
    (or (cl-loop for widen in octocat-mermaid--frame-widen
                 for frames = (octocat-mermaid--frames-1 groups nodes widen)
                 when (octocat-mermaid--frames-ok-p frames nodes) return frames)
        'bad)))

(defun octocat-mermaid--draw-frame (cv frame)
  "Draw the dashed FRAME (see `octocat-mermaid--frames') onto CV.
Whatever is already on the frame's border, such as an edge crossing it,
stays; the title is left out where it would not fit."
  (pcase-let ((`(,x0 ,y0 ,x1 ,y1 ,title ,_) frame))
    (cl-flet ((soft (x y s)
                (when (octocat-mermaid--blank-p cv x y) (octocat-mermaid--put cv x y s))))
      (soft x0 y0 "┌") (soft x1 y0 "┐") (soft x0 y1 "└") (soft x1 y1 "┘")
      (cl-loop for x from (1+ x0) below x1
               do (soft x y0 "╌") (soft x y1 "╌"))
      (cl-loop for y from (1+ y0) below y1
               do (soft x0 y "╎") (soft x1 y "╎"))
      ;; The title goes on the first stretch of the top border it fits
      ;; on (edges may cross the border); failing that, cut short on the
      ;; longest stretch.
      (cl-flet ((free-p (x) (member (octocat-mermaid--get cv x y0) '("╌" nil " "))))
        (let* ((room (- x1 x0 5))
               (full (and (> room 1)
                          (concat " " (truncate-string-to-width title room nil nil "…") " "))))
          (when full
            (or (cl-loop for x from (+ x0 2) to (- x1 1 (string-width full))
                         when (cl-every (lambda (i) (free-p (+ x i)))
                                        (number-sequence 0 (1- (string-width full))))
                         return (progn (octocat-mermaid--put cv x y0 full) t))
                (let ((start (+ x0 2)) (len 0))
                  (while (and (< (+ start len) (- x1 1)) (free-p (+ start len)))
                    (cl-incf len))
                  (when (>= len 5)
                    (octocat-mermaid--put
                     cv start y0
                     (concat " " (truncate-string-to-width title (- len 2) nil nil "…") " ")))))))))))

(defun octocat-mermaid--flow-draw (spec dir maxlabel)
  "Lay out and draw the flowchart SPEC in direction DIR.
Node labels are wrapped to MAXLABEL columns.  Return the lines, or nil if
the chart cannot be drawn."
  (let* ((octocat-mermaid--vertical (and (memq dir '(TD BT)) t))
         (flip (and (memq dir '(BT RL)) t))
         (groups (nth 3 spec))
         (margin (if groups 2 0))
         (table (make-hash-table :test #'equal))
         (nodes (mapcar (lambda (s)
                          (puthash (car s) (octocat-mermaid--make-node s maxlabel) table))
                        (nth 1 spec)))
         (edges (mapcar (lambda (e)
                          (octocat-mermaid--e :from (gethash (nth 0 e) table)
                                              :to (gethash (nth 1 e) table)
                                              :style (nth 2 e) :head (nth 3 e)
                                              :tail (nth 4 e) :text (nth 5 e)))
                        (nth 2 spec))))
    (dolist (g groups)
      (dolist (id (nth 2 g))
        (setf (octocat-mermaid--n-group (gethash id table)) (car g))))
    (unless (cl-some (lambda (e) (eq (octocat-mermaid--e-from e) (octocat-mermaid--e-to e)))
                     edges)
      (octocat-mermaid--break-cycles nodes edges)
      (octocat-mermaid--assign-layers nodes edges flip)
      (let* ((virtuals (octocat-mermaid--add-virtuals edges))
             (all (append nodes virtuals))
             (nl (1+ (apply #'max 0 (mapcar #'octocat-mermaid--n-layer all))))
             (layers (make-vector nl nil))
             (ups (make-hash-table :test #'eq))
             (downs (make-hash-table :test #'eq))
             (cv (octocat-mermaid--canvas)))
        (dolist (n all) (push n (aref layers (octocat-mermaid--n-layer n))))
        (dotimes (l nl) (setf (aref layers l) (nreverse (aref layers l))))
        (dolist (e edges)
          (cl-loop for (a b) on (octocat-mermaid--e-path e) while b
                   do (push a (gethash b ups))
                      (push b (gethash a downs))))
        (dotimes (l nl)
          (setf (aref layers l) (octocat-mermaid--group-layer (aref layers l))))
        (dotimes (_ 4)
          (cl-loop for l from 1 below nl
                   do (setf (aref layers l)
                            (octocat-mermaid--group-layer
                             (octocat-mermaid--order-layer (aref layers l) (aref layers (1- l)) ups))))
          (cl-loop for l from (- nl 2) downto 0
                   do (setf (aref layers l)
                            (octocat-mermaid--group-layer
                             (octocat-mermaid--order-layer (aref layers l) (aref layers (1+ l)) downs)))))
        (octocat-mermaid--place-cross layers ups downs margin)
        (pcase-let ((`(,starts ,sizes ,_) (octocat-mermaid--place-main layers edges margin))
                    (marks nil)
                    (frames nil))
          (octocat-mermaid--attach nodes edges)
          (setq frames (octocat-mermaid--frames groups nodes))
          (dolist (n nodes)
            (let ((xy (octocat-mermaid--xy (octocat-mermaid--n-main n) (octocat-mermaid--n-cross n))))
              (octocat-mermaid--draw-box cv (car xy) (cdr xy)
                                         (octocat-mermaid--n-w n) (octocat-mermaid--n-h n)
                                         (octocat-mermaid--n-lines n) (octocat-mermaid--n-shape n))))
          (dolist (e edges)
            (pcase-let ((`(,pts ,smark ,emark) (octocat-mermaid--route e starts sizes)))
              (octocat-mermaid--draw-line
               cv (mapcar (lambda (p) (octocat-mermaid--xy (car p) (cdr p))) pts)
               (pcase (octocat-mermaid--e-style e)
                 ('dotted '(?┄ . ?┆))
                 ('thick '(?━ . ?┃))))
              (when smark
                (push (cons (octocat-mermaid--xy (car (car pts)) (cdr (car pts)))
                            (octocat-mermaid--mark-glyph smark t))
                      marks))
              (when emark
                (let ((p (car (last pts))))
                  (push (cons (octocat-mermaid--xy (car p) (cdr p))
                              (octocat-mermaid--mark-glyph emark nil))
                        marks)))))
          (dolist (m marks)
            (octocat-mermaid--put cv (car (car m)) (cdr (car m)) (cdr m)))
          (dolist (e edges)
            (octocat-mermaid--place-label cv e starts sizes))
          (unless (eq frames 'bad)
            (dolist (f frames)
              (octocat-mermaid--draw-frame cv f))
            (let ((lines (octocat-mermaid--lines cv)))
              (if groups (octocat-mermaid--dedent lines) lines))))))))

(defun octocat-mermaid--flowchart (spec width)
  "Draw the flowchart SPEC to fit WIDTH columns, or return nil.
Labels are wrapped more and more tightly; a left-to-right chart that still
does not fit is turned top-down."
  (when (and (<= (length (nth 1 spec)) 40) (<= (length (nth 2 spec)) 80))
    (let* ((dir (nth 0 spec))
           (wraps (if width '(40 28 20 14 10) '(40)))
           (sideways (memq dir '(LR RL)))
           (down (if (eq dir 'RL) 'BT 'TD))
           (plan (append (and sideways (list (cons dir 40) (cons dir 24)))
                         (mapcar (lambda (ml) (cons (if sideways down dir) ml)) wraps))))
      (cl-flet ((try ()
                  (cl-loop for (d . ml) in plan
                           for out = (octocat-mermaid--flow-draw spec d ml)
                           when (and out (octocat-mermaid--fits-p out width)) return out)))
        (or (try)
            ;; Frames sized by their nodes alone, with the titles cut short.
            (and width (nth 3 spec)
                 (let ((octocat-mermaid--frame-widen '(nil)))
                   (try))))))))

;;;; State diagrams

(defun octocat-mermaid--parse-state (lines)
  "Parse state diagram LINES into a flowchart spec, or nil if unsupported.
Only transitions, `state \"Name\" as id', `id : text' and `direction' are
understood."
  (let ((dir 'TD) (table (make-hash-table :test #'equal)) order edges header)
    (catch 'fail
      (cl-labels ((node-for (id label)
                    (or (gethash id table)
                        (progn (push id order)
                               (puthash id (list id label 'round) table)))))
        (dolist (raw lines)
          (let ((line (string-trim raw)))
            (cond
             ((or (string-empty-p line) (string-prefix-p "%%" line)))
             ((not header)
              (unless (string-match-p "\\`stateDiagram\\(?:-v2\\)?\\'" line) (throw 'fail nil))
              (setq header t))
             ((string-match "\\`direction[ \t]+\\(TD\\|TB\\|BT\\|LR\\|RL\\)\\'" line)
              (setq dir (intern (match-string 1 line)))
              (when (eq dir 'TB) (setq dir 'TD)))
             ((string-match "\\`state[ \t]+\"\\([^\"]*\\)\"[ \t]+as[ \t]+\\([[:alnum:]_]+\\)\\'" line)
              (setf (nth 1 (node-for (match-string 2 line) (match-string 2 line)))
                    (match-string 1 line)))
             ((string-match (concat "\\`\\(\\[\\*\\]\\|[[:alnum:]_]+\\)[ \t]*-->[ \t]*"
                                    "\\(\\[\\*\\]\\|[[:alnum:]_]+\\)"
                                    "\\(?:[ \t]*:[ \t]*\\(.*\\)\\)?\\'")
                            line)
              (let ((from (match-string 1 line)) (to (match-string 2 line))
                    (text (match-string 3 line)))
                (push (list (if (equal from "[*]")
                                (car (node-for "[*]start" "●"))
                              (car (node-for from from)))
                            (if (equal to "[*]")
                                (car (node-for "[*]end" "◉"))
                              (car (node-for to to)))
                            'solid 'arrow nil text)
                      edges)))
             ((string-match "\\`\\([[:alnum:]_]+\\)[ \t]*:[ \t]*\\(.+\\)\\'" line)
              (let ((spec (node-for (match-string 1 line) (match-string 1 line))))
                (setf (nth 1 spec) (concat (nth 1 spec) "\n" (match-string 2 line)))))
             (t (throw 'fail nil)))))
        (and header order
             (list dir (mapcar (lambda (id) (gethash id table)) (nreverse order))
                   (nreverse edges)))))))

;;;; Sequence diagrams

(defun octocat-mermaid--parse-seq (lines)
  "Parse sequence diagram LINES into (PARTICIPANTS EVENTS AUTONUMBER DEPTH).
PARTICIPANTS are (ID . NAME).  EVENTS are `(msg FROM TO TEXT DASHED HEAD)',
`(note KIND IDS TEXT)', `(begin KIND TEXT)', `(else TEXT)' and `(end)'.
DEPTH is how deeply blocks nest.  Return nil if anything is unsupported."
  (let ((names (make-hash-table :test #'equal))
        order events auto header (depth 0) (maxdepth 0))
    (catch 'fail
      (cl-flet ((ensure (id &optional name)
                  (unless (gethash id names) (push id order))
                  (when (or name (not (gethash id names)))
                    (puthash id (or name (gethash id names) id) names))))
        (dolist (raw lines)
          (let ((line (string-trim raw)))
            (cond
             ((or (string-empty-p line) (string-prefix-p "%%" line)))
             ((not header)
              (unless (string-match-p "\\`sequenceDiagram\\'" line) (throw 'fail nil))
              (setq header t))
             ((string-match-p "\\`\\(?:activate\\|deactivate\\|title\\)\\b" line))
             ((string-match-p "\\`autonumber\\b" line) (setq auto t))
             ((string-match "\\`\\(?:participant\\|actor\\)[ \t]+\\([[:alnum:]_]+\\)\\(?:[ \t]+as[ \t]+\\(.+\\)\\)?\\'"
                             line)
              (ensure (match-string 1 line)
                      (and (match-string 2 line)
                           (octocat-mermaid--clean-label (match-string 2 line)))))
             ((string-match (concat "\\`note[ \t]+\\(over\\|left of\\|right of\\)[ \t]+"
                                    "\\([[:alnum:]_]+\\(?:[ \t]*,[ \t]*[[:alnum:]_]+\\)?\\)"
                                    "[ \t]*:[ \t]*\\(.*\\)\\'")
                            line)
              ;; Read every group before anything else clobbers the match data.
              (let* ((where (match-string 1 line))
                     (who   (match-string 2 line))
                     (what  (match-string 3 line))
                     (kind  (intern (car (split-string (downcase where)))))
                     (ids   (split-string who "[ \t,]+" t))
                     (text  (octocat-mermaid--clean-label what)))
                (dolist (id ids) (ensure id))
                (push (list 'note kind ids text) events)))
             ((string-match "\\`\\(loop\\|alt\\|opt\\|par\\|critical\\|break\\|rect\\)\\b[ \t]*\\(.*\\)\\'" line)
              (setq depth (1+ depth) maxdepth (max maxdepth depth))
              (push (list 'begin (match-string 1 line)
                          (if (equal (match-string 1 line) "rect")
                              ""
                            (octocat-mermaid--clean-label (match-string 2 line))))
                    events))
             ((string-match "\\`\\(?:else\\|and\\|option\\)\\b[ \t]*\\(.*\\)\\'" line)
              (when (= depth 0) (throw 'fail nil))
              (push (list 'else (octocat-mermaid--clean-label (match-string 1 line))) events))
             ((string-match-p "\\`end\\'" line)
              (when (= depth 0) (throw 'fail nil))
              (setq depth (1- depth))
              (push (list 'end) events))
             ((string-match (concat "\\`\\([[:alnum:]_]+\\)[ \t]*\\(--?>>?\\|--?[x)]\\)[+-]?[ \t]*"
                                    "\\([[:alnum:]_]+\\)[ \t]*\\(?::[ \t]*\\(.*\\)\\)?\\'")
                            line)
              (let ((from (match-string 1 line)) (op (match-string 2 line))
                    (to (match-string 3 line))
                    (text (octocat-mermaid--clean-label (or (match-string 4 line) ""))))
                (ensure from) (ensure to)
                (push (list 'msg from to text (string-prefix-p "--" op)
                            (cond ((string-suffix-p ">>" op) 'arrow)
                                  ((string-suffix-p ">" op) 'none)
                                  ((string-suffix-p "x" op) 'cross)
                                  (t 'async)))
                      events)))
             (t (throw 'fail nil)))))
        (and header (= depth 0) order
             (list (mapcar (lambda (id) (cons id (gethash id names))) (nreverse order))
                   (nreverse events) auto maxdepth))))))

(defun octocat-mermaid--seq-prepare (events ids auto maxlabel)
  "Return EVENTS with participants as indices and their text wrapped to MAXLABEL.
IDS lists the participants; numbering is added to messages if AUTO."
  (let ((num 0)
        (idx (lambda (id) (cl-position id ids :test #'equal))))
    (mapcar (lambda (ev)
              (pcase ev
                (`(msg ,from ,to ,text ,dashed ,head)
                 (when auto (cl-incf num))
                 (list 'msg (funcall idx from) (funcall idx to)
                       (octocat-mermaid--wrap (if auto (format "%d. %s" num text) text)
                                              maxlabel)
                       dashed head))
                (`(note ,kind ,nids ,text)
                 (list 'note kind (mapcar idx nids) (octocat-mermaid--wrap text maxlabel)))
                (_ ev)))
            events)))

(defun octocat-mermaid--seq-distances (evs hw n)
  "Return a vector of the distances between the N lifelines of the diagram.
EVS are the prepared events and HW the header widths."
  (let ((d (make-vector (max 0 (1- n)) 0))
        constraints)
    (dotimes (i (1- n))
      (aset d i (+ (/ (+ (nth i hw) (nth (1+ i) hw) 1) 2) 2)))
    (dolist (ev evs)
      (pcase ev
        (`(msg ,a ,b ,lines ,_ ,_)
         (let ((lw (octocat-mermaid--lines-width lines)))
           (if (= a b)
               (when (< (1+ a) n) (push (list a (1+ a) (+ lw 8)) constraints))
             (push (list (min a b) (max a b) (max 6 (+ lw 4))) constraints))))
        (`(note ,kind ,ids ,lines)
         (let ((bw (+ 4 (octocat-mermaid--lines-width lines)))
               (a (apply #'min ids)) (b (apply #'max ids)))
           (pcase kind
             ('over (when (> b a) (push (list a b (max 0 (- bw 5))) constraints)))
             ('left (when (> a 0) (push (list (1- a) a (+ bw 2)) constraints)))
             ('right (when (< (1+ b) n) (push (list b (1+ b) (+ bw 3)) constraints))))))))
    ;; Narrow spans first, so a wide one only adds what is still missing.
    (dolist (c (sort constraints (lambda (x y) (< (- (nth 1 x) (nth 0 x))
                                                  (- (nth 1 y) (nth 0 y))))))
      (pcase-let ((`(,lo ,hi ,need) c))
        (let ((have (cl-loop for i from lo below hi sum (aref d i))))
          (when (< have need)
            (cl-incf (aref d (1- hi)) (- need have))))))
    d))

(defun octocat-mermaid--seq-draw (spec maxlabel maxname)
  "Draw the sequence diagram SPEC, labels wrapped to MAXLABEL, names to MAXNAME."
  (pcase-let* ((`(,parts ,events ,auto ,maxdepth) spec)
               (n (length parts))
               (ids (mapcar #'car parts))
               (names (mapcar (lambda (p) (octocat-mermaid--wrap (cdr p) maxname)) parts))
               (hw (mapcar (lambda (ls) (+ 4 (max 1 (octocat-mermaid--lines-width ls)))) names))
               (hh (+ 2 (apply #'max 1 (mapcar #'length names))))
               (evs (octocat-mermaid--seq-prepare events ids auto maxlabel))
               (d (octocat-mermaid--seq-distances evs hw n))
               (c0 (+ (/ (car hw) 2) maxdepth 1))
               (centers (make-vector n c0))
               (cv (octocat-mermaid--canvas))
               (y hh) (frames nil) (stack nil) (extent 0))
    ;; Notes left of or above the first participant need room on its left.
    (dolist (ev evs)
      (pcase ev
        (`(note ,kind ,nids ,lines)
         (when (memq 0 nids)
           (let ((bw (+ 4 (octocat-mermaid--lines-width lines))))
             (setq c0 (max c0 (pcase kind
                                ('left (+ bw 2))
                                ('over (+ (/ bw 2) 2))
                                (_ 0)))))))))
    (aset centers 0 c0)
    (dotimes (i (1- n))
      (aset centers (1+ i) (+ (aref centers i) (aref d i))))
    (cl-flet ((cx (i) (aref centers i))
              (reach (i w) (setq extent (max extent (+ (aref centers i) w)))))
      ;; Headers.
      (cl-loop for i below n for lines in names for w in hw
               do (octocat-mermaid--draw-box cv (- (cx i) (/ (1- w) 2)) 0 w hh lines 'box)
                  (octocat-mermaid--put cv (cx i) (1- hh) "┬")
                  (reach i (1+ (/ w 2))))
      ;; Events, top to bottom.
      (dolist (ev evs)
        (pcase ev
          (`(msg ,a ,b ,lines ,dashed ,head)
           (let ((lw (octocat-mermaid--lines-width lines))
                 (dash (if dashed "┄" "─")))
             (if (= a b)
                 (let ((x (cx a)) (rows (max 2 (length lines))))
                   (octocat-mermaid--put cv x y (concat "├" (make-string 3 (aref dash 0)) "┐"))
                   (octocat-mermaid--put cv x (1+ y)
                                         (concat "┤" (pcase head ('arrow "◄") ('cross "✕") (_ (string (aref dash 0))))
                                                 (make-string 2 (aref dash 0)) "┘"))
                   (cl-loop for l in lines for i from 0
                            do (octocat-mermaid--put cv (+ x 6) (+ y i) l))
                   (reach a (+ 7 lw))
                   (setq y (+ y rows)))
               (let* ((lo (min a b)) (hi (max a b))
                      (ya (+ y (length lines)))
                      (rightp (> b a)))
                 (cl-loop for l in lines for i from 0
                          do (octocat-mermaid--put
                              cv (+ (cx lo) 1 (/ (- (cx hi) (cx lo) 1 (string-width l)) 2))
                              (+ y i) l))
                 (octocat-mermaid--put cv (cx lo) ya "├")
                 (octocat-mermaid--put cv (cx hi) ya "┤")
                 (cl-loop for x from (1+ (cx lo)) below (cx hi)
                          do (octocat-mermaid--put cv x ya dash))
                 (cl-loop for i from (1+ lo) below hi
                          do (octocat-mermaid--put cv (cx i) ya "┼"))
                 (let ((mark (pcase head
                               ('arrow (if rightp "►" "◄"))
                               ('cross "✕")
                               ('async (if rightp ")" "("))
                               (_ nil))))
                   (when mark
                     (octocat-mermaid--put cv (if rightp (1- (cx hi)) (1+ (cx lo))) ya mark)))
                 (setq y (1+ ya))))))
          (`(note ,kind ,nids ,lines)
           (let* ((tw (octocat-mermaid--lines-width lines))
                  (bw (+ 4 tw))
                  (lo (apply #'min nids)) (hi (apply #'max nids))
                  (left (pcase kind
                          ('left (- (cx lo) 1 bw))
                          ('right (+ (cx hi) 2))
                          (_ (if (> hi lo)
                                 (min (- (cx lo) 2) (- (/ (+ (cx lo) (cx hi)) 2) (/ bw 2)))
                               (- (cx lo) (/ bw 2))))))
                  (w (if (and (eq kind 'over) (> hi lo))
                         (max bw (+ (- (cx hi) (cx lo)) 5))
                       bw)))
             (octocat-mermaid--draw-box cv left y w (+ 2 (length lines)) lines 'box)
             (reach hi (max 0 (- (+ left w) (cx hi))))
             (setq y (+ y 2 (length lines)))))
          (`(begin ,kind ,text)
           (push (list (length stack) y nil (string-trim (concat kind " " text)) nil) stack)
           (setq y (1+ y)))
          (`(else ,text)
           (when stack (push (cons y text) (nth 4 (car stack))))
           (setq y (1+ y)))
          (`(end)
           (let ((f (pop stack)))
             (setf (nth 2 f) y)
             (push f frames))
           (setq y (1+ y)))))
      ;; Lifelines run through anything not drawn on them.
      (dotimes (i n)
        (cl-loop for yy from hh below y
                 do (unless (octocat-mermaid--get cv (cx i) yy)
                      (octocat-mermaid--put cv (cx i) yy "│"))))
      ;; Frames of loop/alt/... blocks span the whole diagram.
      (let ((right (+ extent maxdepth 2)))
        (dolist (f frames)
          (pcase-let ((`(,depth ,y0 ,y1 ,label ,seps) f))
            (let ((x1 depth) (x2 (- right depth)))
              (octocat-mermaid--add-bits cv x1 y0 6)
              (octocat-mermaid--add-bits cv x2 y0 12)
              (octocat-mermaid--add-bits cv x1 y1 3)
              (octocat-mermaid--add-bits cv x2 y1 9)
              (cl-loop for x from (1+ x1) below x2
                       do (octocat-mermaid--add-bits cv x y0 10)
                          (octocat-mermaid--add-bits cv x y1 10))
              (cl-loop for yy from (1+ y0) below y1
                       do (octocat-mermaid--add-bits cv x1 yy 5)
                          (octocat-mermaid--add-bits cv x2 yy 5))
              (octocat-mermaid--put cv (+ x1 2) y0 (concat " " label " "))
              (dolist (s seps)
                (cl-loop for x from (1+ x1) below x2
                         do (when (octocat-mermaid--blank-p cv x (car s))
                              (octocat-mermaid--put cv x (car s) "┄")))
                (unless (string-empty-p (cdr s))
                  (octocat-mermaid--put cv (+ x1 2) (car s) (concat " " (cdr s) " "))))))))
      (octocat-mermaid--lines cv))))

(defun octocat-mermaid--sequence (spec width)
  "Draw the sequence diagram SPEC to fit WIDTH columns, or return nil."
  (when (<= (length (nth 0 spec)) 12)
    (cl-loop for (ml . mn) in (if width
                                  '((40 . 16) (28 . 12) (20 . 10) (14 . 8) (10 . 6) (8 . 5))
                                '((40 . 16)))
             for out = (octocat-mermaid--seq-draw spec ml mn)
             when (octocat-mermaid--fits-p out width) return out)))

;;;; Pie charts

(defun octocat-mermaid--parse-pie (lines)
  "Parse pie chart LINES into (TITLE SHOW-DATA ROWS), or nil if unsupported.
ROWS are (LABEL . VALUE)."
  (let (title show rows header)
    (catch 'fail
      (dolist (raw lines)
        (let ((line (string-trim raw)))
          (cond
           ((or (string-empty-p line) (string-prefix-p "%%" line)))
           ((not header)
            (unless (string-match "\\`pie\\b\\(.*\\)\\'" line) (throw 'fail nil))
            (let ((rest (match-string 1 line)))
              (when (string-match "\\bshowData\\b" rest) (setq show t))
              (when (string-match "\\btitle[ \t]+\\(.+\\)\\'" rest)
                (setq title (octocat-mermaid--clean-label (match-string 1 rest)))))
            (setq header t))
           ((string-match "\\`title[ \t]+\\(.+\\)\\'" line)
            (setq title (octocat-mermaid--clean-label (match-string 1 line))))
           ((string-match "\\`\"\\([^\"]*\\)\"[ \t]*:[ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\'" line)
            (push (cons (match-string 1 line) (string-to-number (match-string 2 line))) rows))
           (t (throw 'fail nil)))))
      (and header rows (> (apply #'+ (mapcar #'cdr rows)) 0)
           (list title show (nreverse rows))))))

(defun octocat-mermaid--pie (spec width)
  "Draw the pie chart SPEC as bars within WIDTH columns, or return nil."
  (pcase-let* ((`(,title ,show ,rows) spec)
               (total (apply #'+ (mapcar #'cdr rows)))
               (top (apply #'max (mapcar #'cdr rows)))
               (lw (min 24 (octocat-mermaid--lines-width (mapcar #'car rows))))
               (pcts (mapcar (lambda (r) (format "%.1f%%" (* 100.0 (/ (float (cdr r)) total)))) rows))
               (vals (mapcar (lambda (r) (format "%g" (cdr r))) rows))
               (pw (octocat-mermaid--lines-width pcts))
               (vw (octocat-mermaid--lines-width vals))
               (tail (+ pw (if show (+ 3 vw) 0)))
               (bw (if width (min 30 (- width lw 2 1 tail)) 30)))
    (when (>= bw 5)
      (append
       (and title (list (truncate-string-to-width title (or width 80))))
       (cl-loop for (label . value) in rows
                for pct in pcts for val in vals
                collect (let* ((eighths (round (* bw 8 (/ (float value) top))))
                               (full (/ eighths 8)) (rem (% eighths 8))
                               (bar (concat (make-string full ?█)
                                            (if (> rem 0) (string (aref "▏▎▍▌▋▊▉" (1- rem))) ""))))
                          (concat (truncate-string-to-width label lw nil ?\s "…")
                                  "  " bar
                                  (make-string (- bw (string-width bar)) ?\s)
                                  " " (make-string (- pw (string-width pct)) ?\s) pct
                                  (if show (format " (%s)" val) ""))))))))

;;;; Entry point

(defun octocat-mermaid--body (lines)
  "Return LINES less any front matter and leading comments or blank lines."
  (let ((lines (seq-drop-while (lambda (l) (or (string-empty-p (string-trim l))
                                               (string-prefix-p "%%" (string-trim l))))
                               lines)))
    (if (equal (string-trim (or (car lines) "")) "---")
        (let ((rest (cdr (seq-drop-while (lambda (l) (not (equal (string-trim l) "---")))
                                         (cdr lines)))))
          (octocat-mermaid--body rest))
      lines)))

(defun octocat-mermaid-render (lines &optional width)
  "Draw the mermaid diagram in LINES (a list of strings) as a list of lines.
WIDTH is the number of columns the drawing may use, or nil for no limit;
the drawing is adapted to it (see the Commentary).  Return nil if the
diagram is of a kind that is not supported, uses a feature that is not,
or cannot be made to fit WIDTH."
  (condition-case nil
      (let* ((lines (octocat-mermaid--body lines))
             (head (string-trim (or (car lines) ""))))
        (cond
         ((string-match-p "\\`\\(?:flowchart\\|graph\\)\\b" head)
          (when-let* ((spec (octocat-mermaid--parse-flow lines)))
            (octocat-mermaid--flowchart spec width)))
         ((string-match-p "\\`stateDiagram\\(?:-v2\\)?\\'" head)
          (when-let* ((spec (octocat-mermaid--parse-state lines)))
            (octocat-mermaid--flowchart spec width)))
         ((string-match-p "\\`sequenceDiagram\\'" head)
          (when-let* ((spec (octocat-mermaid--parse-seq lines)))
            (octocat-mermaid--sequence spec width)))
         ((string-match-p "\\`pie\\b" head)
          (when-let* ((spec (octocat-mermaid--parse-pie lines)))
            (octocat-mermaid--pie spec width)))))
    (error nil)))

(provide 'octocat-mermaid)
;;; octocat-mermaid.el ends here
