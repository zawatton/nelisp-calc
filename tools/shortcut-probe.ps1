param([switch]$OldHandlerControl)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/shortcut-probes/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact -Force | Out-Null
$savedTheme = $env:NELISP_CALC_THEME_FILE
function Assert-Shortcut($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Invoke-ShortcutCase([string]$Name, [string[]]$Commands, [string]$Display, [string]$Handled, [string]$Tokens, [switch]$Entry) {
    $output = @(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $Commands -ExpectedDisplay $Display -Hidden)
    $receipt = @($output | Where-Object { $_ -match '^NATIVE-GTK-INTERACTION-OK session=' })[-1]
    Assert-Shortcut ($receipt -match 'session=(.+) mouse=') "Missing native receipt: $Name"
    $session = $Matches[1]
    $lines = @(Get-Content (Join-Path $session 'key-receipts.txt'))
    $actual = @($lines | ForEach-Object { $_.Split("`t")[2] }) -join ','
    Assert-Shortcut ($actual -ceq $Handled) "$Name handled returns: $actual"
    foreach ($line in $lines) {
        $fields = $line.Split("`t")
        Assert-Shortcut ($fields[6] -eq '2' -and $fields[7] -eq '1') "$Name controller is not window bubble"
        Assert-Shortcut ($fields[11] -eq '1' -and $fields[12] -eq '1') "$Name global controller is not window capture"
        Assert-Shortcut ([int]$fields[9]+[int]$fields[10] -eq [int]$fields[2]) "$Name duplicate dispatch across phases"
        if ($Entry) { Assert-Shortcut ($fields[3] -ceq '12345' -and $fields[4] -eq '1' -and $fields[5] -eq '3') "$Name entry text/selection changed" }
    }
    $requestPath = Join-Path $session 'requests.txt'
    $requests = if (Test-Path $requestPath) { [IO.File]::ReadAllText($requestPath) -replace "`r", '' } else { '' }
    Assert-Shortcut ($requests -ceq $Tokens) "$Name backend tokens differ; see $session"
    $destination = Join-Path $artifact $Name
    New-Item -ItemType Directory -Path $destination | Out-Null
    foreach ($file in @('key-receipts.txt','requests.txt','response.txt','memories.txt','native-interaction.png','theme-state.txt')) {
        $path = Join-Path $session $file
        if (Test-Path $path) { Copy-Item -LiteralPath $path -Destination $destination }
    }
    [ordered]@{name=$Name;display=$Display;handled=$actual;imageSha256=(Get-FileHash (Join-Path $destination 'native-interaction.png')).Hash} | ConvertTo-Json -Compress | Add-Content (Join-Path $artifact 'results.jsonl')
    "SHORTCUT-CASE-PASS $Name"
}
try {
    if ($OldHandlerControl) {
        Invoke-ShortcutCase 'old-unknown' @('ui:key:120:0') '0' '0' ''
        throw 'Old handler unexpectedly passed unknown-key propagation'
    }
    foreach ($theme in @('dark','light')) {
        $env:NELISP_CALC_THEME_FILE = Join-Path $artifact ($theme + '/theme.txt')
        New-Item -ItemType Directory (Split-Path $env:NELISP_CALC_THEME_FILE) -Force | Out-Null
        [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,$theme)
        Invoke-ShortcutCase ($theme+'-arithmetic-memory') @('ui:key:65458:16','ui:key:65451:0','ui:key:65459:2','ui:key:65421:0','ui:key:109:4','ui:key:65307:0','ui:key:50:0','ui:key:112:4','ui:key:65307:0','ui:key:49:0','ui:key:113:4','ui:key:65535:0','ui:key:114:4','ui:key:108:4') '6' '1,1,1,1,1,1,1,1,1,1,1,1,1,1' "2`nadd`n3`nequals`nmemory:store`nclear`n2`nmemory:add`nclear`n1`nmemory:sub`nce`nmemory:recall`nmemory:clear`n"
        Invoke-ShortcutCase ($theme+'-noise') @('ui:key:120:0','ui:key:50:4','ui:key:50:8','ui:key:50:12','ui:key:50:67108864','ui:key:50:134217728','ui:key:50:268435456','ui:key:109:5','ui:key:65535:4','ui:key:53:0') '5' '0,0,1,0,0,0,0,0,0,1' "mode:scientific`n5`n"
        Invoke-ShortcutCase ($theme+'-entry') @('eval:7','ui:entry:12345','ui:focus:entry','ui:entry-select','ui:key:50:0','ui:key:43:0','ui:key:65535:0','ui:key:65288:0','ui:key:65293:0','ui:key:99:4','ui:key:118:4','ui:key:109:4','ui:key:50:8','ui:key:115:0') '0' '0,0,0,0,0,0,0,1,1,0' "eval:7`nmemory:store`nmode:scientific`n" -Entry
        Invoke-ShortcutCase ($theme+'-scientific') @('ui:key:50:8','ui:key:50:0','ui:key:113:0','ui:key:64:1','ui:key:114:0','ui:key:110:0','ui:key:110:4','ui:key:65478:0') '-0.5' '1,1,1,1,1,1,1,1' "mode:scientific`n2`nfunction:square`nfunction:sqrt`nfunction:reciprocal`nfunction:ln`nfunction:exp`nsign`n"
        Invoke-ShortcutCase ($theme+'-trig') @('ui:key:50:8','ui:key:65473:0','ui:key:51:0','ui:key:48:0','ui:key:115:0','ui:key:83:9','ui:key:65475:0') '0.5' '1,1,1,1,1,0,0' "mode:scientific`nangle:deg`n3`n0`nfunction:sin`n"
        Invoke-ShortcutCase ($theme+'-programmer') @('ui:key:51:8','ui:key:65473:0','ui:key:65474:0','ui:key:97:0','ui:key:98:2','ui:key:65475:0','ui:key:114:0','ui:key:64:1','ui:key:37:5') '171' '1,1,1,1,1,1,0,0,0' "mode:programmer`nprog:word:8`nprog:base:hex`nA`nB`nprog:base:dec`n"
        Invoke-ShortcutCase ($theme+'-mixed-mode') @('ui:key:51:8','ui:key:65474:0','FF','ui:key:65475:0') '255' '1,1,1' "mode:programmer`nprog:base:hex`nprog:input:FF`nequals`nprog:base:dec`n"
        Invoke-ShortcutCase ($theme+'-mode-numpad') @('ui:key:52:8','ui:key:53:8','ui:key:49:8','ui:key:65457:0','ui:key:65454:0','ui:key:65461:0','ui:key:65450:0','ui:key:65458:0','ui:key:65293:0','ui:key:65307:0','ui:key:57:0','ui:key:65288:0') '0' '1,1,1,1,1,1,1,1,1,1,1,1' "mode:date`nmode:graph`nmode:standard`n1`ndot`n5`nmul`n2`nequals`nclear`n9`nbackspace`n"
    }
    "SHORTCUT-PROBE-PASS cases=16 artifact=$artifact"
} finally { $env:NELISP_CALC_THEME_FILE = $savedTheme }
