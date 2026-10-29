param([string]$Source)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(-not $Source){$Source=Join-Path $root 'src/nelisp-calc-gui.el'}
$artifact=Join-Path $root ('target/entry-feedback/'+[Guid]::NewGuid().ToString('N'))
$fixture=Join-Path $artifact 'fixture'
New-Item -ItemType Directory -Force (Join-Path $fixture 'src') | Out-Null
foreach($name in @('build.el','keyboard.el','gestures.el','navigation.el','taskbar.el','scientific-controls.el','graph-implicit-controls.el','assets','lisp')){
 Copy-Item -LiteralPath (Join-Path $root $name) -Destination $fixture -Recurse
}
# The fixture builds the real source and real GTK callbacks. Only its entry point
# is replaced; no response process runs, and no visible window is presented.
$text=[IO.File]::ReadAllText($Source)
$fallback=if($text -notmatch '\(defun entry_display '){'(defun entry_display (ctx) (ptr-read-u64 ctx 16))'}else{''}
$driver=@'
 (data-blob ep_path "entry.tsv\0" rodata)
 (data-blob ep_five_png "entry-12345.png\0" rodata)
 (data-blob ep_offset_env "NELISP_CALC_ENTRY_ACK_OFFSET\0" rodata)
 (data-blob ep_101 "1\nediting\n101\n\0" rodata)
 (data-blob ep_102 "12\nediting\n102\n\0" rodata)
 (data-blob ep_format "%ld\t%s\t%s\t%ld\t%ld\t%ld\t%ld\t%ld\t%ld\t%ld\t%ld\n\0" rodata)
 (data-blob ep_zero "0\nready\n0\n\0" rodata)
 (data-blob ep_partial "1\nediting\n1\n\0" rodata)
 (data-blob ep_final "12345\nediting\n5\n\0" rodata)
 (data-blob ep_six "0\nready\n6\n\0" rodata)
 (data-blob ep_equals "3\nok\n10\n\0" rodata)
 (data-blob ep_four "4\nediting\n11\n\0" rodata)
 (data-blob ep_error "ERROR\narithmetic-error\n12\n\0" rodata)
 (data-blob ep_recover "7\nediting\n13\n\0" rodata)
 (data-blob ep_sign "sign\n\0" rodata)
 (data-blob ep_percent "percent\n\0" rodata)
 (data-blob ep_memory "memory:store\n\0" rodata)
 (data-blob ep_function "function:sqrt\n\0" rodata)
 (data-blob ep_negative "-78\nediting\n15\n\0" rodata)
 (data-blob ep_fourteen "-7\nediting\n14\n\0" rodata)
 (data-blob ep_scientific "mode:scientific\n\0" rodata)
 (data-blob ep_standard "mode:standard\n\0" rodata)
 (data-blob ep_recall "history:recall:0\n\0" rodata)
 (defun ep_receipt (ctx id elapsed)
   (let ((surface (extern-call cairo_image_surface_create 0 400 560)))
     (let ((cr (extern-call cairo_create surface)) (start (extern-call g_get_monotonic_time)))
       (seq (extern-call gtk_widget_allocate (ptr-read-u64 ctx 8) 400 560 -1 0)
            (on_draw (ptr-read-u64 ctx 8) cr 400 560 ctx)
            (let ((draw (- (extern-call g_get_monotonic_time) start))
                  (fp (extern-call fopen (data-addr ep_path) (data-addr append_mode))))
              (seq (extern-call fprintf fp (data-addr ep_format) id
                (entry_display ctx) (ptr-read-u64 ctx 16)
                (ptr-read-u64 ctx 32) (ptr-read-u64 ctx 8904)
                (ptr-read-u64 ctx 8888) (ptr-read-u64 ctx 8896) elapsed draw
                (extern-call gtk_widget_get_width (ptr-read-u64 ctx 8))
                (extern-call gtk_widget_get_height (ptr-read-u64 ctx 8)))
                (extern-call fclose fp)))
            (extern-call cairo_surface_write_to_png surface (data-addr interaction_path))
            (if (= id 5) (extern-call cairo_surface_write_to_png surface (data-addr ep_five_png)) 0)
            (extern-call cairo_destroy cr) (extern-call cairo_surface_destroy surface) 0))))
 (defun ep_key (ctx key id)
   (let ((start (extern-call g_get_monotonic_time)))
     (seq (if (= key 65535)
            (extern-call g_signal_emit_by_name (ptr-read-u64 ctx 96) (data-addr key_pressed) key 0 0 (+ ctx 128))
            (emit_input ctx key))
          (ep_receipt ctx id (- (extern-call g_get_monotonic_time) start)) 0)))
 (defun ep_ack (ctx text id)
   (seq (extern-call g_file_set_contents (data-addr response) text -1 0)
        (poll_response ctx) (ep_receipt ctx id 0) 0))
 (defun ep_repeat (ctx remaining)
   (if (> remaining 0) (seq (emit_input ctx 57) (ep_repeat ctx (- remaining 1))) 0))
 (defun ep_long (ctx remaining)
   (if (> remaining 0)
     (seq (entry_echo ctx (data-addr token_10)) (ep_long ctx (- remaining 1))) 0))
 (defun entry_native_offset (ctx)
   (seq (ptr-write-u64 ctx 32 100) (ptr-write-u64 ctx 3480 1)
        (ep_key ctx 49 1) (ep_key ctx 50 2)
        (ep_ack ctx (data-addr ep_101) 3)
        (ep_ack ctx (data-addr ep_102) 4) 0))
 (defun entry_native_fixture (ctx)
   (if (/= (extern-call getenv (data-addr ep_offset_env)) 0)
     (entry_native_offset ctx)
   (seq
    (ep_receipt ctx 0 0)
    (ep_key ctx 49 1) (ep_key ctx 50 2) (ep_key ctx 51 3)
    (ep_key ctx 52 4) (ep_key ctx 53 5)
    (ep_ack ctx (data-addr ep_zero) 6)
    (ep_ack ctx (data-addr ep_partial) 7)
    (ep_ack ctx (data-addr ep_final) 8)
    (ep_key ctx 65307 9) (ep_key ctx 49 10) (ep_key ctx 43 11)
    (ep_key ctx 50 12) (ep_key ctx 61 13) (ep_key ctx 52 14)
    (ep_ack ctx (data-addr ep_six) 57)
    (ep_ack ctx (data-addr ep_equals) 15) (ep_ack ctx (data-addr ep_four) 16)
    (send_command ctx (data-addr ep_sign))
    (ep_ack ctx (data-addr ep_error) 17)
    (ep_key ctx 55 18) (ep_ack ctx (data-addr ep_recover) 19)
    (send_command ctx (data-addr ep_sign)) (ep_receipt ctx 20 0)
    (ep_key ctx 56 21) (ep_ack ctx (data-addr ep_fourteen) 58)
    (ep_ack ctx (data-addr ep_negative) 22)
    (ep_key ctx 46 23) (ep_key ctx 46 24) (ep_key ctx 65288 25)
    (ep_key ctx 65535 26) (ep_key ctx 46 27) (ep_key ctx 65288 28)
    (send_command ctx (data-addr ep_recall)) (ep_key ctx 57 29)
    (ep_key ctx 65307 35) (ep_key ctx 51 36) (ep_key ctx 61 37)
    (ep_key ctx 52 40) (ep_key ctx 65288 41)
    (ep_key ctx 43 38) (ep_key ctx 50 39) (ep_key ctx 61 42)
    (ep_key ctx 65288 43) (ep_key ctx 61 44) (ep_key ctx 52 45)
    (send_command ctx (data-addr ep_percent)) (ep_key ctx 55 46)
    (send_command ctx (data-addr ep_memory)) (ep_receipt ctx 47 0)
    (send_command ctx (data-addr ep_function)) (ep_receipt ctx 48 0)
    (ep_key ctx 53 49)
    (ep_key ctx 65307 59) (ep_key ctx 49 60) (ep_key ctx 43 61)
    (ep_key ctx 50 62) (ep_key ctx 65535 63) (ep_key ctx 51 64)
    (ep_key ctx 61 65) (ep_key ctx 52 66)
    (ep_key ctx 65307 67) (ep_key ctx 49 68) (ep_key ctx 43 69)
    (ep_key ctx 50 70) (ep_key ctx 61 71) (ep_key ctx 65535 72)
    (ep_key ctx 51 73) (ep_key ctx 61 74) (ep_key ctx 52 75)
    (send_command ctx (data-addr ep_scientific))
    (ptr-write-u64 ctx 3120 1) (ep_key ctx 57 30)
    (send_command ctx (data-addr ep_standard)) (ptr-write-u64 ctx 3120 0)
    (ep_repeat ctx 67) (ep_receipt ctx 31 0)
    (ptr-write-u64 ctx 136 0) (ptr-write-u64 ctx 8896 0)
    (ptr-write-u64 ctx 8888 0) (ep_long ctx 260)
    (ptr-write-u64 ctx 8888 1) (ep_receipt ctx 34 0)
    (ptr-write-u64 ctx 8888 0) (ep_receipt ctx 32 0)
    (ptr-write-u64 ctx 8760 1) (ep_key ctx 57 33)
    0)))
