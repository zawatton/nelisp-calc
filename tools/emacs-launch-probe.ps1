$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'emacs-launch.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('calc launcher ' + [Guid]::NewGuid().ToString('N'))
$global:nelispCalcProbeProcesses = @()
# Mock the native boundary: this harness must never restore a desktop window.
Add-Type -TypeDefinition @'
public static class NeLispCalcWindow {
 public static int Calls;
 public static int LastPid;
 public static bool Restore(int pid) { Calls++; LastPid=pid; return true; }
}
public static class NeLispCalcProbeOwner {
 static System.Threading.ManualResetEventSlim ready=new System.Threading.ManualResetEventSlim(false);
 static System.Threading.ManualResetEventSlim stop=new System.Threading.ManualResetEventSlim(false);
 static System.Threading.Thread owner;
 public static void Hold(string name) {
  owner=new System.Threading.Thread(()=> {
   using(var mutex=new System.Threading.Mutex(false,name)) {
    mutex.WaitOne(); ready.Set(); stop.Wait(); mutex.ReleaseMutex();
   }
  }); owner.Start(); ready.Wait();
 }
 public static void Release() { stop.Set(); owner.Join(); }
 public static void Publish(string path) {
  new System.Threading.Thread(()=> {
   System.Threading.Thread.Sleep(250);
   System.IO.File.WriteAllText(path,"{\"guiPid\":12345}");
  }).Start();
 }
}
'@
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) $global:nelispCalcProbeProcesses }
function Get-Process {
    param($Id, $ErrorAction = 'Continue')
    if ($Id -eq 12345) { return [pscustomobject]@{ Id = 12345; Path = (Join-Path $fixture 'target/old/nelisp-calc.exe') } }
    Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction $ErrorAction
}
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'target/variant'), (Join-Path $fixture 'target/old'), (Join-Path $fixture 'other/target'), (Join-Path $fixture 'tools') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'target/variant/nelisp-calc.exe'), 'harmless placeholder')
    [IO.File]::WriteAllText((Join-Path $fixture 'target/old/nelisp-calc.exe'), 'harmless placeholder')
    [IO.File]::WriteAllText((Join-Path $fixture 'other/target/nelisp-calc.exe'), 'harmless placeholder')
    [IO.File]::WriteAllText((Join-Path $fixture 'target/current-gui.txt'), 'variant/nelisp-calc.exe')
    [IO.File]::WriteAllText((Join-Path $fixture 'tools/launch.ps1'), '[IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot -Parent) ''launched''), ''ok'')')
    $global:nelispCalcProbeProcesses = @([pscustomobject]@{ ExecutablePath = (Join-Path $fixture 'target/old/nelisp-calc.exe'); ProcessId = 12345 })
    $result = & $helper -ProjectRoot $fixture | ConvertFrom-Json
    Assert ($result.reused -and $result.guiPid -eq 12345) 'Existing alternate build was not reused'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'launched'))) 'Reuse invoked launcher'
    Assert ([NeLispCalcWindow]::Calls -eq 0) 'Old passive argv unexpectedly restored a window'
    $activated = & $helper -ProjectRoot $fixture -Activate | ConvertFrom-Json
    Assert ($activated.guiPid -eq $result.guiPid -and $activated.reused) 'Activation replaced the existing GUI'
    Assert ([NeLispCalcWindow]::Calls -eq 1 -and [NeLispCalcWindow]::LastPid -eq 12345) 'Explicit activation did not restore the reused PID'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'target/taskbar-command.txt'))) 'Activation reset the mode'
    $null = & $helper -ProjectRoot $fixture -Activate -Hidden
    Assert ([NeLispCalcWindow]::Calls -eq 1) 'Hidden activation touched native windows'
    $savedHidden = $env:NELISP_CALC_HIDDEN
    try {
        $env:NELISP_CALC_HIDDEN = '1'
        $null = & $helper -ProjectRoot $fixture -Activate
        Assert ([NeLispCalcWindow]::Calls -eq 1) 'Environment-hidden activation touched native windows'
    } finally { $env:NELISP_CALC_HIDDEN = $savedHidden }
    $canonicalFixture = [NeLispCalcCanonicalPath]::Resolve($fixture)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalFixture.ToLowerInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $stateFile = Join-Path $fixture 'target/taskbar-session.json'
    [NeLispCalcProbeOwner]::Hold('Local\NeLispCalc-' + $key)
    try {
        # A request during startup waits for publication without taking ownership.
        [NeLispCalcProbeOwner]::Publish($stateFile)
        $activeOwner = & $helper -ProjectRoot $fixture -Activate | ConvertFrom-Json
        Assert ($activeOwner.reused -and $activeOwner.guiPid -eq 12345) 'Active owner was not reused'
        Assert ([NeLispCalcWindow]::Calls -eq 2) 'Active owner did not receive native restoration'
        Assert (Test-Path -LiteralPath $stateFile) 'Activation removed owner session state'
        Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'target/taskbar-command.txt'))) 'Active owner mode was reset'
        Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'launched'))) 'Active owner launched a second GUI'
    } finally { [NeLispCalcProbeOwner]::Release(); Remove-Item -LiteralPath $stateFile }
    $global:nelispCalcProbeProcesses = @([pscustomobject]@{ ExecutablePath = (Join-Path $fixture 'other/target/nelisp-calc.exe'); ProcessId = 67890 })
    $result = & $helper -ProjectRoot $fixture | ConvertFrom-Json
    Assert (-not $result.reused) 'Unrelated app was reused'
    Assert (Test-Path -LiteralPath (Join-Path $fixture 'launched')) 'Space-containing source launcher was not invoked'
    [IO.File]::WriteAllText((Join-Path $fixture 'target/current-gui.txt'), '../escape.exe')
    # Run the intentional failure in a child so its exit cannot stop this harness.
    $shell = (Get-Process -Id $PID).Path
    $failure = & $shell -NoProfile -NonInteractive -File $helper -ProjectRoot $fixture 2>&1
    Assert ($LASTEXITCODE -ne 0) 'Invalid pointer negative control passed'
    Assert (($failure | Out-String) -match 'Invalid native GUI pointer') 'Negative control failed for the wrong reason'
    'EMACS-LAUNCH-PROBE-OK reuse alternate-build unrelated-root spaces invalid-pointer passive-negative-control activate-same-pid hidden environment-hidden active-owner pending-startup mode-preserved'
} finally {
    Remove-Variable -Name nelispCalcProbeProcesses -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture) {
        $tempBoundary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $resolvedFixture = (Resolve-Path -LiteralPath $fixture -ErrorAction Stop).Path
        $absoluteFixture = [IO.Path]::GetFullPath($resolvedFixture)
        if (-not $absoluteFixture.StartsWith($tempBoundary, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path $absoluteFixture -Leaf) -notmatch '^calc launcher [0-9a-f]{32}$' -or
            [IO.Path]::GetFullPath((Split-Path $absoluteFixture -Parent)).TrimEnd('\', '/') -ne $tempBoundary.TrimEnd('\', '/')) {
            throw 'Refusing to remove a fixture outside its temporary directory boundary'
        }
        Remove-Item -LiteralPath $absoluteFixture -Recurse -Force
    }
}
