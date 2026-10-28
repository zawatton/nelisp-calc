;;; nelisp-calc-session.el --- Per-instance memory and user history -*- lexical-binding: t; -*-

(defvar nelisp-calc-session-directory nil)
(defvar nelisp-calc-session-memory nil)
(defvar nelisp-calc-session-history nil)
(defconst nelisp-calc-session-history-limit 100)

(defun nelisp-calc-session-write (name text)
  "Publish one complete ASCII session snapshot."
  (let* ((path (expand-file-name name nelisp-calc-session-directory)) (temporary (concat path ".tmp")))
    (make-directory nelisp-calc-session-directory t)
    (let ((coding-system-for-write 'us-ascii)) (with-temp-file temporary (insert text)))
    (rename-file temporary path t)))
(defun nelisp-calc-session-publish ()
  (nelisp-calc-session-write "memory.txt" (if nelisp-calc-session-memory (concat nelisp-calc-session-memory "\n") ""))
  (let ((index 0) (text ""))
    (dolist (entry nelisp-calc-session-history)
      (setq text (concat text (format "%d\t%s\t%s\n" index (car entry) (cdr entry))) index (1+ index)))
    (nelisp-calc-session-write "history.txt" text)))
(defun nelisp-calc-session-ensure ()
  "Reset state when switching instance targets; never import another session."
  (let ((directory (expand-file-name (or (getenv "NELISP_CALC_TARGET") (expand-file-name "target" nelisp-calc-root)))))
    (unless (equal directory nelisp-calc-session-directory)
      (setq nelisp-calc-session-directory directory nelisp-calc-session-memory nil nelisp-calc-session-history nil)
      (nelisp-calc-session-publish))))
(defun nelisp-calc-session-mode ()
  (if (symbolp nelisp-calc-mode) (symbol-name nelisp-calc-mode) nelisp-calc-mode))
(defun nelisp-calc-session-entry (value)
  "Recall VALUE into the active numeric entry without executing an operation."
  (let ((mode (nelisp-calc-session-mode)))
    (cond ((member mode '("standard" "scientific"))
           (setq nelisp-calc-display value nelisp-calc-expression value nelisp-calc-fresh nil))
          ((equal mode "convert") (setq nelisp-calc-modes-input value nelisp-calc-display value nelisp-calc-modes-fresh nil))
          ((equal mode "currency") (setq nelisp-calc-currency-input value nelisp-calc-display value nelisp-calc-currency-fresh nil))
          (t (error "Recall requires Standard, Scientific, Converter or Currency mode"))))
  (setq nelisp-calc-status "session:recalled"))
(defun nelisp-calc-session-number (expression)
  (let ((result (nelisp-calc-evaluate expression)))
    (unless (plist-get result :ok) (error "Calc memory operation: %s" (plist-get result :error)))
    (let ((value (plist-get result :value)))
      (unless (string-match "\\`[-+]?[0-9]+\\(?:\\.[0-9]*\\)?\\(?:[eE][-+]?[0-9]+\\)?\\'" value)
        (error "A real decimal entry is required")) value)))
;;;###autoload
(defun nelisp-calc-session-token (token)
  "Handle the single memory slot and newest-first history indices."
  (when (or (string-prefix-p "memory:" token) (string-prefix-p "history:" token))
    (condition-case err
        (progn
          (nelisp-calc-session-ensure)
          (cond
           ((equal token "memory:clear") (setq nelisp-calc-session-memory nil nelisp-calc-status "memory:empty"))
           ((equal token "history:clear") (setq nelisp-calc-session-history nil nelisp-calc-status "history:empty"))
           ((equal token "memory:recall")
            (unless nelisp-calc-session-memory (error "Memory is empty"))
            (nelisp-calc-session-entry nelisp-calc-session-memory))
           ((string-match "\\`history:recall:\\([0-9]+\\)\\'" token)
            (let ((entry (nth (string-to-number (match-string 1 token)) nelisp-calc-session-history)))
              (unless entry (error "History index absent"))
              (nelisp-calc-session-entry (nelisp-calc-session-number (cdr entry)))))
           ((member token '("memory:store" "memory:add" "memory:sub"))
            (unless (member (nelisp-calc-session-mode) '("standard" "scientific" "convert" "currency"))
              (error "Numeric memory requires Standard, Scientific, Converter or Currency mode"))
            (let* ((entry (nelisp-calc-session-number nelisp-calc-display))
                   (expression (if (equal token "memory:store") entry
                                 (concat "(" (or nelisp-calc-session-memory "0") ")"
                                         (if (equal token "memory:add") "+" "-") "(" entry ")"))))
              (setq nelisp-calc-session-memory (nelisp-calc-session-number expression)
                    nelisp-calc-status "memory:stored")))
           (t (error "Unknown session token")))
          (nelisp-calc-session-publish))
      (error (setq nelisp-calc-display "ERROR" nelisp-calc-status (concat "session-error:" (error-message-string err)))))
    t))
(defun nelisp-calc-session-context (token)
  "Capture user-level result intent before the core mutates its input.
Only the public token boundary records history; internal Calc evaluations,
including graph samples and memory arithmetic, never enter this hook."
  (let ((mode (nelisp-calc-session-mode)))
    (cond
     ((and (member mode '("standard" "scientific")) (string-prefix-p "eval:" token)) (substring token 5))
     ((string-prefix-p "function:" token) (concat (substring token 9) "(" nelisp-calc-display ")"))
     ((and (equal mode "standard")
           (or (and (member token '("add" "sub" "mul" "div")) nelisp-calc-operator (not nelisp-calc-fresh))
               (and (member token '("equals" "=")) (or nelisp-calc-operator nelisp-calc-last-operator))))
      (concat (or nelisp-calc-accumulator nelisp-calc-display) " "
              (or nelisp-calc-operator nelisp-calc-last-operator) " "
              (if nelisp-calc-operator nelisp-calc-display nelisp-calc-last-operand)))
     ((member token '("equals" "="))
      (cond ((equal mode "scientific") nelisp-calc-display)
            ((equal mode "convert") (format "%s %s -> %s" nelisp-calc-modes-input nelisp-calc-convert-from nelisp-calc-convert-to))
            ((equal mode "currency") (format "%s %s -> %s" nelisp-calc-currency-input nelisp-calc-currency-from nelisp-calc-currency-to))
            ((equal mode "programmer") (and nelisp-calc-prog-left (format "programmer[%d,%d]:%s %s %s" nelisp-calc-prog-base nelisp-calc-prog-width (nelisp-calc-bits-format nelisp-calc-prog-left) nelisp-calc-prog-op nelisp-calc-modes-input))))))))
(defun nelisp-calc-session-record (expression)
  "Record one successful user action, retaining at most 100 entries."
  (when (and expression (not (member nelisp-calc-display '("ERROR" "ENGINE UNAVAILABLE")))
             (not (string-match "error\\|invalid\\|unavailable" nelisp-calc-status)))
    (nelisp-calc-session-ensure)
    (let ((entry (cons (replace-regexp-in-string "[\t\r\n]" " " expression)
                       (replace-regexp-in-string "[\t\r\n]" " " nelisp-calc-display))))
      (setq nelisp-calc-session-history (cons entry nelisp-calc-session-history))
      (when (> (length nelisp-calc-session-history) nelisp-calc-session-history-limit)
        (setcdr (nthcdr (1- nelisp-calc-session-history-limit) nelisp-calc-session-history) nil)))
    (nelisp-calc-session-publish)))
(provide 'nelisp-calc-session)
