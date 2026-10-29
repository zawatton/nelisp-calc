param([switch]$Smoke, [string]$InteractionKeys, [switch]$InteractionBurst, [switch]$InteractionMouse, [string[]]$Commands, [string]$ExpectedDisplay, [string]$ExpectedStatus, [switch]$Hidden, [int]$TimeoutSeconds = 55)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$artifactRoot = Join-Path $projectRoot 'target'
$guiBin = Join-Path $artifactRoot 'nelisp-calc.exe'
$guiPointer = Join-Path $artifactRoot 'current-gui.txt'
if (Test-Path -LiteralPath $guiPointer) {
    $relativeGui = [IO.File]::ReadAllText($guiPointer).Trim()
    if ([IO.Path]::IsPathRooted($relativeGui) -or $relativeGui -match '(^|[\\/])\.\.([\\/]|$)' -or -not $relativeGui) { throw 'Invalid native GUI pointer' }
    $guiBin = Join-Path $artifactRoot $relativeGui
}
$savedEnvironment = @{}
$savedEnvironment['NELISP_CALC_THEME_FILE'] = $env:NELISP_CALC_THEME_FILE
$savedEnvironment['NELISP_CALC_NATIVE_GC_POLICY'] = $env:NELISP_CALC_NATIVE_GC_POLICY
$savedEnvironment['NELISP_CALC_HEADER_PROBE'] = $env:NELISP_CALC_HEADER_PROBE
foreach ($name in @('PATH', 'NELISP_CALC_TARGET', 'NELISP_CALC_KEYS', 'NELISP_CALC_BURST', 'NELISP_CALC_MOUSE', 'NELISP_CALC_SMOKE', 'NELISP_CALC_COMMANDS', 'NELISP_CALC_HIDDEN', 'NELISP_CALC_TODAY', 'NELISP_CALC_REFRESH_COMMAND', 'NELISP_CALC_RATES')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$backend = $null
$gui = $null
$interactionPassed = $false
try {
    $env:NELISP_CALC_HEADER_PROBE = $null
    $bundledDll = @((Join-Path $projectRoot 'runtime/bin'), (Join-Path $projectRoot 'runtime'), (Join-Path (Split-Path $projectRoot -Parent) 'runtime/bin')) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'libgtk-4-1.dll') } | Select-Object -First 1
    $mingwBin = if ($env:NELISP_CALC_DLL_DIR) { $env:NELISP_CALC_DLL_DIR } elseif ($env:MINGW_BIN) { $env:MINGW_BIN } elseif ($bundledDll) { $bundledDll } else { Split-Path (Get-Command gcc -ErrorAction Stop).Source -Parent }
    $env:PATH = "$mingwBin;$env:PATH"
    if (-not $env:NELISP_CALC_THEME_FILE) {
        if ($Smoke -or $InteractionKeys -or $Commands) {
            $env:NELISP_CALC_THEME_FILE = Join-Path $artifactRoot ('theme-fixtures/' + [Guid]::NewGuid().ToString('N') + '/theme.txt')
        } else {
            $env:NELISP_CALC_THEME_FILE = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'NeLispCalc/theme.txt'
        }
    }
    $themeDirectory = Split-Path ([IO.Path]::GetFullPath($env:NELISP_CALC_THEME_FILE)) -Parent
    if (-not (Test-Path -LiteralPath $themeDirectory)) {
        try { New-Item -ItemType Directory -Path $themeDirectory -Force | Out-Null }
        catch { Write-Warning 'Appearance preference directory unavailable; calculation remains available.' }
    }
    if (-not $env:NELISP_CALC_TODAY) { $env:NELISP_CALC_TODAY = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    if (-not (Test-Path -LiteralPath $guiBin)) { throw 'Run tools/build.ps1 first' }
    if ($Smoke) {
        $env:NELISP_CALC_SMOKE = '1'
        $gui = Start-Process -FilePath $guiBin -WorkingDirectory $artifactRoot -WindowStyle Hidden -PassThru
        if (-not $gui.WaitForExit(15000)) { $gui.Kill(); throw 'Native smoke timeout' }
        if ($gui.ExitCode -ne 0) { throw "Native smoke exit $($gui.ExitCode)" }
        Get-Item (Join-Path $artifactRoot 'native-smoke.png')
        return
    }
    . (Join-Path $PSScriptRoot 'runtime.ps1')
    $nelispBin = Resolve-CalcRuntime $projectRoot
    $env:NELISP_CALC_NATIVE_GC_POLICY = Get-CalcRuntimeGcPolicy $projectRoot $nelispBin
    $engineRoot = if ($env:NELISP_CALC_ENGINE_ROOT) { $env:NELISP_CALC_ENGINE_ROOT } else { $projectRoot }
    if (-not $env:NELISP_CALC_RATES) { $env:NELISP_CALC_RATES = Join-Path $artifactRoot 'currency-rates.tsv' }
    $refreshScript = if ($env:NELISP_CALC_RATES_UPDATE_SCRIPT) { $env:NELISP_CALC_RATES_UPDATE_SCRIPT } else { Join-Path $projectRoot 'tools/update-rates.ps1' }
    $env:NELISP_CALC_REFRESH_COMMAND = $null
    if (Test-Path -LiteralPath $refreshScript) {
        $helperCode = "& '" + $refreshScript.Replace("'", "''") + "' -CachePath '" + $env:NELISP_CALC_RATES.Replace("'", "''") + "' *> '" + (Join-Path $artifactRoot 'rates-refresh.log').Replace("'", "''") + "'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperCode))
        $env:NELISP_CALC_REFRESH_COMMAND = 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + $encoded
    }
    $server = if ($env:NELISP_CALC_SERVER) { $env:NELISP_CALC_SERVER } else { Join-Path $engineRoot 'lisp/nelisp-calc-mailbox.el' }
    if (-not (Test-Path -LiteralPath $server)) { throw 'NeLisp Calc mailbox server unavailable' }
    $targetRoot = Join-Path $artifactRoot ('sessions/' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    $responseFile = Join-Path $targetRoot 'response.txt'
    $stopFile = Join-Path $targetRoot 'stop'
    $env:NELISP_CALC_TARGET = $targetRoot
    $env:NELISP_CALC_KEYS = if ($InteractionKeys) { $InteractionKeys } else { $null }
    $env:NELISP_CALC_BURST = if ($InteractionBurst) { '1' } else { $null }
    $env:NELISP_CALC_MOUSE = if ($InteractionMouse) { '1' } else { $null }
    $env:NELISP_CALC_SMOKE = $null
    # Automated native signal tests never present or focus a window.
    $env:NELISP_CALC_HIDDEN = if ($Hidden -or $Commands -or $InteractionKeys) { '1' } else { $null }
    if ($Commands -and $InteractionKeys) { throw 'Choose Commands or InteractionKeys' }
    if ($Commands | Where-Object { -not $_ -or $_ -match '[^\x20-\x7E]|\|' }) { throw 'Commands must be nonempty ASCII and cannot contain |' }
    $env:NELISP_CALC_COMMANDS = if ($Commands) { $Commands -join '|' } else { $null }
    if ($Commands | Where-Object { $_ -match '^(mode:graph$|graph:)' }) {
        $previousGraph = Join-Path $artifactRoot 'graph.txt'
        if (Test-Path -LiteralPath $previousGraph) { Remove-Item -LiteralPath $previousGraph }
    }
    $backend = Start-Process -FilePath $nelispBin -ArgumentList @('--load', ('"' + $server + '"')) -WorkingDirectory $targetRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $targetRoot 'native-backend.stdout.log') -RedirectStandardError (Join-Path $targetRoot 'native-backend.stderr.log')
    $gui = Start-Process -FilePath $guiBin -WorkingDirectory $targetRoot -WindowStyle Hidden -PassThru
    if ($env:NELISP_CALC_TASK_SESSION) {
        $sessionTemporary = $env:NELISP_CALC_TASK_SESSION + '.new'
        @{ guiPid = $gui.Id; session = $targetRoot } | ConvertTo-Json -Compress | Set-Content -LiteralPath $sessionTemporary -Encoding UTF8
        Move-Item -LiteralPath $sessionTemporary -Destination $env:NELISP_CALC_TASK_SESSION -Force
    }
    if ($InteractionKeys -or $Commands) {
        if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 300) { throw 'TimeoutSeconds must be 1..300' }
        if (-not $gui.WaitForExit($TimeoutSeconds * 1000)) { $gui.Kill(); throw 'Native GTK interaction timeout' }
        if ($gui.ExitCode -ne 0) { throw "Native GUI exit $($gui.ExitCode)" }
        if (-not (Test-Path -LiteralPath (Join-Path $targetRoot 'native-interaction.png'))) { throw 'Native GTK interaction did not finish its mailbox commands' }
        $responseLines = @(Get-Content -LiteralPath $responseFile)
        $expectedCount = if ($Commands) {
            $commandMode = 'standard'; $acknowledgements = 0
            $keyReceipts = @()
            $keyReceiptPath = Join-Path $targetRoot 'key-receipts.txt'
            if (Test-Path -LiteralPath $keyReceiptPath) { $keyReceipts = @(Get-Content -LiteralPath $keyReceiptPath) }
            $keyIndex = 0
            foreach ($command in $Commands) {
                if ($command -match '^ui:gesture:(mode|busy):') { $acknowledgements++; continue }
                if ($command -match '^ui:key:') {
                    if ($keyIndex -ge $keyReceipts.Count) { throw 'Missing native key signal receipt' }
                    $receiptFields = $keyReceipts[$keyIndex++].Split("`t")
                    if ($receiptFields[2] -notin @('0','1')) { throw 'Invalid native key handled return' }
                    if ($receiptFields.Count -lt 9 -or $receiptFields[8] -notmatch '^[0-6]$') { throw 'Invalid native key mode receipt' }
                    $commandMode = @('standard','scientific','programmer','convert','date','graph','currency')[[int]$receiptFields[8]]
                    $acknowledgements += [int]$receiptFields[2]
                    continue
                }
                if ($command -match '^(?:nav:)?mode:(.+)$') { $commandMode = $Matches[1] }
                if ($command -match '^ui:') { continue }
                $acknowledgements++
                # Ordinary typed text sets the input and computes only on Enter.
                if ($commandMode -in @('programmer', 'convert', 'currency') -and $command -notmatch ':' -and $command -notmatch '^([0-9A-F]|add|sub|mul|div|equals|dot|clear|backspace|sign)$') { $acknowledgements++ }
            }
            if ($keyIndex -ne $keyReceipts.Count) { throw 'Unexpected native key signal receipt' }
            $gestureSubmissions = Join-Path $targetRoot 'gesture-submissions.txt'
            if (Test-Path -LiteralPath $gestureSubmissions) { $acknowledgements += @(Get-Content -LiteralPath $gestureSubmissions).Count }
            $acknowledgements
        } elseif ($InteractionBurst) { [Math]::Min(64, $InteractionKeys.Length) } else { $InteractionKeys.Length }
        if ($responseLines.Count -lt 3 -or [int]$responseLines[2] -ne $expectedCount) { throw "Native GTK acknowledgement count mismatch; expected $expectedCount" }
        if ($PSBoundParameters.ContainsKey('ExpectedDisplay') -and $responseLines[0] -ne $ExpectedDisplay) { throw "Native GTK display mismatch: $($responseLines[0])" }
        if ($PSBoundParameters.ContainsKey('ExpectedStatus') -and $responseLines[1] -notmatch $ExpectedStatus) { throw "Native GTK status mismatch: $($responseLines[1])" }
        $interactionPassed = $true
        $responseLines
        "NATIVE-GTK-INTERACTION-OK session=$targetRoot mouse=$InteractionMouse burst=$InteractionBurst count=$expectedCount"
    } else { $gui.WaitForExit() }
} finally {
    try {
    if ($gui -and -not $gui.HasExited) { Stop-Process -Id $gui.Id }
    if ($backend -and -not $backend.HasExited) {
        [IO.File]::WriteAllText($stopFile, '')
        if (-not $backend.WaitForExit(2000)) { Stop-Process -Id $backend.Id }
    }
    if ($interactionPassed) {
        foreach ($name in @('response.txt', 'requests.txt', 'native-interaction.png')) {
            $sessionArtifact = Join-Path $targetRoot $name
            if (Test-Path -LiteralPath $sessionArtifact) { Copy-Item -LiteralPath $sessionArtifact -Destination (Join-Path $artifactRoot $name) -Force }
        }
        foreach ($name in @('graph.txt', 'memory.txt', 'history.txt')) {
            $sessionArtifact = Join-Path $targetRoot $name
            if (Test-Path -LiteralPath $sessionArtifact) { Copy-Item -LiteralPath $sessionArtifact -Destination (Join-Path $artifactRoot $name) -Force }
        }
    }
    } finally {
        foreach ($name in $savedEnvironment.Keys) {
            if ($null -eq $savedEnvironment[$name]) {
                Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
            }
        }
    }
}
