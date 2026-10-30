@echo off
rem Envoltorio de vpn.ps1. Sin argumentos (doble clic) hace "asegurar" y deja la ventana abierta.
setlocal
if not "%~1"=="" goto :conargs
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" asegurar
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
:conargs
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" %*
exit /b %ERRORLEVEL%
