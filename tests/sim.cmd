@echo off
rem Simulation regression tests - no real keyboard touched
"%~dp0..\app\AutoHotkey\AutoHotkey64.exe" /ErrorStdOut "%~dp0sim.ahk"
set "testResult=%ERRORLEVEL%"
type "%~dp0sim-results.txt"
exit /b %testResult%
