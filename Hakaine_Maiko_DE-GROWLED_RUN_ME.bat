@echo off
setlocal
title Hakaine Maiko DE-GROWLED
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Hakaine_Maiko_DE-GROWLED.ps1"
if errorlevel 1 (
  echo.
  echo The tool stopped. See the message above.
  pause
)
endlocal
