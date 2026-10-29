param([string]$Runtime, [ValidateRange(5,45)][int]$Seconds = 15,
      [double]$MaxCpuPercent = 5, [double]$MaxGrowthMiB = 32,
      [double]$MaxPrivateMiB = 512, [switch]$WithHistory,
      [ValidateRange(0,500)][int]$Backlog = 0, [string]$MailboxSource,
      [ValidateRange(0,10)][int]$WarmupSeconds = 3)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'runtime.ps1')
if (-not $Runtime) { $Runtime = Resolve-CalcRuntime $root }
$Runtime = (Resolve-Path -LiteralPath $Runtime).Path
$session = Join-Path $root ('target/idle-resource-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $session -Force | Out-Null
$response = Join-Path $session 'response.txt'
$request = Join-Path $session 'requests.txt'
$savedTarget = $env:NELISP_CALC_TARGET
$savedGcPolicy = $env:NELISP_CALC_NATIVE_GC_POLICY
$process = $null
function Wait-Response([int]$Count) {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        if ($process.HasExited) { throw 'Owned backend exited before its response' }
        if (Test-Path -LiteralPath $response) {
            try { $lines = @(Get-Content -LiteralPath $response -ErrorAction Stop) } catch [IO.IOException] { $lines = @() }
            if ($lines.Count -ge 3 -and $lines[2] -eq [string]$Count) { return $lines }
        }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Owned backend response timeout: $Count"
}
try {
    $env:NELISP_CALC_TARGET = $session
    $env:NELISP_CALC_NATIVE_GC_POLICY = Get-CalcRuntimeGcPolicy $root $Runtime
    $server = Join-Path $root 'lisp/nelisp-calc-mailbox.el'
    if ($MailboxSource) { $server = (Resolve-Path -LiteralPath $MailboxSource).Path }
    $startupWatch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $Runtime -ArgumentList @('--load', ('"' + $server + '"')) -WorkingDirectory $session -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $session 'stdout.log') -RedirectStandardError (Join-Path $session 'stderr.log')
    $initial = Wait-Response 0
    $readyMilliseconds = $startupWatch.Elapsed.TotalMilliseconds
    $count = 0
    if ($WithHistory) {
        $tokens = @('mode:standard','mode:standard','1','add','1','clear','clear','1','add','1','equals','backspace','backspace','backspace')
        [IO.File]::AppendAllText($request, (($tokens -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        $count = $tokens.Count
        $history = Wait-Response $count
        if ($history[0] -ne '2') { throw 'History setup display mismatch' }
    }
    if ($Backlog -gt 0) {
        [IO.File]::AppendAllText($request, ((1..$Backlog | ForEach-Object { 'backspace' }) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        $count += $Backlog
        $null = Wait-Response $count
    }
    # Exclude the setup response's remaining publication/cleanup and initial GC.
    if ($WarmupSeconds -gt 0) { Start-Sleep -Seconds $WarmupSeconds }
    $before = Get-Process -Id $process.Id
    $cpu = $before.CPU
    $memory = $before.PrivateMemorySize64
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $Seconds
    $after = Get-Process -Id $process.Id
    $elapsed = $watch.Elapsed.TotalSeconds
    [IO.File]::AppendAllText($request, "clear`n2`nadd`n3`nequals`n", [Text.UTF8Encoding]::new($false))
    $result = Wait-Response ($count + 5)
    $report = [ordered]@{
        runtimeSha256 = (Get-FileHash -LiteralPath $Runtime -Algorithm SHA256).Hash
        runtime = $Runtime; session = $session; seconds = $elapsed; warmupSeconds = $WarmupSeconds
        readyMilliseconds = [Math]::Round($readyMilliseconds, 3)
        mailboxSha256 = (Get-FileHash -LiteralPath $server -Algorithm SHA256).Hash
        oneCorePercent = [Math]::Round(100 * ($after.CPU - $cpu) / $elapsed, 3)
        privateBeforeMiB = [Math]::Round($memory / 1MB, 3)
        privateAfterMiB = [Math]::Round($after.PrivateMemorySize64 / 1MB, 3)
        growthMiB = [Math]::Round(($after.PrivateMemorySize64 - $memory) / 1MB, 3)
        display = $result[0]; processed = $result[2]; historyCount = $count
    }
    [IO.File]::WriteAllText((Join-Path $session 'stop'), '')
    if (-not $process.WaitForExit(10000)) { throw 'Owned backend did not stop' }
    $report.exitCode = $process.ExitCode
    $report.stderrBytes = (Get-Item -LiteralPath (Join-Path $session 'stderr.log')).Length
    $report.pass = $report.oneCorePercent -le $MaxCpuPercent -and $report.growthMiB -le $MaxGrowthMiB -and $report.privateAfterMiB -le $MaxPrivateMiB -and $report.display -eq '5' -and $report.exitCode -eq 0 -and $report.stderrBytes -eq 0
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $session 'measurement.json') -Encoding UTF8
    $report | ConvertTo-Json -Compress
    if (-not $report.pass) { throw 'Idle resource acceptance failed; see measurement.json' }
} finally {
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $env:NELISP_CALC_TARGET = $savedTarget
    $env:NELISP_CALC_NATIVE_GC_POLICY = $savedGcPolicy
}
