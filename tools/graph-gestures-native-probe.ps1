param([hashtable]$ExistingSessions = @{})
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/gestures-native/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact -Force | Out-Null
$savedTheme = $env:NELISP_CALC_THEME_FILE
Add-Type -AssemblyName System.Drawing
function Assert-Gesture($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Invoke-GestureCase([string]$Name, [string[]]$Commands, [string]$Range, [string[]]$Requests, [int]$Submissions, [string]$Display, [string]$Status) {
    if ($ExistingSessions.ContainsKey($Name)) { $session = $ExistingSessions[$Name] } else {
        $output = @(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $Commands -ExpectedDisplay $Display -ExpectedStatus $Status -Hidden -TimeoutSeconds 180)
        $receipt = @($output | Where-Object { $_ -match '^NATIVE-GTK-INTERACTION-OK session=' })[-1]
        Assert-Gesture ($receipt -match 'session=(.+) mouse=') "Missing native gesture session: $Name"
        $session = $Matches[1]
    }
    $response = @(Get-Content (Join-Path $session 'response.txt'))
    Assert-Gesture ($response[0] -eq $Display -and $response[1] -match $Status -and [int]$response[2] -eq $Requests.Count) "$Name response mismatch"
    foreach ($file in @('graph-range.txt','graph-fields.txt')) {
        Assert-Gesture ([IO.File]::ReadAllText((Join-Path $session $file)) -ceq $Range) "$Name accepted/native range disagreement: $file"
    }
    $actual = [IO.File]::ReadAllText((Join-Path $session 'requests.txt')) -replace "`r", ''
    Assert-Gesture ($actual -ceq (($Requests -join "`n") + "`n")) "$Name duplicate or incorrect gesture requests: $actual"
    $submitted = @(Get-Content (Join-Path $session 'gesture-submissions.txt'))
    Assert-Gesture ($submitted.Count -eq $Submissions) "$Name wrong render submission count"
    Assert-Gesture ([IO.File]::ReadAllText((Join-Path $session 'gesture-grouped.txt')) -ceq '1') "$Name drag and click controllers not grouped"
    $rows = @(Get-Content (Join-Path $session 'gesture-receipts.txt') | ForEach-Object { ,($_.Split("`t")) })
    Assert-Gesture ($rows.Count -gt 0) "$Name missing native signal receipts"
    foreach ($row in $rows) {
        Assert-Gesture ($row.Count -eq 15) "$Name malformed receipt"
        Assert-Gesture (($row[7..12] -join ',') -ceq '2,2,1,5,1,1') "$Name controller phase/button/flags/attachment mismatch"
        if ($row[0] -eq 'drag-update') { Assert-Gesture ($row[5] -eq '0') "$Name update rendered before drag completion" }
    }
    if ($Name -eq 'dark-drag-wheel-guards') {
        $begins = @($rows | Where-Object { $_[0] -eq 'drag-begin' })
        Assert-Gesture ($begins[0][2] -eq '0' -and $begins[1][2] -eq '0' -and $begins[2][2] -eq '1') 'Outside-start or inside-start recognition failed'
        Assert-Gesture (@($rows | Where-Object { $_[0] -eq 'cancel' -and $_[2] -eq '0' }).Count -eq 1) 'Inherited cancel signal failed'
        Assert-Gesture (@($rows | Where-Object { $_[0] -eq 'scroll' -and $_[1] -eq '0' }).Count -ge 2) 'Horizontal/non-graph scroll was consumed'
        Assert-Gesture (@($rows | Where-Object { $_[0] -eq 'scroll' -and $_[3] -eq '0' }).Count -ge 2) 'Opposite wheel deltas did not cancel'
        Assert-Gesture (@($rows | Where-Object { $_[0] -eq 'mode:' -and $_[3] -eq '0' -and $_[4] -eq '0' }).Count -eq 1) 'Mode switch retained pending wheel'
    }
    if ($Name -eq 'light-scaled-capped') {
        $scaled = @($rows | Where-Object { $_[0] -eq 'drag-begin' })[0]
        Assert-Gesture ($scaled[13] -eq '800' -and $scaled[14] -eq '1120' -and $scaled[2] -eq '1') 'Real hidden GTK allocation or scaled plot hit test failed'
        Assert-Gesture ($submitted[0] -ceq 'graph:shift:250:-100' -and $submitted[1] -ceq 'graph:zoom:-4') 'Scaled drag direction or wheel cap failed'
    }
    if ($Name -eq 'dark-busy-mixed') {
        $begins = @($rows | Where-Object { $_[0] -eq 'drag-begin' })
        Assert-Gesture ($begins[0][2] -eq '0' -and $begins[-1][2] -eq '1') 'Busy-start guard failed'
        Assert-Gesture (@($rows | Where-Object { $_[0] -eq 'drag-end' -and $_[5] -eq '0' }).Count -ge 1) 'Mixed wheel did not cancel drag'
        Assert-Gesture (@($rows | Where-Object { $_[0] -eq 'scroll' -and $_[3] -eq '2000' -and $_[5] -eq '1' }).Count -eq 1) 'Busy wheel did not coalesce in single pending net'
    }
    $graph = [IO.File]::ReadAllText((Join-Path $session 'graph.txt'))
    Assert-Gesture ($graph.StartsWith("SCG1`n") -and $graph -match '1 [0-9]+ [0-9]+') "$Name genuine sample data missing"
    $projection = switch ($Name) { 'dark-drag-wheel-guards' { '1 500 212' }; 'light-scaled-capped' { '1 500 416' }; 'dark-busy-mixed' { '1 500 500' } }
    Assert-Gesture ($graph.Contains($projection + "`n")) "$Name curve projection did not follow accepted viewport"
    $image = [Drawing.Bitmap]::FromFile((Join-Path $session 'native-interaction.png'))
    try {
        $curve = if ($Name.StartsWith('light')) { [Drawing.Color]::FromArgb(0,95,170).ToArgb() } else { [Drawing.Color]::FromArgb(89,194,255).ToArgb() }
        $pixels = 0
        for ($y=192; $y -lt 539; $y++) { for ($x=17; $x -lt 383; $x++) {
            if ($image.GetPixel($x,$y).ToArgb() -eq $curve) { $pixels++ }
        } }
        # The dark guards fixture intentionally finishes in Standard mode.
        if ($Name -ne 'dark-drag-wheel-guards') { Assert-Gesture ($pixels -gt 50) "$Name theme curve missing from native rendering" }
    } finally { $image.Dispose() }
    $destination = Join-Path $artifact $Name
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    foreach ($file in @('graph.txt','graph-range.txt','graph-fields.txt','requests.txt','response.txt','gesture-receipts.txt','gesture-submissions.txt','gesture-grouped.txt','native-interaction.png','native-backend.stderr.log')) {
        $path = Join-Path $session $file
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $destination }
    }
    [ordered]@{name=$Name;session=$session;range=$Range;requests=$Requests.Count;submissions=$Submissions;signalReceipts=$rows.Count} | ConvertTo-Json -Compress | Add-Content (Join-Path $artifact 'results.jsonl')
    "GESTURES-NATIVE-CASE-PASS $Name requests=$($Requests.Count) submissions=$Submissions signals=$($rows.Count) session=$session"
}
try {
    $env:NELISP_CALC_THEME_FILE = Join-Path $artifact 'theme.txt'
    [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,'dark')
    Invoke-GestureCase 'dark-drag-wheel-guards' @(
        'ui:gesture:begin:200000:365000','ui:gesture:end:92000:35000','ui:gesture:scroll:0:-1000',
        'mode:graph','ui:gesture:begin:0:0','ui:gesture:end:92000:35000',
        'ui:gesture:begin:200000:365000','ui:gesture:update:92000:35000','ui:gesture:cancel:0:0','ui:gesture:end:92000:35000',
        'ui:gesture:begin:200000:365000','ui:gesture:end:0:0',
        'ui:gesture:begin:2147483647:365000','ui:gesture:end:92000:35000',
        'ui:gesture:begin:200000:365000','ui:gesture:update:2147483647:35000','ui:gesture:end:92000:35000',
        'ui:gesture:begin:200000:365000','ui:gesture:end:92000:2147483647',
        'ui:gesture:begin:200000:365000','ui:gesture:update:92000:35000','ui:gesture:end:92000:35000',
        'ui:gesture:pair:-10000:10000','ui:gesture:repeat:250:8','ui:gesture:scroll:1000:0',
        'ui:gesture:begin:200000:365000','mode:standard','ui:gesture:end:92000:35000',
        'mode:graph','ui:gesture:mode:-1000:0'
    ) '-45:35:-38:42' @('mode:graph','graph:shift:-250:100','graph:zoom:-2','mode:standard','mode:graph','mode:standard') 2 '0' '^ready$'
    [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,'light')
    Invoke-GestureCase 'light-scaled-capped' @(
        'mode:graph','ui:gesture:size:800:1120','ui:gesture:begin:400000:730000',
        'ui:gesture:update:-184000:-70000','ui:gesture:end:-184000:-70000','ui:gesture:repeat:1000:32'
    ) '-155:165:-162:158' @('mode:graph','graph:shift:250:-100','graph:zoom:-4') 2 '8 points' '^ok:graph:x\^2:8/101$'
    [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE,'dark')
    Invoke-GestureCase 'dark-busy-mixed' @(
        'mode:graph','ui:gesture:busy:92000:35000',
        'ui:gesture:begin:200000:365000','ui:gesture:pair:-1000:1000','ui:gesture:end:92000:35000'
    ) '-1.25:1.25:-1.25:1.25' @('mode:graph','graph:zoom:1','graph:zoom:2') 1 '89 points' '^ok:graph:x\^2:89/101$'
    "GESTURES-NATIVE-PASS cases=3 artifact=$artifact"
} finally { $env:NELISP_CALC_THEME_FILE = $savedTheme }
