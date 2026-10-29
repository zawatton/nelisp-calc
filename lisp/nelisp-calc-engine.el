;;; nelisp-calc-engine.el --- Genuine Calc adapter -*- lexical-binding: t; -*-

(defvar nelisp-calc-root
  (expand-file-name ".." (file-name-directory
                         (replace-regexp-in-string "\\\\" "/" load-file-name t t))))
(defvar nelisp-calc-engine-error nil)
(defvar nelisp-calc-expression "")
(defvar nelisp-calc-display "0")
(defvar nelisp-calc-status "ready")
(defvar nelisp-calc-fresh t)
(defvar nelisp-calc-accumulator nil)
(defvar nelisp-calc-operator nil)
(defvar nelisp-calc-last-operator nil)
(defvar nelisp-calc-last-operand nil)
(defvar nelisp-calc-mode "standard")
(defvar nelisp-calc-angle 'deg)
(defvar nelisp-calc-precision 12)
(defvar nelisp-calc-ascii-input-settings nil)

(defun nelisp-calc-initialize-owned-backend (owns-default-policy)
  "Initialize a fresh dedicated backend with bounded temporary GC debt.
OWNS-DEFAULT-POLICY must only be non-nil in the application-owned mailbox
process.  Its trusted launcher must attest selector support through
NELISP_CALC_NATIVE_GC_POLICY=debt-v1.  Embedders retain their own policy.
The native debt floor and percentage return to their documented defaults
before any ready response, including when initialization signals an error."
  (if (and owns-default-policy
           (equal (getenv "NELISP_CALC_NATIVE_GC_POLICY") "debt-v1")
           (fboundp 'nelisp--debug-switch)
           (fboundp 'nelisp--gc-pressure))
      (unwind-protect
          (progn
            (nelisp--debug-switch 30 4194304)
            (nelisp--debug-switch 31 100)
            (nelisp-calc-initialize))
        (nelisp--debug-switch 30 0)
        (nelisp--debug-switch 31 0))
    (nelisp-calc-initialize)))

(defun nelisp-calc-initialize ()
  "Load unmodified GNU Calc, preserving the exact initialization error."
  (condition-case err
      (progn
        ;; These redisplay hooks have no purpose in a headless process.
        (defvar redisplay-highlight-region-function nil)
        (defvar redisplay-unhighlight-region-function nil)
        (defvar region-insert-function nil)
        (defvar calc-scan-for-dels nil)
        (load (expand-file-name "lisp/nelisp-calc-compat.el" nelisp-calc-root) nil t)
        (nelisp-calc-compat-install nelisp-calc-root)
        (add-to-list 'load-path
                     (or (getenv "NELISP_CALC_VENDOR")
                         (expand-file-name "../nelisp-emacs/vendor/emacs-lisp/calc"
                                           nelisp-calc-root)))
        (require 'calc)
        ;; Explicit source loading avoids depending on runtime autoload dispatch.
        (require 'calc-aent)
        ;; Load the real macro provider after Calc to avoid eager load cycles.
        (load (expand-file-name "../emacs-lisp/rx.el"
                               (file-name-directory (locate-library "calc"))) nil t)
        (require 'calc-misc)
        (nelisp-calc-compat-load-isqrt
         (expand-file-name "../emacs-lisp/cl-extra.el"
                           (file-name-directory (locate-library "calc"))))
        ;; Initialize GNU extension autoloads before loading their real providers.
        ;; Any scientific expression can be the first request in a fresh process.
        (require 'calc-ext)
        (require 'calc-arith)
        (require 'calc-math)
        (require 'calc-comb)
        (setq nelisp-calc-engine-error nil)
        (let ((probe (plist-get (nelisp-calc-evaluate "0.1+0.2") :value)))
          (unless (equal probe "0.3") (error "Calc startup probe failed: %S" probe)))
        (setq nelisp-calc-engine-error nil))
    (error (setq nelisp-calc-engine-error (prin1-to-string err))))
  (if nelisp-calc-engine-error
      (setq nelisp-calc-display "ENGINE UNAVAILABLE"
            nelisp-calc-status (concat "engine-unavailable:" nelisp-calc-engine-error))
    (setq nelisp-calc-display "0" nelisp-calc-status "ready")))

(defun nelisp-calc-expand-constants (expression)
  "Materialize GNU Calc constants under the caller's active precision."
  (cond ((and (consp expression) (eq (car expression) 'var) (eq (cadr expression) 'pi)) (math-pi))
        ((and (consp expression) (eq (car expression) 'var) (eq (cadr expression) 'e)) (calc-normalize '(calcFunc-exp 1)))
        ((consp expression) (mapcar #'nelisp-calc-expand-constants expression))
        (t expression)))

(defun nelisp-calc-grad-expression (expression)
  "Adapt parsed circular trig nodes from grads to GNU Calc degrees."
  (if (not (consp expression)) expression
    (let ((node (mapcar #'nelisp-calc-grad-expression expression)))
      (cond ((memq (car node) '(calcFunc-sin calcFunc-cos calcFunc-tan))
             (list (car node) (list '* (cadr node) '(frac 9 10))))
            ((memq (car node) '(calcFunc-arcsin calcFunc-arccos calcFunc-arctan))
             (list '* node '(frac 10 9)))
            (t node)))))

(defun nelisp-calc-evaluate (expression &optional precision numeric-operands)
  "Return a structured response from GNU Calc, never another evaluator.
NUMERIC-OPERANDS is an internal validated (LEFT OPERATOR RIGHT) request.
Its literal reader is the same GNU reader used by `math-read-exprs'."
  (if nelisp-calc-engine-error
      (list :ok nil :kind 'engine-unavailable :error nelisp-calc-engine-error)
    (condition-case err
        (let* ((calc-internal-prec (or precision nelisp-calc-precision))
               (calc-angle-mode (if (eq nelisp-calc-angle 'grad) 'deg nelisp-calc-angle))
               (calc-simplify-mode nil)
               (parsed (if numeric-operands
                           (list (list (intern (nth 1 numeric-operands))
                                       (math-read-number (nth 0 numeric-operands))
                                       (math-read-number (nth 2 numeric-operands))))
                         (math-read-exprs expression)))
               (parsed (mapcar #'nelisp-calc-expand-constants parsed))
               (parsed (if (eq nelisp-calc-angle 'grad)
                           (mapcar #'nelisp-calc-grad-expression parsed) parsed))
               (normalized
                (progn
                  (when (or (eq (car parsed) 'error) (/= (length parsed) 1))
                    (error "Calc parse error: %S" parsed))
                  (calc-normalize (car parsed))))
               (normalized
                (if (math-constp normalized) normalized
                  (nelisp-calc-compat-load-isqrt
                   (expand-file-name "../emacs-lisp/cl-extra.el"
                                     (file-name-directory (locate-library "calc"))))
                  (require 'calc-ext)
                  (require 'calc-arith)
                  (require 'calc-math)
                  (require 'calc-comb)
                  (calc-normalize (car parsed))))
               (value (if (math-constp normalized)
                          (math-format-value normalized 1000)
                        (error "Calc number expected: %S" normalized))))
          (if (stringp value)
              (list :ok t :value (if (string-match "\\.\\'" value)
                                    (substring value 0 -1) value))
            (list :ok nil :kind 'calculation-error :error (prin1-to-string value))))
      (error (list :ok nil :kind 'calculation-error :error (prin1-to-string err))))))

(defun nelisp-calc-compute (&optional numeric-operands)
  "Evaluate the current expression and update the display."
  (let ((result (nelisp-calc-evaluate nelisp-calc-expression nil numeric-operands)))
    (if (plist-get result :ok)
        (setq nelisp-calc-display (plist-get result :value)
              nelisp-calc-expression nelisp-calc-display
              nelisp-calc-status "ok" nelisp-calc-fresh t)
      (setq nelisp-calc-display "ERROR"
            nelisp-calc-status
            (concat (symbol-name (plist-get result :kind)) ":"
                    (plist-get result :error))
            nelisp-calc-fresh t))))

(defun nelisp-calc-reset ()
  "Reset the complete Standard interaction state."
  (setq nelisp-calc-expression "0" nelisp-calc-display "0"
        nelisp-calc-status "ready" nelisp-calc-fresh t
        nelisp-calc-accumulator nil nelisp-calc-operator nil
        nelisp-calc-last-operator nil nelisp-calc-last-operand nil))

(defun nelisp-calc-apply (expression &optional numeric-operands)
  "Calculate EXPRESSION and return its numeric value, or nil on error."
  (setq nelisp-calc-expression expression)
  (nelisp-calc-compute numeric-operands)
  (and (equal nelisp-calc-status "ok") nelisp-calc-display))

(defun nelisp-calc-ascii-number-input-p ()
  "Whether GNU input customization leaves ASCII numeric syntax unchanged."
  (and (null calc-language) (null calc-language-input-filter)
       (= calc-number-radix 10)
       (null calc-user-parse-table) (null calc-user-parse-tables)
       (null (get calc-language 'math-parse-table))
       (or (null calc-user-tokens) (equal calc-user-tokens ""))
       (null calc-user-token-chars)
       (let ((settings (list math-read-replacement-list
                             math-read-superscripts math-read-subscripts)))
         (or (equal settings nelisp-calc-ascii-input-settings)
             (and (not (string-match "[0-9.+*/-]" math-read-superscripts))
                  (not (string-match "[0-9.+*/-]" math-read-subscripts))
                  (catch 'changed
                    (dolist (replacement math-read-replacement-list)
                      (when (string-match "\\`[0-9.+*/-]*\\'" (car replacement))
                        (throw 'changed nil)))
                    ;; Copy strings as well as conses: in-place customizations
                    ;; must invalidate the approved-input settings snapshot.
                    (setq nelisp-calc-ascii-input-settings
                          (list (mapcar (lambda (replacement)
                                          (mapcar #'copy-sequence replacement))
                                        math-read-replacement-list)
                                (copy-sequence math-read-superscripts)
                                (copy-sequence math-read-subscripts)))
                    t))))))

(defun nelisp-calc-binary (left operator right)
  "Apply a binary OPERATOR using genuine Calc."
  ;; Only the application's default input grammar permits direct literal reads.
  ;; Custom languages, filters and parse tables must retain the GNU text parser.
  (let ((decimal "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'"))
    (if (and (member operator '("+" "-" "*" "/"))
             (string-match decimal left) (string-match decimal right)
             (nelisp-calc-ascii-number-input-p))
        (nelisp-calc-apply (concat left operator right)
                           (list left operator right))
      (nelisp-calc-apply (concat "(" left ")" operator "(" right ")")))))

(defun nelisp-calc-core-token (token)
  "Consume a Standard calculator token with immediate binary execution."
  (catch 'nelisp-calc-token-handled
    (unless nelisp-calc-engine-error
      (when (or (and (fboundp 'nelisp-calc-graph-token)
                     (nelisp-calc-graph-token token))
                (and (fboundp 'nelisp-calc-modes-token)
                     (nelisp-calc-modes-token token)))
        (throw 'nelisp-calc-token-handled
               (list nelisp-calc-display nelisp-calc-status))))
  (cond
   (nelisp-calc-engine-error
    (setq nelisp-calc-display "ENGINE UNAVAILABLE"
          nelisp-calc-status (concat "engine-unavailable:" nelisp-calc-engine-error)))
   ((equal token "clear") (nelisp-calc-reset))
   ((member token '("mode:scientific" "mode:standard"))
    (setq nelisp-calc-mode (substring token 5))
    (nelisp-calc-reset))
   ((member token '("angle:deg" "angle:rad" "angle:grad"))
    (setq nelisp-calc-angle (intern (substring token 6))
          nelisp-calc-status "ready"))
   ((and (> (length token) 10) (equal (substring token 0 10) "precision:"))
    (let ((precision (string-to-number (substring token 10))))
      (if (and (>= precision 2) (<= precision 100))
          (setq nelisp-calc-precision precision nelisp-calc-status "ready")
        (setq nelisp-calc-status "invalid-token"))))
   ((and (> (length token) 9) (equal (substring token 0 9) "function:"))
    (let* ((name (substring token 9))
           (function (cdr (assoc name '(("sqrt" . "sqrt") ("sin" . "sin")
                                       ("cos" . "cos") ("tan" . "tan")
                                       ("log" . "log10") ("ln" . "ln")
                                       ("exp" . "exp")
                                       ("asin" . "arcsin") ("acos" . "arccos") ("atan" . "arctan")
                                       ("sinh" . "sinh") ("cosh" . "cosh") ("tanh" . "tanh")
                                       ("asinh" . "arcsinh") ("acosh" . "arccosh") ("atanh" . "arctanh")))))
           (value nelisp-calc-display))
      (cond
       (function (nelisp-calc-apply (concat function "(" value ")")))
       ((equal name "pi")
        (let ((nelisp-calc-angle 'rad)) (nelisp-calc-apply "arccos(-1)")))
       ((equal name "e") (nelisp-calc-apply "exp(1)"))
       ((equal name "pow10") (nelisp-calc-apply (concat "10^(" value ")")))
       ((equal name "pow2") (nelisp-calc-apply (concat "2^(" value ")")))
       ((equal name "cuberoot") (nelisp-calc-apply (concat "sign(" value ")*abs(" value ")^(1/3)")))
       ((equal name "square") (nelisp-calc-apply (concat "(" value ")^2")))
       ((equal name "reciprocal") (nelisp-calc-apply (concat "1/(" value ")")))
       ((equal name "factorial") (nelisp-calc-apply (concat "(" value ")!")))
       (t (setq nelisp-calc-status "invalid-token")))))
   ((and (equal nelisp-calc-mode "scientific")
         (or (equal token "dot") (string-match "\\`[0-9]\\'" token)
             (member token '("add" "sub" "mul" "div" "power" "left-paren" "right-paren"))))
    (let ((text (or (cdr (assoc token '(("dot" . ".") ("add" . "+")
                                       ("sub" . "-") ("mul" . "*")
                                       ("div" . "/") ("power" . "^")
                                       ("left-paren" . "(") ("right-paren" . ")")))) token)))
      (when (or (and nelisp-calc-fresh
                     (or (equal token "dot") (equal token "left-paren")
                         (string-match "\\`[0-9]\\'" token)))
                (equal nelisp-calc-display "ERROR"))
        (setq nelisp-calc-display ""))
      (setq nelisp-calc-display (concat nelisp-calc-display text)
            nelisp-calc-fresh nil nelisp-calc-status "editing")))
   ((and (equal nelisp-calc-mode "scientific") (equal token "equals"))
    (nelisp-calc-apply nelisp-calc-display))
   ((member token '("ce" "clear-entry"))
    (setq nelisp-calc-display "0" nelisp-calc-expression "0"
          nelisp-calc-status "ready" nelisp-calc-fresh t))
   ((and (>= (length token) 5) (equal (substring token 0 5) "eval:"))
    (nelisp-calc-reset)
    (nelisp-calc-apply (substring token 5)))
   ((or (equal token "dot") (string-match "\\`[0-9]\\'" token))
    (when (equal nelisp-calc-display "ERROR") (nelisp-calc-reset))
    (when nelisp-calc-fresh (setq nelisp-calc-display "0"))
    (if (equal token "dot")
        (unless (string-match "\\." nelisp-calc-display)
          (setq nelisp-calc-display (concat nelisp-calc-display ".")))
      (setq nelisp-calc-display
            (if (equal nelisp-calc-display "0") token
              (concat nelisp-calc-display token))))
    (setq nelisp-calc-fresh nil nelisp-calc-status "editing"))
   ((equal nelisp-calc-display "ERROR") nil)
   ((equal token "backspace")
    (unless nelisp-calc-fresh
      (setq nelisp-calc-display
            (if (> (length nelisp-calc-display) 1)
                (substring nelisp-calc-display 0 -1) "0"))))
   ((equal token "sign")
    (nelisp-calc-apply (concat "-(" nelisp-calc-display ")"))
    (setq nelisp-calc-fresh nil))
   ((equal token "percent")
    (nelisp-calc-apply
     (concat (if (and nelisp-calc-accumulator
                      (member nelisp-calc-operator '("+" "-")))
                 (concat "(" nelisp-calc-accumulator ")*") "")
             "(" nelisp-calc-display ")/100"))
    (setq nelisp-calc-fresh nil))
   ((member token '("add" "sub" "mul" "div"))
    (let ((operator (cdr (assoc token '(("add" . "+") ("sub" . "-")
                                        ("mul" . "*") ("div" . "/"))))))
      (when (and nelisp-calc-operator (not nelisp-calc-fresh))
        (nelisp-calc-binary nelisp-calc-accumulator nelisp-calc-operator
                            nelisp-calc-display))
      (unless (equal nelisp-calc-display "ERROR")
        (setq nelisp-calc-accumulator nelisp-calc-display
              nelisp-calc-operator operator nelisp-calc-fresh t
              nelisp-calc-last-operator nil nelisp-calc-last-operand nil))))
   ((equal token "equals")
    (let ((operator (or nelisp-calc-operator nelisp-calc-last-operator))
          (operand (if nelisp-calc-operator nelisp-calc-display
                     nelisp-calc-last-operand)))
      (when operator
        (let ((left (if nelisp-calc-operator nelisp-calc-accumulator
                      nelisp-calc-display)))
          (nelisp-calc-binary left operator operand)
          (setq nelisp-calc-last-operator operator nelisp-calc-last-operand operand
                nelisp-calc-operator nil nelisp-calc-accumulator nil
                nelisp-calc-fresh t)))))
   (t (setq nelisp-calc-status "invalid-token")))
  (setq nelisp-calc-expression nelisp-calc-display)
  (list nelisp-calc-display nelisp-calc-status)))

(dolist (module '("nelisp-calc-modes.el" "nelisp-calc-graph.el" "nelisp-calc-session.el"))
  (let ((source (expand-file-name (concat "lisp/" module) nelisp-calc-root)))
    (when (file-exists-p source) (load source nil t))))

(defun nelisp-calc-token (token)
  "Route one user action and record its result once, after mode dispatch."
  (if (and (not nelisp-calc-engine-error) (fboundp 'nelisp-calc-session-token)
           (nelisp-calc-session-token token))
      (list nelisp-calc-display nelisp-calc-status)
    (let ((context (and (fboundp 'nelisp-calc-session-context) (nelisp-calc-session-context token))))
      (nelisp-calc-core-token token)
      (when (fboundp 'nelisp-calc-session-record) (nelisp-calc-session-record context))
      (list nelisp-calc-display nelisp-calc-status))))

(provide 'nelisp-calc-engine)
