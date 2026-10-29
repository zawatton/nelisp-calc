;;; graph-implicit-controls.el --- Bounded SCG1 contour capacity -*- lexical-binding: t; -*-
(require 'cl-lib)
(defun calc-implicit-controls (program)
  "Increase only the native draw_graph SCG1 reader budget to 2048 rows.
The generated DSL function is scoped explicitly; its quoted definitions are
not top-level Elisp definitions and ordinary caller indexes do not cover them."
  (let ((changed 0))
    (prog1
        (mapcar
         (lambda (form)
           (if (and (eq (car-safe form) 'defun) (eq (cadr form) 'draw_graph))
               (let ((original form))
                 ;; Match the full call rather than unrelated numeric limits.
                 (setq form (cl-subst '(graph_points ctx cr fp 2048 0)
                                     '(graph_points ctx cr fp 101 0) form :test #'equal))
                 (when (equal original form) (error "Native graph reader capacity call changed"))
                 (setq changed (1+ changed)) form)
             form)) program)
      (unless (= changed 1) (error "Expected one native draw_graph definition")))))
