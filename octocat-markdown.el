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
;; markdown package), so `octocat-core' can require it.  For now the
;; renderer is a plain dump: the markdown source is shown verbatim,
;; indented and line-prefixed.  GitHub-specific rendering (headings,
;; code fences, task lists, mentions, ...) is to be built up here.
;;
;; Entry point: `octocat-markdown-render'.

;;; Code:

(defun octocat-markdown-render-verbatim (text &optional indent)
  "Return markdown TEXT unrendered, one line per row.
Each line is prefixed with INDENT (a string, default \"  \") and ends in
a newline; INDENT is also repeated on the wrapped continuation lines of
long lines.  Windows-style CR characters are stripped first."
  (let ((indent (or indent "  "))
        (text (replace-regexp-in-string "\r" "" text)))
    (mapconcat (lambda (line)
                 ;; `wrap-prefix' repeats INDENT (a quote bar, say) on the
                 ;; continuation lines of a long, wrapped line.
                 (let ((full (concat indent line "\n")))
                   (put-text-property 0 (length full) 'wrap-prefix indent full)
                   full))
               (split-string text "\n")
               "")))

(defun octocat-markdown-render (text &optional indent)
  "Return markdown TEXT rendered for display, one line per row.
INDENT is as for `octocat-markdown-render-verbatim'.

Currently this is a plain dump of the source text."
  (octocat-markdown-render-verbatim text indent))

(provide 'octocat-markdown)
;;; octocat-markdown.el ends here
