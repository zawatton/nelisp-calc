param([Parameter(Mandatory = $true)][string]$ProjectRoot,
      [ValidateSet('standard','scientific','programmer','graph','date','convert','currency')][string]$Mode = 'standard',
      [switch]$Hidden,
      [switch]$Activate)
$ErrorActionPreference = 'Stop'
$Hidden = $Hidden -or [bool]$env:NELISP_CALC_HIDDEN
function Show-Calculator([int]$GuiPid) {
    if (-not $Activate -or $Hidden) { return }
    if (-not ('NeLispCalcWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NeLispCalcWindow {
 delegate bool Visitor(IntPtr window, IntPtr data);
 [DllImport("user32.dll")] static extern bool EnumWindows(Visitor visitor, IntPtr data);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
 [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
 [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr window, int command);
 [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
 [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
 public static bool Restore(int pid) {
  IntPtr found=IntPtr.Zero;
  EnumWindows((window,data)=> { uint owner; GetWindowThreadProcessId(window,out owner);
   if(owner==(uint)pid && IsWindowVisible(window) && GetWindow(window,4)==IntPtr.Zero) {found=window;return false;} return true;
  },IntPtr.Zero);
  if(found==IntPtr.Zero) return false;
  ShowWindowAsync(found,IsIconic(found)?9:5);
  SetForegroundWindow(found);
  return true;
 }
}
'@
    }
    $windowDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        if ([NeLispCalcWindow]::Restore($GuiPid)) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $windowDeadline)
    throw 'The calculator window did not become available'
}
$mutex = $null
$owned = $false
try {
    $root = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).ProviderPath.TrimEnd('\', '/')
    if (-not ('NeLispCalcCanonicalPath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class NeLispCalcCanonicalPath {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern SafeFileHandle CreateFile(string p,uint a,uint s,IntPtr x,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder p,uint n,uint f);
 public static string Resolve(string p) {
  using(var h=CreateFile(p,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
   if(h.IsInvalid) throw new System.ComponentModel.Win32Exception();
   var b=new StringBuilder(32768); var n=GetFinalPathNameByHandle(h,b,32768,0);
   if(n==0 || n>=32768) throw new System.ComponentModel.Win32Exception();
   string v=b.ToString(); return v.StartsWith(@"\\?\UNC\") ? @"\\"+v.Substring(8) : v.StartsWith(@"\\?\") ? v.Substring(4) : v;
  }
 }
}
'@
    }
    $root = [NeLispCalcCanonicalPath]::Resolve($root)
    function Test-CalculatorPath([string]$ExecutablePath, [string]$TargetPath) {
        if (-not $ExecutablePath) { return $false }
        try { $actualPath = [NeLispCalcCanonicalPath]::Resolve($ExecutablePath) }
        catch { return $false }
        return $actualPath.StartsWith([IO.Path]::GetFullPath($TargetPath) + '\', [StringComparison]::OrdinalIgnoreCase)
    }
    $target = Join-Path $root 'target'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\NeLispCalc-' + $key))
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    $stateFile = Join-Path $target 'taskbar-session.json'
    $inbox = Join-Path $target 'taskbar-command.txt'
    if ($owned) {
        $legacy = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'nelisp-calc.exe'" -ErrorAction Stop | Where-Object {
            Test-CalculatorPath $_.ExecutablePath $target
        } | Select-Object -First 1
        if ($legacy) {
            if ($PSBoundParameters.ContainsKey('Mode')) { throw 'The running calculator predates mode routing; restart it to use Jump List tasks' }
            Show-Calculator $legacy.ProcessId
            @{ status = 'running'; reused = $true; guiPid = $legacy.ProcessId } | ConvertTo-Json -Compress
            return
        }
    }
    if (-not $owned) {
        $existing = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        do {
            if (Test-Path -LiteralPath $stateFile) {
                $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
                $candidate = Get-Process -Id $state.guiPid -ErrorAction SilentlyContinue
                try { $candidatePath = if ($candidate) { $candidate.Path } else { $null } }
                catch { $candidatePath = $null }
                if ($candidate -and (Test-CalculatorPath $candidatePath $target)) { $existing = $candidate; break }
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $existing) { throw 'The calculator session did not become available' }
        if (-not $PSBoundParameters.ContainsKey('Mode')) {
            Show-Calculator $existing.Id
            @{ status = 'running'; reused = $true; guiPid = $existing.Id } | ConvertTo-Json -Compress
            return
        }
    } else {
        if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile }
        if (Test-Path -LiteralPath $inbox) { Remove-Item -LiteralPath $inbox }
        $gui = Join-Path $target 'nelisp-calc.exe'
        $pointer = Join-Path $target 'current-gui.txt'
        if (Test-Path -LiteralPath $pointer) {
            $relative = [IO.File]::ReadAllText($pointer).Trim()
            if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Invalid native GUI pointer' }
            $gui = Join-Path $target $relative
        }
        if (-not (Test-Path -LiteralPath $gui -PathType Leaf)) { throw 'Native GUI is missing' }
    }
    $writeLock = New-Object Threading.Mutex($false, ('Local\NeLispCalc-Task-' + $key))
    $writing = $false
    try {
        try { $writing = $writeLock.WaitOne(20000) } catch [Threading.AbandonedMutexException] { $writing = $true }
        if (-not $writing) { throw 'Mode request queue is busy' }
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (Test-Path -LiteralPath $inbox) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'The calculator did not consume its previous mode request' }
            Start-Sleep -Milliseconds 50
        }
        $temporary = $inbox + '.' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($temporary, ('mode:' + $Mode), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $inbox
    } finally { if ($writing) { $writeLock.ReleaseMutex() }; $writeLock.Dispose() }
    if (-not $owned) {
        Show-Calculator $existing.Id
        @{ status = 'running'; reused = $true; guiPid = $existing.Id; mode = $Mode } | ConvertTo-Json -Compress
        return
    }
    if (-not $env:NELISP_CALC_APP_ID) { $env:NELISP_CALC_APP_ID = 'Fujisawa.NeLispCalc' }
    $env:NELISP_CALC_TASK_INBOX = $inbox
    $env:NELISP_CALC_TASK_SESSION = $stateFile
    $nativeLauncher = Join-Path $target 'NeLispCalc.exe'
    if (-not (Test-Path -LiteralPath $nativeLauncher)) { $nativeLauncher = Join-Path (Split-Path $root -Parent) 'NeLispCalc.exe' }
    if (-not $Hidden -and (Test-Path -LiteralPath $nativeLauncher)) {
        $registration = Start-Process -FilePath $nativeLauncher -ArgumentList '--register' -WindowStyle Hidden -PassThru -Wait
        if ($registration.ExitCode) { Write-Warning 'Jump List registration failed; calculator remains available' }
    }
    $portable = Join-Path (Split-Path $root -Parent) 'portable-launch.ps1'
    $launcher = if ((Test-Path -LiteralPath (Join-Path (Split-Path $root -Parent) 'runtime')) -and
                    (Test-Path -LiteralPath $portable)) { $portable } else { Join-Path $root 'tools/launch.ps1' }
    @{ status = 'starting'; reused = $false; mode = $Mode } | ConvertTo-Json -Compress
    if ($Activate -and -not $Hidden) {
        # This short helper waits on the owner's session without owning its backend.
        $activationArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -ProjectRoot "' + $root + '" -Activate'
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $activationArgs -WindowStyle Hidden | Out-Null
    }
    & $launcher -Hidden:$Hidden
    if (-not $?) { throw 'Calculator launcher failed' }
} finally {
    if ($owned -and $stateFile -and (Test-Path -LiteralPath $stateFile)) { Remove-Item -LiteralPath $stateFile }
    if ($owned) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
