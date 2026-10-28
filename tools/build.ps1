$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$targetRoot = Join-Path $projectRoot 'target'
New-Item -ItemType Directory -Force $targetRoot | Out-Null
$emacsBin = if ($env:EMACS_BIN) { $env:EMACS_BIN } else { (Get-Command emacs -ErrorAction Stop).Source }
$buildId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$relativeExe = 'builds/' + $buildId + '/nelisp-calc.exe'
$savedOutput = $env:NELISP_CALC_GUI_OUTPUT
try {
    $env:NELISP_CALC_GUI_OUTPUT = Join-Path $targetRoot $relativeExe
    & $emacsBin -Q --batch -l (Join-Path $projectRoot 'build.el') *> (Join-Path $targetRoot 'native-build.log')
    if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path $targetRoot 'native-build.log') | Where-Object { $_ -match '^Error:|^Doc |^Debugger|^NATIVE' } | Select-Object -First 3 | ForEach-Object { $_.Substring(0, [Math]::Min(600, $_.Length)) }; throw 'Native AOT build failed; see target/native-build.log' }
    if (-not (Test-Path -LiteralPath $env:NELISP_CALC_GUI_OUTPUT)) { throw 'Native build did not produce the versioned executable' }
    $pointer = Join-Path $targetRoot 'current-gui.txt'
    [IO.File]::WriteAllText(($pointer + '.new'), $relativeExe, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath ($pointer + '.new') -Destination $pointer -Force
    Get-Content (Join-Path $targetRoot 'native-build.log') -Tail 2
} finally {
    $env:NELISP_CALC_GUI_OUTPUT = $savedOutput
}
