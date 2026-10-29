param([switch]$OldBinary)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $project ('target/implicit-native/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact -Force | Out-Null
Add-Type -AssemblyName System.Drawing
$cases = @(@{Name='circle';Expression='x^2+y^2=25'})
if (!$OldBinary) { $cases += @(@{Name='hyperbola';Expression='x*y=1'},@{Name='explicit';Expression='x^2'}) }
foreach ($case in $cases) {
    $status = if ($OldBinary) { '^mode-error:' } elseif ($case.Name -eq 'explicit') { '^ok:graph:x\^2:' } else { '^ok:graph:implicit:' }
    $options = @{ Commands=@('mode:graph',('graph:'+$case.Expression)); ExpectedStatus=$status; Hidden=$true; TimeoutSeconds=180 }
    if ($OldBinary) { $options.ExpectedDisplay='ERROR' }
    $output = @(& (Join-Path $PSScriptRoot 'launch.ps1') @options)
    $receipt = @($output | Where-Object { $_ -match '^NATIVE-GTK-INTERACTION-OK session=' })[-1]
    if ($receipt -notmatch 'session=(.+) mouse=') { throw 'Missing hidden native receipt' }
    $session = $Matches[1]
    $destination = Join-Path $artifact $case.Name
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    foreach ($name in @('graph.txt','response.txt','requests.txt','native-interaction.png','native-backend.stderr.log')) {
        $source = Join-Path $session $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $destination }
    }
    if (!$OldBinary) {
        $rows = @(Get-Content (Join-Path $session 'graph.txt'))
        if ($rows.Count -gt 2048 -or @($rows | Where-Object { $_ -match '^1 ' }).Count -lt 30) { throw 'Contour protocol missing or unbounded' }
        $bitmap = [Drawing.Bitmap]::FromFile((Join-Path $session 'native-interaction.png'))
        try {
            $pixels=0
            for ($y=193; $y -lt [Math]::Min(538,$bitmap.Height); $y++) {
                for ($x=18; $x -lt [Math]::Min(382,$bitmap.Width); $x++) {
                    $color=$bitmap.GetPixel($x,$y)
                    if (($color.R -eq 89 -and $color.G -eq 194 -and $color.B -eq 255) -or ($color.R -eq 0 -and $color.G -eq 95 -and $color.B -eq 170)) { $pixels++ }
                }
            }
            if ($pixels -lt 80) { throw 'Native Cairo curve pixels missing' }
        } finally { $bitmap.Dispose() }
    }
    Write-Output ('IMPLICIT-NATIVE-CASE-PASS '+$case.Name+' session='+$session)
}
Write-Output ('IMPLICIT-NATIVE-PASS artifact='+$artifact)
