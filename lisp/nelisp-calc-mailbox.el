;;; nelisp-calc-mailbox.el --- Persistent mailbox entry -*- lexical-binding: t; -*-

(load (expand-file-name "nelisp-calc-engine.el"
                        (file-name-directory (replace-regexp-in-string "\\\\" "/" load-file-name t t))) nil t)
(defvar nelisp-calc-target
  (or (getenv "NELISP_CALC_TARGET") (expand-file-name "target" nelisp-calc-root)))
(defvar nelisp-calc-request-count 0)

(defun nelisp-calc-ascii-line (value)
  "Keep mailbox fields single-line ASCII."
  (replace-regexp-in-string "[^ -~]" "?" value))

(defun nelisp-calc-write-response ()
  "Atomically publish display, status and processed request count."
  (let ((temporary (expand-file-name "response.tmp" nelisp-calc-target))
        (destination (expand-file-name "response.txt" nelisp-calc-target)))
    (with-temp-buffer
      (insert (nelisp-calc-ascii-line nelisp-calc-display) "\n"
              (nelisp-calc-ascii-line nelisp-calc-status) "\n"
              (number-to-string nelisp-calc-request-count) "\n")
      (write-region (point-min) (point-max) temporary nil 'silent))
    (let ((published nil) (attempt 0))
      (while (not published)
        (condition-case err
            (progn (rename-file temporary destination t) (setq published t))
          (file-error
           (setq attempt (1+ attempt))
           (when (>= attempt 40) (signal (car err) (cdr err)))
           ;; Retain the already computed response; never replay its token.
           (accept-process-output nil 0.05)))))))

(defun nelisp-calc-poll ()
  "Process complete appended request lines, leaving partial lines pending."
  (let ((request (expand-file-name "requests.txt" nelisp-calc-target)))
    (when (file-exists-p request)
      (with-temp-buffer
        (insert-file-contents request)
        (goto-char (point-min))
        (let ((index 0))
          (while (search-forward "\n" nil t)
            (setq index (1+ index))
            (when (> index nelisp-calc-request-count)
              (let ((end (1- (point))))
                (beginning-of-line 0)
                (let ((token (buffer-substring-no-properties (point) end)))
                  (goto-char (1+ end))
                  (condition-case err (nelisp-calc-token token)
                    (error (setq nelisp-calc-display "ERROR"
                                 nelisp-calc-status (prin1-to-string err))))))
              (setq nelisp-calc-request-count index)
              (nelisp-calc-write-response))))))))

(make-directory nelisp-calc-target t)
(nelisp-calc-initialize)
(nelisp-calc-write-response)
(while (not (file-exists-p (expand-file-name "stop" nelisp-calc-target)))
  (nelisp-calc-poll)
  ;; NeLisp currently has no sleep-for; this real primitive waits 50 ms.
  (accept-process-output nil 0.05))
