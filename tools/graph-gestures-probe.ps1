param([ValidateSet('Standalone','Host')][string]$Mode = 'Standalone')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$test = Join-Path $root 'test/graph-gestures-test.el'
$runtime = if ($Mode -eq 'Host') { (Get-Command emacs).Source } else { Join-Path (Split-Path $root -Parent) 'nelisp/target/nelisp.exe' }
$log = Join-Path $root ('target/gestures-' + $Mode + '.log')
$stderr = Join-Path $root ('target/gestures-' + $Mode + '.stderr')
$arguments = if ($Mode -eq 'Host') { @('-Q','--batch','-l', ('"'+$test+'"')) } else { @('--load', ('"'+$test+'"')) }
$process = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
$null = $process.Handle
if (-not $process.WaitForExit(90000)) { $process.Kill(); $process.WaitForExit(); throw 'Gesture core probe exceeded 90 seconds' }
Get-Content $log -Tail 2
if ($process.ExitCode -ne 0 -or -not (Select-String -Path $log -SimpleMatch 'GESTURES-PASS:28' -Quiet)) { Get-Content $stderr -Tail 5; throw 'Gesture core probe failed' }
