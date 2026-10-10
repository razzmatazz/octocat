;;; octocat-mermaid-tests.el --- ERT tests for the mermaid renderer  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for octocat-mermaid.el and its use by the markdown renderer.  Run via:
;;   eask test ert test/octocat-mermaid-tests.el

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'octocat-markdown)

(defun octocat-mermaid-tests--draw (source &optional width)
  "Return the diagram SOURCE drawn for WIDTH, as a string, or nil."
  (when-let* ((lines (octocat-mermaid-render (split-string source "\n") width)))
    (string-join lines "\n")))

(defun octocat-mermaid-tests--rows (&rest rows)
  "Join ROWS with newlines, to write a drawing out row by row."
  (string-join rows "\n"))

(defun octocat-mermaid-tests--width (drawing)
  "Return the width of the widest row of DRAWING."
  (apply #'max (mapcar #'string-width (split-string drawing "\n"))))


;;; Flowcharts

(ert-deftest octocat-mermaid-test-flow-top-down ()
  "A chart runs downwards by default, with an arrow into the target."
  (should (equal (octocat-mermaid-tests--draw "graph TD\nA[Start] --> B[End]")
                 (octocat-mermaid-tests--rows
                  "┌───────┐"
                  "│ Start │"
                  "└───┬───┘"
                  "    │"
                  "    │"
                  "    ▼"
                  " ┌─────┐"
                  " │ End │"
                  " └─────┘")))
  ;; BT runs the other way, so the arrow points up.
  (should (equal (octocat-mermaid-tests--draw "graph BT\nA --> B")
                 (octocat-mermaid-tests--rows
                  "┌───┐"
                  "│ B │"
                  "└───┘"
                  "  ▲"
                  "  │"
                  "  │"
                  "┌─┴─┐"
                  "│ A │"
                  "└───┘"))))

(ert-deftest octocat-mermaid-test-flow-left-right ()
  "A left-to-right chart lays nodes side by side, joined by arrows."
  (should (equal (octocat-mermaid-tests--draw "graph LR\nA[Start] --> B[End]")
                 (octocat-mermaid-tests--rows
                  "┌───────┐     ┌─────┐"
                  "│ Start ├────►│ End │"
                  "└───────┘     └─────┘"))))

(ert-deftest octocat-mermaid-test-flow-edge-labels ()
  "Edge labels sit beside a vertical edge and on a horizontal one."
  (should (equal (octocat-mermaid-tests--draw "graph TD\nA -->|yes| B")
                 (octocat-mermaid-tests--rows
                  "┌───┐"
                  "│ A │"
                  "└─┬─┘"
                  "  │"
                  "  │ yes"
                  "  ▼"
                  "┌───┐"
                  "│ B │"
                  "└───┘")))
  (should (equal (octocat-mermaid-tests--draw "graph LR\nA -- go --> B")
                 (octocat-mermaid-tests--rows
                  "┌───┐      ┌───┐"
                  "│ A ├─ go ►│ B │"
                  "└───┘      └───┘"))))

(ert-deftest octocat-mermaid-test-flow-shapes ()
  "Circles and rounded nodes have round corners; a decision has < and > sides."
  (should (equal (octocat-mermaid-tests--draw "graph TD\nA((c)) --> B{d}\nB --> C(r)")
                 (octocat-mermaid-tests--rows
                  "╭───╮"
                  "│ c │"
                  "╰─┬─╯"
                  "  │"
                  "  │"
                  "  ▼"
                  "┌───┐"
                  "< d >"
                  "└─┬─┘"
                  "  │"
                  "  │"
                  "  ▼"
                  "╭───╮"
                  "│ r │"
                  "╰───╯"))))

(ert-deftest octocat-mermaid-test-flow-edge-styles ()
  "Dotted and thick edges use their own characters; ends can be marked."
  (let ((out (octocat-mermaid-tests--draw "graph TD\nA -.-> B\nA ==> C\nA --x D\nA <--> E")))
    (should (string-match-p "┆" out))
    (should (string-match-p "┃" out))
    (should (string-match-p "✕" out))
    (should (string-match-p "▲" out))))

(ert-deftest octocat-mermaid-test-flow-cycle ()
  "An edge back to an earlier node is drawn pointing up beside the other."
  (let ((out (octocat-mermaid-tests--draw "graph TD\nA --> B\nB --> A")))
    (should (string-match-p "▼" out))
    (should (string-match-p "▲" out))
    (should (string-match-p "A" out))
    (should (string-match-p "B" out))))

(ert-deftest octocat-mermaid-test-flow-fan-out-and-long-edge ()
  "Every node is drawn, with an arrow into each, and a skipping edge is routed."
  (let ((out (octocat-mermaid-tests--draw
              (string-join '("graph TB"
                             "A[Commit] --> B[Build] & C[Lint] & D[Test]"
                             "B --> E[Package]" "C --> E" "D --> E"
                             "A -- skips --> E"
                             "E == deploy ==> F[Production]")
                           "\n"))))
    (dolist (name '("Commit" "Build" "Lint" "Test" "Package" "Production" "skips" "deploy"))
      (should (string-match-p name out)))
    ;; A->B, A->C, A->D, B->E, C->E, D->E, A->E and E->F.
    (should (= 8 (cl-count ?▼ out)))))

(ert-deftest octocat-mermaid-test-flow-multiline-labels ()
  "<br> breaks a label into lines, which are centred."
  (should (equal (octocat-mermaid-tests--draw "graph TD\nA[one<br/>three]")
                 (octocat-mermaid-tests--rows
                  "┌───────┐"
                  "│  one  │"
                  "│ three │"
                  "└───────┘"))))

(ert-deftest octocat-mermaid-test-flow-ignores-styling ()
  "Styling lines, comments and front matter do not matter."
  (should (equal (octocat-mermaid-tests--draw
                  "---\ntitle: x\n---\n%% note\ngraph TD\nA --> B\nstyle A fill:#f9f\nclassDef c fill:#fff")
                 (octocat-mermaid-tests--draw "graph TD\nA --> B"))))

(ert-deftest octocat-mermaid-test-flow-unsupported ()
  "What cannot be drawn faithfully gives nil, so the source is shown."
  (should-not (octocat-mermaid-tests--draw "graph TD\nsubgraph a\nsubgraph b\nX\nend\nend"))
  (should-not (octocat-mermaid-tests--draw "graph TD\nA --> A"))
  (should-not (octocat-mermaid-tests--draw "graph TD\nA ?? B"))
  (should-not (octocat-mermaid-tests--draw "gantt\ntitle x"))
  (should-not (octocat-mermaid-tests--draw "")))


;;; Subgraphs

(ert-deftest octocat-mermaid-test-subgraph-frame ()
  "A subgraph is a dashed frame, with its title, around its nodes."
  (should (equal (octocat-mermaid-tests--draw "graph TD\nsubgraph one\nA --> B\nend")
                 (octocat-mermaid-tests--rows
                  "┌╌ one ╌┐"
                  "╎       ╎"
                  "╎ ┌───┐ ╎"
                  "╎ │ A │ ╎"
                  "╎ └─┬─┘ ╎"
                  "╎   │   ╎"
                  "╎   │   ╎"
                  "╎   ▼   ╎"
                  "╎ ┌───┐ ╎"
                  "╎ │ B │ ╎"
                  "╎ └───┘ ╎"
                  "╎       ╎"
                  "└╌╌╌╌╌╌╌┘"))))

(ert-deftest octocat-mermaid-test-subgraph-title-and-crossing-edges ()
  "`id [Title]' sets the title, and edges cross the frame to reach outside."
  (let ((out (octocat-mermaid-tests--draw
              (string-join '("graph TD" "Dev --> PR"
                             "subgraph ci [Continuous integration]" "Build --> Test" "end"
                             "PR --> Build" "Test --> Deploy")
                           "\n"))))
    (should (string-match-p "┌╌+│? Continuous integration ╌+┐" out))
    (should-not (string-match-p "\\bci\\b" out))
    ;; Dev, PR and Deploy stay outside the frame.
    (let ((rows (split-string out "\n")))
      (dolist (name '("Dev" "PR" "Deploy"))
        (should (cl-find-if (lambda (r) (and (string-match-p name r)
                                             (not (string-match-p "╎" r))))
                            rows)))
      (dolist (name '("Build" "Test"))
        (should (cl-find-if (lambda (r) (and (string-match-p name r) (string-match-p "╎" r)))
                            rows))))
    ;; The edges are not cut by the frame.
    (should (= 4 (cl-count ?▼ out)))))

(ert-deftest octocat-mermaid-test-subgraph-two-side-by-side ()
  "Several subgraphs are framed separately."
  (let ((out (octocat-mermaid-tests--draw
              (string-join '("graph LR"
                             "subgraph front [Frontend]" "UI --> Store" "end"
                             "subgraph back [Backend]" "API --> DB" "end"
                             "Store --> API")
                           "\n"))))
    (should (string-match-p "┌╌ Frontend ╌+┐ ┌╌ Backend ╌+┐" out))
    (should (string-match-p "UI.*Store.*API.*DB" out))))

(ert-deftest octocat-mermaid-test-subgraph-width ()
  "Frames are cut short with their titles when the width is tight."
  (let ((out (octocat-mermaid-tests--draw
              (string-join '("graph TD" "Dev --> PR"
                             "subgraph ci [Continuous integration]" "Build --> Test" "end"
                             "PR --> Build" "Test --> Deploy")
                           "\n")
              20)))
    (should out)
    (should (<= (octocat-mermaid-tests--width out) 20))
    (should (string-match-p "┌╌ Co…" out))))

(ert-deftest octocat-mermaid-test-subgraph-unsupported ()
  "Nested subgraphs, edges to a subgraph and a subgraph with a foreign node
in its way are not drawn."
  (should-not (octocat-mermaid-tests--draw "graph TD\nsubgraph a\nsubgraph b\nX\nend\nend"))
  (should-not (octocat-mermaid-tests--draw "graph TD\nsubgraph one\nA\nend\nX --> one"))
  (should-not (octocat-mermaid-tests--draw "graph TD\nsubgraph s\nA\nB\nend\nA --> C --> B"))
  (should-not (octocat-mermaid-tests--draw "graph TD\nsubgraph s\nA\n")))


;;; Width

(ert-deftest octocat-mermaid-test-flow-width-keeps-left-right-when-it-fits ()
  "A left-to-right chart that fits the width stays on one row."
  (let ((out (octocat-mermaid-tests--draw "flowchart LR\nA[One] --> B[Two] --> C[Three]" 100)))
    (should (equal out (octocat-mermaid-tests--draw "flowchart LR\nA[One] --> B[Two] --> C[Three]")))
    (should (= 3 (length (split-string out "\n"))))))

(ert-deftest octocat-mermaid-test-flow-width-turns-left-right-top-down ()
  "A left-to-right chart too wide for the width is drawn top-down instead."
  (let ((out (octocat-mermaid-tests--draw "flowchart LR\nA[One] --> B[Two] --> C[Three]" 20)))
    (should (equal out (octocat-mermaid-tests--rows
                        " ┌─────┐"
                        " │ One │"
                        " └──┬──┘"
                        "    │"
                        "    │"
                        "    ▼"
                        " ┌─────┐"
                        " │ Two │"
                        " └──┬──┘"
                        "    │"
                        "    │"
                        "    ▼"
                        "┌───────┐"
                        "│ Three │"
                        "└───────┘")))
    (should (<= (octocat-mermaid-tests--width out) 20))))

(ert-deftest octocat-mermaid-test-flow-width-wraps-labels ()
  "Long labels are wrapped until the chart fits."
  (let* ((src "graph TD\nA[a rather long description of the first step] --> B[short]")
         (wide (octocat-mermaid-tests--draw src))
         (narrow (octocat-mermaid-tests--draw src 24)))
    (should (> (octocat-mermaid-tests--width wide) 24))
    (should (<= (octocat-mermaid-tests--width narrow) 24))
    (dolist (word '("rather" "description" "first" "step"))
      (should (string-match-p word narrow)))))

(ert-deftest octocat-mermaid-test-width-too-small ()
  "A diagram that cannot be made to fit gives nil."
  (should-not (octocat-mermaid-tests--draw "graph TD\nA[Start] --> B[End]" 5))
  (should-not (octocat-mermaid-tests--draw "sequenceDiagram\nAlice->>Bob: hello there" 10))
  (should-not (octocat-mermaid-tests--draw "pie\n\"a\" : 1" 6)))


;;; Sequence diagrams

(ert-deftest octocat-mermaid-test-sequence-messages ()
  "Participants are columns; solid and dashed arrows run between them."
  (should (equal (octocat-mermaid-tests--draw "sequenceDiagram\nA->>B: hi\nB-->>A: yo")
                 (octocat-mermaid-tests--rows
                  " ┌───┐  ┌───┐"
                  " │ A │  │ B │"
                  " └─┬─┘  └─┬─┘"
                  "   │  hi  │"
                  "   ├─────►┤"
                  "   │  yo  │"
                  "   ├◄┄┄┄┄┄┤"))))

(ert-deftest octocat-mermaid-test-sequence-autonumber-and-notes ()
  "Autonumber prefixes messages, `participant X as Y' renames, notes are boxes."
  (should (equal (octocat-mermaid-tests--draw
                  "sequenceDiagram\nautonumber\nparticipant A as Alice\nA->>B: hi\nNote over A,B: ok")
                 (octocat-mermaid-tests--rows
                  " ┌───────┐  ┌───┐"
                  " │ Alice │  │ B │"
                  " └───┬───┘  └─┬─┘"
                  "     │ 1. hi  │"
                  "     ├───────►┤"
                  "   ┌────────────┐"
                  "   │     ok     │"
                  "   └────────────┘"))))

(ert-deftest octocat-mermaid-test-sequence-blocks ()
  "loop/alt blocks are framed, with a dashed rule for else."
  (let ((out (octocat-mermaid-tests--draw
              (string-join '("sequenceDiagram" "A->>B: x"
                             "alt ok" "B->>A: y" "else bad" "B-xA: z" "end")
                           "\n"))))
    (should (string-match-p "┌─ alt ok ─[─┼]*┐" out))
    (should (string-match-p "┄ bad ┄" out))
    (should (string-match-p "└─+┼─+┼─+┘" out))
    (should (string-match-p "✕" out))))

(ert-deftest octocat-mermaid-test-sequence-self-message ()
  "A message to oneself loops back to the same lifeline."
  (let ((out (octocat-mermaid-tests--draw "sequenceDiagram\nA->>A: think")))
    (should (string-match-p "├───┐ think" out))
    (should (string-match-p "┤◄──┘" out))))

(ert-deftest octocat-mermaid-test-sequence-width ()
  "Labels are wrapped and the diagram squeezed to fit the width."
  (let* ((src "sequenceDiagram\nAlice->>Bob: a fairly long message to send over\nBob-->>Alice: ok")
         (wide (octocat-mermaid-tests--draw src))
         (narrow (octocat-mermaid-tests--draw src 30)))
    (should (> (octocat-mermaid-tests--width wide) 30))
    (should (<= (octocat-mermaid-tests--width narrow) 30))
    (dolist (word '("fairly" "message" "send" "over"))
      (should (string-match-p word narrow)))))

(ert-deftest octocat-mermaid-test-sequence-unsupported ()
  "A line it does not understand makes the whole diagram unsupported."
  (should-not (octocat-mermaid-tests--draw "sequenceDiagram\nA->>B: hi\nbox Blue\nend"))
  (should-not (octocat-mermaid-tests--draw "sequenceDiagram\nA->>B: hi\nend")))


;;; Pie charts and state diagrams

(ert-deftest octocat-mermaid-test-pie ()
  "Bars are scaled to the biggest slice and labelled with their share."
  (should (equal (octocat-mermaid-tests--draw "pie title T\n\"a\" : 3\n\"b\" : 1")
                 (octocat-mermaid-tests--rows
                  "T"
                  "a  ██████████████████████████████ 75.0%"
                  "b  ██████████                     25.0%")))
  (should (string-match-p "(386)" (octocat-mermaid-tests--draw "pie showData\n\"Dogs\" : 386"))))

(ert-deftest octocat-mermaid-test-pie-width ()
  "The bars shrink to the width."
  (should (equal (octocat-mermaid-tests--draw "pie\n\"alpha\" : 3\n\"beta\" : 1" 24)
                 (octocat-mermaid-tests--rows
                  "alpha  ███████████ 75.0%"
                  "beta   ███▋        25.0%"))))

(ert-deftest octocat-mermaid-test-state ()
  "A state diagram is drawn as rounded states joined by transitions."
  (should (equal (octocat-mermaid-tests--draw "stateDiagram-v2\n[*] --> A\nA --> [*]: done")
                 (octocat-mermaid-tests--rows
                  "╭───╮"
                  "│ ● │"
                  "╰─┬─╯"
                  "  │"
                  "  │"
                  "  ▼"
                  "╭───╮"
                  "│ A │"
                  "╰─┬─╯"
                  "  │"
                  "  │ done"
                  "  ▼"
                  "╭───╮"
                  "│ ◉ │"
                  "╰───╯")))
  (should-not (octocat-mermaid-tests--draw "stateDiagram-v2\nstate X {\nA --> B\n}")))


;;; In the markdown renderer

(ert-deftest octocat-mermaid-test-markdown-draws-the-fence ()
  "A mermaid fence is drawn inside the code block, to the width given."
  (let* ((md "```mermaid\nflowchart LR\nA[One] --> B[Two] --> C[Three]\n```")
         (wide (substring-no-properties (octocat-markdown-render md "" 100)))
         (narrow (substring-no-properties (octocat-markdown-render md "" 20))))
    (should (string-match-p "One ├────►│ Two" wide))
    (should-not (string-match-p "source" wide))
    (should-not (string-match-p "├────►" narrow))
    (dolist (line (split-string narrow "\n" t))
      (should (<= (string-width line) 20)))
    ;; The block is drawn on the code background.
    (should (eq (get-text-property (string-match "One" (octocat-markdown-render md "" 100))
                                   'face (octocat-markdown-render md "" 100))
                'octocat-markdown-code-block))))

(ert-deftest octocat-mermaid-test-markdown-falls-back-to-source ()
  "What cannot be drawn is shown as labelled source."
  (let ((out (substring-no-properties
              (octocat-markdown-render
               "```mermaid\ngraph TD\nsubgraph a\nsubgraph b\nX\nend\nend\n```" ""))))
    (should (string-prefix-p "mermaid diagram (source)\n" out))
    (should (string-match-p "subgraph b" out)))
  ;; Too narrow for the diagram.
  (should (string-match-p "mermaid diagram (source)"
                          (octocat-markdown-render "```mermaid\ngraph TD\nA[Start] --> B\n```" "" 5))))

(provide 'octocat-mermaid-tests)
;;; octocat-mermaid-tests.el ends here
