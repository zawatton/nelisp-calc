;;; nelisp-calc-compat.el --- Standalone Calc prerequisites -*- lexical-binding: t; -*-

(defvar nelisp-calc-compat-original-expt nil)
(defvar nelisp-calc-compat-original-store-binding nil)
(defvar nelisp-calc-compat-isqrt-origin nil)
(defvar nelisp-calc-compat-original-divide nil)
(defvar nelisp-calc-compat-original-remainder nil)
(defvar nelisp-calc-compat-original-mod nil)

;; GNU's preloaded macro-execution state is nil outside keyboard playback.
;; This headless adapter has no keyboard-macro playback loop.
(defvar executing-kbd-macro nil)

(defun nelisp-calc-compat-divmod (dividend divisor)
  "Return exact integer quotient and remainder, truncating toward zero."
  (unless (and (integerp dividend) (integerp divisor))
    (signal 'wrong-type-argument (list 'integerp (if (integerp dividend) divisor dividend))))
  (when (= divisor 0) (signal 'arith-error nil))
  (let* ((remainder (abs dividend)) (denominator (abs divisor))
         (shift (max 0 (- (logb (max 1 remainder)) (logb denominator))))
         (scaled (ash denominator shift)) (bit (ash 1 shift)) (quotient 0))
    (while (> bit 0)
      (when (>= remainder scaled)
        (setq remainder (- remainder scaled) quotient (+ quotient bit)))
      (setq scaled (ash scaled -1) bit (ash bit -1)))
    (cons (if (eq (< dividend 0) (< divisor 0)) quotient (- quotient))
          (if (< dividend 0) (- remainder) remainder))))

(defun nelisp-calc-compat-divide (&rest operands)
  "Preserve runtime division, extending unsupported exact integer divisors."
  (condition-case err
      (apply nelisp-calc-compat-original-divide operands)
    (nelisp-bignum-division-unsupported
     (let ((result (car operands)))
       (dolist (divisor (cdr operands))
         (setq result (car (nelisp-calc-compat-divmod result divisor))))
       result))))

(defun nelisp-calc-compat-remainder (dividend divisor)
  "Preserve runtime remainder, extending unsupported integer divisors."
  (condition-case err
      (funcall nelisp-calc-compat-original-remainder dividend divisor)
    (nelisp-bignum-division-unsupported
     (cdr (nelisp-calc-compat-divmod dividend divisor)))))

(defun nelisp-calc-compat-mod (dividend divisor)
  "Preserve runtime modulus, extending unsupported integer divisors."
  (condition-case err
      (funcall nelisp-calc-compat-original-mod dividend divisor)
    (nelisp-bignum-division-unsupported
     (let ((remainder (cdr (nelisp-calc-compat-divmod dividend divisor))))
       (if (and (/= remainder 0) (not (eq (< remainder 0) (< divisor 0))))
           (+ remainder divisor) remainder)))))

(defun nelisp-calc-compat-load-isqrt (source)
  "Load only the genuine cl-isqrt definition from unmodified SOURCE.
Record hashes of the source file and exact definition text.  This does
not load or provide the cl-extra feature or evaluate its initialization."
  (unless nelisp-calc-compat-isqrt-origin
    (with-temp-buffer
      (insert-file-contents source)
      (let ((file-hash (secure-hash 'sha256 (buffer-string)))
            form start end found)
        (goto-char (point-min))
        (when (search-forward "(defun cl-isqrt " nil t)
          (goto-char (- (point) (length "(defun cl-isqrt ")))
          (setq start (point))
          (setq form (read (current-buffer)))
          (setq end (point))
          (when (and (eq (car-safe form) 'defun)
                     (eq (nth 1 form) 'cl-isqrt))
            (eval form t)
            (setq found t
                  nelisp-calc-compat-isqrt-origin
                  (list :source source :source-sha256 file-hash
                        :definition-sha256
                        (secure-hash 'sha256 (buffer-substring-no-properties start end))))))
        (unless found (error "GNU cl-isqrt definition missing in %s" source))))))

(defun nelisp-calc-compat-expt (base exponent)
  "Preserve exact integer powers; delegate other cases to the runtime."
  (if (and (integerp base) (integerp exponent) (>= exponent 0))
      (let ((result 1) (factor base) (remaining exponent))
        (while (> remaining 0)
          (when (= (% remaining 2) 1) (setq result (* result factor)))
          (setq remaining (/ remaining 2))
          (when (> remaining 0) (setq factor (* factor factor))))
        result)
    (funcall nelisp-calc-compat-original-expt base exponent)))

(defun nelisp-calc-compat-store-binding (keymap event definition remove)
  "Keep a dense KEYMAP's character table before its sparse bindings."
  (let* ((slot (car (emacs-keymap--tail-state keymap event)))
         (result (funcall nelisp-calc-compat-original-store-binding keymap event definition remove)))
    ;; Explicit nil cells shadow inherited bindings and must be preserved.
    ;; The provider currently prepends these cells before a full map's table.
    (when (and slot (not (eq slot (nth 1 keymap))))
      (setcdr keymap (cons slot (delq slot (cdr keymap)))))
    result))

(defun nelisp-calc-compat-install (root)
  "Load existing keymap providers and install bounded compatibility fixes."
  (when (fboundp 'nl-write-file)
    (unless nelisp-calc-compat-original-divide
      (setq nelisp-calc-compat-original-divide (symbol-function '/)
            nelisp-calc-compat-original-remainder (symbol-function '%)
            nelisp-calc-compat-original-mod (symbol-function 'mod))
      (fset '/ #'nelisp-calc-compat-divide)
      (fset '% #'nelisp-calc-compat-remainder)
      (fset 'mod #'nelisp-calc-compat-mod))
    (unless nelisp-calc-compat-original-expt
      (setq nelisp-calc-compat-original-expt (symbol-function 'expt))
      (fset 'expt #'nelisp-calc-compat-expt))
    (unless nelisp-calc-compat-original-store-binding
      (let ((provider (expand-file-name "../nelisp/packages/nelisp-emacs-core/src" root)))
        (add-to-list 'load-path provider)
        (load (expand-file-name "emacs-keymap-builtins.el" provider) nil t))
      (setq nelisp-calc-compat-original-store-binding
            (symbol-function 'emacs-keymap-builtins--store-binding))
      (fset 'emacs-keymap-builtins--store-binding #'nelisp-calc-compat-store-binding)
      ;; GNU's preloaded ESC map is full.  NeLisp's bootstrap creates a
      ;; sparse ESC map; promote its representation without losing bindings.
      (unless (car (emacs-keymap--tail-state esc-map ?x))
        (setcdr esc-map (cons (nth 1 (make-keymap)) (cdr esc-map)))))))

(provide 'nelisp-calc-compat)
