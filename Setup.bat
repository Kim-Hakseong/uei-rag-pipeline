@echo off
setlocal
cd /d "%~dp0"
title uei-rag-pipeline - Setup
echo.
echo ================================================
echo  uei-rag-pipeline SETUP
echo  Requires local-rag to be installed already.
echo ================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
pause
