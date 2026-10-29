function Resolve-CalcRuntime([string]$ProjectRoot) {
    if ($env:NELISP_BIN) {
        if (-not (Test-Path -LiteralPath $env:NELISP_BIN -PathType Leaf)) { throw 'NELISP_BIN does not name a standalone runtime' }
        $runtime = (Resolve-Path -LiteralPath $env:NELISP_BIN).Path
        $null = Get-CalcRuntimeColdImage $ProjectRoot $runtime
        return $runtime
    }
    $selection = Join-Path $ProjectRoot 'target/current-runtime.json'
    if (Test-Path -LiteralPath $selection) {
        $record = Get-Content -LiteralPath $selection -Raw | ConvertFrom-Json
        $relative = [string]$record.path
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Invalid local runtime selection' }
        $runtime = Join-Path $ProjectRoot ('target/' + $relative)
        if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw 'Selected runtime is missing' }
        if ((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash -ne [string]$record.sha256) { throw 'Selected runtime checksum mismatch' }
        $null = Get-CalcRuntimeColdImage $ProjectRoot $runtime
        return (Resolve-Path -LiteralPath $runtime).Path
    }
    $runtime = Join-Path (Split-Path $ProjectRoot -Parent) 'nelisp/target/nelisp.exe'
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw 'Standalone NeLisp unavailable: set NELISP_BIN' }
    $null = Get-CalcRuntimeColdImage $ProjectRoot $runtime
    return (Resolve-Path -LiteralPath $runtime).Path
}

function Get-CalcRuntimeColdImage([string]$ProjectRoot, [string]$Runtime) {
    $companion = $Runtime + '.cold'
    if (-not (Test-Path -LiteralPath $companion -PathType Leaf)) { return '' }
    $runtimeHash = (Get-FileHash -LiteralPath $Runtime -Algorithm SHA256).Hash
    foreach ($name in @('current-runtime.json', 'runtime-capabilities.json')) {
        $metadata = Join-Path $ProjectRoot ('target/' + $name)
        if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) { continue }
        try { $record = Get-Content -LiteralPath $metadata -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        if (-not [string]$record.coldSha256 -or [string]$record.sha256 -ne $runtimeHash) { continue }
        if ((Get-FileHash -LiteralPath $companion -Algorithm SHA256).Hash -ne [string]$record.coldSha256) { throw 'Runtime cold image checksum mismatch' }
        return (Resolve-Path -LiteralPath $companion).Path
    }
    return ''
}

function Get-CalcRuntimeGcPolicy([string]$ProjectRoot, [string]$Runtime) {
    $capabilities = Join-Path $ProjectRoot 'target/runtime-capabilities.json'
    if (-not (Test-Path -LiteralPath $capabilities -PathType Leaf)) { return '' }
    $record = Get-Content -LiteralPath $capabilities -Raw | ConvertFrom-Json
    if ([string]$record.startupGcPolicy -ne 'debt-v1') { return '' }
    if ([string]$record.sha256 -ne (Get-FileHash -LiteralPath $Runtime -Algorithm SHA256).Hash) { return '' }
    return 'debt-v1'
}
