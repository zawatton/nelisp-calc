param([switch]$IgnoreSelectionForControl)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/memory-probes/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact -Force | Out-Null
$savedTheme = $env:NELISP_CALC_THEME_FILE
$env:NELISP_CALC_THEME_FILE = Join-Path $artifact 'theme.txt'
function Assert-Memory($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Invoke-MemoryCase([string]$Name, [string[]]$Commands, [string]$Display, [string]$Rows, [string]$Index, [string]$Theme) {
    if ($IgnoreSelectionForControl) { $Commands = @($Commands | Where-Object { $_ -notmatch '^memory:select:' }) }
    $output = @(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $Commands -ExpectedDisplay $Display -Hidden -TimeoutSeconds 55)
    $receipt = @($output | Where-Object { $_ -match '^NATIVE-GTK-INTERACTION-OK session=' })[-1]
    Assert-Memory ($receipt -match 'session=(.+) mouse=') "Missing native receipt: $Name"
    $session = $Matches[1]
    $destination = Join-Path $artifact $Name
    New-Item -ItemType Directory -Path $destination | Out-Null
    foreach ($file in @('memories.txt','memory.txt','memory-index.txt','memory-native-index.txt','memory-native-value.txt','memory-native-width.bin','history.txt','requests.txt','response.txt','theme-state.txt','native-interaction.png')) {
        $path = Join-Path $session $file
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $destination }
    }
    Assert-Memory ([IO.File]::ReadAllText((Join-Path $session 'memories.txt')) -ceq $Rows) "$Name memory collection mismatch"
    Assert-Memory ([IO.File]::ReadAllText((Join-Path $session 'memory-index.txt')) -ceq $Index) "$Name backend selection mismatch"
    Assert-Memory ([IO.File]::ReadAllText((Join-Path $session 'memory-native-index.txt')) -ceq $Index) "$Name GTK selection mismatch"
    $selectedText = if ($Index -eq '-1') { '' } else { $Display }
    Assert-Memory ([IO.File]::ReadAllText((Join-Path $session 'memory-native-value.txt')) -ceq $selectedText) "$Name GTK selected text mismatch"
    Assert-Memory ([IO.File]::ReadAllText((Join-Path $session 'memory.txt')) -ceq $(if ($Index -eq '-1') { '' } else { $Display + "`n" })) "$Name selected compatibility snapshot mismatch"
    $widths = [IO.File]::ReadAllBytes((Join-Path $session 'memory-native-width.bin'))
    $minimumWidth = [BitConverter]::ToInt32($widths, 0)
    $naturalWidth = [BitConverter]::ToInt32($widths, 4)
    Assert-Memory ($minimumWidth -gt 0 -and $minimumWidth -le 920 -and $naturalWidth -le 920) "$Name desktop bar too wide: minimum=$minimumWidth natural=$naturalWidth"
    Assert-Memory ([IO.File]::ReadAllText((Join-Path $session 'theme-state.txt')) -ceq $Theme) "$Name appearance mismatch"
    $requests = [IO.File]::ReadAllText((Join-Path $session 'requests.txt'))
    Assert-Memory ($requests -match 'memory:select:1') "$Name native changed callback missing"
    [ordered]@{name=$Name;display=$Display;index=$Index;theme=$Theme;rows=$Rows;minimumWidth=$minimumWidth;naturalWidth=$naturalWidth;imageSha256=(Get-FileHash (Join-Path $destination 'native-interaction.png')).Hash} | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $artifact 'results.jsonl')
    "MEMORY-CASE-PASS $Name"
}
try {
    foreach ($theme in @('dark','light')) {
        # Distinct values prove that selecting the older native row matters.
        Invoke-MemoryCase ($theme + '-update') @('eval:12','memory:store','eval:34','memory:store',('ui:theme:' + $theme),'memory:select:1','eval:3','memory:add','memory:recall') '15' "0`t34`n1`t15`n" '1' $theme
        Invoke-MemoryCase ($theme + '-remove') @('eval:12','memory:store','eval:34','memory:store',('ui:theme:' + $theme),'memory:select:1','memory:remove','memory:recall') '34' "0`t34`n" '0' $theme
        Invoke-MemoryCase ($theme + '-clear') @('eval:12','memory:store','eval:34','memory:store',('ui:theme:' + $theme),'memory:select:1','memory:clear') '34' '' '-1' $theme
    }
    "MEMORY-PROBE-PASS cases=6 artifact=$artifact"
} finally {
    $env:NELISP_CALC_THEME_FILE = $savedTheme
}
