;;; nelisp-calc-implicit.el --- Bounded genuine Calc contours -*- lexical-binding: t; -*-

(defvar nelisp-calc-implicit-cells 16)

(defun nelisp-calc-implicit-expression (expression)
  "Return a residual string, or nil for an explicit function of x."
  (let ((parts (split-string expression "=")))
    (cond ((> (length parts) 2) (error "Graph accepts one equality"))
          ((= (length parts) 2)
           (when (or (equal (car parts) "") (equal (cadr parts) ""))
             (error "Equality needs two expressions"))
           (concat "(" (car parts) ")-(" (cadr parts) ")"))
          ((string-match "\\_<y\\_>" expression) expression)
          (t nil))))

(defun nelisp-calc-implicit-substitute (tree x y)
  "Replace Calc variable nodes with already parsed Calc numeric values."
  (cond ((atom tree) tree)
        ((eq (car tree) 'var)
         (cond ((eq (cadr tree) 'x) x) ((eq (cadr tree) 'y) y)
               ((memq (cadr tree) '(pi e)) tree)
               (t (error "Unknown graph variable: %s" (cadr tree)))))
        (t (mapcar (lambda (node) (nelisp-calc-implicit-substitute node x y)) tree))))

(defun nelisp-calc-implicit-value (tree x y)
  "Normalize a substituted expression through genuine Calc."
  (let* ((calc-internal-prec nelisp-calc-precision)
         (calc-angle-mode (if (eq nelisp-calc-angle 'grad) 'deg nelisp-calc-angle)) (calc-simplify-mode nil)
         (result (calc-normalize (nelisp-calc-implicit-substitute tree x y))))
    (unless (math-constp result) (error "Calc number expected: %S" result))
    (let ((text (math-format-value result 1000)))
      (unless (and (stringp text)
                   (string-match "\\`[-+]?[0-9]+\\(?:\\.[0-9]*\\)?\\(?:[eE][-+]?[0-9]+\\)?\\'" text))
        (error "Undefined real Calc sample: %s" text))
      (let ((value (float (string-to-number text))))
        (unless (< (abs value) 1.0e100) (error "Undefined real Calc magnitude"))
        value))))

(defun nelisp-calc-implicit-crossing (a b)
  "Interpolate a zero crossing in normalized pixel geometry."
  (let ((va (nth 2 a)) (vb (nth 2 b)))
    (when (and va vb (or (and (<= va 0) (> vb 0))
                         (and (> va 0) (<= vb 0))))
      (let ((fraction (/ va (- va vb))))
        (list (+ (car a) (* fraction (- (car b) (car a))))
              (+ (cadr a) (* fraction (- (cadr b) (cadr a)))))))))

(defun nelisp-calc-implicit-triangle (a b c)
  "Return one isolated segment; undefined corners never bridge a domain hole."
  (when (and (nth 2 a) (nth 2 b) (nth 2 c))
    (let (points)
      (dolist (edge (list (list a b) (list b c) (list c a)))
        (let ((point (nelisp-calc-implicit-crossing (car edge) (cadr edge))))
          (when point (setq points (cons point points)))))
      (when (= (length points) 2)
        (format "1 %d %d\n1 %d %d\n0 0 0\n"
                (round (caar points)) (round (cadar points))
                (round (caadr points)) (round (cadadr points)))))))

(defun nelisp-calc-implicit-render (residual)
  "Sample a bounded 2D grid using a single genuine Calc parse."
  (setq nelisp-calc-graph-last-error nil)
  (unless (and (integerp nelisp-calc-implicit-cells)
               (>= nelisp-calc-implicit-cells 8) (<= nelisp-calc-implicit-cells 24))
    (error "Implicit graph budget requires 8..24 cells"))
  (when nelisp-calc-engine-error (error "Calc unavailable: %s" nelisp-calc-engine-error))
  (let* ((bounds (nelisp-calc-graph-validate-range nelisp-calc-graph-range))
         (parsed (math-read-exprs residual))
         (n nelisp-calc-implicit-cells) (rows nil) (j 0) (xs nil) (k 0)
         (valid 0) (nonzero 0) (segments 0) (lines "SCG1\n"))
    (when (or (eq (car parsed) 'error) (/= (length parsed) 1))
      (error "Calc parse error: %S" parsed))
    (when (fboundp 'nelisp-calc-expand-constants)
      (let ((calc-internal-prec nelisp-calc-precision))
        (setq parsed (list (nelisp-calc-expand-constants (car parsed))))))
    (when (eq nelisp-calc-angle 'grad)
      (unless (fboundp 'nelisp-calc-grad-expression) (error "Grad Calc AST provider unavailable"))
      (setq parsed (list (nelisp-calc-grad-expression (car parsed)))))
    (while (<= k n)
      (setq xs (cons (car (math-read-exprs
                          (nelisp-calc-graph-literal
                           (+ (nth 0 bounds) (* (/ (float k) n) (- (nth 1 bounds) (nth 0 bounds))))))) xs))
      (setq k (1+ k)))
    (setq xs (nreverse xs))
    ;; Validate variable names even if every sample has an undefined domain.
    (nelisp-calc-implicit-substitute (car parsed) 0 0)
    (while (<= j n)
      (let ((i 0) row
            (y (car (math-read-exprs
                     (nelisp-calc-graph-literal
                      (- (nth 3 bounds) (* (/ (float j) n) (- (nth 3 bounds) (nth 2 bounds)))))))))
        (while (<= i n)
          (let* ((x (nth i xs))
                 (value
                  (condition-case err
                      (nelisp-calc-implicit-value (car parsed) x y)
                    (error
                     (let ((message (error-message-string err)))
                       (if (string-match "Calc number expected\\|Unknown graph\\|void-function\\|file-missing\\|nelisp-" message)
                           (error "%s" message)
                         nil))))))
            (when value (setq valid (1+ valid))
                  (unless (= value 0) (setq nonzero (1+ nonzero))))
            (setq row (cons (list (/ (* 1000.0 i) n) (/ (* 1000.0 j) n) value) row)))
          (setq i (1+ i)))
        (setq rows (cons (nreverse row) rows)))
      (setq j (1+ j)))
    (unless (> valid 0) (error "No defined real Calc samples in implicit viewport"))
    (unless (> nonzero 0) (error "Degenerate implicit expression is zero everywhere sampled"))
    (setq rows (nreverse rows) j 0)
    (while (< j n)
      (let ((top (nth j rows)) (bottom (nth (1+ j) rows)) (i 0))
        (while (< i n)
          (dolist (triangle (list (list (nth i top) (nth (1+ i) top) (nth (1+ i) bottom))
                                  (list (nth i top) (nth (1+ i) bottom) (nth i bottom))))
            (let ((segment (apply #'nelisp-calc-implicit-triangle triangle)))
              (when segment
                (setq segments (1+ segments))
                (when (> segments 682) (error "Implicit contour exceeds 2048-line budget"))
                (setq lines (concat lines segment)))))
          (setq i (1+ i))))
      (setq j (1+ j)))
    (nelisp-calc-graph-write lines)
    (setq nelisp-calc-display (format "%d segments" segments)
          nelisp-calc-status (format "ok:graph:implicit:%d segments:%d samples" segments valid))))

(provide 'nelisp-calc-implicit)
