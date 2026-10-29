param([string]$PackageScript = (Join-Path $PSScriptRoot 'package.ps1'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tools/runtime.ps1')
$fixture = Join-Path $root ('target/runtime-cold-test-' + [Guid]::NewGuid().ToString('N'))
$project = Join-Path $fixture 'source'
$runtime = Join-Path $project 'target/runtimes/test/nelisp.exe'
$selection = Join-Path $project 'target/current-runtime.json'
$capabilities = Join-Path $project 'target/runtime-capabilities.json'
$saved = $env:NELISP_BIN
$checks = 0
function Assert-Cold([bool]$Condition) {
    if (-not $Condition) { throw "Cold image assertion failed at $checks" }
    $script:checks++
}
function Assert-ColdRejected([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-Cold $failed
}
function Write-Selection([string]$RuntimeHash, [string]$ColdHash) {
    @{path='runtimes/test/nelisp.exe';sha256=$RuntimeHash;coldSha256=$ColdHash} | ConvertTo-Json | Set-Content $selection
}
try {
    New-Item -ItemType Directory -Force (Split-Path $runtime) | Out-Null
    [IO.File]::WriteAllText($runtime, 'runtime fixture')
    $runtimeHash = (Get-FileHash $runtime).Hash
    Write-Selection $runtimeHash ''
    $env:NELISP_BIN = $null
    Assert-Cold ((Resolve-CalcRuntime $project) -eq $runtime)
    Assert-Cold ((Get-CalcRuntimeColdImage $project $runtime) -eq '')
    Write-Selection $runtimeHash 'missing image pin'
    Assert-Cold ((Resolve-CalcRuntime $project) -eq $runtime)
    [IO.File]::WriteAllText(($runtime + '.cold'), 'cold fixture')
    $coldHash = (Get-FileHash ($runtime + '.cold')).Hash
    Write-Selection $runtimeHash $coldHash
    Assert-Cold ((Get-CalcRuntimeColdImage $project $runtime) -eq ($runtime + '.cold'))
    Assert-Cold ((Resolve-CalcRuntime $project) -eq $runtime)
    Write-Selection $runtimeHash 'wrong hash'
    Assert-ColdRejected { Resolve-CalcRuntime $project }
    Write-Selection 'wrong runtime hash' $coldHash
    Assert-ColdRejected { Resolve-CalcRuntime $project }
    Assert-Cold ((Get-CalcRuntimeColdImage $project $runtime) -eq '')
    $override = Join-Path $fixture 'override.exe'
    [IO.File]::WriteAllText($override, 'unrelated runtime')
    [IO.File]::WriteAllText(($override + '.cold'), 'unattested image')
    $env:NELISP_BIN = $override
    Assert-Cold ((Resolve-CalcRuntime $project) -eq $override)
    Assert-Cold ((Get-CalcRuntimeColdImage $project $override) -eq '')
    [IO.File]::WriteAllText($selection, '{invalid')
    Assert-Cold (((Resolve-CalcRuntime $project) -eq $override) -and ((Get-CalcRuntimeColdImage $project $override) -eq ''))
    $env:NELISP_BIN = $runtime
    Write-Selection $runtimeHash $coldHash
    Assert-Cold ((Get-CalcRuntimeColdImage $project (Resolve-CalcRuntime $project)) -eq ($runtime + '.cold'))
    $env:NELISP_BIN = $null
    @{sha256=$runtimeHash;startupGcPolicy='debt-v1'} | ConvertTo-Json | Set-Content $capabilities

    # Execute the actual packaging slice with real files, avoiding native build dependencies.
    $packageText = [IO.File]::ReadAllText($PackageScript)
    $start = $packageText.IndexOf("Copy-BundleFile `$runtimeSource 'nelisp/target/nelisp.exe'")
    $end = $packageText.IndexOf("Copy-BundleTree (Join-Path `$source 'lisp')", $start)
    if ($start -lt 0 -or $end -le $start) { throw 'Packaging slice unavailable' }
    $packageSlice = [scriptblock]::Create($packageText.Substring($start, $end - $start))
    function Copy-BundleFile([string]$From, [string]$Relative, [string]$Origin) {
        $destination = Join-Path $bundle $Relative
        New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
        Copy-Item -LiteralPath $From -Destination $destination
        $origins[$Relative] = $Origin
    }
    foreach ($withCold in @($true, $false)) {
        $source = $project
        $runtimeSource = $runtime
        $runtimeColdSource = if ($withCold) { Get-CalcRuntimeColdImage $project $runtime } else { '' }
        $bundle = Join-Path $fixture ('portable-' + $withCold)
        New-Item -ItemType Directory -Force (Join-Path $bundle 'app/target') | Out-Null
        $origins = @{}
        & $packageSlice
        $portableProject = Join-Path $bundle 'app'
        $portableRuntime = Resolve-CalcRuntime $portableProject
        Assert-Cold ((Get-FileHash $portableRuntime).Hash -eq $runtimeHash)
        Assert-Cold ((Get-CalcRuntimeGcPolicy $portableProject $portableRuntime) -eq 'debt-v1')
        if ($withCold) {
            Assert-Cold ((Get-CalcRuntimeColdImage $portableProject $portableRuntime) -eq ($portableRuntime + '.cold'))
            Assert-Cold ((Get-FileHash ($portableRuntime + '.cold')).Hash -eq $coldHash)
        } else {
            Assert-Cold (-not (Test-Path ($portableRuntime + '.cold')))
            Assert-Cold ((Get-CalcRuntimeColdImage $portableProject $portableRuntime) -eq '')
        }
    }
    "RUNTIME-COLD-PASS:$checks"
} finally { $env:NELISP_BIN = $saved }
