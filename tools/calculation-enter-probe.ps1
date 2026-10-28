param([string]$ControlGui)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/calculation-enter-probes/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifact | Out-Null
function Assert-Enter($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-EnterCase([string]$Name, [string[]]$Commands, [string]$Tokens, [string]$Focus) {
    $output = @(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $Commands -ExpectedDisplay 15 -Hidden -TimeoutSeconds 90)
    $line = @($output | Where-Object { $_ -match '^NATIVE-GTK-INTERACTION-OK session=' })[-1]
    Assert-Enter ($line -match 'session=(.+) mouse=') 'Missing interaction session'
    $session = $Matches[1]
    $actual = [IO.File]::ReadAllText((Join-Path $session 'requests.txt')).Replace("`r", '')
    Assert-Enter ($actual -ceq $Tokens) "$Name submitted duplicate or unexpected requests"
    $focusRows = @(Get-Content (Join-Path $session 'calculation-focus.tsv'))
    Assert-Enter (($focusRows -join ',') -ceq $Focus) "$Name native focus/menu mismatch: $($focusRows -join ',')"
    Copy-Item -LiteralPath $session -Destination (Join-Path $artifact $Name) -Recurse
    "CALCULATION-ENTER-CASE-PASS $Name"
}
if ($ControlGui) {
    # This uses the old executable's existing native focus receipt, not new instrumentation.
    $saved = @{}
    foreach ($name in @('PATH','NELISP_CALC_HIDDEN','NELISP_CALC_COMMANDS','NELISP_CALC_TARGET','NELISP_CALC_KEYS','NELISP_CALC_SMOKE','NELISP_CALC_THEME_FILE')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
    $backend = $null; $gui = $null
    try {
        $bin = if ($env:MINGW_BIN) { $env:MINGW_BIN } else { Split-Path (Get-Command gcc).Source -Parent }
        $env:PATH = "$bin;$env:PATH"; $env:NELISP_CALC_HIDDEN = '1'
        $env:NELISP_CALC_TARGET = $artifact; $env:NELISP_CALC_KEYS = $null; $env:NELISP_CALC_SMOKE = $null
        $env:NELISP_CALC_THEME_FILE = Join-Path $artifact 'theme.txt'
        $env:NELISP_CALC_COMMANDS = 'ui:key:50:8|ui:nav:snapshot'
        $nelisp = if ($env:NELISP_BIN) { $env:NELISP_BIN } else { Join-Path (Split-Path $root -Parent) 'nelisp/target/nelisp.exe' }
        $server = Join-Path $root 'lisp/nelisp-calc-mailbox.el'
        $backend = Start-Process -FilePath $nelisp -ArgumentList @('--load', ('"'+$server+'"')) -WorkingDirectory $artifact -WindowStyle Hidden -PassThru
        $gui = Start-Process -FilePath $ControlGui -WorkingDirectory $artifact -WindowStyle Hidden -PassThru
        Assert-Enter ($gui.WaitForExit(30000)) 'Control timed out'
        $row = @(Get-Content (Join-Path $artifact 'navigation-native.tsv'))[-1].Split("`t")
        [IO.File]::WriteAllText((Join-Path $artifact 'negative-control.txt'), "menuOwnsFocus=$($row[11])`n")
        Assert-Enter ($row[11] -eq '0') "CALCULATION-ENTER-NEGATIVE-REJECTED Menu owns actual GTK focus; artifact=$artifact"
        throw 'Old executable unexpectedly passed calculation focus invariant'
    } finally {
        foreach ($process in @($gui,$backend)) { if ($process -and -not $process.HasExited) { $process.Kill() } }
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    }
}
foreach ($enter in @(65293,65421)) {
    Invoke-EnterCase ("mouse-$enter") @('ui:nav:menu','nav:mode:standard','ui:calc-focus','7','add','8','ui:calc-focus',"ui:key:${enter}:0",'ui:calc-focus') "mode:standard`n7`nadd`n8`nequals`n" "1`t0`t0,1`t0`t0,1`t0`t0"
    Invoke-EnterCase ("keys-$enter") @('ui:key:50:8','ui:calc-focus','ui:nav:menu','ui:nav:close','ui:calc-focus',"ui:key:${enter}:0",'ui:key:55:0','ui:key:43:0','ui:key:56:0',"ui:key:${enter}:0",'ui:calc-focus') "mode:scientific`n7`nadd`n8`nequals`n" "1`t0`t0,0`t1`t0,1`t0`t0"
}
# Signals exercise real drawing-area click callbacks and window controller handlers.
# They do not emulate OS keyboard propagation through a focused GtkButton.
"CALCULATION-ENTER-PASS cases=4 artifact=$artifact"
