@echo off
rem ============================================================================
rem  Ydisks Xianyu Helper - one-click deploy (ASCII-only on purpose:
rem  a .bat with non-ASCII text breaks under cp936/cp65001 mismatches)
rem ============================================================================
chcp 65001 >nul
title Ydisks Xianyu Helper - Deploy
cd /d "%~dp0"

set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS_EXE=pwsh.exe"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\run.ps1" -Script bootstrap %*
if errorlevel 1 pause
exit /b %ERRORLEVEL%