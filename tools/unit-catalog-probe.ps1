param([ValidateSet('Standalone','Host')][string]$Mode = 'Standalone', [string]$CatalogRoot, [switch]$Focused, [switch]$Single,
      [switch]$Sharded,
      [ValidateSet('global','length','volume','area','mass','temp','energy','speed','time','power','data','pressure','angle')][string]$Shard,
      [string]$TracePath, [ValidateRange(0,10000)][int]$Offset=0, [ValidateRange(0,8)][int]$Limit=0)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$target = Join-Path $project 'target/unit-catalog'
New-Item -ItemType Directory -Force $target | Out-Null
if ($Sharded) {
    if ($Focused -or $Single -or $Shard -or $CatalogRoot) { throw 'Sharded full coverage cannot be combined with partial/control modes' }
    $directory = Join-Path $target ('batched-'+$Mode)
    New-Item -ItemType Directory -Force $directory | Out-Null
    $reference = Join-Path $target 'batched-Host/reference.tsv'
    if ($Mode -eq 'Host') {
        & $PSCommandPath -Mode Host -TracePath $reference | Select-Object -Last 1
    }
    if (!(Test-Path -LiteralPath $reference)) { throw 'Run -Mode Host -Sharded first to establish independent exhaustive assertion IDs' }
    $expected = @(Get-Content -LiteralPath $reference | ForEach-Object { $_.Split("`t")[0] })
    if ($expected.Count -ne 308 -or @($expected | Select-Object -Unique).Count -ne 308) { throw 'Reference must contain exactly 308 distinct passing assertion IDs' }
    $all = @(); $stages = @()
    $batches = @([pscustomobject]@{name='global'; category='global'; offset=0; limit=0; expected=40})
    foreach ($category in @('length','volume','area','mass','temp','energy','speed','time','power','data','pressure','angle')) {
        $count = @($expected | Where-Object {$_ -like "identity/$category/*"}).Count
        for ($start=0; $start -lt $count; $start+=8) {
            $batches += [pscustomobject]@{ name=($category+'-'+$start); category=$category; offset=$start; limit=8; expected=(2*[Math]::Min(8,$count-$start)) }
        }
    }
    foreach ($batch in $batches) {
        $stage = $batch.name
        $trace = Join-Path $directory ($stage+'.tsv')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            & $PSCommandPath -Mode $Mode -Shard $batch.category -Offset $batch.offset -Limit $batch.limit -TracePath $trace | Select-Object -Last 1
            $ids = @(Get-Content -LiteralPath $trace | ForEach-Object { $_.Split("`t")[0] })
            if ($ids.Count -ne $batch.expected -or @($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Missing or duplicate batch assertion IDs' }
            $all += $ids
            $stages += [pscustomobject]@{ stage=$stage; assertions=$ids.Count; elapsedMs=$clock.ElapsedMilliseconds; status='PASS' }
            "UNIT-SHARD-PASS:$stage assertions=$($ids.Count) elapsedMs=$($clock.ElapsedMilliseconds)"
        } catch {
            $partial = if (Test-Path -LiteralPath $trace) { @(Get-Content -LiteralPath $trace | ForEach-Object { $_.Split("`t")[0] }) } else { @() }
            $stages += [pscustomobject]@{ stage=$stage; partialAssertions=$partial.Count; elapsedMs=$clock.ElapsedMilliseconds; status='FAIL'; error=$_.Exception.Message }
            @{ mode=$Mode; stages=$stages; completedUnique=@($all | Select-Object -Unique).Count; expected=308; status='FAIL'; completedAssertionIds=$all; partialAssertionIds=$partial } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $directory 'coverage.json')
            throw "UNIT-SHARD-FAIL:$stage : $($_.Exception.Message)"
        }
    }
    $unique = @($all | Sort-Object -Unique)
    if ($all.Count -ne 308 -or $unique.Count -ne 308 -or @(Compare-Object ($expected | Sort-Object) $unique).Count) { throw 'Sharded assertion union differs from exhaustive reference' }
    @{ mode=$Mode; stages=$stages; completedUnique=$unique.Count; expected=308; assertionIds=$unique; status='PASS' } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $directory 'coverage.json')
    "UNIT-CATALOG-SHARDED-PASS:308 unique=308 processes=$($batches.Count) maxUnits=8 mode=$Mode"
    return
}
$runtime = if ($Mode -eq 'Host') { (Get-Command emacs).Source } else { Join-Path (Split-Path $project -Parent) 'nelisp/target/nelisp.exe' }
$test = Join-Path $project 'test/unit-catalog-test.el'
$arguments = if ($Mode -eq 'Host') { @('-Q','--batch','-l', ('"'+$test+'"')) } else { @('--load', ('"'+$test+'"')) }
$log = Join-Path $target ($Mode + $(if ($CatalogRoot) {'-control'} else {''}) + $(if ($Focused) {'-focused'} else {''}) + $(if ($Single) {'-single'} else {''}) + $(if ($Shard) {'-shard-'+$Shard} else {''}) + $(if ($Limit) {'-batch-'+$Offset} else {''}) + '.log')
$oldRoot = $env:UNIT_CATALOG_ROOT
$oldFocused = $env:UNIT_CATALOG_FOCUSED
$oldSingle = $env:UNIT_CATALOG_SINGLE
$oldShard = $env:UNIT_CATALOG_SHARD
$oldTrace = $env:UNIT_CATALOG_TRACE
$oldOffset = $env:UNIT_CATALOG_OFFSET
$oldLimit = $env:UNIT_CATALOG_LIMIT
try {
    $env:UNIT_CATALOG_ROOT = $CatalogRoot
    $env:UNIT_CATALOG_FOCUSED = if ($Focused) {'1'} else {$null}
    $env:UNIT_CATALOG_SINGLE = if ($Single) {'1'} else {$null}
    $env:UNIT_CATALOG_SHARD = if ($Shard) {$Shard} else {$null}
    $env:UNIT_CATALOG_TRACE = if ($TracePath) {$TracePath} else {$null}
    $env:UNIT_CATALOG_OFFSET = if ($Limit) {[string]$Offset} else {$null}
    $env:UNIT_CATALOG_LIMIT = if ($Limit) {[string]$Limit} else {$null}
    if ($TracePath) { [IO.File]::WriteAllText($TracePath,'') }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError ($log+'.stderr')
    $null = $p.Handle
    $timeout = if ($Single) {30000} elseif ($Shard) {90000} else {300000}
    $peakPrivate = 0L
    while (!$p.WaitForExit(250)) {
        try { $p.Refresh(); $peakPrivate=[Math]::Max($peakPrivate,$p.PrivateMemorySize64) } catch { }
        if ($timer.ElapsedMilliseconds -ge $timeout) {
            $p.Kill(); $null=$p.WaitForExit(5000)
            @{ pid=$p.Id; sampledPeakPrivateBytes=$peakPrivate; timeoutMs=$timeout; status='TIMEOUT' } | ConvertTo-Json | Set-Content ($log+'.metrics.json')
            throw "Owned unit probe exceeded $timeout ms"
        }
    }
    @{ pid=$p.Id; sampledPeakPrivateBytes=$peakPrivate; timeoutMs=$timeout; elapsedMs=$timer.ElapsedMilliseconds; status='EXITED' } | ConvertTo-Json | Set-Content ($log+'.metrics.json')
    Get-Content $log -Tail 2
    if ($p.ExitCode -ne 0) { Get-Content ($log+'.stderr') -Tail 4; throw "Unit probe failed: $log" }
    if (!(Select-String -LiteralPath $log -SimpleMatch 'UNIT-CATALOG-PASS:' -Quiet)) { throw 'Missing completion sentinel' }
    "UNIT-PROBE-ELAPSED-MS:$($timer.ElapsedMilliseconds)"
} finally {
    $env:UNIT_CATALOG_ROOT = $oldRoot; $env:UNIT_CATALOG_FOCUSED = $oldFocused; $env:UNIT_CATALOG_SINGLE = $oldSingle
    $env:UNIT_CATALOG_SHARD = $oldShard; $env:UNIT_CATALOG_TRACE = $oldTrace
    $env:UNIT_CATALOG_OFFSET = $oldOffset; $env:UNIT_CATALOG_LIMIT = $oldLimit
}
