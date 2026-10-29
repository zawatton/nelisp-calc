$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tools/runtime.ps1')
$fixture=Join-Path $root ('target/runtime-gc-capability-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force (Join-Path $fixture 'target')|Out-Null
$runtime=Join-Path $fixture 'runtime.exe'
$other=Join-Path $fixture 'other.exe'
$metadata=Join-Path $fixture 'target/runtime-capabilities.json'
[IO.File]::WriteAllText($runtime,'first runtime fixture')
[IO.File]::WriteAllText($other,'other runtime fixture')
$checks=0
function Assert-Capability([bool]$Condition){if(-not $Condition){throw "Capability assertion failed at $checks"};$script:checks++}
Assert-Capability ((Get-CalcRuntimeGcPolicy $fixture $runtime) -eq '')
@{sha256=(Get-FileHash -LiteralPath $runtime).Hash;startupGcPolicy='debt-v1'}|ConvertTo-Json|Set-Content $metadata
Assert-Capability ((Get-CalcRuntimeGcPolicy $fixture $runtime) -eq 'debt-v1')
Assert-Capability ((Get-CalcRuntimeGcPolicy $fixture $other) -eq '')
[IO.File]::AppendAllText($runtime,'mutation')
Assert-Capability ((Get-CalcRuntimeGcPolicy $fixture $runtime) -eq '')
@{sha256=(Get-FileHash -LiteralPath $runtime).Hash;startupGcPolicy='unknown'}|ConvertTo-Json|Set-Content $metadata
Assert-Capability ((Get-CalcRuntimeGcPolicy $fixture $runtime) -eq '')
@{sha256=(Get-FileHash -LiteralPath $runtime).Hash}|ConvertTo-Json|Set-Content $metadata
Assert-Capability ((Get-CalcRuntimeGcPolicy $fixture $runtime) -eq '')
[IO.File]::WriteAllText($metadata,'{invalid')
$failed=$false
try{Get-CalcRuntimeGcPolicy $fixture $runtime|Out-Null}catch{$failed=$true}
Assert-Capability $failed
"RUNTIME-GC-CAPABILITY-PASS:$checks"
