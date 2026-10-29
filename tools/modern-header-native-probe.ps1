$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/modern-header-native-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifact | Out-Null
$saved = @{}
foreach ($name in @('PATH','NELISP_CALC_HIDDEN','NELISP_CALC_HEADER_PROBE','NELISP_CALC_COMMANDS','NELISP_CALC_THEME_FILE','NELISP_CALC_SMOKE','NELISP_CALC_KEYS')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
try {
    $bin = if ($env:MINGW_BIN) { $env:MINGW_BIN } else { Split-Path (Get-Command gcc).Source -Parent }
    $env:PATH = "$bin;$env:PATH"
    $env:NELISP_CALC_HIDDEN = '1'
    $env:NELISP_CALC_HEADER_PROBE = '1'
    $env:NELISP_CALC_SMOKE = $null
    $env:NELISP_CALC_KEYS = $null
    $exe = Join-Path $root ('target/' + (Get-Content (Join-Path $root 'target/current-gui.txt') -Raw).Trim())
    $cases = @()
    foreach ($theme in @('light','dark')) {
        foreach ($mode in @('standard','scientific')) {
            $session = Join-Path $artifact ($theme + '-' + $mode)
            New-Item -ItemType Directory -Force $session | Out-Null
            [IO.File]::WriteAllText((Join-Path $session 'response.txt'), "0`nready`n0`n")
            $env:NELISP_CALC_THEME_FILE = Join-Path $session 'theme.txt'
            [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,$theme)
            $env:NELISP_CALC_COMMANDS = if ($mode -eq 'scientific') { 'mode:scientific' } else { $null }
            $stderr = Join-Path $session 'stderr.log'
            $process = Start-Process -FilePath $exe -WorkingDirectory $session -WindowStyle Hidden -PassThru -RedirectStandardError $stderr
            if (-not $process.WaitForExit(5000)) { $process.Kill(); throw 'Owned offscreen header probe timed out' }
            if ($process.ExitCode -ne 0) { throw 'Native header probe failed' }
            if ((Get-Item $stderr).Length -ne 0) { throw "GTK/CSS diagnostic in $stderr" }
            $png = Join-Path $session 'header-native.png'
            if (-not (Test-Path $png) -or (Get-Item $png).Length -lt 1000) { throw 'Missing allocated GTK screenshot' }
            $fields = (Get-Content (Join-Path $session 'header-native.tsv') | Select-Object -Last 1).Split("`t")
            $width = [int]$fields[0]; $height = [int]$fields[1]
            if ($fields.Count -ne 9 -or $fields[6] -ne '1' -or $fields[7] -ne '1' -or $fields[8] -ne '1') { throw 'Activation, native window controls or resize contract failed' }
            if ([int]$fields[2] -lt 300 -or [int]$fields[3] -lt 28 -or [int]$fields[5] -lt 28) { throw 'Native header or navigation was not allocated' }
            if ($mode -eq 'standard' -and ($width -ne 381 -or $height -gt 600)) { throw "Compact geometry out of bounds: $width x $height" }
            if ($mode -eq 'scientific' -and ($width -lt 400 -or $height -gt 768)) { throw "Scientific geometry out of bounds: $width x $height" }
            $cases += [pscustomobject]@{ theme=$theme; mode=$mode; width=$width; height=$height; png=$png; sha256=(Get-FileHash $png).Hash }
            "HEADER-NATIVE-CASE-PASS $theme-$mode ${width}x${height}"
        }
    }
    [pscustomobject]@{ pass=$true; cases=$cases; limits=@('No desktop compositor frame capture','Native maximize/drag/minimize not exercised to avoid activation') } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $artifact 'receipt.json') -Encoding UTF8
    "HEADER-NATIVE-PASS cases=$($cases.Count) artifact=$artifact"
} finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    }
}
