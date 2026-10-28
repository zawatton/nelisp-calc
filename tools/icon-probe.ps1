param([string]$NegativeExe)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifact = Join-Path $root ('target/icon-probes/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $artifact | Out-Null
$exe = Join-Path $root ('target/' + (Get-Content (Join-Path $root 'target/current-gui.txt') -Raw).Trim())
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CalcIconProbe {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
 [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
 [DllImport("kernel32.dll")] public static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
 [DllImport("kernel32.dll")] public static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
 [DllImport("kernel32.dll")] public static extern IntPtr LockResource(IntPtr resource);
 [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern uint ExtractIconEx(string path, int index, [Out] IntPtr[] big, [Out] IntPtr[] small, uint count);
 [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
 public static int Frames(string path) {
  var module=LoadLibraryEx(path, IntPtr.Zero, 2);
  if(module==IntPtr.Zero) throw new Exception("Could not load PE resources");
  try { var resource=FindResource(module, (IntPtr)1, (IntPtr)14);
   if(resource==IntPtr.Zero) return 0;
   return Marshal.ReadInt16(LockResource(LoadResource(module, resource)),4);
  } finally { FreeLibrary(module); }
 }
 public static bool Extract(string path) {
  if(ExtractIconEx(path,-1,null,null,0)!=1) return false;
  var big=new IntPtr[1]; var small=new IntPtr[1];
  var count=ExtractIconEx(path,0,big,small,1);
  var ok=count>0 && count!=uint.MaxValue && big[0]!=IntPtr.Zero && small[0]!=IntPtr.Zero;
  if(!ok) Console.WriteLine("ICON-EXTRACT-DIAGNOSTIC count={0} big={1} small={2}",count,big[0],small[0]);
  if(big[0]!=IntPtr.Zero) DestroyIcon(big[0]);
  if(small[0]!=IntPtr.Zero) DestroyIcon(small[0]);
  return ok;
 }
}
'@
$frames=[CalcIconProbe]::Frames($exe)
$extracted=[CalcIconProbe]::Extract($exe)
if ($frames -ne 7 -or -not $extracted) { throw "Application PE icon check failed: frames=$frames extracted=$extracted" }
if ($NegativeExe -and [CalcIconProbe]::Frames((Resolve-Path -LiteralPath $NegativeExe).Path) -ne 0) { throw 'Negative PE unexpectedly has application icon group 1' }
$saved = @{}
foreach ($name in @('PATH','NELISP_CALC_HIDDEN','NELISP_CALC_COMMANDS','NELISP_CALC_THEME_FILE','NELISP_CALC_SMOKE','NELISP_CALC_KEYS')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
try {
    $bin=if($env:MINGW_BIN){$env:MINGW_BIN}else{Split-Path (Get-Command gcc -ErrorAction Stop).Source -Parent}
    $env:PATH="$bin;$env:PATH"
    $env:NELISP_CALC_HIDDEN='1'; $env:NELISP_CALC_COMMANDS='ui:nav:snapshot'
    $env:NELISP_CALC_SMOKE=$null; $env:NELISP_CALC_KEYS=$null
    $env:NELISP_CALC_THEME_FILE=Join-Path $artifact 'theme.txt'
    [IO.File]::WriteAllText((Join-Path $artifact 'response.txt'),"5`nready`n0`n")
    $process=Start-Process -FilePath $exe -WorkingDirectory $artifact -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(15000)) {
        $process.Kill(); $process.WaitForExit()
        throw 'Owned hidden icon fixture timed out'
    }
    if ($process.ExitCode -ne 0) { throw "Hidden fixture exit $($process.ExitCode)" }
    $bytes=[IO.File]::ReadAllBytes((Join-Path $artifact 'icon-native.bin'))
    if ($bytes.Length -ne 40) { throw 'Invalid HWND/icon readback receipt' }
    $values=@(0..4 | ForEach-Object {[BitConverter]::ToUInt64($bytes,8*$_)})
    if ($values[0] -eq 0 -or $values[1] -eq 0 -or $values[2] -eq 0 -or $values[1] -ne $values[3] -or $values[2] -ne $values[4]) {
        throw 'WM_GETICON differs from loaded application resource icons'
    }
    if (Test-Path -LiteralPath (Join-Path $artifact 'requests.txt')) { throw 'UI fixture unexpectedly submitted backend requests' }
    $snapshot=([IO.File]::ReadAllText((Join-Path $artifact 'navigation-native.tsv')).TrimEnd()).Split("`t")
    if ($snapshot[9] -ne '5') { throw 'Hidden UI did not preserve the backend-fixture display' }
    "ICON-NATIVE-PASS frames=7 shell=big,small hwnd=$($values[0]) WM_GETICON=big,small fixture=hidden artifact=$artifact"
    if ($NegativeExe) { 'ICON-NEGATIVE-PASS group1=absent' }
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
}
