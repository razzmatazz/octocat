;;; octocat-markdown-tests.el --- ERT tests for the markdown renderer  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for octocat-markdown.el and the glue around it in octocat-core.el
;; and octocat-edit.el.  Run via:
;;   eask test ert test/octocat-markdown-tests.el

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'octocat)

(defun octocat-markdown-tests--md (text &optional width)
  "Return TEXT rendered as markdown, without indent or text properties.
WIDTH is passed on to `octocat-markdown-render'."
  (substring-no-properties (octocat-markdown-render text "" width)))

(defun octocat-markdown-tests--prop (rendered needle prop)
  "Return property PROP of the first character of NEEDLE in RENDERED."
  (get-text-property (string-match (regexp-quote needle) rendered) prop rendered))


;;; Glue in octocat-core

(ert-deftest octocat-markdown-test-string ()
  "Every line gets the indent and a wrap prefix; raw text is kept verbatim."
  (let ((out (octocat--markdown-string "a *b*\r\nc" "> " t)))
    (should (equal (substring-no-properties out) "> a *b*\n> c\n"))
    (should (equal (get-text-property 0 'wrap-prefix out) "> "))))

(ert-deftest octocat-markdown-test-insert-allows-folding ()
  "Inserting markdown lets folded <details> bodies be invisible."
  (with-temp-buffer
    (setq buffer-invisibility-spec '((magit-section . t)))
    (octocat--insert-markdown "text")
    (should (member 'octocat-markdown-details buffer-invisibility-spec))))


;;; Inline

(ert-deftest octocat-markdown-test-inline ()
  "Inline markup is replaced by faces; snake_case and escapes survive."
  (let ((out (octocat-markdown-render "*a* **b** `c` snake_case_name \\*x\\*" "")))
    (should (equal (substring-no-properties out) "a b c snake_case_name *x*\n"))
    (should (equal (get-text-property 0 'face out) 'italic))
    (should (equal (get-text-property 2 'face out) 'bold)))
  (let ((out (octocat-markdown-render "[some link](https://google.com)" "")))
    (should (equal (substring-no-properties out) "some link\n"))
    (should (equal (get-text-property 0 'octocat-markdown-url out) "https://google.com")))
  (should (equal (octocat-markdown-tests--md "@bob fixed #5 <!-- x --><b>hi</b>")
                 "@bob fixed #5 hi\n")))

(ert-deftest octocat-markdown-test-emoji-img-kbd ()
  "Shortcodes become emoji, <img> a link and <kbd> a key; unknown codes stay."
  (should (equal (octocat-markdown-tests--md "ship it :rocket: :nope: 12:30:45")
                 "ship it 🚀 :nope: 12:30:45\n"))
  (let ((out (octocat-markdown-render "<img src=\"http://x/y.png\" alt=\"logo\">" "")))
    (should (equal (substring-no-properties out) "[image: logo]\n"))
    (should (equal (get-text-property 0 'octocat-markdown-url out) "http://x/y.png")))
  (should (equal (octocat-markdown-tests--md "press <kbd>Ctrl</kbd>") "press [Ctrl]\n")))

(ert-deftest octocat-markdown-test-reference-links ()
  "Reference-style links resolve through their definitions, else stay literal."
  (let ((out (octocat-markdown-render
              "see [the docs][1], [Other] and [nope][x]\n\n[1]: http://docs\n[other]: http://o"
              "")))
    (should (equal (substring-no-properties out) "see the docs, Other and [nope][x]\n"))
    (should (equal (octocat-markdown-tests--prop out "the docs" 'octocat-markdown-url)
                   "http://docs"))
    (should (equal (octocat-markdown-tests--prop out "Other" 'octocat-markdown-url)
                   "http://o"))))

(ert-deftest octocat-markdown-test-footnotes ()
  "Footnote references are numbered in order and listed below a rule."
  (should (equal (octocat-markdown-tests--md
                  "b[^b] a[^a] b[^b]\n\n[^a]: Note A\n[^b]: Note B\n  runs on")
                 (concat "b¹ a² b¹\n"
                         (make-string 20 ?─) "\n"
                         "¹ Note B runs on\n"
                         "² Note A\n")))
  ;; An undefined footnote stays as written.
  (should (equal (octocat-markdown-tests--md "x[^none]") "x[^none]\n")))

(ert-deftest octocat-markdown-test-math ()
  "Inline and fenced TeX is approximated in Unicode; currency is left alone."
  (should (equal (octocat-markdown-tests--md "so $x^2 + \\alpha_1$ holds")
                 "so x² + α₁ holds\n"))
  (should (equal (octocat-markdown-tests--md "costs $5 and $10") "costs $5 and $10\n"))
  (should (equal (octocat-markdown-tests--md "```math\n\\frac{a}{b} \\le \\sqrt{x}\n```")
                 " a⁄b ≤ √(x) \n")))


;;; References

(ert-deftest octocat-markdown-test-references ()
  "#123, owner/repo#123 and commit hashes carry what is needed to open them."
  (let ((out (octocat-markdown-render
              "see #12, octo/cat#3, abc1234 and octo/cat@deadbeef1" "")))
    (should (equal (octocat-markdown-tests--prop out "#12" 'octocat-markdown-ref)
                   '(issue nil 12)))
    (should (equal (octocat-markdown-tests--prop out "octo/cat#3" 'octocat-markdown-ref)
                   '(issue "octo/cat" 3)))
    (should (equal (octocat-markdown-tests--prop out "abc1234" 'octocat-markdown-ref)
                   '(commit nil "abc1234")))
    (should (equal (octocat-markdown-tests--prop out "octo/cat@deadbeef1" 'octocat-markdown-ref)
                   '(commit "octo/cat" "deadbeef1"))))
  ;; Words and plain numbers made of hex digits are not hashes.
  (let ((out (octocat-markdown-render "defaced 1234567 123e4567-e89b" "")))
    (should-not (cl-some (lambda (i) (get-text-property i 'octocat-markdown-ref out))
                         (number-sequence 0 (1- (length out)))))))

(ert-deftest octocat-markdown-test-mention-links-to-profile ()
  "A mention links to the user's, or the team's, GitHub page."
  (let ((out (octocat-markdown-render "@bob and @org/team" "")))
    (should (equal (octocat-markdown-tests--prop out "@bob" 'octocat-markdown-url)
                   "https://github.com/bob"))
    (should (equal (octocat-markdown-tests--prop out "@org/team" 'octocat-markdown-url)
                   "https://github.com/orgs/org/teams/team"))))

(ert-deftest octocat-markdown-test-follow ()
  "RET on a link browses it and on a reference calls the reference function."
  (let ((out (octocat-markdown-render "[l](http://u) #7" "")) browsed opened)
    (should (eq (lookup-key (get-text-property 0 'keymap out) (kbd "RET"))
                #'octocat-markdown-follow))
    (cl-letf (((symbol-function 'browse-url) (lambda (u) (setq browsed u)))
              (octocat-markdown-ref-function (lambda (&rest args) (setq opened args))))
      (with-temp-buffer
        (insert out)
        (goto-char (point-min))
        (octocat-markdown-follow)
        (goto-char (1+ (string-match "#7" out)))
        (octocat-markdown-follow)
        (goto-char (point-max))
        (should-error (octocat-markdown-follow) :type 'user-error)))
    (should (equal browsed "http://u"))
    (should (equal opened '(issue nil 7)))))

(ert-deftest octocat-markdown-test-open-ref ()
  "A number is opened as a PR or an issue, as GitHub says; a hash as a commit."
  (let (opened (answer "true"))
    (cl-letf (((symbol-function 'octocat--run-gh)
               (lambda (_name _args parse callback) (funcall callback (funcall parse answer))))
              ((symbol-function 'octocat-pr-open)
               (lambda (&rest a) (push (cons 'pr a) opened)))
              ((symbol-function 'octocat-issue-open)
               (lambda (&rest a) (push (cons 'issue a) opened)))
              ((symbol-function 'octocat-commit-open)
               (lambda (&rest a) (push (cons 'commit a) opened))))
      (octocat--markdown-open-ref 'issue "o/r" 5)
      (setq answer "false\n")
      (octocat--markdown-open-ref 'issue "o/r" 6)
      (octocat--markdown-open-ref 'commit "o/r" "abc1234"))
    (should (equal (nreverse opened)
                   '((pr "o/r" 5) (issue "o/r" 6) (commit "o/r" "abc1234"))))))


;;; Blocks

(ert-deftest octocat-markdown-test-blocks ()
  "Headings, rules, fences, quotes and lists lose their markup."
  (should (equal (octocat-markdown-tests--md "# Title\n\n\n\ntext")
                 "Title\ntext\n"))
  ;; Blank rows next to standalone blocks are dropped; prose keeps one.
  (should (equal (octocat-markdown-tests--md "*a* **b**\n\n---\n\n```\nx\n```\n\none\n\ntwo")
                 (concat "a b\n" (make-string 40 ?─) "\n x \n\none\n\ntwo\n")))
  (should (equal (octocat-markdown-tests--md "```\ncore\nlonger\n```")
                 " core   \n longer \n"))
  (should (equal (octocat-markdown-tests--md "- a\n  - b\n- [x] c\n- [ ] d\n1. e")
                 "• a\n  ◦ b\n☑ c\n☐ d\n1. e\n"))
  (should (equal (octocat-markdown-tests--md "> [!NOTE]\n> hi") "│ Note\n│ hi\n"))
  (should (string-prefix-p "─" (octocat-markdown-tests--md "---"))))

(ert-deftest octocat-markdown-test-setext-headings ()
  "A line underlined by === or --- is a heading, not text and a rule."
  (let ((out (octocat-markdown-render "Big\n===\n\nSmall\n---\ntext" "")))
    (should (equal (substring-no-properties out) "Big\nSmall\ntext\n"))
    (should (eq (octocat-markdown-tests--prop out "Big" 'face) 'octocat-markdown-heading-1))
    (should (eq (octocat-markdown-tests--prop out "Small" 'face) 'octocat-markdown-heading-2)))
  ;; A rule after a blank row is still a rule.
  (should (equal (octocat-markdown-tests--md "text\n\n---")
                 (concat "text\n" (make-string 40 ?─) "\n"))))

(ert-deftest octocat-markdown-test-indented-code ()
  "Four spaces after a blank row make a code block; inside a paragraph they do not."
  (should (equal (octocat-markdown-tests--md "text\n\n    a\n\n      b\n\nafter")
                 "text\n\n a   \n     \n   b \n\nafter\n"))
  (should (equal (octocat-markdown-tests--md "text\n    still text") "text\nstill text\n")))

(ert-deftest octocat-markdown-test-code-highlighting ()
  "Fenced code is fontified by its language, and plain without one."
  (let ((out (octocat-markdown-render "```elisp\n(defun f ())\n```" "")))
    (should (memq 'font-lock-keyword-face
                  (ensure-list (octocat-markdown-tests--prop out "defun" 'face))))
    (should (memq 'octocat-markdown-code-block
                  (ensure-list (octocat-markdown-tests--prop out "defun" 'face)))))
  (let ((out (octocat-markdown-render "```nosuchlang\n(defun f ())\n```" "")))
    (should (eq (octocat-markdown-tests--prop out "defun" 'face)
                'octocat-markdown-code-block)))
  (let ((out (let ((octocat-markdown-highlight-code nil))
               (octocat-markdown-render "```elisp\n(defun f ())\n```" ""))))
    (should (eq (octocat-markdown-tests--prop out "defun" 'face)
                'octocat-markdown-code-block))))

(ert-deftest octocat-markdown-test-mermaid-is-labelled ()
  "A mermaid fence is shown as source, labelled as such."
  (should (equal (octocat-markdown-tests--md "```mermaid\nA-->B\n```")
                 "mermaid diagram (source)\n A-->B \n")))

(ert-deftest octocat-markdown-test-tight-lists-and-quotes ()
  "Blank rows around lists and inside list items and quotes are dropped."
  (should (equal (octocat-markdown-tests--md "text\n\n- a\n\n- b\n\nafter")
                 "text\n• a\n• b\nafter\n"))
  ;; A blank row inside an item survives only between paragraphs (and is
  ;; indented like the rest of the item).
  (should (equal (octocat-markdown-tests--md "- one\n\n  two\n\n  ---\n\n  three")
                 (concat "• one\n  \n  two\n  " (make-string 40 ?─) "\n  three\n")))
  (should (equal (octocat-markdown-tests--md "> \n> a\n>\n> # h\n>\n> b\n> ")
                 "│ a\n│ h\n│ b\n")))

(ert-deftest octocat-markdown-test-lazy-continuation ()
  "Unindented text after a list item line continues the item; blocks end it."
  (should (equal (octocat-markdown-tests--md "- a\nb\n- c\n# h")
                 "• a\n  b\n• c\nh\n"))
  ;; After a blank row it is a paragraph of its own.
  (should (equal (octocat-markdown-tests--md "- a\n\nb") "• a\nb\n")))

(ert-deftest octocat-markdown-test-table ()
  "Tables are drawn with aligned columns."
  (should (equal (octocat-markdown-tests--md "| a | b |\n|---|--:|\n| 1 | 22 |")
                 (concat "┌───┬────┐\n"
                         "│ a │  b │\n"
                         "├───┼────┤\n"
                         "│ 1 │ 22 │\n"
                         "└───┴────┘\n"))))

(ert-deftest octocat-markdown-test-table-escaped-pipe ()
  "An escaped pipe stays in its cell, in a code span too; a bare one splits."
  (should (equal (octocat-markdown-tests--md "| a |\n|---|\n| `x\\|y` |")
                 (concat "┌─────┐\n"
                         "│ a   │\n"
                         "├─────┤\n"
                         "│ x|y │\n"
                         "└─────┘\n"))))

(ert-deftest octocat-markdown-test-table-fits-width ()
  "A table wider than WIDTH wraps its cells; a short one is untouched."
  (let* ((md "| id | description |\n|--|--|\n| 1 | a rather long description of things |\n| 2 | short |")
         (out (octocat-markdown-tests--md md 24))
         (lines (split-string (string-trim-right out) "\n")))
    (dolist (l lines) (should (<= (string-width l) 24)))
    (should (string-match-p "rather" out))
    (should (string-match-p "things" out))
    ;; Wrapped rows are told apart by a rule between them.
    (should (= 2 (cl-count-if (lambda (l) (string-prefix-p "├" l)) (cdr (cdr lines)))))
    (should (equal (octocat-markdown-render md "" 200)
                   (octocat-markdown-render md "")))))

(ert-deftest octocat-markdown-test-wrap-prefix ()
  "List continuation lines hang under the item text."
  (let ((out (octocat-markdown-render "- item" "> ")))
    (should (equal (get-text-property 0 'wrap-prefix out) ">   "))))


;;; <details>

(defun octocat-markdown-tests--visible ()
  "Return the visible text of the current buffer, newlines shown as |.
Text replaced by a `display' string shows as that string."
  (let (out)
    (dotimes (i (- (point-max) (point-min)))
      (let ((pos (+ (point-min) i)))
        (unless (invisible-p pos)
          (let ((display (get-text-property pos 'display)))
            (push (if (stringp display) display (string (char-after pos))) out)))))
    (replace-regexp-in-string "\n" "|" (apply #'concat (nreverse out)))))

(ert-deftest octocat-markdown-test-details-starts-collapsed ()
  "The summary shows and the body is hidden until RET toggles it."
  (with-temp-buffer
    (insert (octocat-markdown-render
             "<details>\n<summary>Why <b>so</b></summary>\n\nfirst\n\nsecond\n</details>\nafter" ""))
    (setq buffer-invisibility-spec '((magit-section . t)))
    (octocat-markdown--ensure-invisibility)
    (should (equal (octocat-markdown-tests--visible) "▸ Why so|after|"))
    (goto-char (point-min))
    (octocat-markdown-follow)
    ;; The blank row between the paragraphs is a single space.
    (should (equal (octocat-markdown-tests--visible) "▾ Why so|first| |second|after|"))
    (goto-char (point-min))
    (octocat-markdown-follow)
    (should (equal (octocat-markdown-tests--visible) "▸ Why so|after|"))))

(ert-deftest octocat-markdown-test-details-open-and-nested ()
  "An `open' <details> starts expanded; a nested one shows as a title."
  (with-temp-buffer
    (insert (octocat-markdown-render
             "<details open><summary>A</summary>\nx\n<details><summary>B</summary>\ny\n</details>\n</details>"
             ""))
    (setq buffer-invisibility-spec '((magit-section . t)))
    (octocat-markdown--ensure-invisibility)
    (should (equal (octocat-markdown-tests--visible) "▾ A|x|B|y|"))
    (goto-char (point-min))
    (octocat-markdown-follow)
    (should (equal (octocat-markdown-tests--visible) "▸ A|"))))

(ert-deftest octocat-markdown-test-details-without-summary ()
  "A <details> without a summary is titled \"Details\"."
  (should (string-prefix-p "▸ Details\n"
                           (octocat-markdown-tests--md "<details>\nbody\n</details>"))))


;;; Font-lock in the edit buffer

(ert-deftest octocat-markdown-test-edit-mode-font-lock ()
  "The edit buffer highlights markdown source with the renderer's faces."
  (with-temp-buffer
    (insert "# Title\n\n**bold** `code` @bob #12\n\n```\n**not bold**\n```\n")
    (octocat-edit-mode)
    (font-lock-ensure)
    (cl-flet ((face-at (needle)
                (ensure-list (get-text-property
                              (+ (point-min) (string-match (regexp-quote needle) (buffer-string)))
                              'face))))
      (should (memq 'octocat-markdown-heading (face-at "Title")))
      (should (memq 'bold (face-at "bold**")))
      (should (memq 'octocat-markdown-code (face-at "code")))
      (should (memq 'octocat-markdown-mention (face-at "@bob")))
      (should (memq 'octocat-markdown-mention (face-at "#12")))
      (should (memq 'octocat-markdown-code-block (face-at "not bold")))
      (should-not (memq 'bold (face-at "not bold"))))))

(provide 'octocat-markdown-tests)
;;; octocat-markdown-tests.el ends here
