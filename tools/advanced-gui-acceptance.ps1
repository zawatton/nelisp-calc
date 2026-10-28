param(
    [ValidateSet('Advanced', 'Conversion', 'GraphCurrency', 'All')]
    [string]$Group = 'Advanced',
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$target = Join-Path $projectRoot 'target'

function Assert-ModeResponse {
    param([string[]]$Lines, [string]$Value, [string]$Status, [int]$Count)
    if ($Lines.Count -ne 3 -or $Lines[0] -cne $Value -or
        $Lines[1] -notmatch $Status -or $Lines[2] -cne [string]$Count) {
        throw ('Unexpected native mode response: ' + ($Lines -join ' | '))
    }
}

if ($SelfTest) {
    Assert-ModeResponse @('2', 'programmer:unsigned:64-bit:base-16', '6') '2' '^programmer:' 6
    $rejected = 0
    foreach ($broken in @(
        @{ Lines = @('3', 'programmer:unsigned:64-bit:base-16', '6') },
        @{ Lines = @('2', 'mode-error:test', '6') },
        @{ Lines = @('2', 'programmer:unsigned:64-bit:base-16', '5') },
        @{ Lines = @('2', 'programmer:unsigned:64-bit:base-16') }
    )) {
        try { Assert-ModeResponse $broken.Lines '2' '^programmer:' 6 }
        catch { $rejected++ }
    }
    if ($rejected -ne 4) { throw 'Advanced verifier accepted a broken response' }
    Write-Output 'ADVANCED-VERIFIER-PASS: healthy receipt and four negative controls'
    exit 0
}

$cases = @(
    @{ Name = 'science'; Group = 'Advanced'; Commands = @('mode:scientific', '2', 'function:ln'); Value = '0.69314718056'; Status = '^ok$' },
    @{ Name = 'programmer'; Group = 'Advanced'; Commands = @('mode:programmer', 'prog:base:hex', 'A', 'prog:and', '3', 'equals'); Value = '2'; Status = '^programmer:unsigned:64-bit:base-16$' },
    @{ Name = 'convert'; Group = 'Conversion'; Commands = @('mode:convert', 'convert:category:length', 'convert:from:m', 'convert:to:ft', '1', 'equals'); Value = '3.28083989501'; Status = '^convert:length:m:ft$' },
    @{ Name = 'date'; Group = 'Conversion'; Commands = @('mode:date', 'date:add:2024-02-28:1'); Value = '2024-02-29'; Status = '^date:' },
    @{ Name = 'graph'; Group = 'GraphCurrency'; Commands = @('mode:graph', 'graph:x^2'); Value = '31 points'; Status = '^ok:graph:x\^2:31/101$' },
    @{ Name = 'currency'; Group = 'GraphCurrency'; Commands = @('mode:currency', 'currency:from:EUR', 'currency:to:JPY', '1', 'equals'); Value = ''; Status = '^ok:currency:ECB:[0-9-]+:EUR/JPY$' }
)

foreach ($case in $cases | Where-Object { $Group -eq 'All' -or $_.Group -eq $Group }) {
    $receiptPath = Join-Path $target ('gui-' + $case.Name + '-acceptance.json')
    if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath }
    if ($case.Name -eq 'currency') {
        $ratesPath = if ($env:NELISP_CALC_RATES) { $env:NELISP_CALC_RATES } else { Join-Path $target 'currency-rates.tsv' }
        $jpy = @([IO.File]::ReadAllLines($ratesPath) | Where-Object { $_.StartsWith("JPY`t") })
        if ($jpy.Count -ne 1) { throw 'Actual ECB cache has no unique JPY rate' }
        $case.Value = $jpy[0].Split("`t")[1]
    }
    $log = Join-Path $target ('gui-' + $case.Name + '-launch.log')
    & (Join-Path $PSScriptRoot 'launch.ps1') -Commands $case.Commands -ExpectedDisplay $case.Value -ExpectedStatus $case.Status -Hidden *> $log
    $lines = [IO.File]::ReadAllLines((Join-Path $target 'response.txt'))
    Assert-ModeResponse $lines $case.Value $case.Status $case.Commands.Count
    $image = Join-Path $target ('gui-' + $case.Name + '.png')
    Copy-Item -LiteralPath (Join-Path $target 'native-interaction.png') -Destination $image -Force
    if ($case.Name -eq 'graph') {
        $points = [IO.File]::ReadAllLines((Join-Path $target 'graph.txt'))
        if ($points[0] -cne 'SCG1' -or @($points | Where-Object { $_ -match '^1 ' }).Count -ne 31 -or
            $points -cnotcontains '1 400 300' -or $points -cnotcontains '1 350 50') {
            throw 'Native graph does not contain the expected genuine Calc samples'
        }
        Copy-Item -LiteralPath (Join-Path $target 'graph.txt') -Destination (Join-Path $target 'gui-graph.txt') -Force
    }
    $pointer = Join-Path $target 'current-gui.txt'
    $binary = Join-Path $target ([IO.File]::ReadAllText($pointer).Trim())
    [ordered]@{
        case = $case.Name
        commands = $case.Commands
        response = $lines
        executableSha256 = (Get-FileHash $binary).Hash
        imageSha256 = (Get-FileHash $image).Hash
        verifiedUtc = [DateTime]::UtcNow.ToString('o')
        presentedWindow = $false
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    Write-Output ('NATIVE-MODE-PASS: ' + $case.Name + ' -> ' + $case.Value)
}
