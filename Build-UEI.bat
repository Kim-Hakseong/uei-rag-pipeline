@echo off
setlocal
cd /d "%~dp0"
title uei-rag-pipeline - Build (split + embed)
echo.
echo ================================================
echo  BUILD - split manuals and embed them
echo  Put your manual PDFs in manuals-inbox\ first.
echo ================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build_uei.ps1"
echo.
pause
