@echo off
setlocal
cd /d "%~dp0"
title uei-rag-pipeline - UEI Mode (coding)

rem ============================================================
rem  Start-UEI-Mode.bat - double-click entry point (UEI/coding)
rem    Swaps port 8090 to the coder model, brings up the embedder
rem    and the @uei context server, then you code in VSCode.
rem
rem  NOTE: ASCII-only on purpose. cmd.exe mis-parses multi-byte
rem  characters in .bat files. Korean docs live in README.md.
rem ============================================================

echo.
echo ================================================
echo  UEI mode - starting coder + manual search
echo ================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\serve_coder.ps1"
if errorlevel 1 goto FAILED

echo.
echo Next: open VSCode, use @uei in Continue.
echo   Config guide: docs\continue-config.md
echo.
pause
exit /b 0

:FAILED
echo.
echo [FAILED] UEI mode did not start. Check logs\coder-YYYYMMDD.err.log
echo   If VRAM is short, lower CTX_CODER in spec\paths.md (32768 -^> 16384 -^> 8192)
echo.
pause
exit /b 1
