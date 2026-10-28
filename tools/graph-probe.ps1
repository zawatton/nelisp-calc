param([ValidateSet('Standalone','Host')][string]$Mode = 'Standalone')
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$target = Join-Path $project 'target'
New-Item -ItemType Directory -Force $target | Out-Null
$test = Join-Path $project 'test/graph-test.el'
$runtime = if ($Mode -eq 'Host') { (Get-Command emacs).Source } else { Join-Path (Split-Path $project -Parent) 'nelisp/target/nelisp.exe' }
$argsList = if ($Mode -eq 'Host') { @('-Q','--batch','-l', ('"' + $test + '"')) } else { @('--load', ('"' + $test + '"')) }
$log = Join-Path $target ('graph-' + $Mode + '.log')
$stderr = Join-Path $target ('graph-' + $Mode + '.stderr')
$clock = [Diagnostics.Stopwatch]::StartNew()
$oldToday = $env:NELISP_CALC_TODAY
try {
    $env:NELISP_CALC_TODAY = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
    $process = Start-Process -FilePath $runtime -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
} finally { $env:NELISP_CALC_TODAY = $oldToday }
$null = $process.Handle
if (!$process.WaitForExit(55000)) { $process.Kill(); $process.WaitForExit(); throw 'Graph probe exceeded 55 seconds' }
$clock.Stop()
Write-Output ('GRAPH-ELAPSED-SECONDS:' + $clock.Elapsed.TotalSeconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))
Get-Content $log -Tail 4
Get-Content $stderr -Tail 4
if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) { throw 'Graph process failed' }
if (!(Select-String -Path $log -SimpleMatch 'GRAPH-PASS:16' -Quiet)) { throw 'Missing graph completion sentinel' }
