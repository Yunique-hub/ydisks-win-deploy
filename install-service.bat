@echo off
rem  ASCII-only on purpose: a .bat with non-ASCII text breaks under cp936/cp65001 mismatches.
rem  Install/remove the Windows service. Needs elevation -> run.ps1 -Elevate raises UAC.
chcp 65001 >nul
title Ydisks Xianyu Helper - Service
cd /d "%~dp0"

set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS_EXE=pwsh.exe"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\run.ps1" -Script install-service -Elevate -Pause -Arguments "-Mode","install"
exit /b %ERRORLEVEL%