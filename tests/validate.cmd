@echo off
rem Syntax gate for the AHK sources
"%~dp0..\app\AutoHotkey\AutoHotkey64.exe" /ErrorStdOut /validate "%~dp0..\app\KeyboardToggle.ahk"
if %ERRORLEVEL% NEQ 0 exit /b 1
"%~dp0..\app\AutoHotkey\AutoHotkey64.exe" /ErrorStdOut /validate "%~dp0..\app\lib\KbCore.ahk"
if %ERRORLEVEL% NEQ 0 exit /b 1
echo SYNTAX_OK
exit /b 0
