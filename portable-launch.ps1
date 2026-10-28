param([switch]$Hidden, [string[]]$Commands, [string]$ExpectedDisplay, [string]$ExpectedStatus, [int]$TimeoutSeconds = 55)
$ErrorActionPreference = 'Stop'
$bundle = $PSScriptRoot
$env:NELISP_CALC_DLL_DIR = Join-Path $bundle 'runtime/bin'
$env:NELISP_BIN = Join-Path $bundle 'nelisp/target/nelisp.exe'
$env:NELISP_CALC_ENGINE_ROOT = Join-Path $bundle 'app'
$env:NELISP_CALC_VENDOR = Join-Path $bundle 'nelisp-emacs/vendor/emacs-lisp/calc'
$env:NELISP_EMACS_DIR = Join-Path $bundle 'nelisp-emacs'
$env:NELISP_CALC_SERVER = Join-Path $bundle 'app/lisp/package-entry.el'
$env:GSETTINGS_SCHEMA_DIR = Join-Path $bundle 'runtime/share/glib-2.0/schemas'
$arguments = @{ Hidden = $Hidden; TimeoutSeconds = $TimeoutSeconds }
if ($Commands) { $arguments.Commands = $Commands }
if ($PSBoundParameters.ContainsKey('ExpectedDisplay')) { $arguments.ExpectedDisplay = $ExpectedDisplay }
if ($PSBoundParameters.ContainsKey('ExpectedStatus')) { $arguments.ExpectedStatus = $ExpectedStatus }
& (Join-Path $bundle 'app/tools/launch.ps1') @arguments