'@
# Old sources get only the read helper; their absent local echo remains absent.
if($fallback){$driver=$driver.Replace('(entry_echo ctx (data-addr token_10))','0')}
$text=$text.Replace(' (defun main ()',(" $fallback`n"+$driver+"`n (defun main ()"))
$text=$text.Replace(' (defun header_probe_capture (ctx)', ' (defun header_probe_capture (ctx)')
$marker=" (defun header_probe_capture (ctx)`n   (let ((window (ptr-read-u64 ctx 3288)))"
$text=$text.Replace("`r`n","`n")
if(-not $text.Contains($marker)){throw 'Native offscreen capture hook missing'}
$text=$text.Replace($marker," (defun header_probe_capture (ctx)`n   (let ((window (seq (entry_native_fixture ctx) (ptr-read-u64 ctx 3288))))")
[IO.File]::WriteAllText((Join-Path $fixture 'src/nelisp-calc-gui.el'),$text,[Text.UTF8Encoding]::new($false))
$saved=@{}
foreach($name in @('NELISP_ROOT','NELISP_CALC_GUI_OUTPUT','NELISP_CALC_HIDDEN','NELISP_CALC_HEADER_PROBE','NELISP_CALC_COMMANDS','NELISP_CALC_KEYS','NELISP_CALC_SMOKE','NELISP_CALC_MOUSE','NELISP_CALC_ENTRY_ACK_OFFSET','PATH')){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
 $env:NELISP_ROOT=Join-Path (Split-Path $root -Parent) 'nelisp'
 $exe=Join-Path $artifact 'entry-native.exe'; $env:NELISP_CALC_GUI_OUTPUT=$exe
 & emacs -Q --batch -l (Join-Path $fixture 'build.el') *> (Join-Path $artifact 'build.log')
 if($LASTEXITCODE -ne 0){throw "Native fixture build failed: $artifact/build.log"}
 $env:NELISP_CALC_HIDDEN='1'; $env:NELISP_CALC_HEADER_PROBE='entry'
 $env:NELISP_CALC_COMMANDS=$null; $env:NELISP_CALC_KEYS=$null; $env:NELISP_CALC_SMOKE=$null
 $bin=if($env:MINGW_BIN){$env:MINGW_BIN}else{Split-Path (Get-Command gcc).Source -Parent}
 $env:PATH="$bin;$env:PATH"
 foreach($mouse in @($false,$true)){
  foreach($offset in @($false,$true)){
  $session=Join-Path $artifact ($(if($mouse){'mouse'}else{'keys'})+$(if($offset){'-offset100'}else{''}))
  New-Item -ItemType Directory -Force $session | Out-Null
  $env:NELISP_CALC_MOUSE=if($mouse){'1'}else{$null}
  $env:NELISP_CALC_ENTRY_ACK_OFFSET=if($offset){'100'}else{$null}
  $process=Start-Process -FilePath $exe -WorkingDirectory $session -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $session 'stderr.log')
  try{if(-not $process.WaitForExit(10000)){$process.Kill();throw 'Native entry fixture timed out'};$process.Refresh();if($null -ne $process.ExitCode -and $process.ExitCode -ne 0){throw "Native entry fixture exit=$($process.ExitCode)"}}finally{if(-not $process.HasExited){$process.Kill()}}
  $rows=@{};foreach($line in Get-Content (Join-Path $session 'entry.tsv')){$f=$line.Split("`t");$rows[[int]$f[0]]=$f}
  if($offset){
   if($rows[2][1] -ne '12' -or $rows[3][1] -ne '12' -or $rows[3][2] -ne '1' -or $rows[3][4] -ne '102' -or $rows[4][1] -ne '12' -or $rows[4][5] -ne '0'){throw "Absolute causal barrier failed: $artifact"}
   "ENTRY-NATIVE-CASE-PASS mouse=$mouse offset=100 receipts=$($rows.Count) artifact=$session"
   continue
  }
  foreach($pair in @(@(1,'1'),@(2,'12'),@(3,'123'),@(4,'1234'),@(5,'12345'),@(6,'12345'),@(7,'12345'),@(8,'12345'),@(9,'0'),@(10,'1'),@(12,'2'),@(14,'4'),@(15,'4'),@(16,'4'),@(17,'ERROR'),@(18,'7'),@(19,'7'),@(20,'7'),@(21,'7'),@(22,'-78'),@(23,'-78.'),@(24,'-78.'),@(25,'-78'),@(26,'0'),@(27,'0.'),@(28,'0'))){if($rows[$pair[0]][1] -cne $pair[1]){throw "ENTRY-FAIL id=$($pair[0]) display=$($rows[$pair[0]][1]) expected=$($pair[1]) artifact=$artifact"}}
  foreach($id in 1..5){if($rows[$id][2] -ne '0' -or [long]$rows[$id][7] -gt 30000 -or [long]$rows[$id][8] -gt 30000 -or [int]$rows[$id][9] -le 0){throw "Entry did not render independently within 30ms id=$id artifact=$artifact"}}
  foreach($pair in @(@(40,'34'),@(41,'3'),@(42,'2'),@(43,'2'),@(45,'4'),@(46,'4'))){if($rows[$pair[0]][1] -cne $pair[1]){throw "Fresh/opaque semantics failed id=$($pair[0]) artifact=$artifact"}}
  if($rows[47][6] -ne '4' -or $rows[48][6] -ne '4' -or $rows[49][1] -ne '4' -or $rows[49][6] -ne '2'){throw "Memory/function freshness was guessed: $artifact"}
  if($rows[63][1] -ne '0' -or $rows[64][1] -ne '3' -or $rows[66][1] -ne '4' -or $rows[72][1] -ne '0' -or $rows[73][1] -ne '3' -or $rows[75][1] -ne '4'){throw "CE discarded pending/repeat arithmetic intent: $artifact"}
  if($rows[29][5] -ne '1' -or $rows[30][5] -ne '0' -or $rows[31][5] -ne '0' -or $rows[34][1].Length -ne 255 -or $rows[32][5] -ne '0' -or $rows[33][1] -ne $rows[33][2]){throw "Opaque/mode/overflow/fail-stop failed: $artifact"}
  $header=(Get-Content (Join-Path $session 'header-native.tsv') | Select-Object -Last 1).Split("`t")
  if($header[6] -ne '1' -or -not (Test-Path (Join-Path $session 'header-native.png'))){throw 'Offscreen GTK snapshot or no-activation contract failed'}
  "ENTRY-NATIVE-CASE-PASS mouse=$mouse receipts=$($rows.Count) artifact=$session"
  }
 }
 "ENTRY-NATIVE-PASS cases=4 artifact=$artifact"
}finally{foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}}
