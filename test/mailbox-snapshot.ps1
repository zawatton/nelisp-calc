$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$probe = Join-Path $project 'tools/engine-probe.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($probe, [ref]$null, [ref]$null)
$reader = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-Response' }, $true)
Invoke-Expression $reader.Extent.Text
$directory = Join-Path $project 'target/snapshot-test'
New-Item -ItemType Directory -Force $directory | Out-Null
$response = Join-Path $directory 'response.txt'
$ready = Join-Path $directory 'ready'
function Start-Interference([string]$Kind) {
    if (Test-Path $ready) { Remove-Item -LiteralPath $ready }
    $job = Start-Job -ArgumentList $response, $ready, $Kind -ScriptBlock {
        param($response, $ready, $kind)
        if ($kind -eq 'lock') {
            $handle = [IO.File]::Open($response, 'Open', 'ReadWrite', 'None')
            try {
                [IO.File]::WriteAllText($ready, 'ready')
                Start-Sleep -Milliseconds 300
            } finally { $handle.Dispose() }
        } else {
            [IO.File]::Move($response, ($response + '.hidden'))
            try {
                [IO.File]::WriteAllText($ready, 'ready')
                Start-Sleep -Milliseconds 300
            } finally { [IO.File]::Move(($response + '.hidden'), $response) }
        }
    }
    $deadline = (Get-Date).AddSeconds(10)
    while (!(Test-Path $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 5 }
    if (!(Test-Path $ready)) { throw 'Interference worker did not acquire target' }
    return $job
}
[IO.File]::WriteAllText($response, "0.3`nok`n1`n")
$job = Start-Interference 'lock'
try {
    $failed = $false
    try { [IO.File]::ReadAllLines($response) | Out-Null }
    catch [IO.IOException] {
        $failed = $true
        Write-Output ('ORIGINAL-READER-RED: IOException code=' + ($_.Exception.HResult -band 65535))
    }
    if (!$failed) { throw 'Negative control did not fail during exclusive lock' }
    $snapshot = Read-Response $response
    if (($snapshot -join '|') -ne '0.3|ok|1') { throw 'Locked response snapshot changed' }
} finally { $job | Wait-Job | Receive-Job; $job | Remove-Job -Force }
$job = Start-Interference 'missing'
try {
    $snapshot = Read-Response $response
    if (($snapshot -join '|') -ne '0.3|ok|1') { throw 'Missing response snapshot changed' }
} finally { $job | Wait-Job | Receive-Job; $job | Remove-Job -Force }
[IO.File]::WriteAllText($response, '')
$rejected = $false
try { Read-Response $response | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'Empty response accepted' }
Write-Output 'SNAPSHOT-READER-PASS: exclusive lock, missing window, empty rejection, exact count'
