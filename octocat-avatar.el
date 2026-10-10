;;; octocat-avatar.el --- Draw an avatar image as coloured ASCII art  -*- lexical-binding: t; package-lint-main-file: "octocat.el"; -*-

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

;; Turns a PNG or JPEG into a list of propertized strings, one character
;; per cell: the character's density follows the cell's brightness and its
;; foreground is the cell's average colour.
;;
;; Emacs can display an image but gives Lisp no access to its pixels, so
;; this file decodes the formats GitHub serves avatars in itself, in plain
;; Elisp and with no external tools:
;;
;;   - PNG: all colour types and bit depths, non-interlaced
;;     (inflating goes through the built-in `zlib-decompress-region').
;;   - JPEG: baseline / extended sequential Huffman, greyscale or YCbCr,
;;     any chroma subsampling, restart intervals.  Progressive JPEGs are
;;     not supported.
;;
;; A decoded image is a list (WIDTH HEIGHT PIXELS) where PIXELS is a flat
;; vector of R G B A integers (0..255), four per pixel, row by row.
;; Decoding is the slow step; `octocat-avatar-render' only box-averages
;; the pixels, so it is cheap to call again when the available size
;; changes.
;;
;; This file knows nothing about GitHub.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)

(defconst octocat-avatar--max-pixels (* 640 640)
  "Images with more pixels than this are not decoded.")

(defconst octocat-avatar--ramp " .·:;-~=+*ox#%&@█"
  "Unicode characters from least to most \"ink\".")

(defconst octocat-avatar--ascii-ramp " .:-=+*#%@"
  "7-bit characters from least to most \"ink\".")


;;;; Byte helpers

(defsubst octocat-avatar--u16 (s i)
  "Return the big-endian 16-bit integer at index I of unibyte string S."
  (logior (ash (aref s i) 8) (aref s (1+ i))))

(defsubst octocat-avatar--u32 (s i)
  "Return the big-endian 32-bit integer at index I of unibyte string S."
  (logior (ash (aref s i) 24) (ash (aref s (+ i 1)) 16)
          (ash (aref s (+ i 2)) 8) (aref s (+ i 3))))


;;;; PNG

(defsubst octocat-avatar--paeth (a b c)
  "Return the PNG Paeth predictor of the bytes A, B and C."
  (let* ((p  (- (+ a b) c))
         (pa (abs (- p a)))
         (pb (abs (- p b)))
         (pc (abs (- p c))))
    (cond ((and (<= pa pb) (<= pa pc)) a)
          ((<= pb pc) b)
          (t c))))

(defun octocat-avatar--png-sample (row index depth)
  "Return sample INDEX of the unfiltered scanline ROW at bit DEPTH.
Samples deeper than eight bits are reduced to their high byte."
  (cond ((= depth 8) (aref row index))
        ((= depth 16) (aref row (* 2 index)))
        (t (let* ((bit   (* index depth))
                  (shift (- 8 depth (mod bit 8))))
             (logand (ash (aref row (/ bit 8)) (- shift))
                     (1- (ash 1 depth)))))))

(defun octocat-avatar--png-inflate (chunks)
  "Return the inflated concatenation of the zlib stream in CHUNKS, or nil."
  (when (zlib-available-p)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (apply #'concat chunks))
      (and (zlib-decompress-region (point-min) (point-max))
           (buffer-string)))))

