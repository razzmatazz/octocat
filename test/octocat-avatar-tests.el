;;; octocat-avatar-tests.el --- ERT tests for octocat-avatar.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via:
;;   eask test ert test/octocat-avatar-tests.el
;;
;; The fixtures are 16x16 images of four flat quadrants: red (top left),
;; green #20c040 (top right), blue #3050f0 (bottom left) and white
;; (bottom right).  The PNG is a 2-bit palette image, which exercises the
;; sub-byte sample unpacking; the JPEG is baseline with 4:2:0 chroma.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'octocat-avatar)
(require 'octocat-user)
(require 'seq)

(defconst octocat-avatar-tests--png
  "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQAgMAAABinRfyAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAMUExURf8AACDAQDBQ8P///wUdDs0AAAABYktHRAMRDEzyAAAAB3RJTUUH6goKESINmuGZWwAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0xMC0xMFQxNzozNDoxMyswMDowMBGb9yEAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMTAtMTBUMTc6MzQ6MTMrMDA6MDBgxk+dAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTEwLTEwVDE3OjM0OjEzKzAwOjAwN9NuQgAAABZJREFUCNdjYGAIDWUggli16v9/IggAR90f4d0m7YAAAAAASUVORK5CYII="
  "Base64 of the PNG fixture.")

(defconst octocat-avatar-tests--jpeg
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYHCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgr/wAARCAAQABADASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAACAr/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAwX/xAAnEQABAgMFCQAAAAAAAAAAAAASERMHFBUCCCFDYgMXGCQlQUJhY//aAAwDAQACEQMRAD8AF5sC2qYLEi7Tu0leqzEweQ2LYfa2qn6RO64XLzETuLqlcpTKY/mTLsyzo2AAxrI/Ecf/2Q=="
  "Base64 of the JPEG fixture.")

(defun octocat-avatar-tests--pixel (image x y)
  "Return the (R G B A) of pixel (X, Y) of IMAGE."
  (let ((o (* 4 (+ (* y (car image)) x))))
    (cl-loop for k below 4 collect (aref (nth 2 image) (+ o k)))))

(defun octocat-avatar-tests--close-p (actual expected tolerance)
  "Non-nil when the RGB of ACTUAL is within TOLERANCE of EXPECTED."
  (cl-every (lambda (a e) (<= (abs (- a e)) tolerance)) actual expected))

(ert-deftest octocat-avatar-test-png ()
  "A palette PNG decodes to exactly its pixels."
  (let ((image (octocat-avatar-decode
                (base64-decode-string octocat-avatar-tests--png))))
    (should (equal (list (car image) (cadr image)) '(16 16)))
    (should (equal (octocat-avatar-tests--pixel image 2 2)  '(255 0 0 255)))
    (should (equal (octocat-avatar-tests--pixel image 10 2) '(32 192 64 255)))
    (should (equal (octocat-avatar-tests--pixel image 2 10) '(48 80 240 255)))
    (should (equal (octocat-avatar-tests--pixel image 12 12) '(255 255 255 255)))))

(ert-deftest octocat-avatar-test-jpeg ()
  "A subsampled baseline JPEG decodes to its colours, within rounding."
  (let ((image (octocat-avatar-decode
                (base64-decode-string octocat-avatar-tests--jpeg))))
    (should (equal (list (car image) (cadr image)) '(16 16)))
    (should (octocat-avatar-tests--close-p
             (octocat-avatar-tests--pixel image 2 2)  '(251 1 3 255) 8))
    (should (octocat-avatar-tests--close-p
             (octocat-avatar-tests--pixel image 10 2) '(29 194 66 255) 8))
    (should (octocat-avatar-tests--close-p
             (octocat-avatar-tests--pixel image 2 10) '(46 81 243 255) 8))
    (should (octocat-avatar-tests--close-p
             (octocat-avatar-tests--pixel image 12 12) '(255 255 255 255) 8))))

(ert-deftest octocat-avatar-test-decode-rejects-garbage ()
  "Unknown, empty and truncated input decodes to nil rather than erroring."
  (should-not (octocat-avatar-decode ""))
  (should-not (octocat-avatar-decode "GIF89a not an image"))
  (let ((png  (base64-decode-string octocat-avatar-tests--png))
        (jpeg (base64-decode-string octocat-avatar-tests--jpeg)))
    (should-not (octocat-avatar-decode (substring png 0 40)))
    (should-not (octocat-avatar-decode (substring jpeg 0 100)))))

(ert-deftest octocat-avatar-test-render-shape ()
  "The art is COLS wide and half as many rows tall for a square image."
  (let* ((image (octocat-avatar-decode
                 (base64-decode-string octocat-avatar-tests--png)))
         (rows  (octocat-avatar-render image 8 'dark)))
    (should (= (length rows) 4))
    (dolist (row rows)
      (should (= (string-width row) 8)))))

(ert-deftest octocat-avatar-test-render-colour-and-density ()
  "Cells carry their average colour; bright is dense only on dark."
  (let* ((image (octocat-avatar-decode
                 (base64-decode-string octocat-avatar-tests--png)))
         (dark  (car (octocat-avatar-render image 4 'dark 'ramp)))
         (light (car (octocat-avatar-render image 4 'light 'ramp)))
         (ramp  octocat-avatar--ramp))
    ;; Four columns, two rows: the top row is red, red, green, green.
    (should (equal (get-text-property 0 'face dark) '(:foreground "#ff0000")))
    (should (equal (get-text-property 3 'face dark) '(:foreground "#20c040")))
    ;; Green is brighter than red: denser on a dark background, sparser
    ;; on a light one.
    (should (> (seq-position ramp (aref dark 3))
               (seq-position ramp (aref dark 0))))
    (should (< (seq-position ramp (aref light 3))
               (seq-position ramp (aref light 0))))))

(ert-deftest octocat-avatar-test-render-transparent-pixels ()
  "Fully transparent pixels take the background's colour."
  (let* ((px (vector 255 0 0 0  255 0 0 0
                     255 0 0 0  255 0 0 0))
         (rows (octocat-avatar-render (list 2 2 px) 2 'dark 'ramp)))
    (should (equal (get-text-property 0 'face (car rows))
                   '(:foreground "#000000")))))

(ert-deftest octocat-avatar-test-blocks-is-the-default ()
  "With Unicode available the default style is quadrant blocks."
  (let ((px (vector 255 0 0 255  0 0 255 255  0 0 255 255  255 0 0 255)))
    (cl-letf (((symbol-function 'octocat-avatar-unicode-p) (lambda () t)))
      ;; Red on the main diagonal, blue on the other: drawn as the
      ;; anti-diagonal block in blue over red.
      (let ((cell (car (octocat-avatar-render (list 2 2 px) 1 'dark))))
        (should (equal (substring-no-properties cell) "▞"))
        (should (equal (get-text-property 0 'face cell)
                       '(:foreground "#0000ff" :background "#ff0000")))))))

(ert-deftest octocat-avatar-test-blocks ()
  "Each cell is split along its best quadrant partition, in two colours."
  (let* ((px (vector 255 0 0 255  255 0 0 255  0 0 255 255  0 0 255 255))
         (cell (car (octocat-avatar-render (list 2 2 px) 1 'dark 'blocks))))
    (should (equal (substring-no-properties cell) "▀"))
    (should (equal (get-text-property 0 'face cell)
                   '(:foreground "#ff0000" :background "#0000ff")))))

(ert-deftest octocat-avatar-test-ascii-is-seven-bit ()
  "The `ascii' style uses nothing outside 7-bit ASCII."
  (let* ((image (octocat-avatar-decode
                 (base64-decode-string octocat-avatar-tests--png))))
    (dolist (row (octocat-avatar-render image 16 'dark 'ascii))
      (should (string-match-p "\\`[ -~]*\\'" (substring-no-properties row))))))

(ert-deftest octocat-avatar-test-falls-back-to-ascii-without-unicode ()
  "With no Unicode support the default style is 7-bit ASCII."
  (let ((image (octocat-avatar-decode
                (base64-decode-string octocat-avatar-tests--png))))
    (cl-letf (((symbol-function 'octocat-avatar-unicode-p) (lambda () nil)))
      (dolist (row (octocat-avatar-render image 16 'dark))
        (should (string-match-p "\\`[ -~]*\\'" (substring-no-properties row)))))))

;;; User page layout

(ert-deftest octocat-avatar-test-columns-follow-window-width ()
  "The avatar takes a quarter of the window, within its limits."
  (let ((octocat-user-avatar-max-columns 40))
    (should (= (octocat-user--avatar-columns 80) 20))
    (should (= (octocat-user--avatar-columns 120) 30))
    (should (= (octocat-user--avatar-columns 400) 40))
    (should (= (octocat-user--avatar-columns 40) 0))))

(ert-deftest octocat-avatar-test-beside-pads-the-shorter-side ()
  "Lines sit to the right of the art; the shorter list is padded."
  (should (equal (octocat-user--beside '("ab" "cd") '("one"))
                 '("ab  one" "cd  ")))
  (should (equal (octocat-user--beside '("ab") '("one" "two"))
                 '("ab  one" "    two"))))

(provide 'octocat-avatar-tests)
;;; octocat-avatar-tests.el ends here
