;;; nelisp-calc.el --- Launch the native calculator -*- lexical-binding: t; -*-

(defgroup nelisp-calc nil "Native NeLisp calculator launcher." :group 'external)

(defcustom nelisp-calc-project-root nil
  "Calculator checkout or portable app directory, or nil to infer it."
  :type '(choice (const nil) directory))

(defconst nelisp-calc--module-file (or load-file-name buffer-file-name))
(defvar nelisp-calc--process nil)

(defun nelisp-calc--root ()
  "Resolve the application root without loading its calculation engine."
  (file-name-as-directory
   (expand-file-name
    (or nelisp-calc-project-root
        (let ((module (or nelisp-calc--module-file
                          (locate-library "nelisp-calc"))))
          (unless module (user-error "Cannot locate nelisp-calc.el"))
          (expand-file-name ".." (file-name-directory module)))))))

(defun nelisp-calc--sentinel (process _event)
  "Report a failed launcher PROCESS without displaying its buffer."
  (when (memq (process-status process) '(exit signal))
    (if (zerop (process-exit-status process))
        (message "NeLisp Calc launcher finished")
      (let ((buffer (process-buffer process)))
        (if (buffer-live-p buffer)
            (message "NeLisp Calc launch failed; see %s" (buffer-name buffer))
          (message "NeLisp Calc launch failed; launcher output buffer was closed"))))))

;;;###autoload
(defun nelisp-calc ()
  "Show the native calculator asynchronously, preserving an existing session."
  (interactive)
    (let* ((owner-live (and (processp nelisp-calc--process)
                            (process-live-p nelisp-calc--process)))
           (root (nelisp-calc--root))
           (helper (expand-file-name "tools/emacs-launch.ps1" root))
           (shell (or (executable-find "pwsh.exe")
                      (executable-find "powershell.exe")
                      (user-error "PowerShell is unavailable")))
           (buffer (get-buffer-create (if owner-live " *NeLisp Calc activation*"
                                       " *NeLisp Calc launcher*")))
           (default-directory root)
           (w32-start-process-show-window nil))
      (unless (file-regular-p helper)
        (user-error "NeLisp Calc launcher is missing: %s" helper))
      (with-current-buffer buffer (erase-buffer))
      (condition-case err
          (let ((request (make-process
                 :name "nelisp-calc-launcher" :buffer buffer :noquery t
                 :connection-type 'pipe :sentinel #'nelisp-calc--sentinel
                 :command (list shell "-NoProfile" "-NonInteractive"
                                "-WindowStyle" "Hidden" "-ExecutionPolicy" "Bypass"
                                "-File" helper "-ProjectRoot" root "-Activate"))))
            (unless owner-live (setq nelisp-calc--process request)))
        (error
         (with-current-buffer buffer (insert (error-message-string err)))
         (user-error "NeLisp Calc launch failed: %s" (error-message-string err))))
      (message "NeLisp Calc display requested"))
  nelisp-calc--process)

(provide 'nelisp-calc)
;;; nelisp-calc.el ends here
