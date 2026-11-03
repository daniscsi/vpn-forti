@echo off
rem Envoltorio de vpn.ps1. Sin argumentos (doble clic) hace "asegurar" y deja la ventana abierta.
setlocal
rem Lo primero: comprobar si hay version nueva y descargarla (siempre; ACTUALIZAR_SIN=1 lo salta, ACTUALIZAR_CADA_MIN=N lo limita).
rem Sin salida por consola (la salida es el JSON de vpn.ps1); solo queda rastro en actualizar.log. El bloque con goto evita
rem que cmd siga leyendo por un desplazamiento viejo si el pull cambia este mismo .cmd.
(
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0actualizar.ps1" >nul 2>&1
    goto :actualizado
)
:actualizado
del /q "%~dp0.actualizado" >nul 2>&1
if not "%~1"=="" goto :conargs
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" asegurar
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
:conargs
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" %*
exit /b %ERRORLEVEL%
