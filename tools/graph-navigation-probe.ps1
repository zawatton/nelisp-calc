param([ValidateSet('Standalone','Host')][string]$Mode = 'Standalone')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/navigation-probes/' + $Mode + '-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact -Force | Out-Null
$runtime = if ($Mode -eq 'Host') { (Get-Command emacs).Source } else { Join-Path (Split-Path $root -Parent) 'nelisp/target/nelisp.exe' }
$test = Join-Path $root 'test/graph-navigation-test.el'
$arguments = if ($Mode -eq 'Host') { @('-Q','--batch','-l', ('"' + $test + '"')) } else { @('--load', ('"' + $test + '"')) }
$savedTarget = $env:NAVIGATION_TARGET
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    $env:NAVIGATION_TARGET = $artifact
    $process = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $artifact 'stdout.log') -RedirectStandardError (Join-Path $artifact 'stderr.log')
} finally { $env:NAVIGATION_TARGET = $savedTarget }
$null = $process.Handle
if (-not $process.WaitForExit(120000)) { $process.Kill(); $process.WaitForExit(); throw 'Navigation probe exceeded 120 seconds' }
$clock.Stop()
Get-Content (Join-Path $artifact 'stdout.log') -Tail 7
if ($process.ExitCode -ne 0) { Get-Content (Join-Path $artifact 'stderr.log') -Tail 8; throw 'Navigation process failed' }
if (-not (Select-String -Path (Join-Path $artifact 'stdout.log') -SimpleMatch 'NAVIGATION-PASS:28' -Quiet)) { throw 'Missing navigation completion sentinel' }
"NAVIGATION-PROBE-PASS mode=$Mode checks=28 seconds=$($clock.Elapsed.TotalSeconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) artifact=$artifact"
