param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent), [string]$MingwBin = $env:MINGW_BIN, [string]$LauncherSnapshot, [switch]$NoZip)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$dev = Split-Path $source -Parent
if (-not $MingwBin) { $MingwBin = Split-Path (Get-Command gcc -ErrorAction Stop).Source -Parent }
$MingwBin = (Resolve-Path -LiteralPath $MingwBin).Path
$objdump = (Get-Command objdump -ErrorAction Stop).Source
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$output = Join-Path $project ('target/packages/' + $stamp)
$bundle = Join-Path $output 'NeLisp-Calc'
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
$origins = @{}
function Copy-BundleFile([string]$From, [string]$Relative, [string]$Origin) {
    $resolved = (Resolve-Path -LiteralPath $From).Path
    $destination = Join-Path $bundle $Relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $resolved -Destination $destination
    $origins[$Relative.Replace('\', '/')] = $Origin
}
function Copy-BundleTree([string]$From, [string]$Relative, [string]$Origin) {
    $tree = (Resolve-Path -LiteralPath $From).Path
    foreach ($file in Get-ChildItem -LiteralPath $tree -Recurse -File) {
        $suffix = $file.FullName.Substring($tree.Length).TrimStart('\', '/')
        Copy-BundleFile $file.FullName (Join-Path $Relative $suffix) ($Origin + '/' + $suffix.Replace('\', '/'))
    }
}
$pointer = [IO.File]::ReadAllText((Join-Path $source 'target/current-gui.txt')).Trim()
if ([IO.Path]::IsPathRooted($pointer) -or $pointer -match '(^|[\\/])\.\.([\\/]|$)' -or -not $pointer) { throw 'Invalid source GUI pointer' }
$guiSource = Join-Path $source ('target/' + $pointer)
Copy-BundleFile $guiSource 'app/target/nelisp-calc.exe' ('app/target/' + $pointer)
Copy-BundleFile (Join-Path $dev 'nelisp/target/nelisp.exe') 'nelisp/target/nelisp.exe' 'nelisp/target/nelisp.exe'
Copy-BundleTree (Join-Path $source 'lisp') 'app/lisp' 'app/lisp'
Copy-BundleTree (Join-Path $source 'src') 'app/src' 'app/src'
foreach ($file in @('build.el', 'keyboard.el', 'gestures.el', 'README.org')) { Copy-BundleFile (Join-Path $source $file) ('app/' + $file) ('app/' + $file) }
foreach ($file in @('launch.ps1', 'update-rates.ps1')) {
    $scriptSource = if ($file -eq 'launch.ps1' -and $LauncherSnapshot) { $LauncherSnapshot } else { Join-Path $source ('tools/' + $file) }
    Copy-BundleFile $scriptSource ('app/tools/' + $file) ('app/tools/' + $file)
}
if (Test-Path -LiteralPath (Join-Path $source 'target/currency-rates.tsv')) { Copy-BundleFile (Join-Path $source 'target/currency-rates.tsv') 'app/target/currency-rates.tsv' 'app/target/currency-rates.tsv' }
Copy-BundleTree (Join-Path $dev 'nelisp-emacs/vendor/emacs-lisp') 'nelisp-emacs/vendor/emacs-lisp' 'nelisp-emacs/vendor/emacs-lisp'
foreach ($package in @('nelisp-emacs-core', 'nelisp-emacs-foundation')) { Copy-BundleTree (Join-Path $dev ('nelisp/packages/' + $package + '/src')) ('nelisp/packages/' + $package + '/src') ('nelisp/packages/' + $package + '/src') }
Copy-BundleTree (Join-Path $dev 'nelisp/lisp') 'nelisp/lisp' 'nelisp/lisp'
Copy-BundleTree (Join-Path $dev 'nelisp/vendor/emacs-lisp') 'nelisp/vendor/emacs-lisp' 'nelisp/vendor/emacs-lisp'
Copy-BundleTree (Join-Path $dev 'nelisp/vendor/staged-emacs-lisp') 'nelisp/vendor/staged-emacs-lisp' 'nelisp/vendor/staged-emacs-lisp'
foreach ($file in @('LICENSE', 'LICENSE.nelisp-emacs-lib')) { Copy-BundleFile (Join-Path $dev ('nelisp/' + $file)) ('licenses/nelisp/' + $file) ('nelisp/' + $file) }
Copy-BundleFile (Join-Path $dev 'nelisp-emacs/LICENSE') 'licenses/nelisp-emacs/LICENSE' 'nelisp-emacs/LICENSE'
$mingwRoot = Split-Path $MingwBin -Parent
Copy-BundleTree (Join-Path $mingwRoot 'share/licenses') 'licenses/mingw' 'MINGW/share/licenses'
$schema = Join-Path $mingwRoot 'share/glib-2.0/schemas/gschemas.compiled'
if (Test-Path -LiteralPath $schema) { Copy-BundleFile $schema 'runtime/share/glib-2.0/schemas/gschemas.compiled' 'MINGW/share/glib-2.0/schemas/gschemas.compiled' }
$queue = New-Object 'System.Collections.Generic.Queue[string]'
$queue.Enqueue((Resolve-Path -LiteralPath $guiSource).Path)
$queue.Enqueue((Resolve-Path -LiteralPath (Join-Path $dev 'nelisp/target/nelisp.exe')).Path)
$visited = @{}
$edges = @()
while ($queue.Count -gt 0) {
    $binary = $queue.Dequeue()
    if ($visited.ContainsKey($binary)) { continue }
    $visited[$binary] = $true
    $headers = & $objdump -p $binary
    if ($LASTEXITCODE -ne 0) { throw "objdump failed for $binary" }
    foreach ($line in $headers) {
        if ($line -notmatch 'DLL Name:\s*(\S+)') { continue }
        $name = $Matches[1]
        $system = Join-Path $env:SystemRoot ('System32/' + $name)
        $systemImport = (Test-Path -LiteralPath $system) -or $name -match '^(api-ms-|ext-ms-)'
        $edges += @{ binary = [IO.Path]::GetFileName($binary); dependency = $name; windowsSystem = $systemImport }
        if ($systemImport) { continue }
        $dependency = Join-Path $MingwBin $name
        if (-not (Test-Path -LiteralPath $dependency)) { throw "Unresolved non-system DLL: $name required by $binary" }
        if (-not $origins.ContainsKey(('runtime/bin/' + $name))) { Copy-BundleFile $dependency ('runtime/bin/' + $name) ('MINGW/bin/' + $name) }
        $queue.Enqueue((Resolve-Path -LiteralPath $dependency).Path)
    }
}
foreach ($template in @('Launch.cmd', 'portable-launch.ps1')) { Copy-BundleFile (Join-Path $project $template) $template ('package-template/' + $template) }
$entry = @'
;;; package-entry.el --- Isolated relocatable package bootstrap -*- lexical-binding: t; -*-
(let* ((root (file-name-directory (replace-regexp-in-string "\\\\" "/" load-file-name t t)))
       (bundle (expand-file-name "../.." root)))
  (setq load-path
        (mapcar (lambda (path) (expand-file-name path bundle))
                '("app/lisp" "nelisp/lisp"
                  "nelisp/packages/nelisp-emacs-core/src"
                  "nelisp/packages/nelisp-emacs-foundation/src"
                  "nelisp/vendor/emacs-lisp" "nelisp/vendor/emacs-lisp/progmodes"
                  "nelisp/vendor/emacs-lisp/emacs-lisp" "nelisp/vendor/emacs-lisp/calendar"
                  "nelisp/vendor/staged-emacs-lisp"
                  "nelisp-emacs/vendor/emacs-lisp/calc"
                  "nelisp-emacs/vendor/emacs-lisp/emacs-lisp"
                  "nelisp-emacs/vendor/emacs-lisp")))
  (load (expand-file-name "nelisp-calc-mailbox.el" root) nil t))
'@
[IO.File]::WriteAllText((Join-Path $bundle 'app/lisp/package-entry.el'), $entry, (New-Object Text.UTF8Encoding($false)))
$origins['app/lisp/package-entry.el'] = 'generated: isolated package bootstrap'
$notice = @'
NeLisp Calc portable Windows folder

Run Launch.cmd. PowerShell 7 is preferred; Windows PowerShell is used when
pwsh is unavailable. PowerShell and Windows system DLLs are not bundled.
GNU Emacs, gcc and the source checkout are not required at runtime.
The native GUI, NeLisp runtime, GNU Calc sources, provider sources and
non-system native DLL dependency closure are included. Currency rates
are a dated cache; refresh requires internet access.

The application and bundled GNU/NeLisp components retain their original
copyright/license headers. licenses/ contains the NeLisp and dependency
license notices, and GNU source COPYING is preserved in the vendor tree.
manifest.json records each shipped file's SHA256 and source-relative origin.
dll-imports.json records Windows-system exclusions and DLL dependency edges.
This is a local portable artifact, not a signed installer or a single exe.
Before external redistribution, accompany GPL components with their complete
corresponding source and retain the dependency license notices.
'@
[IO.File]::WriteAllText((Join-Path $bundle 'README.txt'), $notice, (New-Object Text.UTF8Encoding($false)))
$origins['README.txt'] = 'generated: package usage and license notice'
$edges | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $bundle 'dll-imports.json') -Encoding UTF8
$origins['dll-imports.json'] = 'generated: objdump PE import traversal'
$manifest = foreach ($file in Get-ChildItem -LiteralPath $bundle -Recurse -File) {
    $relative = $file.FullName.Substring($bundle.Length).TrimStart('\', '/').Replace('\', '/')
    @{ path = $relative; bytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash; origin = $origins[$relative] }
}
@{ schemaVersion = 1; generatedUtc = [DateTime]::UtcNow.ToString('o'); guiSource = ('app/target/' + $pointer); powershellBundled = $false; files = @($manifest) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Encoding UTF8
$zip = $null
if (-not $NoZip) { $zip = Join-Path $output 'NeLisp-Calc.zip'; Compress-Archive -LiteralPath $bundle -DestinationPath $zip -CompressionLevel Optimal }
$summary = @{ bundle = $bundle; zip = $zip; bytes = ($manifest | Measure-Object bytes -Sum).Sum; files = @($manifest).Count; nativeDlls = @(Get-ChildItem -LiteralPath (Join-Path $bundle 'runtime/bin') -Filter '*.dll').Count }
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'package-summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Compress
