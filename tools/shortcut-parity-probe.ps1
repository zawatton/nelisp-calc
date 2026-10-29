param([ValidateSet('Standalone','Host')][string]$Mode='Standalone')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$runtime=if($Mode -eq 'Host'){(Get-Command emacs).Source}else{Join-Path (Split-Path $root -Parent) 'nelisp/target/nelisp.exe'}
$test=Join-Path $root 'test/shortcut-parity-test.el'
$log=Join-Path $root ('target/shortcut-parity-'+$Mode+'.log')
$stderr=$log+'.stderr'
$arguments=if($Mode -eq 'Host'){@('-Q','--batch','-l',('"'+$test+'"'))}else{@('--load',('"'+$test+'"'))}
$p=Start-Process $runtime -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
$null=$p.Handle
if(-not $p.WaitForExit(30000)){$p.Kill();throw 'Scientific shortcut probe exceeded 30 seconds'}
Get-Content $log -Tail 3
if($p.ExitCode -ne 0 -or -not (Select-String -Path $log -SimpleMatch -Pattern 'SHORTCUT-PARITY-PASS:27' -Quiet)){Get-Content $stderr -Tail 4;throw 'Scientific shortcut target probe failed'}
