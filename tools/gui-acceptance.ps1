param(
    [string]$Keys = '2+3*4=',
    [string]$Expected = '20',
    [switch]$Mouse,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent

function Assert-CalculatorResponse {
    param([string[]]$Lines, [string]$Value, [int]$Count)
    if ($Lines.Count -ne 3) { throw 'Incomplete calculator response' }
    if ($Lines[0] -cne $Value) { throw "Expected $Value; received $($Lines[0])" }
    if ($Lines[1] -notmatch '^ok(:|$)') { throw "Calculation failed: $($Lines[1])" }
    if ($Lines[2] -cne [string]$Count) { throw "Expected $Count acknowledged commands; received $($Lines[2])" }
}

if ($SelfTest) {
    Assert-CalculatorResponse @('20', 'ok', '6') '20' 6
    $rejected = 0
    foreach ($broken in @(
        @{ Lines = @('21', 'ok', '6') },
        @{ Lines = @('20', 'engine-unavailable:test', '6') },
        @{ Lines = @('20', 'ok', '5') },
        @{ Lines = @('20', 'ok') }
    )) {
        try { Assert-CalculatorResponse $broken.Lines '20' 6 }
        catch { $rejected++ }
    }
    if ($rejected -ne 4) { throw "Verifier accepted broken input: rejected $rejected of 4" }
    Write-Output 'GUI-VERIFIER-PASS: healthy receipt accepted, 4 broken receipts rejected'
    exit 0
}

if ($Keys -notmatch '^[0-9+*/=.%\-]+$') { throw 'Unsupported acceptance key sequence' }
& (Join-Path $PSScriptRoot 'launch.ps1') -InteractionKeys $Keys -InteractionBurst -InteractionMouse:$Mouse
$response = Join-Path $projectRoot 'target/response.txt'
$lines = [IO.File]::ReadAllLines($response)
Assert-CalculatorResponse $lines $Expected $Keys.Length
$image = Join-Path $projectRoot 'target/native-interaction.png'
if (-not (Test-Path -LiteralPath $image)) { throw 'Missing actual native GUI image' }
$stableImageName = if ($Mouse) { 'target/gui-mouse.png' } else { 'target/gui-keyboard.png' }
$stableImage = Join-Path $projectRoot $stableImageName
Copy-Item -LiteralPath $image -Destination $stableImage -Force
$guiPointer = Join-Path $projectRoot 'target/current-gui.txt'
$guiRelative = if (Test-Path -LiteralPath $guiPointer) { [IO.File]::ReadAllText($guiPointer).Trim() } else { 'nelisp-calc.exe' }
$guiBinary = Join-Path (Join-Path $projectRoot 'target') $guiRelative
$receipt = [ordered]@{
    keys = $Keys
    expected = $Expected
    actual = $lines[0]
    acknowledged = [int]$lines[2]
    executableSha256 = (Get-FileHash $guiBinary).Hash
    imageSha256 = (Get-FileHash $stableImage).Hash
}
$receiptName = if ($Mouse) { 'target/gui-mouse-acceptance.json' } else { 'target/gui-acceptance.json' }
$receipt | ConvertTo-Json | Set-Content (Join-Path $projectRoot $receiptName) -Encoding UTF8
Write-Output "GUI-CALCULATION-PASS: $Keys -> $Expected ($($Keys.Length) ordered commands)"
