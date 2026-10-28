param([ValidateSet('Standalone', 'Standard', 'Scientific', 'ScientificPrecision', 'Prerequisites', 'ScientificTokens', 'WideDivision', 'IsqrtProvider', 'Host', 'Mailbox', 'ArithmeticMailbox', 'MailboxLock')][string]$Mode = 'Standalone')
$ErrorActionPreference = 'Stop'
function Add-Request([string]$Path, [string]$Content) {
    $stream = $null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            break
        } catch [IO.IOException] {
            if (($_.Exception.HResult -band 65535) -notin @(32, 33)) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
    if (!$stream) { throw 'Request append sharing retry exhausted' }
    try {
        $bytes = [Text.Encoding]::ASCII.GetBytes($Content)
        # Never retry an ambiguous write: only opening the handle is retried.
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } finally { $stream.Dispose() }
}
function Read-Response([string]$Path) {
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try {
            $snapshot = [IO.File]::ReadAllLines($Path)
            if ($snapshot.Count -eq 3 -and $snapshot[0].Length -gt 0 -and $snapshot[1].Length -gt 0 -and $snapshot[2] -match '^\d+$') {
                return ,$snapshot
            }
        } catch [IO.IOException] {
            if (($_.Exception.HResult -band 65535) -notin @(2, 3, 32, 33)) { throw }
        }
        Start-Sleep -Milliseconds 25
    }
    throw 'Complete mailbox response snapshot unavailable after bounded retries'
}
$project = Split-Path $PSScriptRoot -Parent
$devRoot = Split-Path $project -Parent
$target = Join-Path $project 'target'
New-Item -ItemType Directory -Force $target | Out-Null
$runtime = Join-Path $devRoot 'nelisp/target/nelisp.exe'
$testFile = Join-Path $project 'test/engine-reference.el'
if ($Mode -eq 'Standard') { $testFile = Join-Path $project 'test/engine-standard.el' }
$focusedTests = @{ Scientific = 'engine-scientific.el'; ScientificPrecision = 'scientific-precision.el'; Prerequisites = 'scientific-prerequisites.el'; ScientificTokens = 'scientific-tokens.el'; WideDivision = 'compat-wide-division.el'; IsqrtProvider = 'compat-isqrt-provider.el' }
if ($focusedTests.ContainsKey($Mode)) { $testFile = Join-Path $project ('test/' + $focusedTests[$Mode]) }
$log = Join-Path $target ('engine-' + $Mode.ToLower() + '.log')
$sources = @('calc/calc.el', 'calc/calc-macs.el', 'calc/calc-loaddefs.el', 'calc/calc-aent.el', 'calc/calc-misc.el', 'calc/calc-ext.el', 'calc/calc-arith.el', 'calc/calc-math.el', 'calc/calc-comb.el', 'emacs-lisp/cl-extra.el', 'emacs-lisp/rx.el') | ForEach-Object {
    $source = Join-Path $devRoot ('nelisp-emacs/vendor/emacs-lisp/' + $_)
    @{ source = ('../nelisp-emacs/vendor/emacs-lisp/' + $_); sha256 = (Get-FileHash $source -Algorithm SHA256).Hash }
}
$sources += @('emacs-keymap-builtins.el', 'emacs-keymap.el') | ForEach-Object {
    $source = Join-Path $devRoot ('nelisp/packages/nelisp-emacs-core/src/' + $_)
    @{ source = ('../nelisp/packages/nelisp-emacs-core/src/' + $_); sha256 = (Get-FileHash $source -Algorithm SHA256).Hash }
}
$listProvider = 'nelisp/packages/nelisp-emacs-foundation/src/emacs-list.el'
$sources += @{ source = ('../' + $listProvider); sha256 = (Get-FileHash (Join-Path $devRoot $listProvider) -Algorithm SHA256).Hash }
@{ runtime = '../nelisp/target/nelisp.exe'; runtimeVersion = (& $runtime --version); runtimeSha256 = (Get-FileHash $runtime -Algorithm SHA256).Hash; sources = $sources } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $target 'engine-origin.json') -Encoding UTF8
if ($Mode -eq 'Host') {
    $ErrorActionPreference = 'Continue'
    & emacs -Q --batch -l $testFile *> $log
    $result = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
} elseif ($Mode -in @('Standalone', 'Standard', 'Scientific', 'ScientificPrecision', 'Prerequisites', 'ScientificTokens', 'WideDivision', 'IsqrtProvider')) {
    $stderr = Join-Path $target ('engine-' + $Mode.ToLower() + '.stderr')
    $process = Start-Process -FilePath $runtime -ArgumentList @('--load', ('"' + $testFile + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
    $null = $process.Handle
    if (!$process.WaitForExit(25000)) { $process.Kill(); throw 'Standalone arithmetic probe exceeded 25 seconds' }
    $result = $process.ExitCode
    if ($null -eq $result) { throw 'Standalone exit code unavailable; refusing a green gate' }
    if (Test-Path $stderr) { Get-Content $stderr -TotalCount 4 }
} else {
    $mailbox = Join-Path $target 'engine-mailbox'
    New-Item -ItemType Directory -Force $mailbox | Out-Null
    foreach ($name in @('requests.txt', 'response.txt', 'response.tmp', 'stop')) {
        $file = Join-Path $mailbox $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    $oldTarget = $env:NELISP_CALC_TARGET
    $env:NELISP_CALC_TARGET = $mailbox.Replace('\', '/')
    $entry = Join-Path $project 'lisp/nelisp-calc-mailbox.el'
    $process = Start-Process -FilePath $runtime -ArgumentList @('--load', ('"' + $entry + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $target 'engine-mailbox.stderr')
    try {
        $response = Join-Path $mailbox 'response.txt'
        $deadline = (Get-Date).AddSeconds(25)
        while (!(Test-Path $response) -and (Get-Date) -lt $deadline -and !$process.HasExited) { Start-Sleep -Milliseconds 50 }
        if (!(Test-Path $response)) { throw 'Mailbox startup timed out or process exited' }
        if ($Mode -eq 'MailboxLock') {
            $lock = [IO.File]::Open((Join-Path $mailbox 'requests.txt'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { Start-Sleep -Milliseconds 300 } finally { $lock.Dispose() }
            if ($process.HasExited) {
                Get-Content (Join-Path $target 'engine-mailbox.stderr') -TotalCount 8
                throw 'Backend exited during exclusive request read lock'
            }
        }
        Add-Request (Join-Path $mailbox 'requests.txt') "eval:0.1+0.2`n"
        do {
            Start-Sleep -Milliseconds 50
            $lines = Read-Response $response
        } while (($lines.Count -lt 3 -or $lines[2] -ne '1') -and (Get-Date) -lt $deadline -and !$process.HasExited)
        if ($lines.Count -lt 3 -or $lines[2] -ne '1') { throw 'Request was not acknowledged' }
        if ($lines[0] -eq 'ENGINE UNAVAILABLE' -and $lines[1] -notlike 'engine-unavailable:*') { throw 'Missing structured engine failure' }
        if ($lines[0] -ne 'ENGINE UNAVAILABLE' -and $lines[0] -ne '0.3') { throw 'Unexpected calculation result' }
        if ($Mode -in @('ArithmeticMailbox', 'MailboxLock') -and $lines[0] -ne '0.3') { throw 'Genuine arithmetic mailbox did not return 0.3' }
        Add-Request (Join-Path $mailbox 'requests.txt') 'clear'
        Start-Sleep -Milliseconds 150
        if ((Read-Response $response)[2] -ne '1') { throw 'Partial request was processed' }
        Add-Request (Join-Path $mailbox 'requests.txt') "`n"
        do {
            Start-Sleep -Milliseconds 50
            $lines = Read-Response $response
        } while (($lines.Count -lt 3 -or $lines[2] -ne '2') -and (Get-Date) -lt $deadline -and !$process.HasExited)
        if ($lines[2] -ne '2') { throw 'Second request was not acknowledged' }
        Write-Output ('MAILBOX-TRANSPORT-PASS: ' + ($lines -join ' | '))
        $result = 0
    } finally {
        [IO.File]::WriteAllText((Join-Path $mailbox 'stop'), '')
        if (!$process.WaitForExit(3000)) { $process.Kill() }
        $env:NELISP_CALC_TARGET = $oldTarget
    }
}
if ($Mode -notin @('Mailbox', 'ArithmeticMailbox', 'MailboxLock')) { Get-Content $log -Tail 8 }
exit $result
