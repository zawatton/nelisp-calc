;;; nelisp-calc-mailbox.el --- Persistent mailbox entry -*- lexical-binding: t; -*-

(load (expand-file-name "nelisp-calc-engine.el"
                        (file-name-directory (replace-regexp-in-string "\\\\" "/" load-file-name t t))) nil t)
(defvar nelisp-calc-target
  (or (getenv "NELISP_CALC_TARGET") (expand-file-name "target" nelisp-calc-root)))
(defvar nelisp-calc-request-count 0)
(defvar nelisp-calc-request-size 0)
(defvar nelisp-calc-request-file nil)
(defvar nelisp-process-adapter--poll-quantum)

(defun nelisp-calc-idle-wait ()
  "Wait one mailbox interval, pumping registered processes and timers."
  (if (and (boundp 'nelisp-process-adapter--live)
           (null nelisp-process-adapter--live)
           (boundp 'nelisp-async-core--timers)
           (null nelisp-async-core--timers)
           (fboundp 'nelisp-async-core--nanosleep))
      ;; No callback can become ready in this single-threaded runtime until
      ;; Lisp runs again.  Avoid building the general adapter wait machinery.
      (nelisp-async-core--nanosleep 0.1)
    (let ((nelisp-process-adapter--poll-quantum 0.1))
      (accept-process-output nil 0.1))))

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
  "Process complete appended request lines, leaving partial lines pending.
The request file is append-only: truncation is rejected and same-size
replacement is unsupported.  Unchanged polls only inspect file metadata."
  (let* ((request (or nelisp-calc-request-file
                      (setq nelisp-calc-request-file
                            (expand-file-name "requests.txt" nelisp-calc-target))))
         (attributes (file-attributes request))
         (size (if attributes (nth 7 attributes) 0)))
    (when (< size nelisp-calc-request-size)
      (error "Calculator request mailbox was truncated"))
    (when (> size nelisp-calc-request-size)
      (with-temp-buffer
        (insert-file-contents request)
        (goto-char (point-min))
        (let ((index 0))
          (while (search-forward "\n" nil t)
            (setq index (1+ index))
            (when (> index nelisp-calc-request-count)
              (let ((end (1- (point))))
                (beginning-of-line 0)
                (let ((token (replace-regexp-in-string
                              "\r$" "" (buffer-substring-no-properties (point) end))))
                  (goto-char (1+ end))
                  (condition-case err (nelisp-calc-token token)
                    (error (setq nelisp-calc-display "ERROR"
                                 nelisp-calc-status (prin1-to-string err))))))
              (setq nelisp-calc-request-count index)
              (nelisp-calc-write-response)))))
      ;; Cache the pre-read size only after success.  An append racing with
      ;; the read causes another read next poll, with acknowledged lines skipped.
      (setq nelisp-calc-request-size size))))

(make-directory nelisp-calc-target t)
(nelisp-calc-initialize-owned-backend t)
(nelisp-calc-write-response)
(let ((stop-file (expand-file-name "stop" nelisp-calc-target)))
 (while (not (file-exists-p stop-file))
  (nelisp-calc-poll)
  ;; Match the mailbox and adapter waits to the GUI's 100 ms polling interval.
  ;; Timer deadlines still shorten the wait; extra process-pump passes add no
  ;; mailbox responsiveness while this synchronous call is waiting.
  (nelisp-calc-idle-wait)))
