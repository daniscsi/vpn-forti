@echo off
rem Envoltorio de vpn.ps1. Sin argumentos (doble clic) hace "asegurar" y deja la ventana abierta.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0actualizar.ps1" >nul 2>&1
if not "%~1"=="" goto :conargs
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" asegurar
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
:conargs
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" %*
exit /b %ERRORLEVEL%
