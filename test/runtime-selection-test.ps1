$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tools/runtime.ps1')
$fixture = Join-Path $root ('target/runtime-selection-' + [Guid]::NewGuid().ToString('N'))
$project = Join-Path $fixture 'app'
$fallback = Join-Path $fixture 'nelisp/target/nelisp.exe'
$selected = Join-Path $project 'target/runtimes/test/nelisp.exe'
$selection = Join-Path $project 'target/current-runtime.json'
$saved = $env:NELISP_BIN
$checks = 0
function Assert-Selection([bool]$Condition) {
    if (-not $Condition) { throw "Runtime selection assertion failed at $checks" }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-Selection $failed
}
try {
    New-Item -ItemType Directory -Force -Path (Split-Path $fallback), (Split-Path $selected) | Out-Null
    [IO.File]::WriteAllText($fallback, 'fallback fixture')
    [IO.File]::WriteAllText($selected, 'selected fixture')
    $env:NELISP_BIN = $null
    Assert-Selection ((Resolve-CalcRuntime $project) -eq $fallback)
    @{path='runtimes/test/nelisp.exe';sha256=(Get-FileHash -LiteralPath $selected).Hash} | ConvertTo-Json | Set-Content -LiteralPath $selection
    Assert-Selection ((Resolve-CalcRuntime $project) -eq $selected)
    [IO.File]::AppendAllText($selected, 'mutation')
    Assert-Rejected { Resolve-CalcRuntime $project }
    $env:NELISP_BIN = $fallback
    Assert-Selection ((Resolve-CalcRuntime $project) -eq $fallback)
    $env:NELISP_BIN = $null
    @{path='../nelisp.exe';sha256='bad'} | ConvertTo-Json | Set-Content -LiteralPath $selection
    Assert-Rejected { Resolve-CalcRuntime $project }
    $env:NELISP_BIN = Join-Path $fixture 'missing.exe'
    Assert-Rejected { Resolve-CalcRuntime $project }
    "RUNTIME-SELECTION-PASS:$checks"
} finally { $env:NELISP_BIN = $saved }
