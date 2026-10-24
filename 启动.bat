@echo off
rem  ASCII-only on purpose: a .bat with non-ASCII text breaks under cp936/cp65001 mismatches.
chcp 65001 >nul
title Ydisks Xianyu Helper - Start
cd /d "%~dp0"

set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS_EXE=pwsh.exe"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\run.ps1" -Script start -Pause %*
exit /b %ERRORLEVEL%