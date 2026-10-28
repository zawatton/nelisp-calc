param([switch]$IgnoreToggleForControl)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/theme-probes/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $artifact -Force | Out-Null
$savedThemeFile = $env:NELISP_CALC_THEME_FILE
$env:NELISP_CALC_THEME_FILE = Join-Path $artifact 'theme.txt'
function Assert-True($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Invoke-ThemeCase([string]$Name, [string[]]$Commands, [string]$Theme, [string]$Display = '0', [switch]$Graph) {
    if ($IgnoreToggleForControl) { $Commands = @($Commands | Where-Object { $_ -notmatch '^ui:theme:' }) }
    $output = @(& (Join-Path $PSScriptRoot 'launch.ps1') -Commands $Commands -ExpectedDisplay $Display -Hidden -TimeoutSeconds 55)
    $receipt = @($output | Where-Object { $_ -match '^NATIVE-GTK-INTERACTION-OK session=' })[-1]
    Assert-True ($receipt -match 'session=(.+) mouse=') "Missing native receipt: $Name"
    $session = $Matches[1]
    $destination = Join-Path $artifact $Name
    New-Item -ItemType Directory -Path $destination | Out-Null
    foreach ($file in @('native-interaction.png','theme-state.txt','theme-native-color.bin','theme-native.css','theme-settings.bin','theme-feedback.txt','requests.txt','response.txt','theme-dark.png','theme-light.png','graph.txt')) {
        $path = Join-Path $session $file
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $destination }
    }
    Assert-True ([IO.File]::ReadAllText((Join-Path $destination 'theme-state.txt')) -ceq $Theme) "$Name selected theme mismatch"
    $native = [IO.File]::ReadAllBytes((Join-Path $destination 'theme-native-color.bin'))
    $foreground = if ($Theme -eq 'light') { @(24,28,35) } else { @(245,245,247) }
    foreach ($i in 0..2) {
        $actual = [BitConverter]::ToSingle($native, $i * 4)
        Assert-True ([Math]::Abs($actual - ($foreground[$i] / 255.0)) -lt 0.004) "$Name GTK computed foreground channel $i mismatch: $actual"
    }
    $scheme = [BitConverter]::ToInt32([IO.File]::ReadAllBytes((Join-Path $destination 'theme-settings.bin')), 0)
    Assert-True ($scheme -eq $(if ($Theme -eq 'light') { 1 } else { 2 })) "$Name native CSS scheme mismatch"
    $bitmap = [Drawing.Bitmap]::new((Join-Path $destination 'native-interaction.png'))
    try {
        $background = $bitmap.GetPixel(0, 0)
        $expected = if ($Theme -eq 'light') { @(246,247,249) } else { @(26,28,33) }
        Assert-True ($background.R -eq $expected[0] -and $background.G -eq $expected[1] -and $background.B -eq $expected[2]) "$Name Cairo background mismatch: $background"
        if ($Graph) {
            $graphPixel = $bitmap.GetPixel(20, 200)
            $graphExpected = if ($Theme -eq 'light') { @(255,255,255) } else { @(36,38,46) }
            Assert-True ($graphPixel.R -eq $graphExpected[0] -and $graphPixel.G -eq $graphExpected[1] -and $graphPixel.B -eq $graphExpected[2]) "$Name graph background mismatch"
            Assert-True ((Get-Content (Join-Path $destination 'graph.txt') -TotalCount 1) -ceq 'SCG1') "$Name graph sample missing"
        } else {
            $button = $bitmap.GetPixel(305, 472)
            $accent = if ($Theme -eq 'light') { @(20,91,155) } else { @(56,125,184) }
            Assert-True ($button.R -eq $accent[0] -and $button.G -eq $accent[1] -and $button.B -eq $accent[2]) "$Name equals button mismatch"
        }
        [ordered]@{ name=$Name; theme=$Theme; nativeForeground=$foreground; scheme=$scheme; background=$expected; imageSha256=(Get-FileHash (Join-Path $destination 'native-interaction.png')).Hash } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $artifact 'results.jsonl')
    } finally { $bitmap.Dispose() }
    "THEME-CASE-PASS $Name"
}
try {
    Invoke-ThemeCase 'dark-default' @('clear') 'dark'
    Invoke-ThemeCase 'light-arithmetic' @('2','ui:theme:light','add','3','equals') 'light' '5'
    Assert-True ([IO.File]::ReadAllText($env:NELISP_CALC_THEME_FILE) -ceq 'light') 'Light preference not saved'
    Invoke-ThemeCase 'light-reload' @('clear') 'light'
    Invoke-ThemeCase 'dark-roundtrip' @('clear','ui:theme:dark','ui:theme:light','ui:theme:dark') 'dark'
    Assert-True ([IO.File]::ReadAllText($env:NELISP_CALC_THEME_FILE) -ceq 'dark') 'Dark preference not saved'
    Invoke-ThemeCase 'light-graph' @('mode:graph','graph:x^2','ui:theme:light') 'light' '31 points' -Graph
    Invoke-ThemeCase 'dark-graph' @('mode:graph','graph:x^2','ui:theme:dark') 'dark' '31 points' -Graph
    [IO.File]::WriteAllText($env:NELISP_CALC_THEME_FILE, 'invalid-value')
    Invoke-ThemeCase 'invalid-default' @('clear') 'dark'
    Invoke-ThemeCase 'ui-only-light' @('ui:theme:light') 'light'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $artifact 'ui-only-light/requests.txt'))) 'Theme-only command reached backend'
    $env:NELISP_CALC_THEME_FILE = Join-Path $artifact 'blocked-config'
    New-Item -ItemType Directory -Path $env:NELISP_CALC_THEME_FILE | Out-Null
    Invoke-ThemeCase 'save-failure' @('2','ui:theme:light','add','3','equals') 'light' '5'
    Assert-True ([IO.File]::ReadAllText((Join-Path $artifact 'save-failure/theme-feedback.txt')) -ceq 'Appearance changed; could not save preference') 'Preference failure feedback missing'
    "THEME-PROBE-PASS artifact=$artifact"
} finally {
    $env:NELISP_CALC_THEME_FILE = $savedThemeFile
}
