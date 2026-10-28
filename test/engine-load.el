;;; engine-load.el --- Source loading gate only -*- lexical-binding: t; -*-
(load (expand-file-name "../lisp/nelisp-calc-engine.el"
                        (file-name-directory
                         (replace-regexp-in-string "\\\\" "/" load-file-name t t))) nil t)
(nelisp-calc-initialize)
(unless (and (featurep 'calc) (featurep 'calc-aent)
             (fboundp 'calc-eval) (fboundp 'calc-do-calc-eval))
  (error "Genuine Calc source loading failed: %S" nelisp-calc-engine-error))
(princ "ENGINE-SOURCE-LOAD-PASS\n")
(princ (format "COMPUTE-STATUS: %S\n" nelisp-calc-engine-error))
