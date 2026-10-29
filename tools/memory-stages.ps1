param([string]$Runtime, [switch]$Profile, [string]$Source, [switch]$BoundaryGc, [switch]$LowGc, [switch]$Preload, [switch]$NativeGc, [switch]$OwnedGc)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (!$Source) { $Source = Join-Path $root 'lisp/nelisp-calc-engine.el' }
$session = Join-Path $root ('target/memory-stages-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $session | Out-Null
$engine = [IO.File]::ReadAllText($Source)
$sourceHash = (Get-FileHash $Source).Hash
if ($Preload) {
    $engine = $engine.Replace('(nelisp-calc-compat-install nelisp-calc-root)', '(add-to-list ''load-path (expand-file-name "../nelisp/packages/nelisp-emacs-core/src" nelisp-calc-root)) (dolist (feature ''(emacs-list cl-lib emacs-char-table emacs-subr-extras emacs-keymap)) (require feature) (garbage-collect)) (nelisp-calc-compat-install nelisp-calc-root) (garbage-collect)')
    $engine = $engine.Replace("(require 'calc)", "(require 'calc-macs) (garbage-collect) (require 'rect) (garbage-collect) (require 'calc)")
}
if ($BoundaryGc) {
    $engine = $engine.Replace('(nelisp-calc-compat-install nelisp-calc-root)', '(nelisp-calc-compat-install nelisp-calc-root) (garbage-collect)')
    $engine = $engine.Replace("(require 'calc)", "(require 'calc) (garbage-collect)")
}
if ($Profile) {
    $compat = [IO.File]::ReadAllText((Join-Path $root 'lisp/nelisp-calc-compat.el'))
    $compat = $compat.Replace('(setq nelisp-calc-compat-original-store-binding', '(memory-stage "keymap-provider") (setq nelisp-calc-compat-original-store-binding')
    [IO.File]::WriteAllText((Join-Path $session 'compat.el'), $compat)
    $engine = $engine.Replace('(expand-file-name "lisp/nelisp-calc-compat.el" nelisp-calc-root)', '(expand-file-name "compat.el" (getenv "MEMORY_SESSION"))')
    $engine = $engine.Replace('(nelisp-calc-compat-install nelisp-calc-root)', '(nelisp-calc-compat-install nelisp-calc-root) (memory-stage "compat")')
    $engine = [regex]::Replace($engine, "\(require '(calc(?:-[a-z]+)?)\)", { param($m) $m.Value + ' (memory-stage "' + $m.Groups[1].Value + '")' }, 0)
}
[IO.File]::WriteAllText((Join-Path $session 'engine.el'), $engine)
$script = @'
(setq nelisp-calc-root (getenv "MEMORY_ROOT"))
(defun memory-stage (name)
  (let ((path (expand-file-name name (getenv "MEMORY_SESSION"))))
    (write-region (prin1-to-string (list :arena (if (fboundp 'nelisp--arena-stats) (nelisp--arena-stats) nil) :gc (if (fboundp 'nelisp--gc-diag) (nelisp--gc-diag 0) nil))) nil path nil 'silent)
    (while (not (file-exists-p (concat path ".go"))) (accept-process-output nil 0.02))))
(memory-stage "bare")
(load (expand-file-name "engine.el" (getenv "MEMORY_SESSION")) nil t)
(nelisp-calc-initialize)
(when nelisp-calc-engine-error (error "%s" nelisp-calc-engine-error))
(memory-stage "startup")
(dolist (token '("mode:standard" "mode:standard" "1" "add" "1" "clear" "clear" "1" "add" "1" "equals" "backspace" "backspace" "backspace")) (nelisp-calc-token token))
(unless (equal nelisp-calc-display "2") (error "History mismatch"))
(memory-stage "history")
(dolist (case '(("sin(30)" "0.5") ("5!" "120") ("sqrt(2)" "1.41421356237")))
  (let ((result (nelisp-calc-evaluate (car case))))
    (unless (equal (plist-get result :value) (cadr case)) (error "First science failed: %S" result))))
(memory-stage "science")
(garbage-collect)
(memory-stage "gc")
(princ "MEMORY-STAGES-PASS\n")
'@
[IO.File]::WriteAllText((Join-Path $session 'probe.el'), $script)
if ($OwnedGc) {
    $script = $script.Replace('(nelisp-calc-initialize)', '(nelisp-calc-initialize-owned-backend t)')
    [IO.File]::WriteAllText((Join-Path $session 'probe.el'), $script)
}
if ($NativeGc) {
    $script = $script.Replace('(nelisp-calc-initialize)', '(unwind-protect (progn (nelisp--debug-switch 30 4194304) (nelisp--debug-switch 31 100) (nelisp-calc-initialize)) (nelisp--debug-switch 30 0) (nelisp--debug-switch 31 0))')
    [IO.File]::WriteAllText((Join-Path $session 'probe.el'), $script)
}
if ($LowGc) { [IO.File]::WriteAllText((Join-Path $session 'probe.el'), "(setq gc-cons-threshold 800000 gc-cons-percentage 0.1)`n" + $script) }
$oldRoot = $env:MEMORY_ROOT; $oldSession = $env:MEMORY_SESSION
$oldPolicy = $env:NELISP_CALC_NATIVE_GC_POLICY
if ($OwnedGc) { $env:NELISP_CALC_NATIVE_GC_POLICY = 'debt-v1' }
$env:MEMORY_ROOT = $root; $env:MEMORY_SESSION = $session
$p = $null; $rows = @(); $seen = @{}
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    $p = Start-Process -FilePath $Runtime -ArgumentList @('--load', ('"' + (Join-Path $session 'probe.el') + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $session 'stdout') -RedirectStandardError (Join-Path $session 'stderr')
    $null = $p.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(80)
    while (!$p.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        foreach ($f in Get-ChildItem $session -File) {
            if ($f.Name -in @('bare','keymap-provider','compat','startup','history','science','gc','calc','calc-aent','calc-misc','calc-ext','calc-arith','calc-math','calc-comb') -and !$seen.ContainsKey($f.Name)) {
                $q = Get-Process -Id $p.Id
                $rows += [ordered]@{stage=$f.Name; elapsedSeconds=$watch.Elapsed.TotalSeconds; privateMiB=$q.PrivateMemorySize64/1MB; workingMiB=$q.WorkingSet64/1MB; cpu=$q.CPU; arena=[IO.File]::ReadAllText($f.FullName)}
                $seen[$f.Name] = $true
                [IO.File]::WriteAllText(($f.FullName + '.go'), '')
            }
        }
        Start-Sleep -Milliseconds 20
    }
    if (!$p.HasExited) { throw 'Stage timeout' }
    $report = @{session=$session; sourceSha256=(Get-FileHash $Source).Hash; generatedSourceSha256=(Get-FileHash (Join-Path $session 'engine.el')).Hash; probeSha256=(Get-FileHash (Join-Path $session 'probe.el')).Hash; runtimeSha256=(Get-FileHash $Runtime).Hash; profile=[bool]$Profile; nativeGc=[bool]$NativeGc; boundaryGc=[bool]$BoundaryGc; lowGc=[bool]$LowGc; preload=[bool]$Preload; rows=$rows; exitCode=$p.ExitCode; stderr=[IO.File]::ReadAllText((Join-Path $session 'stderr')); stdout=[IO.File]::ReadAllText((Join-Path $session 'stdout'))}
    $report.sourceSha256 = $sourceHash
    $report.ownedGc = [bool]$OwnedGc
    $report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $session 'report.json')
    $report | ConvertTo-Json -Depth 6 -Compress
    if ($p.ExitCode -ne 0 -or $report.stdout -notmatch 'MEMORY-STAGES-PASS') { throw 'Stage probe failed' }
} finally {
    if ($p -and !$p.HasExited) { $p.Kill(); $p.WaitForExit() }
    $env:MEMORY_ROOT=$oldRoot; $env:MEMORY_SESSION=$oldSession
    $env:NELISP_CALC_NATIVE_GC_POLICY=$oldPolicy
}
