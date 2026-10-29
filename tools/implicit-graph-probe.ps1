param([ValidateSet('Standalone','Host')][string]$Mode = 'Standalone')
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$target = Join-Path $project 'target'
New-Item -ItemType Directory -Force $target | Out-Null
$runtime = if ($Mode -eq 'Host') { (Get-Command emacs).Source } else { Join-Path (Split-Path $project -Parent) 'nelisp/target/nelisp.exe' }
$test = Join-Path $project 'test/implicit-graph-test.el'
$arguments = if ($Mode -eq 'Host') { @('-Q','--batch','-l', ('"' + $test + '"')) } else { @('--load', ('"' + $test + '"')) }
$log = Join-Path $target ('implicit-' + $Mode + '.log')
$stderr = Join-Path $target ('implicit-' + $Mode + '.stderr')
$process = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
$null = $process.Handle
if (!$process.WaitForExit(240000)) { $process.Kill(); $process.WaitForExit(); throw 'Implicit probe exceeded 240 seconds' }
Get-Content $log -Tail 3
Get-Content $stderr -Tail 3
if ($process.ExitCode -ne 0 -or !(Select-String -Path $log -SimpleMatch 'IMPLICIT-PASS:21' -Quiet)) { throw 'Implicit acceptance failed' }
