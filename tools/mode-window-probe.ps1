param([string]$NegativeExe)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/mode-window-probes/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifact | Out-Null
$saved = @{}
foreach ($name in @('PATH','NELISP_CALC_HIDDEN','NELISP_CALC_COMMANDS','NELISP_CALC_THEME_FILE','NELISP_CALC_SMOKE','NELISP_CALC_KEYS')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
function Assert-Size($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    if ($NegativeExe) {
        $exe = (Resolve-Path -LiteralPath $NegativeExe).Path
        $env:NELISP_CALC_HIDDEN='1'; $env:NELISP_CALC_SMOKE=$null; $env:NELISP_CALC_KEYS=$null
        $env:NELISP_CALC_COMMANDS='ui:nav:snapshot|ui:compact|ui:nav:snapshot'
        $env:NELISP_CALC_THEME_FILE=Join-Path $artifact 'theme.txt'
        [IO.File]::WriteAllText((Join-Path $artifact 'response.txt'),"42`nready`n0`n")
        $process=Start-Process -FilePath $exe -WorkingDirectory $artifact -WindowStyle Hidden -PassThru
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Owned negative fixture timed out' }
        Assert-Size ($process.ExitCode -eq 0) 'Negative fixture process failed'
        $row=(Get-Content (Join-Path $artifact 'navigation-native.tsv') | Where-Object { $_.Split("`t")[7] -eq '1' } | Select-Object -Last 1).Split("`t")
        # This is the same compact threshold enforced on the new native tree.
        Assert-Size ([int]$row[12] -le 400 -and [int]$row[14] -le 600) "COMPACT-SIZE-FAIL actual=$($row[12])x$($row[14]) artifact=$artifact"
        "MODE-WINDOW-SIZE-ONLY-PASS actual=$($row[12])x$($row[14]) artifact=$artifact"
        return
    }
    foreach ($theme in @('dark','light')) {
        $env:NELISP_CALC_THEME_FILE=Join-Path $artifact ($theme+'-theme.txt')
        [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,$theme)
        $commands=@('ui:nav:snapshot','ui:nav:menu','nav:mode:scientific','ui:nav:snapshot')
        foreach ($mode in @('standard','scientific','programmer','convert','date','graph','currency')) {
            $commands+=@(('mode:'+$mode),'ui:nav:snapshot')
        }
        $commands+=@('ui:key:49:8','ui:nav:snapshot','ui:nav:history','ui:nav:memory','ui:nav:settings','ui:nav:close',
            'ui:compact','ui:nav:snapshot','ui:compact','ui:nav:snapshot','clear','7','add','8','equals','ui:nav:snapshot')
        $output=@(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $commands -ExpectedDisplay 15 -Hidden -TimeoutSeconds 120)
        $line=@($output | Where-Object {$_ -match '^NATIVE-GTK-INTERACTION-OK session='})[-1]
        Assert-Size ($line -match 'session=(.+) mouse=') 'Missing native interaction session'
        $session=$Matches[1]
        $rows=@(Get-Content (Join-Path $session 'mode-window-native.tsv') | ForEach-Object { ,([int[]]$_.Split("`t")) })
        $seen=@{}
        foreach ($row in $rows) {
            Assert-Size ($row.Count -eq 12) 'Invalid geometry receipt'
            $seen[$row[0]]=$true
            Assert-Size ($row[6] -ge $row[2] -and $row[7] -ge $row[3] -and $row[8] -gt 0 -and $row[9] -gt 0) 'Invalid real GTK allocation'
            Assert-Size ($row[6] -le 1000 -and $row[7] -le 768) "Oversized mode $($row[0]): $($row[6])x$($row[7])"
            if ($row[0] -eq 0 -and $row[1] -eq 1) {
                Assert-Size ($row[2] -le 400 -and $row[3] -le 600 -and $row[6] -le 400 -and $row[7] -le 600) 'Standard did not recover compact geometry'
                Assert-Size ($row[10] -eq 0 -and $row[11] -eq 0) 'Standard contains unnecessary panels'
            }
            if ($row[0] -eq 4) { Assert-Size ($row[7] -le 650 -and $row[9] -le 220) 'Date retained an unnecessary keypad' }
        }
        Assert-Size ($seen.Count -eq 7) 'Not all native modes were exercised'
        $nav=@(Get-Content (Join-Path $session 'navigation-native.tsv') | ForEach-Object { ,$_.Split("`t") })
        foreach ($row in $nav) { Assert-Size ($row[10] -eq '1') 'Native navigation access was lost' }
        Assert-Size ($nav[-1][1] -eq 'Standard' -and $nav[-1][9] -eq '15') 'Scaled native mouse click arithmetic failed'
        Copy-Item -LiteralPath $session -Destination (Join-Path $artifact $theme) -Recurse
        "MODE-WINDOW-CASE-PASS theme=$theme modes=7 standard=$($rows[-1][6])x$($rows[-1][7]) rows=$($rows.Count)"
    }
    "MODE-WINDOW-PASS themes=2 modes=7 artifact=$artifact"
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
}
