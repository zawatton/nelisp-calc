param([switch]$KeepDrawerClosedForControl, [switch]$BackendOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/navigation-access-probes/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifact | Out-Null
$saved = @{}
foreach ($name in @('PATH','NELISP_CALC_HIDDEN','NELISP_CALC_COMMANDS','NELISP_CALC_THEME_FILE','NELISP_CALC_SMOKE','NELISP_CALC_KEYS')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
function Assert-Access($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Read-Access([string]$Session) {
    $path = Join-Path $Session 'navigation-native.tsv'
    Assert-Access (Test-Path -LiteralPath $path) 'Missing native navigation structure receipt'
    $rows = @(Get-Content -LiteralPath $path | ForEach-Object {
        $fields = $_.Split("`t")
        Assert-Access ($fields.Count -eq 16) 'Invalid navigation receipt shape'
        Assert-Access ($fields[10] -eq '1') 'Native labels, visibility or panel ownership failed'
        Assert-Access (([int]$fields[3]+[int]$fields[4]+[int]$fields[5]+[int]$fields[6]) -le 1) 'Panels are not exclusive'
        [pscustomobject]@{ Fields=$fields }
    })
    return $rows
}
function Invoke-AccessLayout([string]$Theme) {
    $session = Join-Path $artifact ($Theme+'-layout')
    New-Item -ItemType Directory -Force $session | Out-Null
    [IO.File]::WriteAllText((Join-Path $session 'response.txt'),"42`nready`n0`n")
    $env:NELISP_CALC_THEME_FILE = Join-Path $session 'theme.txt'
    [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,$Theme)
    $env:NELISP_CALC_HIDDEN = '1'; $env:NELISP_CALC_SMOKE=$null; $env:NELISP_CALC_KEYS=$null
    $menu = if ($KeepDrawerClosedForControl) {'ui:nav:snapshot'} else {'ui:nav:menu'}
    $env:NELISP_CALC_COMMANDS = @('ui:entry:123+4','ui:nav:snapshot',$menu,'ui:nav:history','ui:nav:memory','ui:nav:settings','ui:compact','ui:nav:snapshot','ui:compact','ui:nav:snapshot','ui:nav:close') -join '|'
    $gui = Join-Path $root 'target/nelisp-calc.exe'
    $pointer = Join-Path $root 'target/current-gui.txt'
    if (Test-Path -LiteralPath $pointer) { $gui = Join-Path $root ('target/'+[IO.File]::ReadAllText($pointer).Trim()) }
    $process = Start-Process -FilePath $gui -WorkingDirectory $session -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $session 'native.stderr.log')
    if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Owned hidden native layout probe timed out' }
    Assert-Access ($process.ExitCode -eq 0) 'Hidden native layout process failed'
    $rows = @(Read-Access $session)
    Assert-Access ($rows.Count -eq 8) 'Unexpected layout receipt count'
    # The first row is the closed baseline; every open must reveal the actual panel.
    foreach ($pair in @(@(1,6504),@(2,6512),@(3,6520),@(4,6528))) {
        $f=$rows[$pair[0]].Fields
        Assert-Access ($f[2] -eq [string]$pair[1] -and $f[11] -eq '1') "Native drawer visibility/focus contract failed at row $($pair[0])"
    }
    foreach ($row in $rows) {
        $f=$row.Fields
        Assert-Access ($f[8] -eq '123+4' -and $f[9] -eq '42') 'Panel changed entry or calculation display'
        Assert-Access ([int]$f[14] -le 768 -and [int]$f[15] -le 768) 'Navigation caused offscreen vertical growth'
        if ($f[7] -eq '1') { Assert-Access ($f[14] -eq $rows[0].Fields[14] -and $f[15] -eq $rows[0].Fields[15]) 'Opening panels changed compact-layout height' }
    }
    Assert-Access ($rows[0].Fields[7] -eq '1' -and $rows[5].Fields[7] -eq '0' -and $rows[6].Fields[7] -eq '1') 'Automatic Compact / Full recovery failed'
    Assert-Access ($rows[7].Fields[2] -eq '0' -and $rows[7].Fields[11] -eq '1') 'Close did not restore opener focus'
    Assert-Access (-not (Test-Path -LiteralPath (Join-Path $session 'requests.txt'))) 'UI-only access submitted a calculation'
    "ACCESS-NATIVE-CASE-PASS $Theme-layout height=$($rows[0].Fields[14])"
}
function Invoke-AccessBackend([string]$Theme) {
    $env:NELISP_CALC_THEME_FILE=Join-Path $artifact ($Theme+'-backend-theme.txt')
    [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,$Theme)
    $commands=@('ui:nav:menu','nav:mode:scientific','9','function:sqrt','ui:nav:snapshot',
        'memory:store','eval:12','memory:store','ui:nav:memory','memory:select:1','memory:recall','ui:nav:snapshot',
        'memory:remove','ui:nav:history','history:recall:0','ui:nav:snapshot','ui:nav:close',
        'ui:nav:settings',('ui:theme:'+$(if($Theme -eq 'dark'){'light'}else{'dark'})),('ui:theme:'+$Theme),'ui:nav:close')
    foreach ($key in @(49,50,51,52,53,50)) { $commands+=@(('ui:key:'+$key+':8'),'ui:nav:snapshot') }
    $commands+=@('ui:nav:menu','nav:mode:programmer','15','ui:nav:snapshot')
    $output=@(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $commands -ExpectedDisplay 15 -Hidden -TimeoutSeconds 120)
    $line=@($output | Where-Object {$_ -match '^NATIVE-GTK-INTERACTION-OK session='})[-1]
    Assert-Access ($line -match 'session=(.+) mouse=') 'Missing native backend session'
    $session=$Matches[1]
    $rows=@(Read-Access $session)
    Assert-Access ($rows[0].Fields[2] -eq '6504') 'Menu was not open before choosing Scientific'
    Assert-Access ($rows[1].Fields[1] -eq 'Scientific' -and $rows[1].Fields[2] -eq '0') 'Mode click did not close drawer/update caption'
    Assert-Access ($rows[2].Fields[9] -eq '3') 'Scientific native sqrt did not calculate 3'
    Assert-Access ($rows[4].Fields[9] -eq '3' -and $rows[4].Fields[2] -eq '6520') 'Memory panel did not recall selected older value'
    Assert-Access ($rows[6].Fields[9] -eq '12' -and $rows[6].Fields[2] -eq '6512') 'History panel did not recall actual history'
    $captions=@($rows | Where-Object {$_.Fields[0] -eq 'ui:nav:snapshot'} | Select-Object -Last 7 | Select-Object -First 6 | ForEach-Object {$_.Fields[1]}) -join ','
    Assert-Access ($captions -eq 'Standard,Scientific,Programmer,Date,Graph,Scientific') 'Alt mode caption routing failed'
    $requests=[IO.File]::ReadAllText((Join-Path $session 'requests.txt')).Replace("`r",'')
    $expected="mode:scientific`n9`nfunction:sqrt`nmemory:store`neval:12`nmemory:store`nmemory:select:1`nmemory:recall`nmemory:remove`nhistory:recall:0`nmode:standard`nmode:scientific`nmode:programmer`nmode:date`nmode:graph`nmode:scientific`n"
    $expected+="mode:programmer`nprog:input:15`nequals`n"
    Assert-Access ($requests -ceq $expected) 'Access controls submitted unexpected backend commands'
    Assert-Access ([IO.File]::ReadAllText((Join-Path $session 'memories.txt')).Replace("`r",'') -eq "0`t12`n") 'Memory removal did not preserve other actual entry'
    Copy-Item -LiteralPath $session -Destination (Join-Path $artifact ($Theme+'-backend')) -Recurse
    "ACCESS-NATIVE-CASE-PASS $Theme-backend"
}
try {
    $bin=if($env:MINGW_BIN){$env:MINGW_BIN}else{Split-Path (Get-Command gcc -ErrorAction Stop).Source -Parent}
    $env:PATH="$bin;$env:PATH"
    foreach($theme in @('dark','light')) { if(-not $BackendOnly){Invoke-AccessLayout $theme}; Invoke-AccessBackend $theme }
    $caseCount=if($BackendOnly){2}else{4}
    "ACCESS-NATIVE-PASS cases=$caseCount artifact=$artifact"
} finally {
    foreach($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
}
