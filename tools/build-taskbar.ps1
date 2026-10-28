param([string]$OutputRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'target'))
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$target = Join-Path $project 'target/taskbar'
New-Item -ItemType Directory -Path $target -Force | Out-Null
$gcc = (Get-Command gcc -ErrorAction Stop).Source
$windres = Join-Path (Split-Path $gcc -Parent) 'windres.exe'
$resource = Join-Path $target 'icon.o'
Push-Location (Join-Path $project 'assets')
try {
    & $windres '-i' 'nelisp-calc.rc' '-o' $resource
    if ($LASTEXITCODE) { throw 'Launcher resource compilation failed' }
} finally { Pop-Location }
$temporary = Join-Path $target ('launcher-' + [guid]::NewGuid().ToString('N') + '.exe')
& $gcc '-std=c11' '-Wall' '-Wextra' '-Werror' '-O2' '-municode' '-mwindows' '-static-libgcc' (Join-Path $PSScriptRoot 'taskbar-launcher.c') $resource '-o' $temporary '-lole32' '-lshell32' '-luuid' '-lpropsys'
if ($LASTEXITCODE) { throw 'Launcher compilation failed' }
# Launchers exit immediately, so an installed launcher is never held by the GUI.
Copy-Item -LiteralPath $temporary -Destination (Join-Path $OutputRoot 'NeLispCalc.exe') -Force
Get-FileHash -LiteralPath (Join-Path $OutputRoot 'NeLispCalc.exe')