(defun octocat-avatar--decode-png (bytes)
  "Decode the PNG in unibyte string BYTES, or return nil if unsupported."
  (let ((pos 8) (len (length bytes))
        width height depth ctype interlace palette idat)
    (while (< (+ pos 12) (1+ len))
      (let* ((clen  (octocat-avatar--u32 bytes pos))
             (type  (substring bytes (+ pos 4) (+ pos 8)))
             (start (+ pos 8))
             (end   (+ start clen)))
        (if (> end len)
            (setq pos len)
          (cond ((equal type "IHDR")
                 (setq width     (octocat-avatar--u32 bytes start)
                       height    (octocat-avatar--u32 bytes (+ start 4))
                       depth     (aref bytes (+ start 8))
                       ctype     (aref bytes (+ start 9))
                       interlace (aref bytes (+ start 12))))
                ((equal type "PLTE") (setq palette (substring bytes start end)))
                ((equal type "IDAT") (push (substring bytes start end) idat))
                ((equal type "IEND") (setq end len)))
          (setq pos (+ end 4)))))
    (when (and width height idat (eql interlace 0)
               (> width 0) (> height 0)
               (<= (* width height) octocat-avatar--max-pixels)
               (memq depth '(1 2 4 8 16))
               (memq ctype '(0 2 3 4 6))
               (or (/= ctype 3) palette))
      (octocat-avatar--png-pixels
       (octocat-avatar--png-inflate (nreverse idat))
       width height depth ctype palette))))

(defun octocat-avatar--png-pixels (raw width height depth ctype palette)
  "Unfilter RAW scanlines and return the image list, or nil if RAW is short.
WIDTH, HEIGHT, DEPTH, CTYPE and PALETTE come from the PNG header."
  (let* ((channels (pcase ctype (0 1) (2 3) (3 1) (4 2) (6 4)))
         (bits     (* channels depth))
         (bpp      (max 1 (/ bits 8)))
         (stride   (/ (+ (* width bits) 7) 8))
         (px       (make-vector (* width height 4) 255))
         (maxv     (1- (ash 1 depth)))
         prev)
    (when (and raw (>= (length raw) (* height (1+ stride))))
      (dotimes (y height)
        (let* ((off (* y (1+ stride)))
               (ft  (aref raw off))
               (cur (make-vector stride 0)))
          (dotimes (i stride)
            (let* ((x (aref raw (+ off 1 i)))
                   (a (if (>= i bpp) (aref cur (- i bpp)) 0))
                   (b (if prev (aref prev i) 0))
                   (c (if (and prev (>= i bpp)) (aref prev (- i bpp)) 0)))
              (aset cur i
                    (logand 255
                            (pcase ft
                              (0 x)
                              (1 (+ x a))
                              (2 (+ x b))
                              (3 (+ x (/ (+ a b) 2)))
                              (4 (+ x (octocat-avatar--paeth a b c)))
                              (_ (error "Bad PNG filter")))))))
          (setq prev cur)
          (dotimes (x width)
            (let ((o (* 4 (+ (* y width) x))))
              (pcase ctype
                (0 (let ((g (/ (* 255 (octocat-avatar--png-sample cur x depth))
                               (if (= depth 16) 255 maxv))))
                     (aset px o g) (aset px (+ o 1) g) (aset px (+ o 2) g)))
                (2 (dotimes (k 3)
                     (aset px (+ o k)
                           (octocat-avatar--png-sample cur (+ (* 3 x) k) depth))))
                (3 (let ((i (* 3 (octocat-avatar--png-sample cur x depth))))
                     (dotimes (k 3)
                       (aset px (+ o k) (if (< (+ i k) (length palette))
                                            (aref palette (+ i k))
                                          0)))))
                (4 (let ((g (octocat-avatar--png-sample cur (* 2 x) depth)))
                     (aset px o g) (aset px (+ o 1) g) (aset px (+ o 2) g)
                     (aset px (+ o 3)
                           (octocat-avatar--png-sample cur (1+ (* 2 x)) depth))))
                (6 (dotimes (k 4)
                     (aset px (+ o k)
                           (octocat-avatar--png-sample cur (+ (* 4 x) k) depth))))))))))
    (and prev (list width height px))))


;;;; JPEG

(defconst octocat-avatar--zigzag
  [0  1  8 16  9  2  3 10 17 24 32 25 18 11  4  5
   12 19 26 33 40 48 41 34 27 20 13  6  7 14 21 28
   35 42 49 56 57 50 43 36 29 22 15 23 30 37 44 51
   58 59 52 45 38 31 39 46 53 60 61 54 47 55 62 63]
  "Natural (row-major) index of the Nth coefficient in zigzag order.")

(defconst octocat-avatar--idct-table
  (let ((tbl (make-vector 64 0.0)))
    (dotimes (x 8)
      (dotimes (u 8)
        (aset tbl (+ (* x 8) u)
              (* (if (= u 0) (/ 1.0 (sqrt 2.0)) 1.0)
                 0.5
                 (cos (/ (* (+ (* 2 x) 1) u float-pi) 16.0))))))
    tbl)
  "One-dimensional 8-point inverse DCT basis, indexed by X * 8 + U.")

(cl-defstruct (octocat-avatar--bits (:constructor octocat-avatar--bits-make (data pos))
                                    (:copier nil))
  "Bit reader over the entropy-coded segment of a JPEG."
  data pos (buf 0) (cnt 0))

(cl-defstruct (octocat-avatar--comp (:constructor octocat-avatar--comp-make
                                                  (id h v tq))
                                    (:copier nil))
  "One colour component of a JPEG frame."
  id h v tq plane pw (pred 0) dct act)

(defun octocat-avatar--bits-bit (st)
  "Return the next bit of the entropy-coded data read by ST.
A marker, or the end of the data, reads as zeros."
  (when (= (octocat-avatar--bits-cnt st) 0)
    (let* ((data (octocat-avatar--bits-data st))
           (pos  (octocat-avatar--bits-pos st))
           (len  (length data))
           (b    (if (< pos len) (aref data pos) 0)))
      (cond ((>= pos len)
             (setf (octocat-avatar--bits-buf st) 0))
            ((= b #xFF)
             (if (and (< (1+ pos) len) (= (aref data (1+ pos)) 0))
                 (setf (octocat-avatar--bits-pos st) (+ pos 2)
                       (octocat-avatar--bits-buf st) #xFF)
               (setf (octocat-avatar--bits-buf st) 0)))
            (t (setf (octocat-avatar--bits-pos st) (1+ pos)
                     (octocat-avatar--bits-buf st) b)))
      (setf (octocat-avatar--bits-cnt st) 8)))
  (let ((cnt (1- (octocat-avatar--bits-cnt st))))
    (setf (octocat-avatar--bits-cnt st) cnt)
    (logand 1 (ash (octocat-avatar--bits-buf st) (- cnt)))))

(defun octocat-avatar--bits-receive (st n)
  "Read N bits from ST as an unsigned integer."
  (let ((v 0))
    (dotimes (_ n)
      (setq v (logior (ash v 1) (octocat-avatar--bits-bit st))))
    v))

(defsubst octocat-avatar--extend (v n)
  "Sign-extend V, a value N bits wide, as JPEG does."
  (if (< v (ash 1 (1- n))) (+ v 1 (- (ash 1 n))) v))

(defun octocat-avatar--huff-build (counts symbols)
  "Build a decoding table from COUNTS (codes per length) and SYMBOLS."
  (let ((mincode (make-vector 17 0))
        (maxcode (make-vector 17 -1))
        (valptr  (make-vector 17 0))
        (code 0) (k 0))
    (cl-loop for l from 1 to 16
             do (let ((n (aref counts (1- l))))
                  (aset valptr l k)
                  (aset mincode l code)
                  (setq code (+ code n)
                        k    (+ k n))
                  (aset maxcode l (if (> n 0) (1- code) -1))
                  (setq code (ash code 1))))
    (vector mincode maxcode valptr symbols)))

(defun octocat-avatar--huff-decode (st table)
  "Decode one Huffman symbol from ST using TABLE."
  (let ((code 0) (l 0) result)
    (while (not result)
      (setq l (1+ l))
      (when (> l 16) (error "Bad Huffman code"))
      (setq code (logior (ash code 1) (octocat-avatar--bits-bit st)))
      (let ((mx (aref (aref table 1) l)))
        (when (and (>= mx 0) (<= code mx))
          (setq result (aref (aref table 3)
                             (+ (aref (aref table 2) l)
                                (- code (aref (aref table 0) l))))))))
    result))

(defun octocat-avatar--jpeg-block (st comp qt)
  "Decode one 8x8 block of COMP from ST, dequantized with QT.
Return the coefficients in natural order."
  (let* ((coef (make-vector 64 0))
         (s    (octocat-avatar--huff-decode st (octocat-avatar--comp-dct comp)))
         (k    1))
    (when (> s 0)
      (cl-incf (octocat-avatar--comp-pred comp)
               (octocat-avatar--extend (octocat-avatar--bits-receive st s) s)))
    (aset coef 0 (* (octocat-avatar--comp-pred comp) (aref qt 0)))
    (while (< k 64)
      (let* ((rs (octocat-avatar--huff-decode st (octocat-avatar--comp-act comp)))
             (r  (ash rs -4))
             (sz (logand rs 15)))
        (if (= sz 0)
            (if (= r 15) (setq k (+ k 16)) (setq k 64))
          (setq k (+ k r))
          (when (< k 64)
            (aset coef (aref octocat-avatar--zigzag k)
                  (* (octocat-avatar--extend
                      (octocat-avatar--bits-receive st sz) sz)
                     (aref qt k))))
          (setq k (1+ k)))))
    coef))

(defun octocat-avatar--jpeg-idct (coef plane stride px py)
  "Inverse-DCT COEF into the 8x8 square of PLANE at (PX, PY).
STRIDE is the width of PLANE."
  (let ((tmp (make-vector 64 0.0))
        (tbl octocat-avatar--idct-table))
    (dotimes (v 8)
      (dotimes (x 8)
        (let ((s 0.0))
          (dotimes (u 8)
            (setq s (+ s (* (aref tbl (+ (* x 8) u))
                            (aref coef (+ (* v 8) u))))))
          (aset tmp (+ (* v 8) x) s))))
    (dotimes (y 8)
      (dotimes (x 8)
        (let ((s 0.0))
          (dotimes (v 8)
            (setq s (+ s (* (aref tbl (+ (* y 8) v))
                            (aref tmp (+ (* v 8) x))))))
          (aset plane (+ (* (+ py y) stride) px x)
                (max 0 (min 255 (round (+ s 128.0))))))))))

(defun octocat-avatar--jpeg-restart (st)
  "Realign ST on the byte after the next restart marker."
  (setf (octocat-avatar--bits-cnt st) 0)
  (let ((data (octocat-avatar--bits-data st))
        (pos  (octocat-avatar--bits-pos st)))
    (while (and (< (1+ pos) (length data))
                (not (and (= (aref data pos) #xFF)
                          (<= #xD0 (aref data (1+ pos)) #xD7))))
      (setq pos (1+ pos)))
    (setf (octocat-avatar--bits-pos st) (min (length data) (+ pos 2)))))

(defun octocat-avatar--jpeg-scan (st comps width height qts restart)
  "Decode the MCUs of one scan from ST and return the RGBA image list.
COMPS are the frame's components, WIDTH and HEIGHT its size, QTS the
quantization tables and RESTART the restart interval (or nil)."
  (let* ((hmax (apply #'max (mapcar #'octocat-avatar--comp-h comps)))
         (vmax (apply #'max (mapcar #'octocat-avatar--comp-v comps)))
         (mcux (/ (+ width (1- (* 8 hmax))) (* 8 hmax)))
         (mcuy (/ (+ height (1- (* 8 vmax))) (* 8 vmax)))
         (count 0))
    (dolist (c comps)
      (let ((pw (* mcux (octocat-avatar--comp-h c) 8)))
        (setf (octocat-avatar--comp-pw c) pw
              (octocat-avatar--comp-plane c)
              (make-vector (* pw mcuy (octocat-avatar--comp-v c) 8) 0))))
    (dotimes (my mcuy)
      (dotimes (mx mcux)
        (when (and restart (> restart 0) (> count 0) (= 0 (mod count restart)))
          (octocat-avatar--jpeg-restart st)
          (dolist (c comps) (setf (octocat-avatar--comp-pred c) 0)))
        (dolist (c comps)
          (let ((h  (octocat-avatar--comp-h c))
                (v  (octocat-avatar--comp-v c))
                (qt (aref qts (octocat-avatar--comp-tq c))))
            (dotimes (by v)
              (dotimes (bx h)
                (octocat-avatar--jpeg-idct
                 (octocat-avatar--jpeg-block st c qt)
                 (octocat-avatar--comp-plane c) (octocat-avatar--comp-pw c)
                 (* 8 (+ (* mx h) bx)) (* 8 (+ (* my v) by)))))))
        (setq count (1+ count))))
    (octocat-avatar--jpeg-rgba comps width height hmax vmax)))

(defun octocat-avatar--jpeg-sample (comp x y hmax vmax)
  "Return COMP's sample for image pixel (X, Y) given HMAX and VMAX."
  (aref (octocat-avatar--comp-plane comp)
        (+ (* (/ (* y (octocat-avatar--comp-v comp)) vmax)
              (octocat-avatar--comp-pw comp))
           (/ (* x (octocat-avatar--comp-h comp)) hmax))))

(defun octocat-avatar--jpeg-rgba (comps width height hmax vmax)
  "Convert the planes of COMPS to the RGBA image list of WIDTH x HEIGHT.
HMAX and VMAX are the largest sampling factors."
  (let ((px (make-vector (* width height 4) 255))
        (c0 (nth 0 comps)) (c1 (nth 1 comps)) (c2 (nth 2 comps)))
    (dotimes (y height)
      (dotimes (x width)
        (let ((o (* 4 (+ (* y width) x)))
              (l (octocat-avatar--jpeg-sample c0 x y hmax vmax)))
          (if (null c1)
              (progn (aset px o l) (aset px (+ o 1) l) (aset px (+ o 2) l))
            (let ((cb (- (octocat-avatar--jpeg-sample c1 x y hmax vmax) 128))
                  (cr (- (octocat-avatar--jpeg-sample c2 x y hmax vmax) 128)))
              (aset px o       (max 0 (min 255 (round (+ l (* 1.402 cr))))))
              (aset px (+ o 1) (max 0 (min 255 (round (- l (* 0.344136 cb)
                                                         (* 0.714136 cr))))))
              (aset px (+ o 2) (max 0 (min 255 (round (+ l (* 1.772 cb)))))))))))
    (list width height px)))

(defun octocat-avatar--decode-jpeg (bytes)
  "Decode the baseline JPEG in unibyte string BYTES, or return nil."
  (let ((pos 2) (len (length bytes))
        (qts (make-vector 4 nil))
        (dcs (make-vector 4 nil))
        (acs (make-vector 4 nil))
        comps width height restart result)
    (while (and (< (1+ pos) len) (not result))
      (while (and (< pos len) (/= (aref bytes pos) #xFF))
        (setq pos (1+ pos)))
      (while (and (< pos len) (= (aref bytes pos) #xFF))
        (setq pos (1+ pos)))
      (let ((m (if (< pos len) (aref bytes pos) #xD9)))
        (setq pos (1+ pos))
        (cond
         ((or (= m 0) (= m 1) (<= #xD0 m #xD8)) nil)
         ((= m #xD9) (setq pos len))
         (t
          (let* ((start (+ pos 2))
                 (end   (+ pos (octocat-avatar--u16 bytes pos))))
            (cond
             ((= m #xDB)
              (let ((p start))
                (while (< p end)
                  (let* ((pq (ash (aref bytes p) -4))
                         (tq (logand (aref bytes p) 15))
                         (tbl (make-vector 64 0)))
                    (setq p (1+ p))
                    (dotimes (i 64)
                      (aset tbl i (if (= pq 0)
                                      (aref bytes (+ p i))
                                    (octocat-avatar--u16 bytes (+ p (* 2 i))))))
                    (setq p (+ p (if (= pq 0) 64 128)))
                    (aset qts tq tbl)))))
             ((= m #xC4)
              (let ((p start))
                (while (< p end)
                  (let* ((tc (ash (aref bytes p) -4))
                         (th (logand (aref bytes p) 15))
                         (counts (make-vector 16 0))
                         (n 0))
                    (dotimes (i 16)
                      (aset counts i (aref bytes (+ p 1 i)))
                      (setq n (+ n (aref counts i))))
                    (let ((tbl (octocat-avatar--huff-build
                                counts (substring bytes (+ p 17) (+ p 17 n)))))
                      (if (= tc 0) (aset dcs th tbl) (aset acs th tbl)))
                    (setq p (+ p 17 n))))))
             ((or (= m #xC0) (= m #xC1))
              (let ((nc (aref bytes (+ start 5))))
                (unless (and (= (aref bytes start) 8) (memq nc '(1 3)))
                  (error "Unsupported JPEG"))
                (setq height (octocat-avatar--u16 bytes (+ start 1))
                      width  (octocat-avatar--u16 bytes (+ start 3))
                      comps
                      (cl-loop for i below nc
                               for p = (+ start 6 (* 3 i))
                               collect (octocat-avatar--comp-make
                                        (aref bytes p)
                                        (if (= nc 1) 1 (ash (aref bytes (1+ p)) -4))
                                        (if (= nc 1) 1 (logand (aref bytes (1+ p)) 15))
                                        (aref bytes (+ p 2)))))
                (unless (and (> width 0) (> height 0)
                             (<= (* width height) octocat-avatar--max-pixels))
                  (error "Bad JPEG size"))))
             ((or (= m #xC2) (and (>= m #xC3) (<= m #xCF)
                                  (not (memq m '(#xC4 #xC8 #xCC)))))
              (error "Unsupported JPEG"))
             ((= m #xDD)
              (setq restart (octocat-avatar--u16 bytes start)))
             ((= m #xDA)
              (let ((ns (aref bytes start)))
                (unless (and comps (= ns (length comps)))
                  (error "Unsupported JPEG scan"))
                (dotimes (i ns)
                  (let* ((cs (aref bytes (+ start 1 (* 2 i))))
                         (tb (aref bytes (+ start 2 (* 2 i))))
                         (c  (cl-find cs comps :key #'octocat-avatar--comp-id)))
                    (unless c (error "Bad JPEG scan"))
                    (setf (octocat-avatar--comp-dct c) (aref dcs (ash tb -4))
                          (octocat-avatar--comp-act c) (aref acs (logand tb 15)))))
                (setq result
                      (octocat-avatar--jpeg-scan
                       (octocat-avatar--bits-make bytes end)
                       comps width height qts restart)))))
            (setq pos end))))))
    result))


;;;; Public API

(defun octocat-avatar-decode (bytes)
  "Decode the PNG or JPEG in unibyte string BYTES.
Return (WIDTH HEIGHT PIXELS), where PIXELS is a flat vector of R G B A
integers, or nil when BYTES is corrupt or in an unsupported format."
  (condition-case nil
      (cond ((and (> (length bytes) 8)
                  (= (aref bytes 0) 137)
                  (equal (substring bytes 1 4) "PNG"))
             (octocat-avatar--decode-png bytes))
            ((and (> (length bytes) 4)
                  (= (aref bytes 0) #xFF) (= (aref bytes 1) #xD8))
             (octocat-avatar--decode-jpeg bytes)))
    (error nil)))

(defun octocat-avatar-dark-background-p ()
  "Return non-nil when the selected frame has a dark background."
  (eq (frame-parameter nil 'background-mode) 'dark))

(defun octocat-avatar-unicode-p ()
  "Return non-nil when Emacs can display the block characters.
Asks the selected frame, so a terminal that is not set up for UTF-8
reports nil."
  (and (char-displayable-p ?▀) (char-displayable-p ?▘) t))

(defconst octocat-avatar--quadrants
  [" " "▘" "▝" "▀" "▖" "▌" "▞" "▛" "▗" "▚" "▐" "▜" "▄" "▙" "▟" "█"]
  "Quadrant glyphs indexed by mask.
The mask has 1 for the upper left, 2 for the upper right, 4 for the
lower left and 8 for the lower right quadrant.")

(defun octocat-avatar--grid (image nx ny bg)
  "Box-average IMAGE onto a grid of NX by NY samples.
Transparent pixels are blended with the grey level BG (0..255).  Return
a flat vector of NX * NY * 3 floats in 0..1: R G B of each sample, row
by row."
  (pcase-let* ((`(,w ,h ,px) image)
               (grid (make-vector (* nx ny 3) 0.0)))
    (dotimes (cy ny)
      (dotimes (cx nx)
        (let* ((x0 (/ (* cx w) nx))
               (x1 (min w (max (1+ x0) (/ (* (1+ cx) w) nx))))
               (y0 (/ (* cy h) ny))
               (y1 (min h (max (1+ y0) (/ (* (1+ cy) h) ny))))
               (r 0.0) (g 0.0) (b 0.0) (n 0))
          (cl-loop for y from y0 below y1
                   do (cl-loop for x from x0 below x1
                               do (let* ((i (* 4 (+ (* y w) x)))
                                         (a (aref px (+ i 3)))
                                         (back (* bg (- 255 a))))
                                    (cl-incf r (+ (* (aref px i) a) back))
                                    (cl-incf g (+ (* (aref px (+ i 1)) a) back))
                                    (cl-incf b (+ (* (aref px (+ i 2)) a) back))
                                    (cl-incf n))))
          (let ((d (* 255.0 255.0 (max n 1)))
                (o (* 3 (+ (* cy nx) cx))))
            (aset grid o (/ r d))
            (aset grid (+ o 1) (/ g d))
            (aset grid (+ o 2) (/ b d))))))
    grid))

(defsubst octocat-avatar--lum (grid o)
  "Return the brightness (0..1) of the sample at offset O of GRID."
  (+ (* 0.299 (aref grid o))
     (* 0.587 (aref grid (+ o 1)))
     (* 0.114 (aref grid (+ o 2)))))

(defun octocat-avatar--hex (r g b)
  "Return the colour name for R, G and B given as floats in 0..1."
  (format "#%02x%02x%02x"
          (round (* 255 (min 1.0 (max 0.0 r))))
          (round (* 255 (min 1.0 (max 0.0 g))))
          (round (* 255 (min 1.0 (max 0.0 b))))))

(defun octocat-avatar--tone-fn (grid dark)
  "Return a function mapping a GRID offset to a tone in 0..1.
The tone is the brightness stretched over the range the image uses, so
a flat or low-contrast avatar still spans the whole scale.  It is
inverted unless DARK, so that more \"ink\" always means a higher tone."
  (let ((lo 1.0) (hi 0.0))
    (cl-loop for o from 0 below (length grid) by 3
             do (let ((l (octocat-avatar--lum grid o)))
                  (setq lo (min lo l) hi (max hi l))))
    (let ((span (- hi lo)))
      ;; A (nearly) flat image has no range to stretch: take its
      ;; brightness as it is.
      (when (< span 0.05)
        (setq lo 0.0 span 1.0))
      (lambda (o)
        (let ((v (min 1.0 (max 0.0 (/ (- (octocat-avatar--lum grid o) lo) span)))))
          (if dark v (- 1.0 v)))))))

(defun octocat-avatar--render-ramp (grid cols rows dark ramp)
  "Draw GRID (COLS by ROWS samples) with one character of RAMP per cell.
DARK is as for `octocat-avatar-render'."
  (let ((tone (octocat-avatar--tone-fn grid dark))
        (top  (1- (length ramp))))
    (cl-loop for cy below rows
             collect
             (mapconcat
              (lambda (cx)
                (let ((o (* 3 (+ (* cy cols) cx))))
                  (propertize
                   (string (aref ramp (round (* top (funcall tone o)))))
                   'face (list :foreground
                               (octocat-avatar--hex (aref grid o)
                                                    (aref grid (+ o 1))
                                                    (aref grid (+ o 2)))))))
              (number-sequence 0 (1- cols)) ""))))

(defun octocat-avatar--render-blocks (grid cols rows)
  "Draw GRID (COLS * 2 by ROWS * 2 samples) with quadrant blocks.
Each cell is split in two colours, foreground and background, along
whichever of the seven quadrant partitions fits its four samples best."
  (let ((nx (* cols 2)))
    (cl-loop
     for cy below rows
     collect
     (mapconcat
      (lambda (cx)
        (let* ((offs (vector (* 3 (+ (* cy 2 nx) (* cx 2)))
                             (* 3 (+ (* cy 2 nx) (* cx 2) 1))
                             (* 3 (+ (* (1+ (* cy 2)) nx) (* cx 2)))
                             (* 3 (+ (* (1+ (* cy 2)) nx) (* cx 2) 1))))
               best-err best-m best-fg best-bg)
          (cl-loop
           for m from 1 to 7
           do (let ((fg (list 0.0 0.0 0.0)) (bg (list 0.0 0.0 0.0))
                    (nf 0) (nb 0) (err 0.0))
                (dotimes (i 4)
                  (let ((o (aref offs i))
                        (side (if (/= 0 (logand m (ash 1 i))) fg bg)))
                    (if (eq side fg) (cl-incf nf) (cl-incf nb))
                    (dotimes (k 3)
                      (cl-incf (nth k side) (aref grid (+ o k))))))
                (dotimes (k 3)
                  (setf (nth k fg) (/ (nth k fg) nf)
                        (nth k bg) (/ (nth k bg) nb)))
                (dotimes (i 4)
                  (let ((o (aref offs i))
                        (side (if (/= 0 (logand m (ash 1 i))) fg bg)))
                    (dotimes (k 3)
                      (cl-incf err (expt (- (aref grid (+ o k)) (nth k side)) 2)))))
                (when (or (null best-err) (< err best-err))
                  (setq best-err err best-m m best-fg fg best-bg bg))))
          (propertize (aref octocat-avatar--quadrants best-m)
                      'face (list :foreground (apply #'octocat-avatar--hex best-fg)
                                  :background (apply #'octocat-avatar--hex best-bg)))))
      (number-sequence 0 (1- cols)) ""))))

(defun octocat-avatar-render (image cols &optional background style)
  "Render IMAGE as a list of strings, COLS characters wide.
The height follows the image's aspect ratio, halved because a character
cell is about twice as tall as it is wide.  Transparent pixels are
blended with BACKGROUND, `dark' or `light' (nil asks the selected
frame, see `octocat-avatar-dark-background-p').

STYLE picks the characters:
  `blocks' -- quadrant blocks, four sub-pixels a cell, each cell with a
      foreground and a background colour.
  `ramp' -- one Unicode shade character a cell, denser for brighter
      pixels on a dark background and for darker ones on a light one.
  `ascii' -- like `ramp', with 7-bit characters only.
The default is `blocks', or `ascii' when Emacs cannot display
Unicode (see `octocat-avatar-unicode-p')."
  (pcase-let* ((`(,w ,h ,_px) image)
               (dark (pcase background
                       ('dark t)
                       ('light nil)
                       (_ (octocat-avatar-dark-background-p))))
               (cols (max 1 cols))
               (rows (max 1 (round (/ (* cols h) (* 2.0 w)))))
               (style (or style (if (octocat-avatar-unicode-p) 'blocks 'ascii)))
               (sub  (if (eq style 'blocks) 2 1))
               (grid (octocat-avatar--grid image (* cols sub) (* rows sub)
                                           (if dark 0 255))))
    (pcase style
      ('ramp  (octocat-avatar--render-ramp grid cols rows dark octocat-avatar--ramp))
      ('ascii (octocat-avatar--render-ramp grid cols rows dark
                                           octocat-avatar--ascii-ramp))
      (_      (octocat-avatar--render-blocks grid cols rows)))))

(defun octocat-avatar--fetched (status callback)
  "Hand the body of the finished `url-retrieve' to CALLBACK.
STATUS is the retrieval status plist; the current buffer holds the
response, and is killed here."
  (let ((buf (current-buffer))
        (result
         (cond
          ((plist-get status :error)
           (cons 'error (format "%s" (plist-get status :error))))
          ((progn (goto-char (point-min))
                  (not (looking-at "HTTP/[0-9.]+ 200")))
           (cons 'error "Avatar request failed"))
          ((re-search-forward "\r?\n\r?\n" nil t)
           (buffer-substring-no-properties (point) (point-max)))
          (t (cons 'error "Malformed avatar response")))))
    (kill-buffer buf)
    (funcall callback result)))

(defun octocat-avatar-fetch (url callback)
  "Fetch URL asynchronously and call CALLBACK with its body.
CALLBACK receives a unibyte string, or a cons (error . MESSAGE)."
  (condition-case err
      (url-retrieve url #'octocat-avatar--fetched (list callback) t t)
    (error (funcall callback (cons 'error (error-message-string err))))))

(provide 'octocat-avatar)
;;; octocat-avatar.el ends here
