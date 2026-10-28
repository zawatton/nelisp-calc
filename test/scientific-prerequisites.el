;;; scientific-prerequisites.el --- Calc numeric prerequisites -*- lexical-binding: t; -*-

(let ((root (expand-file-name ".." (file-name-directory load-file-name))))
  (load (expand-file-name "lisp/nelisp-calc-compat.el" root) nil t)
  (nelisp-calc-compat-install root))

;; GNU Calc's math-numdigs uses this exact integer exponent while creating
;; its pi cache.  Scientific loading must retain an exact integer result.
(unless (equal (expt 10 21) 1000000000000000000000)
  (error "Scientific prerequisite failed: exact bignum exponentiation"))
(unless (equal (expt 2 100) 1267650600228229401496703205376)
  (error "Scientific prerequisite failed: wider integer exponentiation"))
(dolist (case '(((expt 2 70) 1180591620717411303424)
                ((expt -3 3) -27) ((expt -3 4) 81)
                ((expt 0 0) 1) ((expt 0 9) 0)
                ((expt 2 -3) 0.125) ((expt 4 0.5) 2.0)))
  (unless (= (eval (car case) t) (cadr case))
    (error "Exponent regression: %S" case)))
(let ((map (make-keymap)))
  (define-key map "Y" nil)
  (unless (arrayp (nth 1 map)) (error "Dense map nil binding displaced table"))
  (define-key map "Y?" 'ignore)
  (unless (eq (lookup-key map "Y?") 'ignore)
    (error "Dense prefix lookup failed"))
  (unless (arrayp (nth 1 map)) (error "Dense prefix displaced table")))
(when (fboundp 'nl-write-file)
  (unless (arrayp (nth 1 esc-map)) (error "GNU full ESC map precondition failed")))
(princ "SCIENTIFIC-PREREQUISITES-PASS\n")
