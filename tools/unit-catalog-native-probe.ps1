$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$categories = @('length','volume','area','mass','temp','energy','speed','time','power','data','pressure','angle')
$counts = @(12,21,11,14,3,8,7,8,5,35,6,4)
$commands = @('mode:convert')
foreach ($category in $categories) { $commands += @(('convert:category:'+$category),'ui:unit:snapshot') }
$commands += @('convert:category:volume','convert:from:galuk','convert:to:l','1','equals','ui:nav:snapshot')
$output = @(& (Join-Path $PSScriptRoot 'launch.ps1') -Hidden -Commands $commands -ExpectedDisplay '4.54609' -TimeoutSeconds 120)
$line = @($output | Where-Object { $_ -match '^NATIVE-GTK-INTERACTION-OK session=' })[-1]
if ($line -notmatch 'session=(.+) mouse=') { throw 'Missing native session receipt' }
$session = $Matches[1]
$rows = @(Get-Content (Join-Path $session 'unit-native.tsv') | ForEach-Object { ,$_.Split("`t") })
if ($rows.Count -ne 268) { throw "Expected 268 native item receipts, got $($rows.Count)" }
for ($i=0; $i -lt $categories.Count; $i++) {
    foreach ($offset in @('3008','3016')) {
        $items = @($rows | Where-Object { $_[0] -eq $categories[$i] -and $_[1] -eq $offset })
        if ($items.Count -ne $counts[$i]) { throw "Wrong native item count $($categories[$i])/$offset : $($items.Count)" }
        foreach ($item in $items) {
            if (!$item[2] -or !$item[3] -or [int]$item[4] -le 0 -or [int]$item[4] -gt 400) { throw "Invalid native combo receipt: $item" }
        }
        if (@($items | ForEach-Object { $_[2] } | Select-Object -Unique).Count -ne $items.Count) { throw 'Duplicate native unit ID' }
    }
}
foreach ($case in @(@('mass','longton','lb','2240'),@('data','mib','kib','1024'),@('angle','grad','deg','0.9'))) {
    & (Join-Path $PSScriptRoot 'launch.ps1') -Hidden -Commands @('mode:convert',('convert:category:'+$case[0]),('convert:from:'+$case[1]),('convert:to:'+$case[2]),'1','equals') -ExpectedDisplay $case[3] -TimeoutSeconds 120 | Select-Object -Last 1
}
"UNIT-CATALOG-NATIVE-PASS:268 session=$session"
