@echo off
rem Refreshes Gen's stats from the Riot API, then opens the page.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"
if errorlevel 1 timeout /t 5 >nul
start "" "%~dp0index.html"
