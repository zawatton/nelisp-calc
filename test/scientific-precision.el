;;; scientific-precision.el --- Scientific precision and first-request acceptance -*- lexical-binding: t; -*-
(load (expand-file-name "../lisp/nelisp-calc-engine.el" (file-name-directory (replace-regexp-in-string "\\\\" "/" load-file-name t t))) nil t)
(nelisp-calc-initialize)
(setq nelisp-calc-angle 'rad)
;; The logarithm is deliberately the first request in a fresh process.
;; These values are independently checked with stock GNU Emacs Calc.
(dolist (item '(("ln(2)" 30 "0.693147180559945309417232121458")
                ("exp(1)" 30 "2.71828182845904523536028747135")
                ("sin(1)" 30 "0.84147098480789650665250232163")
                ("cos(1)" 30 "0.540302305868139717400936607443")
                ("tan(1)" 30 "1.55740772465490223050697480746")
                ("30!" 30 "265252859812191058636308480000000")
                ("ln(2)" 12 "0.69314718056")
                ("exp(1)" 12 "2.71828182846")))
  (let ((result (nelisp-calc-evaluate (nth 0 item) (nth 1 item))))
    (unless (and (plist-get result :ok) (equal (plist-get result :value) (nth 2 item)))
      (error "Scientific precision mismatch %S: %S" item result))))
(princ "SCIENTIFIC-PRECISION-PASS\n")
