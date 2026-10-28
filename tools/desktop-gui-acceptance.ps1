param([ValidateSet('All','Memory','History','Signed','Window')][string]$Group = 'All', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$target = Join-Path $project 'target'
function Assert-DesktopResponse {
    param([string[]]$Response, [string]$Value, [string]$Status, [int]$Count)
    if ($Response.Count -ne 3 -or $Response[0] -cne $Value -or $Response[1] -notmatch $Status -or $Response[2] -cne [string]$Count) {
        throw ('Unexpected desktop response: ' + ($Response -join ' | '))
    }
}
if ($SelfTest) {
    Assert-DesktopResponse @('7','session:recalled','6') '7' '^session:recalled$' 6
    $rejected = 0
    foreach ($bad in @(@{r=@('8','session:recalled','6')}, @{r=@('7','session-error:test','6')}, @{r=@('7','session:recalled','5')}, @{r=@('7','session:recalled')})) {
        try { Assert-DesktopResponse $bad.r '7' '^session:recalled$' 6 } catch { $rejected++ }
    }
    if ($rejected -ne 4) { throw 'Desktop verifier accepted broken evidence' }
    Write-Output 'DESKTOP-VERIFIER-PASS: healthy response and four negative controls'
    exit 0
}
$cases = @(
    @{ Name='Memory'; Commands=@('5','memory:store','clear','2','memory:add','memory:recall'); Value='7'; Status='^session:recalled$'; Count=6 },
    @{ Name='History'; Commands=@('2','add','3','equals','clear','history:recall:0'); Value='5'; Status='^session:recalled$'; Count=6 },
    @{ Name='Signed'; Commands=@('mode:programmer','prog:word:8','prog:base:hex','F','F','prog:signed','prog:base:dec'); Value='-1'; Status='^programmer:signed:8-bit:base-10$'; Count=7 },
    @{ Name='Window'; Commands=@('ui:compact','ui:compact','ui:topmost','ui:topmost','2','add','3','equals'); Value='5'; Status='^ok$'; Count=4 }
)
foreach ($case in $cases | Where-Object { $Group -eq 'All' -or $_.Name -eq $Group }) {
    $name = $case.Name.ToLowerInvariant()
    $receiptPath = Join-Path $target ('desktop-' + $name + '-acceptance.json')
    if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath }
    & (Join-Path $PSScriptRoot 'launch.ps1') -Commands $case.Commands -ExpectedDisplay $case.Value -ExpectedStatus $case.Status -Hidden *> (Join-Path $target ('desktop-' + $name + '-launch.log'))
    $response = [IO.File]::ReadAllLines((Join-Path $target 'response.txt'))
    Assert-DesktopResponse $response $case.Value $case.Status $case.Count
    if ($case.Name -eq 'Memory' -and [IO.File]::ReadAllText((Join-Path $target 'memory.txt')).Trim() -cne '7') { throw 'Memory snapshot mismatch' }
    if ($case.Name -eq 'History' -and !([IO.File]::ReadAllLines((Join-Path $target 'history.txt')) | Where-Object { $_ -match '^0\t2 \+ 3\t5$' })) { throw 'Meaningful history record absent' }
    foreach ($file in @('memory.txt','history.txt','native-interaction.png')) {
        $source = Join-Path $target $file
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $target ('desktop-' + $name + '-' + $file)) -Force }
    }
    $binary = Join-Path $target ([IO.File]::ReadAllText((Join-Path $target 'current-gui.txt')).Trim())
    [ordered]@{
        case=$case.Name; commands=$case.Commands; response=$response
        executableSha256=(Get-FileHash $binary).Hash
        verifiedUtc=[DateTime]::UtcNow.ToString('o')
        presentedWindow=$false; clipboardActionsRequested=$false
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    Write-Output ('DESKTOP-NATIVE-PASS: ' + $case.Name + ' -> ' + $case.Value)
}
