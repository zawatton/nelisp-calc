@echo off
if exist "%~dp0NeLispCalc.exe" (
  start "" "%~dp0NeLispCalc.exe" %*
  exit /b
)
where pwsh.exe >nul 2>nul
if %errorlevel% equ 0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0portable-launch.ps1" %*
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0portable-launch.ps1" %*
)
