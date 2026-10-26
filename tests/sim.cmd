@echo off
rem Simulation regression tests - no real keyboard touched
"%~dp0..\app\AutoHotkey\AutoHotkey64.exe" "%~dp0sim.ahk"
type "%~dp0sim-results.txt"
exit /b %ERRORLEVEL%
