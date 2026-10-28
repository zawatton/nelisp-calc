param([hashtable]$ExistingSessions = @{})
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/navigation-native/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact -Force | Out-Null
$savedTheme = $env:NELISP_CALC_THEME_FILE
Add-Type -AssemblyName System.Drawing
function Assert-Navigation($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Invoke-NavigationCase([string]$Name, [string[]]$Commands, [string]$Range, [string]$ExpectedRequests, [string]$Display, [string]$Status, [string]$Handled, [switch]$Square) {
    if ($ExistingSessions.ContainsKey($Name)) {
        $session = $ExistingSessions[$Name]
        $response = @(Get-Content (Join-Path $session 'response.txt'))
        Assert-Navigation ($response[0] -ceq $Display -and $response[1] -match $Status -and [int]$response[2] -eq $ExpectedRequests.Split("`n",[StringSplitOptions]::RemoveEmptyEntries).Count) "$Name existing response mismatch"
    } else {
        $output = @(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $Commands -ExpectedDisplay $Display -ExpectedStatus $Status -Hidden -TimeoutSeconds 180)
        $receipt = @($output | Where-Object { $_ -match '^NATIVE-GTK-INTERACTION-OK session=' })[-1]
        Assert-Navigation ($receipt -match 'session=(.+) mouse=') "Missing native receipt: $Name"
        $session = $Matches[1]
    }
    foreach ($fileName in @('graph-range.txt','graph-fields.txt')) {
        Assert-Navigation ([IO.File]::ReadAllText((Join-Path $session $fileName)) -ceq $Range) "$Name authoritative/native range mismatch: $fileName"
    }
    Assert-Navigation (([IO.File]::ReadAllText((Join-Path $session 'requests.txt')) -replace "`r", '') -ceq $ExpectedRequests) "$Name duplicate or incorrect backend tokens"
    $graph = [IO.File]::ReadAllText((Join-Path $session 'graph.txt')) -replace "`r", ''
    $valid = @($graph.Split("`n") | Where-Object { $_ -match '^1 ' }).Count
    Assert-Navigation ($valid -eq $(if ($Square) { 45 } else { 101 })) "$Name actual genuine sample count: $valid"
    Assert-Navigation ($graph.Contains($(if ($Square) { "1 250 500`n" } else { "1 500 500`n" }))) "$Name deterministic projection missing"
    if ($Handled) {
        $keys = @(Get-Content (Join-Path $session 'key-receipts.txt'))
        Assert-Navigation ((@($keys | ForEach-Object { $_.Split("`t")[2] }) -join ',') -ceq $Handled) "$Name key handled mismatch"
        foreach ($line in $keys) {
            $fields = $line.Split("`t")
            Assert-Navigation ($fields.Count -eq 13 -and ([int]$fields[9]+[int]$fields[10] -eq [int]$fields[2])) "$Name key dispatched twice"
            Assert-Navigation ($fields[6] -eq '2' -and $fields[7] -eq '1' -and $fields[11] -eq '1' -and $fields[12] -eq '1') "$Name controller phase or attachment"
        }
        foreach ($line in $keys | Select-Object -Last 2) {
            $fields = $line.Split("`t")
            Assert-Navigation ($fields[3] -ceq '12345' -and $fields[4] -eq '1' -and $fields[5] -eq '3' -and $fields[9] -eq '1' -and $fields[10] -eq '0') "$Name global zoom changed entry or bubbled"
        }
    }
    $bitmap = [Drawing.Bitmap]::FromFile((Join-Path $session 'native-interaction.png'))
    try {
        $curve = if ($Name.StartsWith('light')) { [Drawing.Color]::FromArgb(0,95,170).ToArgb() } else { [Drawing.Color]::FromArgb(89,194,255).ToArgb() }
        $pixels = 0; $forbidden = 0
        for ($y=193; $y -lt 538; $y++) { for ($x=18; $x -lt 382; $x++) {
            if ($bitmap.GetPixel($x,$y).ToArgb() -eq $curve) { $pixels++; if ($x -gt 300) { $forbidden++ } }
        } }
        Assert-Navigation ($pixels -gt 100) "$Name rendered curve missing"
        if ($Square) { Assert-Navigation ($forbidden -eq 0) "$Name curve remains in old/unbounded geometry" }
    } finally { $bitmap.Dispose() }
    $size = [IO.File]::ReadAllBytes((Join-Path $session 'graph-controls-size.bin'))
    $width = [BitConverter]::ToInt32($size,0); $height = [BitConverter]::ToInt32($size,16)
    Assert-Navigation ($width -gt 0 -and $width -le 540 -and $height -gt 0 -and $height -le 560) "$Name graph panel size $width x $height"
    $destination = Join-Path $artifact $Name
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    foreach ($fileName in @('graph-range.txt','graph-fields.txt','graph-controls-size.bin','graph.txt','response.txt','requests.txt','key-receipts.txt','native-interaction.png','native-backend.stderr.log')) {
        $path = Join-Path $session $fileName
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $destination }
    }
    [ordered]@{name=$Name;session=$session;range=$Range;validSamples=$valid;curvePixels=$pixels;negativeStripCurvePixels=$forbidden;panelWidth=$width;panelHeight=$height;imageSha256=(Get-FileHash (Join-Path $destination 'native-interaction.png')).Hash} | ConvertTo-Json -Compress | Add-Content (Join-Path $artifact 'results.jsonl')
    "NAVIGATION-NATIVE-CASE-PASS $Name samples=$valid curvePixels=$pixels panel=$width`x$height"
}
try {
    foreach ($theme in @('dark','light')) {
        $env:NELISP_CALC_THEME_FILE = Join-Path $artifact ($theme + '-theme.txt')
        [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,$theme)
        Invoke-NavigationCase ($theme+'-buttons') @('mode:graph','graph:x^2','graph:nav:in','graph:nav:right','graph:nav:left','graph:nav:up','graph:nav:down','graph:nav:out','graph:nav:reset','graph:nav:in','graph:nav:right') '-2.5:7.5:-5:5' "mode:graph`ngraph:x^2`ngraph:nav:in`ngraph:nav:right`ngraph:nav:left`ngraph:nav:up`ngraph:nav:down`ngraph:nav:out`ngraph:nav:reset`ngraph:nav:in`ngraph:nav:right`n" '45 points' '^ok:graph:x\^2:45/101$' '' -Square
        Invoke-NavigationCase ($theme+'-keys-rejected-range') @('ui:key:65451:4','ui:key:65453:4','mode:graph','graph:x','ui:entry:12345','ui:focus:entry','ui:entry-select','ui:key:65451:4','ui:key:65453:4','graph:range:10:-10:-10:10') '-10:10:-10:10' "mode:graph`ngraph:x`ngraph:nav:in`ngraph:nav:out`ngraph:range:10:-10:-10:10`n" 'ERROR' '^mode-error:' '0,0,1,1'
    }
    "NAVIGATION-NATIVE-PASS cases=4 artifact=$artifact"
} finally { $env:NELISP_CALC_THEME_FILE = $savedTheme }
