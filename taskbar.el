;;; taskbar.el --- Native taskbar identity and serialized mode inbox -*- lexical-binding: t; -*-

(defun calc-taskbar-controls (program)
  "Add validated task dispatch on the GTK main loop.
The launcher publishes one complete allowlisted request at a time.  Requests
enter through emit_command, preserving the existing asynchronous engine queue."
  (let ((forms
         '((data-blob taskbar_id_env "NELISP_CALC_APP_ID\0" rodata)
           (data-blob taskbar_id "Fujisawa.NeLispCalc\0" rodata)
           (data-blob taskbar_inbox_env "NELISP_CALC_TASK_INBOX\0" rodata)
           (data-blob taskbar_receipt "taskbar-receipt.txt\0" rodata)
           (data-blob taskbar_identity_receipt "taskbar-identity.txt\0" rodata)
           (defun taskbar_identity ()
             (let ((id (extern-call getenv (data-addr taskbar_id_env))))
               (let ((wide (extern-call g_utf8_to_utf16
                             (if (= id 0) (data-addr taskbar_id) id) -1 0 0 0)))
                 (seq (if (= wide 0) 0
                        (if (= (extern-call SetCurrentProcessExplicitAppUserModelID wide) 0)
                          (let ((out (extern-call calloc 1 8)))
                            (seq (if (= (extern-call GetCurrentProcessExplicitAppUserModelID out) 0)
                                   (let ((actual (extern-call g_utf16_to_utf8 (ptr-read-u64 out 0) -1 0 0 0)))
                                     (seq (if (= actual 0) 0
                                            (extern-call g_file_set_contents (data-addr taskbar_identity_receipt) actual -1 0))
                                          (extern-call g_free actual)
                                          (extern-call CoTaskMemFree (ptr-read-u64 out 0)))) 0)
                                 (extern-call free out))) 0))
                      (extern-call g_free wide) 0))))
           (defun poll_taskbar (ctx)
             (let ((path (extern-call getenv (data-addr taskbar_inbox_env))))
               (if (or (= path 0) (>= (- (ptr-read-u64 ctx 152) (ptr-read-u64 ctx 144)) 64)) 0
                 (let ((fp (extern-call fopen path (data-addr read_mode))))
                   (if (= fp 0) 0
                     (let ((buffer (extern-call calloc 128 1)))
                       (seq (extern-call fread buffer 1 127 fp)
                            (extern-call fclose fp)
                            (extern-call remove path)
                            (if (= (taskbar_valid buffer) 1)
                              (seq (emit_command ctx buffer)
                                   (extern-call g_file_set_contents (data-addr taskbar_receipt) buffer -1 0)
                                   (if (= (extern-call getenv (data-addr hidden_env)) 0)
                                     (extern-call gtk_window_present (ptr-read-u64 ctx 3288))
                                     (navigation_snapshot ctx buffer))) 0)
                            (extern-call free buffer) 0)))))))))
        (valid 0))
    (dolist (mode '(standard scientific programmer graph date convert currency))
      (let ((id (intern (format "taskbar_mode_%s" mode))))
        (push `(data-blob ,id ,(concat "mode:" (symbol-name mode) "\0") rodata) forms)
        (setq valid `(if (= (extern-call strcmp buffer (data-addr ,id)) 0) 1 ,valid))))
    (push `(defun taskbar_valid (buffer) ,valid) forms)
    (setq program
          (mapcar (lambda (form)
                    (cond
                     ((and (eq (car-safe form) 'defun) (eq (cadr form) 'poll_response))
                      `(defun poll_response (ctx) (seq (poll_taskbar ctx) ,(nth 3 form))))
                     ((and (eq (car-safe form) 'defun) (eq (cadr form) 'main))
                      `(defun main () (seq (taskbar_identity)
                        ,(cl-subst '(seq (poll_taskbar ctx) (extern-call g_timeout_add 100 (addr-of poll_response) ctx))
                                   '(extern-call g_timeout_add 100 (addr-of poll_response) ctx)
                                   (nth 3 form) :test #'equal))))
                     (t form))) program))
    (append program (nreverse forms))))

(provide 'calc-taskbar)
;;; taskbar.el ends here
