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
;; Block level: ATX and setext headings, horizontal rules, fenced and
;; indented code (syntax-highlighted by language), block quotes
;; (including `> [!NOTE]' alerts), bullet, numbered and task lists with
;; nesting, tables, footnotes and collapsible <details>.  Inline:
;; `code', **bold**, *italic*, ~~strike~~, inline and reference-style
;; links, images, autolinks, @mentions, #123 and commit references,
;; :emoji: shortcodes and $math$.  HTML comments are dropped and other
;; HTML tags are stripped, keeping their content.  Mermaid fences are
;; drawn by `octocat-mermaid' to fit the width.
;;
;; Links, #123 and commit references and <details> summaries are
;; interactive: they carry a `keymap' text property binding RET and
;; mouse-1 to `octocat-markdown-follow', which works in any buffer the
;; rendered string is inserted into.
;;
;; Entry points: `octocat-markdown-render' and
;; `octocat-markdown-render-verbatim'.  `octocat-markdown-font-lock-keywords'
;; highlights markdown source in an edit buffer.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'octocat-mermaid)

;;;; Faces

(defgroup octocat-markdown nil
  "Markdown rendering in octocat buffers."
  :group 'tools
  :prefix "octocat-markdown-")

(defface octocat-markdown-heading
  '((t :weight bold))
  "Face for markdown headings."
  :group 'octocat-markdown)

;; A terminal ignores :height, so there h1 is underlined and h2 coloured
;; to tell the levels apart.
(defface octocat-markdown-heading-1
  '((((type graphic)) :inherit octocat-markdown-heading :height 1.3)
    (t :inherit octocat-markdown-heading :underline t))
  "Face for first-level markdown headings."
  :group 'octocat-markdown)

(defface octocat-markdown-heading-2
  '((((type graphic)) :inherit octocat-markdown-heading :height 1.15)
    (t :inherit (octocat-markdown-heading font-lock-function-name-face)))
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

;;;; Following links

(defvar octocat-markdown-ref-function nil
  "Function that opens a reference found in rendered markdown.
Called with KIND (`issue' or `commit'), REPO (an \"owner/name\" string, or
nil for the repository of the current buffer) and ID (an issue number or
a commit SHA).")

(defvar octocat-markdown-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'octocat-markdown-follow)
    (define-key map [mouse-1] #'octocat-markdown-follow)
    map)
  "Keymap put on links, references and <details> summaries.
It is a `keymap' text property, which takes precedence over the major mode
and Evil state maps, so RET works in every buffer a rendered string lands in.")

(defun octocat-markdown--interactive (s help &rest props)
  "Return S made interactive: highlighted, with HELP and PROPS, RET-able."
  (let ((s (copy-sequence s)))
    (add-text-properties 0 (length s)
                         (append (list 'help-echo help
                                       'mouse-face 'highlight
                                       'keymap octocat-markdown-link-map)
                                 props)
                         s)
    s))

(defun octocat-markdown--link (label url)
  "Return LABEL as a link to URL."
  (octocat-markdown--interactive
   (octocat-markdown--face label 'octocat-markdown-link)
   (format "RET: open %s" url) 'octocat-markdown-url url))

(defun octocat-markdown--ref (label kind repo id)
  "Return LABEL as a reference to KIND (`issue' or `commit') ID in REPO."
  (octocat-markdown--interactive
   (octocat-markdown--face label 'octocat-markdown-mention)
   (format "RET: open %s" label) 'octocat-markdown-ref (list kind repo id)))

(defun octocat-markdown--mention (name)
  "Return @NAME (a user or an org/team) as a link to its GitHub page."
  (octocat-markdown--interactive
   (octocat-markdown--face name 'octocat-markdown-mention)
   (format "RET: open %s" name)
   'octocat-markdown-url
   (if (string-match "\\`@\\([^/]+\\)/\\(.+\\)\\'" name)
       (format "https://github.com/orgs/%s/teams/%s"
               (match-string 1 name) (match-string 2 name))
     (concat "https://github.com/" (substring name 1)))))

(defun octocat-markdown--ensure-invisibility ()
  "Make folded <details> bodies invisible in the current buffer."
  (add-to-invisibility-spec 'octocat-markdown-details))

(defun octocat-markdown-toggle-details (&optional pos)
  "Expand or collapse the <details> whose summary is at POS (default point)."
  (interactive)
  (save-excursion
    (goto-char (or pos (point)))
    (let* ((bol (line-beginning-position))
           (arrow (text-property-any bol (line-end-position)
                                     'octocat-markdown-arrow t))
           (inhibit-read-only t)
           beg end hidden)
      (forward-line 1)
      (setq beg (point)
            hidden (eq (get-text-property beg 'invisible) 'octocat-markdown-details))
      (while (and (not (eobp)) (get-text-property (point) 'octocat-markdown-fold))
        (forward-line 1))
      (setq end (point))
      (octocat-markdown--ensure-invisibility)
      (when (> end beg)
        (if hidden
            (remove-text-properties beg end '(invisible nil))
          (put-text-property beg end 'invisible 'octocat-markdown-details))
        (when arrow
          (put-text-property arrow (1+ arrow) 'display (if hidden "▾" "▸")))))))

(defun octocat-markdown-follow (&optional event)
  "Follow the link, reference or <details> summary at point (or at EVENT)."
  (interactive (list last-nonmenu-event))
  (let* ((pos (if (mouse-event-p event) (posn-point (event-start event)) (point)))
         (url (get-text-property pos 'octocat-markdown-url))
         (ref (get-text-property pos 'octocat-markdown-ref)))
    (cond (ref (if octocat-markdown-ref-function
                   (apply octocat-markdown-ref-function ref)
                 (user-error "Octocat: no way to open %s" (nth 2 ref))))
          (url (browse-url url))
          ((get-text-property pos 'octocat-markdown-details)
           (octocat-markdown-toggle-details pos))
          (t (user-error "Octocat: nothing to follow here")))))

;;;; Emoji, math and footnote helpers

(defconst octocat-markdown--emoji
  '(("tada" . "🎉") ("+1" . "👍") ("-1" . "👎") ("thumbsup" . "👍")
    ("thumbsdown" . "👎") ("rocket" . "🚀") ("heart" . "❤️") ("smile" . "😄")
    ("smiley" . "😃") ("grin" . "😁") ("joy" . "😂") ("laughing" . "😆")
    ("wink" . "😉") ("thinking" . "🤔") ("confused" . "😕") ("cry" . "😢")
    ("sob" . "😭") ("warning" . "⚠️") ("white_check_mark" . "✅")
    ("heavy_check_mark" . "✔️") ("x" . "❌") ("bug" . "🐛") ("sparkles" . "✨")
    ("fire" . "🔥") ("eyes" . "👀") ("memo" . "📝") ("lock" . "🔒")
    ("wrench" . "🔧") ("hammer" . "🔨") ("construction" . "🚧") ("zap" . "⚡")
    ("bulb" . "💡") ("books" . "📚") ("star" . "⭐") ("100" . "💯")
    ("pray" . "🙏") ("clap" . "👏") ("wave" . "👋") ("ok_hand" . "👌")
    ("muscle" . "💪") ("boom" . "💥") ("package" . "📦") ("gear" . "⚙️")
    ("link" . "🔗") ("mag" . "🔍") ("bookmark" . "🔖") ("pushpin" . "📌")
    ("hourglass" . "⌛") ("tada2" . "🎊") ("question" . "❓")
    ("exclamation" . "❗") ("point_right" . "👉") ("point_left" . "👈")
    ("recycle" . "♻️") ("art" . "🎨") ("lipstick" . "💄") ("ambulance" . "🚑")
    ("rewind" . "⏪") ("truck" . "🚚") ("shipit" . "🐿️") ("turtle" . "🐢")
    ("snake" . "🐍") ("coffee" . "☕") ("beer" . "🍺") ("pizza" . "🍕")
    ("skull" . "💀") ("poop" . "💩") ("see_no_evil" . "🙈")
    ("information_source" . "ℹ️") ("arrow_right" . "➡️") ("arrow_left" . "⬅️")
    ("arrow_up" . "⬆️") ("arrow_down" . "⬇️") ("green_circle" . "🟢")
    ("red_circle" . "🔴") ("large_blue_circle" . "🔵") ("sunny" . "☀️")
    ("octocat" . "🐙") ("trophy" . "🏆") ("crown" . "👑") ("gift" . "🎁"))
  "Emoji shortcodes understood by the inline renderer.")

(defconst octocat-markdown--tex-symbols
  '(("alpha" . "α") ("beta" . "β") ("gamma" . "γ") ("delta" . "δ")
    ("epsilon" . "ε") ("varepsilon" . "ε") ("zeta" . "ζ") ("eta" . "η")
    ("theta" . "θ") ("iota" . "ι") ("kappa" . "κ") ("lambda" . "λ")
    ("mu" . "μ") ("nu" . "ν") ("xi" . "ξ") ("pi" . "π") ("rho" . "ρ")
    ("sigma" . "σ") ("tau" . "τ") ("upsilon" . "υ") ("phi" . "φ")
    ("varphi" . "φ") ("chi" . "χ") ("psi" . "ψ") ("omega" . "ω")
    ("Gamma" . "Γ") ("Delta" . "Δ") ("Theta" . "Θ") ("Lambda" . "Λ")
    ("Xi" . "Ξ") ("Pi" . "Π") ("Sigma" . "Σ") ("Phi" . "Φ") ("Psi" . "Ψ")
    ("Omega" . "Ω") ("sum" . "∑") ("prod" . "∏") ("int" . "∫")
    ("oint" . "∮") ("infty" . "∞") ("partial" . "∂") ("nabla" . "∇")
    ("pm" . "±") ("mp" . "∓") ("times" . "×") ("div" . "÷") ("cdot" . "·")
    ("ast" . "∗") ("circ" . "∘") ("le" . "≤") ("leq" . "≤") ("ge" . "≥")
    ("geq" . "≥") ("ne" . "≠") ("neq" . "≠") ("approx" . "≈")
    ("equiv" . "≡") ("sim" . "∼") ("propto" . "∝") ("ll" . "≪")
    ("gg" . "≫") ("in" . "∈") ("notin" . "∉") ("subset" . "⊂")
    ("supset" . "⊃") ("subseteq" . "⊆") ("supseteq" . "⊇") ("cup" . "∪")
    ("cap" . "∩") ("emptyset" . "∅") ("forall" . "∀") ("exists" . "∃")
    ("neg" . "¬") ("land" . "∧") ("lor" . "∨") ("to" . "→")
    ("rightarrow" . "→") ("leftarrow" . "←") ("leftrightarrow" . "↔")
    ("Rightarrow" . "⇒") ("Leftarrow" . "⇐") ("Leftrightarrow" . "⇔")
    ("mapsto" . "↦") ("ldots" . "…") ("cdots" . "⋯") ("dots" . "…")
    ("angle" . "∠") ("degree" . "°") ("prime" . "′") ("hbar" . "ℏ")
    ("ell" . "ℓ") ("Re" . "ℜ") ("Im" . "ℑ") ("aleph" . "ℵ")
    ("langle" . "⟨") ("rangle" . "⟩") ("quad" . " ") ("qquad" . "  ")
    ("," . " ") (";" . " ") (":" . " ") ("!" . "") ("{" . "{") ("}" . "}")
    ("%" . "%") ("$" . "$") ("&" . "&") ("#" . "#") ("_" . "_"))
  "TeX control words rendered by `octocat-markdown--tex'.")

(defconst octocat-markdown--super
  '((?0 . "⁰") (?1 . "¹") (?2 . "²") (?3 . "³") (?4 . "⁴") (?5 . "⁵")
    (?6 . "⁶") (?7 . "⁷") (?8 . "⁸") (?9 . "⁹") (?+ . "⁺") (?- . "⁻")
    (?= . "⁼") (?\( . "⁽") (?\) . "⁾") (?n . "ⁿ") (?i . "ⁱ"))
  "Superscript forms of characters.")

(defconst octocat-markdown--sub
  '((?0 . "₀") (?1 . "₁") (?2 . "₂") (?3 . "₃") (?4 . "₄") (?5 . "₅")
    (?6 . "₆") (?7 . "₇") (?8 . "₈") (?9 . "₉") (?+ . "₊") (?- . "₋")
    (?= . "₌") (?\( . "₍") (?\) . "₎") (?a . "ₐ") (?e . "ₑ") (?o . "ₒ")
    (?x . "ₓ") (?i . "ᵢ") (?j . "ⱼ") (?n . "ₙ"))
  "Subscript forms of characters.")

(defun octocat-markdown--script (text table marker)
  "Return TEXT in the scripts of TABLE, or \"MARKER(TEXT)\" if it has no form."
  (if (cl-every (lambda (c) (assq c table)) text)
      (mapconcat (lambda (c) (cdr (assq c table))) text "")
    (concat marker "(" text ")")))

(defun octocat-markdown--tex (tex)
  "Return the TeX math source TEX approximated in Unicode."
  (let ((s tex)
        (group "{\\([^{}]*\\)}"))
    ;; Innermost groups first, so \frac{\sqrt{x}}{2} works.
    (dotimes (_ 4)
      (setq s (replace-regexp-in-string
               (concat "\\\\\\(?:d\\|t\\)?frac *" group " *" group)
               "\\1⁄\\2" s)
            s (replace-regexp-in-string (concat "\\\\sqrt *" group) "√(\\1)" s)
            s (replace-regexp-in-string
               (concat "\\\\\\(?:text\\|mathrm\\|mathbf\\|mathit\\|mathbb\\|operatorname\\|mathcal\\) *" group)
               "\\1" s)))
    (setq s (replace-regexp-in-string "\\\\sqrt *\\([^ {]\\)" "√\\1" s)
          s (replace-regexp-in-string "\\\\\\(?:left\\|right\\|big\\|Big\\)\\([.|(]?\\)" "\\1" s))
    (setq s (replace-regexp-in-string
             "\\\\\\([A-Za-z]+\\|[^A-Za-z]\\)"
             (lambda (m)
               (let ((hit (assoc (substring m 1) octocat-markdown--tex-symbols)))
                 (if hit (cdr hit) (substring m 1))))
             s t t))
    (setq s (replace-regexp-in-string
             "\\^\\(?:{\\([^{}]*\\)}\\|\\([^ {]\\)\\)"
             (lambda (m)
               (octocat-markdown--script
                (or (and (string-match "\\^{\\([^{}]*\\)}" m) (match-string 1 m))
                    (substring m 1))
                octocat-markdown--super "^"))
             s t t)
          s (replace-regexp-in-string
             "_\\(?:{\\([^{}]*\\)}\\|\\([^ {]\\)\\)"
             (lambda (m)
               (octocat-markdown--script
                (or (and (string-match "_{\\([^{}]*\\)}" m) (match-string 1 m))
                    (substring m 1))
                octocat-markdown--sub "_"))
             s t t))
    (string-trim (replace-regexp-in-string "[{}]" "" s))))

(defvar octocat-markdown--definitions nil
  "Hash table of reference-link definitions (lowercase label -> URL), or nil.")

(defvar octocat-markdown--footnotes nil
  "Alist of footnote definitions (label . text) of the text being rendered.")

(defvar octocat-markdown--footnote-order nil
  "Labels of the footnotes referenced so far, most recent first.")

(defun octocat-markdown--footnote-number (label)
  "Return the number of footnote LABEL, or nil if it is not defined."
  (when (assoc label octocat-markdown--footnotes)
    (unless (member label octocat-markdown--footnote-order)
      (push label octocat-markdown--footnote-order))
    (- (length octocat-markdown--footnote-order)
       (cl-position label octocat-markdown--footnote-order :test #'equal))))

(defun octocat-markdown--superscript (n)
  "Return the number N in superscript digits."
  (octocat-markdown--script (number-to-string n) octocat-markdown--super "^"))

(defun octocat-markdown--definition (label)
  "Return the URL of reference-link LABEL, or nil."
  (and octocat-markdown--definitions
       (gethash (downcase (string-join (split-string label) " "))
                octocat-markdown--definitions)))

(defun octocat-markdown--sha-p (sha)
  "Return non-nil if SHA is plausibly an abbreviated commit hash.
Besides being 7 to 40 hex digits it must mix letters and digits, so words
like \"defaced\" and numbers like 1234567 are not taken for hashes."
  (and (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" sha)
       (string-match-p "[0-9]" sha)
       (string-match-p "[a-f]" sha)))

(defun octocat-markdown--img (tag)
  "Return the HTML <img> TAG as an image link."
  (let ((src (and (string-match "src=\"\\([^\"]*\\)\"" tag) (match-string 1 tag)))
        (alt (and (string-match "alt=\"\\([^\"]*\\)\"" tag) (match-string 1 tag))))
    (octocat-markdown--link
     (format "[image%s]" (if (string-empty-p (or alt "")) "" (concat ": " alt)))
     (or src ""))))

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
    (,"<img\\b[^>]*>" ,(lambda (m) (octocat-markdown--img (nth 0 m))))
    (,"<kbd>\\(.*?\\)</kbd>"
     ,(lambda (m) (octocat-markdown--face (concat "[" (nth 1 m) "]")
                                           'octocat-markdown-code)))
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
    ;; Reference-style links, footnote references and [shortcut] links
    ;; stay literal unless the label has a definition.
    (,"\\[\\([^]\n]+\\)\\]\\[\\([^]\n]*\\)\\]"
     ,(lambda (m)
          (let* ((id  (if (string-empty-p (nth 2 m)) (nth 1 m) (nth 2 m)))
                 (url (octocat-markdown--definition id)))
            (if url
                (octocat-markdown--link (octocat-markdown--inline (nth 1 m)) url)
              (concat "[" (octocat-markdown--inline (nth 1 m)) "]["
                      (nth 2 m) "]")))))
    (,"\\[\\^\\([^]\n]+\\)\\]"
     ,(lambda (m)
          (if-let* ((n (octocat-markdown--footnote-number (nth 1 m))))
              (octocat-markdown--face (octocat-markdown--superscript n)
                                      'octocat-markdown-mention)
            (nth 0 m))))
    (,"\\[\\([^]\n^][^]\n]*\\)\\]"
     ,(lambda (m)
          (if-let* ((url (octocat-markdown--definition (nth 1 m))))
              (octocat-markdown--link (octocat-markdown--inline (nth 1 m)) url)
            (concat "[" (octocat-markdown--inline (nth 1 m)) "]"))))
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
     ,(lambda (m) (octocat-markdown--mention (nth 1 m)))
     1)
    (,"\\(?:\\`\\|[^[:alnum:]_&]\\)\\(\\(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\)?#[0-9]+\\)\\b"
     ,(lambda (m)
          (string-match "\\`\\(.*\\)#\\([0-9]+\\)\\'" (nth 1 m))
          (octocat-markdown--ref (nth 1 m) 'issue
                                 (let ((repo (match-string 1 (nth 1 m))))
                                   (and (not (string-empty-p repo)) repo))
                                 (string-to-number (match-string 2 (nth 1 m)))))
     1)
    ;; Commit hashes: a short or full SHA, optionally as owner/repo@sha.
    (,"\\(?:\\`\\|[^[:alnum:]_/#&@.-]\\)\\(\\(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@\\)?[0-9a-f]\\{7,40\\}\\)\\(?:[^[:alnum:]_-]\\|\\'\\)"
     ,(lambda (m)
          (let* ((text (nth 1 m))
                 (at   (string-search "@" text))
                 (sha  (if at (substring text (1+ at)) text)))
            (if (octocat-markdown--sha-p sha)
                (octocat-markdown--ref (if at text (substring sha 0 7))
                                       'commit (and at (substring text 0 at)) sha)
              text)))
     1)
    (,":\\([a-z0-9_+-]+\\):"
     ,(lambda (m) (or (cdr (assoc (nth 1 m) octocat-markdown--emoji)) (nth 0 m))))
    ;; $math$: the opening $ is followed, and the closing one preceded, by
    ;; a non-space, and the closing one is not followed by a digit ($5 and $10).
    (,"\\(?:\\`\\|[^[:alnum:]_$\\]\\)\\(\\$[^$[:space:]]\\(?:[^$\n]*?[^$[:space:]\\]\\)?\\$\\)\\(?:[^[:digit:]]\\|\\'\\)"
     ,(lambda (m)
          (octocat-markdown--face
           (octocat-markdown--tex (substring (nth 1 m) 1 -1))
           'octocat-markdown-code))
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
(defconst octocat-markdown--setext-re "^ \\{0,3\\}\\(=+\\|-+\\) *$")
(defconst octocat-markdown--details-re "\\`[ \t]*<details\\b\\([^>]*\\)>")
(defconst octocat-markdown--link-def-re
  (concat "^ \\{0,3\\}\\[\\([^]^][^]]*\\)\\]: *<?\\([^[:space:]>]+\\)>?"
          "\\(?: +\\(?:\"[^\"]*\"\\|'[^']*'\\|([^)]*)\\)\\)? *$")
  "Matches a reference-link definition, `[label]: url \"title\"'.")
(defconst octocat-markdown--footnote-def-re "^\\[\\^\\([^]]+\\)\\]: *\\(.*\\)$"
  "Matches the first line of a footnote definition, `[^label]: text'.")

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

(defcustom octocat-markdown-highlight-code t
  "Non-nil means fenced code is syntax-highlighted by its language."
  :type 'boolean
  :group 'octocat-markdown)

(defcustom octocat-markdown-language-modes
  '(("elisp" . emacs-lisp-mode) ("el" . emacs-lisp-mode)
    ("emacs-lisp" . emacs-lisp-mode) ("lisp" . lisp-mode)
    ("scheme" . scheme-mode) ("clojure" . clojure-mode)
    ("python" . python-mode) ("py" . python-mode)
    ("ruby" . ruby-mode) ("rb" . ruby-mode) ("perl" . perl-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("shell" . sh-mode)
    ("zsh" . sh-mode) ("console" . sh-mode)
    ("c" . c-mode) ("cpp" . c++-mode) ("c++" . c++-mode)
    ("java" . java-mode) ("go" . go-mode) ("rust" . rust-mode)
    ("rs" . rust-mode) ("swift" . swift-mode) ("kotlin" . kotlin-mode)
    ("js" . js-mode) ("javascript" . js-mode) ("jsx" . js-mode)
    ("ts" . typescript-mode) ("typescript" . typescript-mode)
    ("json" . js-json-mode) ("jsonc" . js-json-mode)
    ("yaml" . yaml-mode) ("yml" . yaml-mode) ("toml" . conf-toml-mode)
    ("ini" . conf-mode) ("html" . html-mode) ("xml" . nxml-mode)
    ("css" . css-mode) ("scss" . scss-mode) ("sql" . sql-mode)
    ("lua" . lua-mode) ("make" . makefile-mode) ("makefile" . makefile-mode)
    ("dockerfile" . dockerfile-mode) ("diff" . diff-mode)
    ("patch" . diff-mode) ("tex" . latex-mode) ("latex" . latex-mode))
  "Alist mapping a code fence's language to the major mode that highlights it.
Languages whose mode is not available are shown unhighlighted."
  :type '(alist :key-type string :value-type symbol)
  :group 'octocat-markdown)

(defconst octocat-markdown--highlight-limit 20000
  "Longest code, in characters, that is syntax-highlighted.")

(defun octocat-markdown--highlight (code lang)
  "Return the lines of CODE (a list of strings) fontified for LANG, or nil.
The fontified text is built in a scratch buffer under LANG's major mode
with its hooks suppressed, and only the faces are kept."
  (let ((mode (and octocat-markdown-highlight-code lang
                   (cdr (assoc (downcase lang) octocat-markdown-language-modes))))
        (text (string-join code "\n")))
    (when (and mode (fboundp mode)
               (<= (length text) octocat-markdown--highlight-limit))
      (condition-case nil
          (with-temp-buffer
            (insert text)
            (delay-mode-hooks (funcall mode))
            (font-lock-ensure)
            (let ((pos (point-min)) out)
              (while (< pos (point-max))
                (let ((next (next-single-char-property-change pos 'face nil (point-max)))
                      (face (get-text-property pos 'face)))
                  (push (if face
                            (propertize (buffer-substring-no-properties pos next)
                                        'face face)
                          (buffer-substring-no-properties pos next))
                        out)
                  (setq pos next)))
              (split-string (apply #'concat (nreverse out)) "\n")))
        (error nil)))))

(defun octocat-markdown--code-block (code &optional lang)
  "Return the lines of fenced CODE (a list of strings) as a padded block.
LANG is the fence's language, which picks the syntax highlighting.  A
`math' fence is shown as Unicode text.  A `mermaid' one is drawn by
`octocat-mermaid-render' to fit the width available; when that cannot
draw it, the source is shown, labelled as such."
  (let* ((lang (and lang (car (split-string lang))))
         (diagram (and (equal lang "mermaid")
                       (octocat-mermaid-render
                        code (and octocat-markdown--avail (- octocat-markdown--avail 2)))))
         (code (cond (diagram diagram)
                     ((member lang '("math" "latex-math"))
                      (split-string (octocat-markdown--tex (string-join code "\n")) "\n"))
                     (t code)))
         (code (or (and (not diagram) (octocat-markdown--highlight code lang)) code))
         (width (apply #'max 0 (mapcar #'string-width code))))
    (append
     (when (and (equal lang "mermaid") (not diagram))
       (list (cons (octocat-markdown--face "mermaid diagram (source)"
                                           'octocat-markdown-dimmed 'italic)
                   0)))
     (mapcar (lambda (l)
               (let ((s (concat " " l (make-string (- width (string-width l)) ?\s) " ")))
                 (add-face-text-property 0 (length s) 'octocat-markdown-code-block t s)
                 (cons s 0)))
             (or code '(""))))))

(defun octocat-markdown--alert (label)
  "Return the heading line for the GitHub alert LABEL, or nil."
  (when (string-match "\\`\\[!\\(NOTE\\|TIP\\|IMPORTANT\\|WARNING\\|CAUTION\\)\\] *\\'" label)
    (octocat-markdown--face (capitalize (match-string 1 label)) 'bold)))

(defconst octocat-markdown--indented-re "\\`\\(?: \\{4\\}\\|\t\\)"
  "Matches a line indented far enough to be an indented code block.")

(defun octocat-markdown--unindent (line)
  "Return LINE less the four columns that make it indented code."
  (if (string-prefix-p "\t" line)
      (substring line 1)
    (substring line (min 4 (length line)))))

(defun octocat-markdown--block-start-p (line)
  "Return non-nil if LINE opens a block, so it cannot continue a paragraph."
  (or (string-match-p octocat-markdown--item-re line)
      (string-match-p octocat-markdown--fence-re line)
      (string-match-p octocat-markdown--hr-re line)
      (string-match-p octocat-markdown--quote-re line)
      (string-match-p "\\` \\{0,3\\}#\\{1,6\\}\\(?: \\|\\'\\)" line)
      (string-match-p octocat-markdown--details-re line)))

(defun octocat-markdown--lazy-p (prev next)
  "Return non-nil if NEXT continues, unindented, the list item line PREV."
  (and prev
       (not (octocat-markdown--blank-p prev))
       (not (octocat-markdown--blank-p next))
       (not (string-match-p octocat-markdown--fence-re prev))
       (not (octocat-markdown--block-start-p next))))

(defun octocat-markdown--heading-row (text level)
  "Return the row of a heading of LEVEL with markdown source TEXT."
  (octocat-markdown--standout
   (cons (octocat-markdown--face
          (octocat-markdown--inline text)
          (pcase level (1 'octocat-markdown-heading-1)
                 (2 'octocat-markdown-heading-2)
                 (_ 'octocat-markdown-heading)))
         0)))

(defun octocat-markdown--count (regexp string)
  "Return how many times REGEXP matches in STRING."
  (let ((n 0) (pos 0))
    (while (string-match regexp string pos)
      (setq n (1+ n) pos (max (1+ pos) (match-end 0))))
    n))

(defvar octocat-markdown--in-details nil
  "Non-nil while rendering the body of a <details>.
A <details> inside another does not fold: it shows as a bold title.")

(defun octocat-markdown--details (line lines depth)
  "Render the <details> element opened on LINE, the rest of it in LINES.
DEPTH is as for `octocat-markdown--blocks'.  Return (ROWS . REST), REST
being the lines after the closing tag.

The summary becomes a row that RET expands or collapses; the body rows
carry an `octocat-markdown-fold' property (see `octocat-markdown--finish')
and start collapsed unless the tag has `open'."
  (string-match octocat-markdown--details-re line)
  (let* ((open  (string-match-p "\\bopen\\b" (match-string 1 line)))
         (level 1)
         inner)
    (push (substring line (match-end 0)) lines)
    (while (and lines (> level 0))
      (let ((l (pop lines)))
        (setq level (+ level (octocat-markdown--count "<details\\b" l)
                       (- (octocat-markdown--count "</details>" l))))
        (when (<= level 0)
          (setq l (if (string-match "\\`\\(.*\\)</details>" l) (match-string 1 l) l)))
        (push l inner)))
    (let* ((text (string-join (nreverse inner) "\n"))
           (summary nil)
           (body text))
      (when (string-match "<summary[^>]*>\\(\\(?:.\\|\n\\)*?\\)</summary>" text)
        (setq summary (string-trim (replace-regexp-in-string
                                    "[ \t\n]+" " " (match-string 1 text)))
              body (concat (substring text 0 (match-beginning 0))
                           (substring text (match-end 0)))))
      (let* ((title (octocat-markdown--face
                     (octocat-markdown--inline (if (member summary '(nil "")) "Details" summary))
                     'bold))
             (rows  (let ((octocat-markdown--in-details t))
                      (octocat-markdown--tidy
                       (octocat-markdown--blocks (split-string body "\n") depth)))))
        (cons
         (if octocat-markdown--in-details
             (cons (octocat-markdown--standout (cons title 0)) rows)
           (cons
            (octocat-markdown--standout
             (cons (octocat-markdown--interactive
                    (concat (propertize "▸" 'octocat-markdown-arrow t
                                        'display (and open "▾"))
                            " " title)
                    "RET: expand or collapse" 'octocat-markdown-details t)
                   0))
            (mapcar (lambda (r)
                      (let ((s (copy-sequence (if (string-empty-p (car r)) " " (car r)))))
                        (put-text-property 0 (length s) 'octocat-markdown-fold
                                           (if open 'open 'closed) s)
                        (cons s (cdr r))))
                    rows)))
         lines)))))

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
          (let ((fence (match-string 1 line))
                (lang  (string-trim (match-string 2 line)))
                code)
            (while (and lines
                        (not (string-match-p
                              (concat "^ \\{0,3\\}" (regexp-quote (substring fence 0 1))
                                      "\\{" (number-to-string (length fence)) ",\\} *$")
                              (car lines))))
              (push (pop lines) code))
            (pop lines)
            (dolist (l (octocat-markdown--code-block (nreverse code) lang))
              (push l out))))
         ;; Indented code: four spaces, after a blank row or a block.
         ((and (string-match-p octocat-markdown--indented-re line)
               (let ((prev (car out)))
                 (or (null prev) (string-empty-p (car prev))
                     (octocat-markdown--standout-p prev))))
          (let ((code (list (octocat-markdown--unindent line))))
            (while (and lines
                        (or (string-match-p octocat-markdown--indented-re (car lines))
                            (and (octocat-markdown--blank-p (car lines))
                                 (let ((next (seq-find (lambda (l) (not (octocat-markdown--blank-p l)))
                                                       lines)))
                                   (and next (string-match-p octocat-markdown--indented-re next))))))
              (push (octocat-markdown--unindent (pop lines)) code))
            (dolist (l (octocat-markdown--code-block (nreverse code)))
              (push l out))))
         ((string-match-p octocat-markdown--details-re line)
          (pcase-let ((`(,rows . ,rest) (octocat-markdown--details line lines depth)))
            (dolist (r rows) (push r out))
            (setq lines rest)))
         ((string-match-p octocat-markdown--hr-re line)
          (push (octocat-markdown--standout
                 (cons (propertize (make-string 40 ?─) 'face 'octocat-markdown-dimmed) 0))
                out))
         ((string-match octocat-markdown--heading-re line)
          (push (octocat-markdown--heading-row (or (match-string 2 line) "")
                                               (length (match-string 1 line)))
                out))
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
                           (octocat-markdown--tidy
                            (octocat-markdown--blocks quoted depth))))
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
                                   (and next (> (octocat-markdown--indentation next) indent))))
                            ;; Lazy continuation: unindented text running on.
                            (octocat-markdown--lazy-p (car content) (car lines))))
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
                           (octocat-markdown--tidy
                            (octocat-markdown--blocks
                             (if task (cons (substring first (cdr task)) (cdr content)) content)
                             (1+ depth))))))
              (when (null rows) (setq rows (list (cons "" 0))))
              (let ((firstp t))
                (dolist (r rows)
                  (push (octocat-markdown--standout
                         (cons (if firstp
                                   (concat label " " (car r))
                                 (concat (make-string pad ?\s) (car r)))
                               (+ pad (cdr r))))
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
         ;; Setext heading: a line underlined by === or ---.
         ((and lines (string-match octocat-markdown--setext-re (car lines)))
          (let ((level (if (string-prefix-p "=" (string-trim-left (pop lines))) 1 2)))
            (push (octocat-markdown--heading-row (string-trim line) level) out)))
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

(defun octocat-markdown--row-fold (row)
  "Return the fold state (`open' or `closed') of ROW, or nil if it is not folded."
  (let* ((s (car row))
         (i (text-property-not-all 0 (length s) 'octocat-markdown-fold nil s)))
    (and i (get-text-property i 'octocat-markdown-fold s))))

(defun octocat-markdown--finish (rows indent)
  "Join ROWS (see `octocat-markdown--blocks') into a string prefixed by INDENT.
Wrapped continuation lines repeat INDENT, plus each row's hang.  The
lines of a collapsed <details> body are invisible, newline included."
  (mapconcat (lambda (row)
               (let ((full (concat indent (car row) "\n"))
                     (fold (octocat-markdown--row-fold row)))
                 (put-text-property 0 (length full) 'wrap-prefix
                                    (concat indent (make-string (cdr row) ?\s)) full)
                 (when fold
                   (add-text-properties
                    0 (length full)
                    (append '(octocat-markdown-fold t)
                            (and (eq fold 'closed) '(invisible octocat-markdown-details)))
                    full))
                 full))
             rows ""))

(defun octocat-markdown--extract-definitions (lines)
  "Return LINES less the link and footnote definitions, which are recorded.
Link definitions go to `octocat-markdown--definitions' and footnotes to
`octocat-markdown--footnotes'.  Code fences are left alone."
  (let (out fence)
    (while lines
      (let ((l (pop lines)))
        (cond
         ((string-match octocat-markdown--fence-re l)
          (let ((mark (substring (match-string 1 l) 0 1)))
            (setq fence (cond ((null fence) mark) ((equal fence mark) nil) (t fence))))
          (push l out))
         (fence (push l out))
         ((string-match octocat-markdown--link-def-re l)
          (puthash (downcase (string-join (split-string (match-string 1 l)) " "))
                   (match-string 2 l) octocat-markdown--definitions))
         ((string-match octocat-markdown--footnote-def-re l)
          (let ((label (match-string 1 l))
                (text  (match-string 2 l)))
            (while (and lines (string-match-p "\\`  +[^ ]\\|\\`\t" (car lines)))
              (setq text (concat text " " (string-trim (pop lines)))))
            (push (cons label text) octocat-markdown--footnotes)))
         (t (push l out)))))
    (nreverse out)))

(defun octocat-markdown--footnote-rows ()
  "Return the rows listing the footnotes referenced by the text, or nil."
  (when octocat-markdown--footnote-order
    (cons (octocat-markdown--standout
           (cons (propertize (make-string 20 ?─) 'face 'octocat-markdown-dimmed) 0))
          (cl-loop for label in (reverse octocat-markdown--footnote-order)
                   for n from 1
                   collect (cons (concat (octocat-markdown--face
                                          (octocat-markdown--superscript n)
                                          'octocat-markdown-mention)
                                         " "
                                         (octocat-markdown--inline
                                          (cdr (assoc label octocat-markdown--footnotes))))
                                 2)))))

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
         (octocat-markdown--avail (and width (- width (string-width indent))))
         (octocat-markdown--definitions (make-hash-table :test #'equal))
         (octocat-markdown--footnotes nil)
         (octocat-markdown--footnote-order nil)
         (octocat-markdown--in-details nil)
         (rows (octocat-markdown--blocks
                (octocat-markdown--extract-definitions
                 (octocat-markdown--lines text)))))
    (octocat-markdown--finish
     (or (octocat-markdown--tidy (append rows (octocat-markdown--footnote-rows)))
         (list (cons "" 0)))
     indent)))

;;;; Font-lock for markdown source

(defvar octocat-markdown-font-lock-keywords
  '(;; Fenced code first, so nothing inside it is taken for markup.
    ("^ \\{0,3\\}\\(?:```\\|~~~\\).*\n\\(?:.*\n\\)*?\\(?: \\{0,3\\}\\(?:```\\|~~~\\).*$\\|\\'\\)"
     (0 'octocat-markdown-code-block t))
    ("^ \\{0,3\\}\\(#\\{1,6\\}\\)\\( +.*\\)$"
     (1 'octocat-markdown-dimmed) (2 'octocat-markdown-heading))
    ("^ \\{0,3\\}\\([=-]+\\) *$" (1 'octocat-markdown-dimmed))
    ("^ \\{0,3\\}\\(>[> ]*\\)" (1 'octocat-markdown-dimmed))
    ("^ *\\([-*+]\\|[0-9]+[.)]\\)\\(?: +\\(\\[[ xX]\\]\\)\\)? "
     (1 'font-lock-builtin-face) (2 'font-lock-builtin-face nil t))
    ("^ \\{0,3\\}\\(?:\\([-*_]\\) *\\)\\{3,\\}$" (0 'octocat-markdown-dimmed))
    ("^|.*|$" (0 'octocat-markdown-dimmed))
    ("`[^`\n]+`" (0 'octocat-markdown-code))
    ("\\*\\*\\([^[:space:]*]\\(?:.*?[^[:space:]]\\)?\\)\\*\\*" (0 'bold))
    ("\\(?:\\`\\|[^[:alnum:]_]\\)\\(__[^[:space:]_]\\(?:.*?[^[:space:]_]\\)?__\\)"
     (1 'bold))
    ("\\*\\([^*[:space:]]\\(?:[^*\n]*?[^*[:space:]]\\)?\\)\\*" (0 'italic))
    ("\\(?:\\`\\|[^[:alnum:]_]\\)\\(_[^_[:space:]]\\(?:[^_\n]*?[^_[:space:]]\\)?_\\)\\(?:[^[:alnum:]_]\\|\\'\\)"
     (1 'italic))
    ("~~[^[:space:]~]\\(?:.*?[^[:space:]~]\\)?~~" (0 'octocat-markdown-strike))
    ("!?\\[\\([^]\n]+\\)\\](\\([^)\n]*\\))"
     (1 'octocat-markdown-link) (2 'octocat-markdown-dimmed))
    ("\\[\\([^]\n]+\\)\\]\\[[^]\n]*\\]" (1 'octocat-markdown-link))
    ("^ \\{0,3\\}\\(\\[[^]\n]+\\]\\):" (1 'octocat-markdown-link))
    ("<\\(?:https?://[^>\n]+\\|/?[a-zA-Z][^<>\n]*\\|!--.*?--\\)>"
     (0 'octocat-markdown-dimmed))
    ("https?://[^[:space:]<>]*[^[:space:]<>.,;:!?)\"']" (0 'octocat-markdown-link))
    ("\\(?:\\`\\|[^[:alnum:]_/]\\)\\(@[A-Za-z0-9][A-Za-z0-9-]*\\(?:/[A-Za-z0-9_.-]+\\)?\\)"
     (1 'octocat-markdown-mention))
    ("\\(?:\\`\\|[^[:alnum:]_&]\\)\\(\\(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\)?#[0-9]+\\)\\b"
     (1 'octocat-markdown-mention)))
  "Font-lock keywords for markdown source, as in `octocat-edit-mode'.
Fenced code is matched across lines, so the buffer sets `font-lock-multiline'.")

(provide 'octocat-markdown)
;;; octocat-markdown.el ends here
