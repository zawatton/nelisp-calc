param([ValidateSet('Standalone','Host')][string]$Mode = 'Standalone')
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$target = Join-Path $project 'target'
New-Item -ItemType Directory -Force $target | Out-Null
$test = Join-Path $project 'test/session-test.el'
$runtime = if ($Mode -eq 'Host') { (Get-Command emacs).Source } else { Join-Path (Split-Path $project -Parent) 'nelisp/target/nelisp.exe' }
$arguments = if ($Mode -eq 'Host') { @('-Q','--batch','-l', ('"' + $test + '"')) } else { @('--load', ('"' + $test + '"')) }
$log = Join-Path $target ('session-' + $Mode + '.log')
$stderr = Join-Path $target ('session-' + $Mode + '.stderr')
$clock = [Diagnostics.Stopwatch]::StartNew()
$process = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
$null = $process.Handle
if (!$process.WaitForExit(55000)) { $process.Kill(); $process.WaitForExit(); throw 'Session probe exceeded55 seconds' }
$clock.Stop()
Write-Output ('SESSION-ELAPSED-SECONDS:' + $clock.Elapsed.TotalSeconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))
Get-Content $log -Tail 4
Get-Content $stderr -Tail 4
if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) { throw 'Session process failed' }
if (!(Select-String -Path $log -Pattern '^SESSION-PASS:68$' -Quiet)) { throw 'Missing session completion sentinel (41 original +27 multiple-memory checks)' }
