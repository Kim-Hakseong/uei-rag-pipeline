@echo off
setlocal
cd /d "%~dp0"
title uei-rag-pipeline - Stop UEI Mode

rem ============================================================
rem  Stop-UEI-Mode.bat - stops ports 8090 / 8091 / 8099 only.
rem  Resolves port -> PID and kills just those. Never uses
rem  taskkill /im, which would also kill other projects' servers.
rem  Does NOT close VSCode or AnythingLLM.
rem ============================================================

echo.
echo ================================================
echo  UEI mode - stopping servers
echo ================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stop_all.ps1"

echo.
pause
exit /b 0
