@echo off
rem 一键安装入口: 绕过执行策略限制, 双击即可
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
pause
