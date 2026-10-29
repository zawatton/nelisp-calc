param([string]$ControlGui,[switch]$SelectorOnly)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$artifact=Join-Path $root ('target/shortcut-parity-native/'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifact|Out-Null
function Check-KeyCase($name,$commands,$display,$handled,$tokens){
 $output=@(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $commands -ExpectedDisplay $display -Hidden)
 $receipt=@($output|Where-Object {$_ -match '^NATIVE-GTK-INTERACTION-OK session='})[-1]
 if($receipt -notmatch 'session=(.+) mouse='){throw "Missing receipt $name"}
 $session=$Matches[1]
 $rows=@(Get-Content (Join-Path $session 'key-receipts.txt'))
 $actual=@($rows|ForEach-Object {$_.Split("`t")[2]}) -join ','
 if($actual -cne $handled){throw "$name handled=$actual expected=$handled"}
 foreach($row in $rows){$f=$row.Split("`t");if([int]$f[9]+[int]$f[10] -ne [int]$f[2]){throw "$name duplicated dispatch"}}
 $path=Join-Path $session 'requests.txt'
 $requests=if(Test-Path $path){[IO.File]::ReadAllText($path) -replace "`r",''}else{''}
 if($requests -cne $tokens){throw "$name unexpected backend tokens ($session)"}
 if($name -eq 'scientific-selector'){
  $geometry=@(Get-Content (Join-Path $session 'scientific-controls.tsv'))
  if($geometry.Count -ne 4){throw 'Selector reset emitted an extra action or omitted a selection'}
  foreach($line in $geometry){$size=$line.Split("`t");if([int]$size[1] -gt 768 -or [int]$size[1] -le 0 -or [int]$size[2] -le 0){throw "Invalid scientific control geometry: $line"}}
 }
 Copy-Item -LiteralPath $session -Destination (Join-Path $artifact $name) -Recurse
 "SHORTCUT-PARITY-NATIVE-PASS $name"
}
if($ControlGui){
 $pointer=Join-Path $root 'target/current-gui.txt'
 $saved=[IO.File]::ReadAllText($pointer)
 $relative=[IO.Path]::GetRelativePath((Join-Path $root 'target'),$ControlGui)
 if($relative -match '^\.\.') {throw 'Control must be an isolated target build'}
 try{[IO.File]::WriteAllText($pointer,$relative);Check-KeyCase 'old-f5-unhandled' @('ui:key:50:8','ui:key:65474:0') '0' '1,0' "mode:scientific`n"}
 finally{[IO.File]::WriteAllText($pointer,$saved)}
 return
}
if($SelectorOnly){
 Check-KeyCase 'scientific-selector' @('ui:key:50:8','ui:focus:science','science:select:1','eval:1','science:select:4','eval:512','science:select:15','science:select:15','ui:calc-focus','ui:key:65293:0') '2' '1,1' "mode:scientific`nangle:grad`neval:1`nfunction:asin`neval:512`nfunction:cuberoot`nfunction:cuberoot`nequals`n"
 return
}
Check-KeyCase 'grad-inverse' @('ui:key:50:8','ui:key:65472:0','eval:100','ui:key:115:0','ui:key:83:1') '100' '1,1,1,1' "mode:scientific`nangle:grad`neval:100`nfunction:sin`nfunction:asin`n"
Check-KeyCase 'constants-powers' @('ui:key:50:8','ui:key:112:2','ui:key:69:1','eval:3','ui:key:103:4','eval:3','ui:key:103:0','eval:-8','ui:key:98:0') '-2' '1,1,1,1,1,1' "mode:scientific`nfunction:pi`nfunction:e`neval:3`nfunction:pow10`neval:3`nfunction:pow2`neval:-8`nfunction:cuberoot`n"
Check-KeyCase 'hyperbolic' @('ui:key:50:8','eval:0','ui:key:115:4','ui:key:83:5','ui:key:111:4','ui:key:79:5','ui:key:116:4','ui:key:84:5') '0' '1,1,1,1,1,1,1' "mode:scientific`neval:0`nfunction:sinh`nfunction:asinh`nfunction:cosh`nfunction:acosh`nfunction:tanh`nfunction:atanh`n"
Check-KeyCase 'modifier-isolation' @('ui:key:83:1','ui:key:115:4','ui:key:50:8','ui:key:83:2','ui:key:83:9','ui:key:83:13','ui:key:115:67108864','ui:focus:entry','ui:key:83:1','ui:key:115:4','ui:key:83:5') '0' '0,0,1,1,0,0,0,0,0,0' "mode:scientific`nfunction:sin`n"
Check-KeyCase 'programmer-mod' @('ui:key:51:8','prog:input:17','ui:key:37:1','prog:input:5','ui:key:65293:0') '2' '1,1,1' "mode:programmer`nprog:input:17`nprog:mod`nprog:input:5`nequals`n"
"SHORTCUT-PARITY-NATIVE-ALL-PASS artifact=$artifact"
