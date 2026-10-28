$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$target = Join-Path $project 'target'
New-Item -ItemType Directory -Force $target | Out-Null
$runtime = Join-Path (Split-Path $project -Parent) 'nelisp/target/nelisp.exe'
function Start-Engine([string]$Entry, [string]$Name) {
    $p = Start-Process $runtime -ArgumentList @('--load', ('"' + $Entry + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $target ($Name + '.out')) -RedirectStandardError (Join-Path $target ($Name + '.err'))
    $null = $p.Handle
    return $p
}
$cold = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 3; $i++) {
    $p = Start-Engine (Join-Path $project 'test/engine-benchmark-eval.el') ('engine-benchmark-cold' + $i)
    if (!$p.WaitForExit(25000)) { $p.Kill(); throw 'Cold timeout' }
    if ($p.ExitCode -ne 0 -or !(Select-String -Path (Join-Path $target ('engine-benchmark-cold' + $i + '.out')) -SimpleMatch '0.3' -Quiet)) { throw 'Cold result failed' }
}
$cold.Stop()
$mailbox = Join-Path $target ('engine-benchmark-mailbox-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $mailbox | Out-Null
$oldTarget = $env:NELISP_CALC_TARGET
$env:NELISP_CALC_TARGET = $mailbox.Replace('\', '/')
$warm = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Engine (Join-Path $project 'lisp/nelisp-calc-mailbox.el') 'engine-benchmark-persistent'
try {
    $response = Join-Path $mailbox 'response.txt'
    $request = Join-Path $mailbox 'requests.txt'
    for ($i = 1; $i -le 3; $i++) {
        $deadline = (Get-Date).AddSeconds(25)
        $appended = $false
        while (!$appended) {
            try { [IO.File]::AppendAllText($request, "eval:0.1+0.2`n", [Text.Encoding]::ASCII); $appended = $true }
            catch [IO.IOException] { if ((Get-Date) -gt $deadline) { throw }; Start-Sleep -Milliseconds 25 }
        }
        do {
            Start-Sleep -Milliseconds 25
            $lines = if (Test-Path $response) { [IO.File]::ReadAllLines($response) } else { @() }
        } while (($lines.Count -lt 3 -or $lines[2] -ne [string]$i) -and (Get-Date) -lt $deadline -and !$p.HasExited)
        if ($lines.Count -lt 3 -or $lines[2] -ne [string]$i -or $lines[0] -ne '0.3') { throw 'Persistent arithmetic failed' }
    }
    $warm.Stop()
    @{ expression = '0.1+0.2'; expected = '0.3'; requests = 3; coldProcessCount = 3; persistentProcessCount = 1; coldMilliseconds = $cold.ElapsedMilliseconds; persistentMilliseconds = $warm.ElapsedMilliseconds } |
        ConvertTo-Json | Set-Content (Join-Path $target 'engine-benchmark.json') -Encoding UTF8
    Get-Content (Join-Path $target 'engine-benchmark.json')
} finally {
    [IO.File]::WriteAllText((Join-Path $mailbox 'stop'), '')
    if (!$p.WaitForExit(3000)) { $p.Kill() }
    $env:NELISP_CALC_TARGET = $oldTarget
}
