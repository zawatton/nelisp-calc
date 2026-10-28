;;; engine-benchmark-eval.el --- Fresh arithmetic measurement -*- lexical-binding: t; -*-
(load (expand-file-name "../lisp/nelisp-calc-engine.el"
                        (file-name-directory
                         (replace-regexp-in-string "\\\\" "/" load-file-name t t))) nil t)
(nelisp-calc-initialize)
(unless (equal (plist-get (nelisp-calc-evaluate "0.1+0.2") :value) "0.3")
  (error "Benchmark arithmetic failed"))
(princ "0.3\n")
