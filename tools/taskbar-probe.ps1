param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$target = Join-Path $root 'target'
$launcher = Join-Path $target 'NeLispCalc.exe'
if (-not (Test-Path -LiteralPath $launcher)) {
    $launcher = Join-Path (Split-Path $root -Parent) 'NeLispCalc.exe'
}
$links = Join-Path $target ('taskbar-links-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $links -Force | Out-Null
$savedId = $env:NELISP_CALC_APP_ID
$savedHidden = $env:NELISP_CALC_HIDDEN
$env:NELISP_CALC_APP_ID = 'Fujisawa.NeLispCalc.Test.' + [guid]::NewGuid().ToString('N')
$env:NELISP_CALC_HIDDEN = '1'
$guiId = $null
$proof = @{ appId = $env:NELISP_CALC_APP_ID; modes = @(); invalidExitCodes = @() }
function Invoke-Launcher([string[]]$Arguments) {
    $p = Start-Process -FilePath $launcher -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait
    return $p.ExitCode
}
function Await-File([string]$Path, [string]$Text) {
    $limit = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -eq $Text) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $limit)
    throw "Expected receipt was not produced: $Path"
}
try {
    if (Test-Path (Join-Path $target 'taskbar-session.json')) { throw 'Probe requires an isolated checkout with no running calculator session' }
    if ((Invoke-Launcher @('--register')) -ne 0) { throw 'ICustomDestinationList commit failed' }
    if ((Invoke-Launcher @('--export-tasks', ('"' + $links + '"'))) -ne 0) { throw 'Task export failed' }
    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.NameSpace($links)
    $wscript = New-Object -ComObject WScript.Shell
    foreach ($mode in @('scientific','standard','programmer','graph','date','convert','currency')) {
        $path = Join-Path $links ($mode + '.lnk')
        $item = $folder.ParseName($mode + '.lnk')
        $shortcut = $wscript.CreateShortcut($path)
        if ($item.ExtendedProperty('System.AppUserModel.ID') -ne $env:NELISP_CALC_APP_ID -or
            $shortcut.Arguments -ne ('--mode ' + $mode) -or $shortcut.TargetPath -ne $launcher) { throw 'COM task readback mismatch' }
        # Invoke the persisted IShellLink through the Shell, as the taskbar does.
        Start-Process -FilePath $path -WindowStyle Hidden
        $limit = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path (Join-Path $target 'taskbar-session.json'))) {
            if ([DateTime]::UtcNow -gt $limit) { throw 'No GUI session' }
            Start-Sleep -Milliseconds 100
        }
        $state = Get-Content (Join-Path $target 'taskbar-session.json') -Raw | ConvertFrom-Json
        if ($guiId -and $guiId -ne $state.guiPid) { throw 'Task started a duplicate GUI' }
        $guiId = $state.guiPid
        Await-File (Join-Path $state.session 'taskbar-receipt.txt') ('mode:' + $mode)
        Await-File (Join-Path $state.session 'taskbar-identity.txt') $env:NELISP_CALC_APP_ID
        $proof.modes += @{ mode=$mode; guiPid=$guiId; title=$item.ExtendedProperty('System.Title') }
    }
    foreach ($arguments in @(@('--mode','unknown'),@('--mode'),@('--mode','date','--mode','graph'),@('--unknown'))) {
        $code = Invoke-Launcher $arguments
        if ($code -ne 2) { throw 'Invalid native argument accepted' }
        $proof.invalidExitCodes += $code
    }
    $requests = Join-Path $state.session 'requests.txt'
    $limit = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $settled = @(Get-Content -LiteralPath $requests)
        if ($settled.Count -eq 7) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $limit)
    if ($settled.Count -ne 7) { throw ('Sequential backend mode requests did not settle: ' + ($settled -join '|')) }
    $before = @(Get-Content -LiteralPath $requests).Count
    $children = foreach ($mode in @('date','standard','scientific')) {
        Start-Process -FilePath $launcher -ArgumentList '--mode',$mode -WindowStyle Hidden -PassThru
    }
    foreach ($child in $children) { $child.WaitForExit() }
    $limit = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $after = @(Get-Content -LiteralPath $requests)
        if ($after.Count -ge $before + 3) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $limit)
    $tail = @($after | Select-Object -Skip $before | Sort-Object)
    if (($tail -join '|') -ne 'mode:date|mode:scientific|mode:standard') { throw ('Concurrent mode requests were lost or duplicated: ' + ($tail -join '|')) }
    $again = Get-Content (Join-Path $target 'taskbar-session.json') -Raw | ConvertFrom-Json
    if ($again.guiPid -ne $guiId) { throw 'Concurrent invocation duplicated GUI' }
    $proof.concurrent = @{ samePid=$true; requests=$tail }
    $proof.guiPid = $guiId
    $proof.status = 'PASS'
    $proof | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $target 'taskbar-proof.json') -Encoding UTF8
    $proof | ConvertTo-Json -Depth 5 -Compress
} finally {
    # Only the PID created by this isolated probe is eligible for cleanup.
    if ($guiId) { Stop-Process -Id $guiId -ErrorAction SilentlyContinue }
    $env:NELISP_CALC_APP_ID = $savedId
    $env:NELISP_CALC_HIDDEN = $savedHidden
}
