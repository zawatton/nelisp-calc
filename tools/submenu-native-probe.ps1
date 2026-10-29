param([string]$Gui)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/submenu-native-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifact | Out-Null
$saved = @{}
foreach ($name in @('PATH','NELISP_CALC_HIDDEN','NELISP_CALC_HEADER_PROBE','NELISP_CALC_COMMANDS','NELISP_CALC_THEME_FILE','NELISP_CALC_SMOKE','NELISP_CALC_KEYS')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
try {
    $bin = if ($env:MINGW_BIN) { $env:MINGW_BIN } else { Split-Path (Get-Command gcc).Source -Parent }
    $env:PATH = "$bin;$env:PATH"
    $env:NELISP_CALC_HIDDEN = '1'; $env:NELISP_CALC_HEADER_PROBE = 'submenu'
    $env:NELISP_CALC_SMOKE = $null; $env:NELISP_CALC_KEYS = $null
    if (-not $Gui) { $Gui = Join-Path $root ('target/' + (Get-Content (Join-Path $root 'target/current-gui.txt') -Raw).Trim()) }
    $cases = @()
    foreach ($theme in @('light','dark')) {
        foreach ($panel in @('menu','history','memory','settings')) {
            $session = Join-Path $artifact ($theme + '-' + $panel)
            New-Item -ItemType Directory -Force $session | Out-Null
            [IO.File]::WriteAllText((Join-Path $session 'response.txt'), "42`nready`n0`n")
            $env:NELISP_CALC_THEME_FILE = Join-Path $session 'theme.txt'
            [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,$theme)
            # Keep real command automation alive until the allocated 600ms GTK snapshot.
            $env:NELISP_CALC_COMMANDS = 'ui:nav:' + $panel + ('|ui:nav:snapshot' * 12)
            $stderr = Join-Path $session 'stderr.log'
            $process = Start-Process -FilePath $Gui -WorkingDirectory $session -WindowStyle Hidden -PassThru -RedirectStandardError $stderr
            try {
                if (-not $process.WaitForExit(5000)) { throw 'Owned offscreen submenu probe timed out' }
                if ($process.ExitCode -ne 0) { throw 'Native submenu probe failed' }
            } finally { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
            if ((Get-Item $stderr).Length -ne 0) { throw "GTK/CSS diagnostic in $stderr" }
            $png = Join-Path $session 'panel-native.png'
            if (-not (Test-Path $png) -or (Get-Item $png).Length -lt 1000) { throw 'Missing actual GTK panel child rendering' }
            $f = (Get-Content (Join-Path $session 'panel-native.tsv') | Select-Object -Last 1).Split("`t")
            $window = (Get-Content (Join-Path $session 'header-native.tsv') | Select-Object -Last 1).Split("`t")
            if ($f.Count -ne 5 -or [int]$f[1] -lt 200 -or [int]$f[1] -gt 365 -or [int]$f[2] -gt 460 -or [int]$f[4] -lt 28) { throw "Panel clipped or close target too small: $f" }
            if ($window[0] -ne '381' -or [int]$window[1] -gt 600 -or $window[6] -ne '1') { throw 'Compact or no-activation contract failed' }
            $cases += [pscustomobject]@{ theme=$theme; panel=$panel; width=[int]$f[1]; height=[int]$f[2]; png=$png; full=(Join-Path $session 'header-native.png'); sha256=(Get-FileHash $png).Hash }
            "SUBMENU-NATIVE-CASE-PASS $theme-$panel $($f[1])x$($f[2])"
        }
    }
    [pscustomobject]@{ pass=$true; cases=$cases; limits=@('Native widget snapshots only; no desktop capture or foreground activation','Dropdown popup interaction is not exercised') } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $artifact 'receipt.json') -Encoding UTF8
    "SUBMENU-NATIVE-PASS cases=$($cases.Count) artifact=$artifact"
} finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    }
}
