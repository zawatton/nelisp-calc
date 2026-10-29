param([string]$Gui, [switch]$TimeoutCheck, [switch]$ScientificCheck, [string]$ControlSource)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($ControlSource) {
    $source = [IO.File]::ReadAllText($ControlSource)
    $poll = [regex]::Match($source, '(?s)\(defun poll_response .*?(?=\(defun on_destroy)')
    if (-not $poll.Success) { throw 'Control poll function missing' }
    if ($poll.Value -match 'extern-call gtk_widget_queue_draw') { throw 'IDLE-NEGATIVE-REJECTED unconditional redraw in original poll (one request per 100 ms)' }
    throw 'Control did not contain the expected old poll implementation'
}
if (-not $Gui) { $Gui = Join-Path $root 'target/idle-gui-repaired/nelisp-calc.exe' }
$artifact = Join-Path $root ('target/idle-redraw-probes/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifact | Out-Null
$saved = @{}
foreach ($key in @('PATH','NELISP_CALC_TARGET','NELISP_CALC_HIDDEN','NELISP_CALC_IDLE_PROBE','NELISP_CALC_COMMANDS','NELISP_CALC_KEYS','NELISP_CALC_SMOKE','NELISP_CALC_THEME_FILE')) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
function Read-Counters {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $artifact 'counters.bin'))
    if ($bytes.Length -ne 16) { throw 'Incomplete native counters' }
    @([BitConverter]::ToUInt64($bytes,0), [BitConverter]::ToUInt64($bytes,8))
}
function Assert-Idle($condition, $message) { if (-not $condition) { throw $message } }
function Write-Response($display, $status, $count) {
    [IO.File]::WriteAllText((Join-Path $artifact 'response.new'), "$display`n$status`n$count`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath (Join-Path $artifact 'response.new') -Destination (Join-Path $artifact 'response.txt') -Force
}
$process = $null; $backend = $null
try {
    $bin = if ($env:MINGW_BIN) { $env:MINGW_BIN } else { Split-Path (Get-Command gcc).Source -Parent }
    $env:PATH = "$bin;$env:PATH"
    $env:NELISP_CALC_HIDDEN = '1'; $env:NELISP_CALC_KEYS = $null; $env:NELISP_CALC_SMOKE = $null
    $env:NELISP_CALC_THEME_FILE = Join-Path $artifact 'theme.txt'
    $env:NELISP_CALC_IDLE_PROBE = Join-Path $artifact 'counters.bin'
    $env:NELISP_CALC_COMMANDS = $null
    if ($ScientificCheck) {
        $env:NELISP_CALC_TARGET = $artifact
        $env:NELISP_CALC_COMMANDS = 'mode:scientific|3|science:select:14|ui:focus:science|ui:key:65293:0|mode:standard|mode:scientific|science:select:1|mode:standard|clear|7|add|8|ui:key:65293:0'
        $runtime = if ($env:NELISP_BIN) { $env:NELISP_BIN } else { Join-Path (Split-Path $root -Parent) 'nelisp/target/nelisp.exe' }
        $server = Join-Path $root 'lisp/nelisp-calc-mailbox.el'
        $backend = Start-Process -FilePath $runtime -ArgumentList @('--load', ('"'+$server+'"')) -WorkingDirectory $artifact -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $artifact 'backend.stderr')
    } elseif (-not $TimeoutCheck) { Write-Response '0' 'Ready' 0 }
    $process = Start-Process -FilePath $Gui -WorkingDirectory $artifact -WindowStyle Hidden -PassThru
    if ($ScientificCheck) {
        Assert-Idle ($process.WaitForExit(90000)) 'Scientific native timeout'
        Assert-Idle ($process.ExitCode -eq 0) 'Scientific native GUI failed'
        Assert-Idle (Test-Path (Join-Path $artifact 'native-interaction.png')) 'Scientific native interaction did not complete'
        $response = @(Get-Content (Join-Path $artifact 'response.txt'))
        Assert-Idle ($response[0] -ceq '15') 'Scientific/mode/Return final result differs'
        $requests = [IO.File]::ReadAllText((Join-Path $artifact 'requests.txt')).Replace("`r",'')
        Assert-Idle ($requests -ceq "mode:scientific`n3`nfunction:pow2`nmode:standard`nmode:scientific`nangle:grad`nmode:standard`nclear`n7`nadd`n8`nequals`n") 'Scientific selector/Return commands differ'
        Assert-Idle ($response[2] -eq '12') 'Scientific response count differs'
        Assert-Idle (@(Get-Content (Join-Path $artifact 'scientific-controls.tsv')).Count -eq 2) 'Scientific selector native callback receipt differs'
        "IDLE-SCIENTIFIC-PASS display=15 count=12 selectorCallbacks=2 returnKeys=2 modeTransitions=4 artifact=$artifact"
        return
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path (Join-Path $artifact 'counters.bin'))) {
        Assert-Idle (-not $process.HasExited) 'Native GUI exited before ready'
        Assert-Idle ([DateTime]::UtcNow -lt $deadline) 'Native GUI ready timeout'
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Seconds 3
    $before = Read-Counters; $process.Refresh(); $cpu = $process.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Seconds 3
    $after = Read-Counters; $process.Refresh()
    $cpuMs = $process.TotalProcessorTime.TotalMilliseconds - $cpu
    Assert-Idle ($after[0] -eq $before[0] -and $after[1] -ge $before[1]+20) 'Idle polls queued redraws'
    [ordered]@{ drawsBefore=$before[0]; drawsAfter=$after[0]; polls=$after[1]-$before[1]; cpuMs=$cpuMs; sampleMs=3000 } | ConvertTo-Json -Compress | Set-Content (Join-Path $artifact 'idle.json')
    if ($TimeoutCheck) {
        # Exercise the real 901-tick boundary without changing production timing.
        $deadline = [DateTime]::UtcNow.AddSeconds(100)
        do { Start-Sleep -Milliseconds 500; $after = Read-Counters } while ($after[0] -lt 2 -and [DateTime]::UtcNow -lt $deadline)
        Assert-Idle ($after[0] -eq 2 -and $after[1] -ge 901) 'Timeout status did not invalidate exactly once'
        Start-Sleep -Seconds 1
        Assert-Idle ((Read-Counters)[0] -eq 2) 'Timeout feedback redraws continuously'
        "IDLE-TIMEOUT-PASS polls=$($after[1]) draws=$($after[0]) artifact=$artifact"
    } else {
        foreach ($case in @(@('7','Ready',0), @('7','Failure tooltip',0), @('7','Failure tooltip',1))) {
            $before = Read-Counters
            Write-Response $case[0] $case[1] $case[2]
            Start-Sleep -Milliseconds 400
            $after = Read-Counters
            Assert-Idle ($after[0] -eq $before[0]+1) 'Changed response did not invalidate exactly once'
        }
        "IDLE-REDRAW-PASS idlePolls=30 idleDraws=0 sameCountDisplay=1 sameCountStatus=1 countOnly=1 cpuMs=$cpuMs artifact=$artifact"
    }
} finally {
    if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    if ($backend -and -not $backend.HasExited) { $backend.Kill(); $backend.WaitForExit() }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
}
