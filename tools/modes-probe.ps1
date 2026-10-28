param([ValidateSet('Standalone','Host')][string]$Mode = 'Standalone')
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$target = Join-Path $project 'target'
New-Item -ItemType Directory -Force $target | Out-Null
$test = Join-Path $project 'test/modes-test.el'
$runtime = if ($Mode -eq 'Host') { (Get-Command emacs).Source } else { Join-Path (Split-Path $project -Parent) 'nelisp/target/nelisp.exe' }
$argsList = if ($Mode -eq 'Host') { @('-Q','--batch','-l', ('"' + $test + '"')) } else { @('--load', ('"' + $test + '"')) }
$log = Join-Path $target ('modes-' + $Mode + '.log')
$stderr = Join-Path $target ('modes-' + $Mode + '.stderr')
$process = Start-Process -FilePath $runtime -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
$null = $process.Handle
if (!$process.WaitForExit(25000)) { $process.Kill(); throw 'Modes probe exceeded 25 seconds' }
Get-Content $log -Tail 5
Get-Content $stderr -Tail 5
if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) { throw 'Modes process failed' }
if (!(Select-String -Path $log -SimpleMatch 'MODES-PASS:26' -Quiet)) { throw 'Missing mode completion sentinel' }
