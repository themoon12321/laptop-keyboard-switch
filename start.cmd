@echo off
set "AHK=AutoHotkey32.exe"
if exist "%SystemRoot%\SysWOW64" set "AHK=AutoHotkey64.exe"
start "" "%~dp0app\AutoHotkey\%AHK%" "%~dp0app\KeyboardToggle.ahk" gui
