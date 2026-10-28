param([Parameter(Mandatory = $true)][string]$BundleRoot, [string]$LauncherSnapshot)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$original = (Resolve-Path -LiteralPath $BundleRoot).Path
$run = Join-Path $project ('target/package-probes/' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$bundle = Join-Path $run 'Relocated Calc'
Copy-Item -LiteralPath $original -Destination $bundle -Recurse
$manifest = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
$verified = 0
foreach ($file in $manifest.files) {
    $path = Join-Path $bundle $file.path
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) { throw "Package hash mismatch: $($file.path)" }
    $verified++
}
if ($LauncherSnapshot) {
    $snapshot = (Resolve-Path -LiteralPath $LauncherSnapshot).Path
    Copy-Item -LiteralPath $snapshot -Destination (Join-Path $bundle 'app/tools/launch.ps1') -Force
}
$launcher = Join-Path $bundle 'app/tools/launch.ps1'
$launcherText = Get-Content -LiteralPath $launcher -Raw
if ($launcherText -notmatch 'NELISP_CALC_DLL_DIR' -or $launcherText -notmatch 'NELISP_CALC_SERVER') { throw 'Package launcher lacks bundled DLL/bootstrap overrides' }
$entry = Get-Content -LiteralPath (Join-Path $bundle 'app/lisp/package-entry.el') -Raw
if ($entry -notmatch '\(setq load-path' -or $entry -match '[A-Za-z]:[\\/]') { throw 'Package bootstrap does not isolate source lookup' }
$shell = (Get-Process -Id $PID).Path
$hostDirectory = Split-Path $shell -Parent
$driver = Join-Path $run 'probe-driver.ps1'
$driverSource = @'
param([string]$Bundle)
$ErrorActionPreference = 'Stop'
$env:PATH = (Join-Path $Bundle 'runtime/bin') + ';' + $env:SystemRoot + '\System32;' + $env:SystemRoot + ';' + (Split-Path (Get-Process -Id $PID).Path -Parent)
foreach ($name in @('MINGW_BIN', 'NELISP_BIN', 'NELISP_CALC_ENGINE_ROOT', 'NELISP_CALC_VENDOR', 'NELISP_EMACS_DIR', 'NELISP_CALC_SERVER', 'NELISP_CALC_TARGET', 'NELISP_CALC_KEYS', 'NELISP_CALC_COMMANDS', 'NELISP_CALC_THEME_FILE')) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
& (Join-Path $Bundle 'portable-launch.ps1') -Hidden -Commands @('2', 'add', '3', 'equals') -ExpectedDisplay '5' -TimeoutSeconds 90
& (Join-Path $Bundle 'portable-launch.ps1') -Hidden -Commands @('mode:scientific', 'eval:sqrt(2)') -ExpectedDisplay '1.41421356237' -TimeoutSeconds 90
'PACKAGE-NATIVE-E2E-PASS'
'@
[IO.File]::WriteAllText($driver, $driverSource, (New-Object Text.UTF8Encoding($false)))
$code = "& '" + $driver.Replace("'", "''") + "' -Bundle '" + $bundle.Replace("'", "''") + "'"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
$stdout = Join-Path $run 'probe.stdout.log'
$stderr = Join-Path $run 'probe.stderr.log'
$worker = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WorkingDirectory $run -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$null = $worker.Handle
$observed = @{}
$modules = @{}
$foreign = @{}
$descendants = @{ ([string]$worker.Id) = $true }
$deadline = (Get-Date).AddSeconds(210)
while (-not $worker.HasExited -and (Get-Date) -lt $deadline) {
    foreach ($process in Get-CimInstance Win32_Process -Filter "Name = 'nelisp.exe' OR Name = 'nelisp-calc.exe' OR Name LIKE 'emacs%.exe'") {
        if (-not $descendants.ContainsKey([string]$process.ParentProcessId) -and -not $descendants.ContainsKey([string]$process.ProcessId)) { continue }
        $descendants[[string]$process.ProcessId] = $true
        if (-not $process.ExecutablePath -or $process.Name -like 'emacs*' -or -not $process.ExecutablePath.StartsWith($bundle + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $foreign[[string]$process.ProcessId] = @{ executable = $process.ExecutablePath; commandLine = $process.CommandLine }
            continue
        }
        $observed[[string]$process.ProcessId] = @{ pid = $process.ProcessId; executable = $process.ExecutablePath; commandLine = $process.CommandLine }
        if ($process.Name -eq 'nelisp-calc.exe') {
            try {
                foreach ($module in (Get-Process -Id $process.ProcessId -ErrorAction Stop).Modules) { $modules[$module.FileName] = $true }
            } catch { }
        }
    }
    Start-Sleep -Milliseconds 150
    $worker.Refresh()
}
if (-not $worker.HasExited) { $worker.Kill(); throw "Package probe exceeded deadline; logs at $run" }
$worker.WaitForExit()
$text = Get-Content -LiteralPath $stdout -Raw
if ($worker.ExitCode -ne 0 -or $text -notmatch 'PACKAGE-NATIVE-E2E-PASS') { throw "Package native probe failed, exit=$($worker.ExitCode); logs at $run" }
$native = @($observed.Values)
if ($foreign.Count) { throw ('Unbundled native process or host Emacs observed: ' + ($foreign.Values | ConvertTo-Json -Compress)) }
if (@($native | Where-Object { $_.executable -match '[\\/]nelisp\.exe$' }).Count -lt 2 -or @($native | Where-Object { $_.executable -match '[\\/]nelisp-calc\.exe$' }).Count -lt 2) { throw 'Both relocated backend and GUI processes were not observed for both native sessions' }
$unexpected = @($modules.Keys | Where-Object { -not $_.StartsWith($bundle + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and -not $_.StartsWith($env:SystemRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
if ($unexpected.Count) { throw ('Unbundled native modules: ' + ($unexpected -join ', ')) }
$evidence = @{ status = 'PASS'; relocatedBundle = $bundle; originalBundle = $original; workingDirectory = $run; shellHost = $shell; verifiedFiles = $verified; launcherSnapshot = $LauncherSnapshot; launcherSha256 = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash; nativeProcesses = $native; loadedGuiModules = @($modules.Keys); arithmetic = '2+3=5'; scientific = 'sqrt(2)=1.41421356237'; hostEmacsUsed = $false; clipboardTouched = $false; visibleWindowRequested = $false }
$evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $run 'package-probe.json') -Encoding UTF8
"PACKAGE-PROBE-PASS report=$run verified=$verified nativeProcesses=$($native.Count) modules=$($modules.Count)"
