<#
.SYNOPSIS
  Pruebas de vpn-forti sin dependencias (PowerShell 5.1, sin Pester): detección del diálogo de error de Electron,
  orden y elección de modos de arranque, fallback, regla de no cerrar FortiClient con VPN conectada, enmascarado
  del diagnóstico, config.json y formato del JSON de "diagnosticar".

.DESCRIPTION
  powershell -NoProfile -ExecutionPolicy Bypass -File pruebas\pruebas.ps1 [-Filtro texto] [-SinGui]

  Los accesos a FortiClient, al Explorador y a la VPN se sustituyen por dobles: NO se abre, cierra ni mata
  FortiClient. Pruebas con efectos visibles (se saltan con -SinGui):
    - un MessageBox «Error» falso de otro proceso para comprobar que el diálogo se detecta y se cierra de verdad;
    - "vpn.ps1 probar-arranque" real, solo si HAY VPN conectada (entonces debe salir con 9 sin tocar FortiClient).
  "vpn.ps1 diagnosticar" real es de solo lectura (escribe en una carpeta temporal).
  Sale con el número de pruebas fallidas.
#>
[CmdletBinding()]
param([string]$Filtro = '', [switch]$SinGui)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
$script:Total = 0; $script:Fallos = 0; $script:Saltadas = 0
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("vpn-forti-pruebas-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $Tmp | Out-Null

function Probar([string]$Nombre, [scriptblock]$Cuerpo) {
    if ($Filtro -and $Nombre -notmatch [regex]::Escape($Filtro)) { return }
    $script:Total++
    try { & $Cuerpo; Write-Host "  ok    $Nombre" -ForegroundColor Green }
    catch { $script:Fallos++; Write-Host "  FALLA $Nombre`n        $($_.Exception.Message)" -ForegroundColor Red }
}
function Saltar([string]$Nombre, [string]$Motivo) { $script:Saltadas++; Write-Host "  salta $Nombre ($Motivo)" -ForegroundColor Yellow }
function Afirmar($Condicion, [string]$Mensaje = 'la condición es falsa') { if (-not $Condicion) { throw $Mensaje } }
function Igual($Actual, $Esperado, [string]$Mensaje = '') { if ((@($Actual) -join '|') -ne (@($Esperado) -join '|')) { throw "esperado '$(@($Esperado) -join '|')', obtenido '$(@($Actual) -join '|')' $Mensaje" } }

# ---------------------------------------------------------------- bibliotecas y dobles
. (Join-Path $Raiz 'lib\Consola.ps1')
. (Join-Path $Raiz 'lib\Diagnostico.ps1')
$script:ElevacionSegPorDefecto = 1
$script:CierreEsperaSeg = 1
$script:DirLanzamiento = $Tmp
# Funciones reales que luego se sustituyen por dobles: la prueba del diálogo falso las necesita tal cual.
$RealBuscarDialogo = ${function:Buscar-DialogoErrorForti}
$RealCerrarDialogo = ${function:Cerrar-DialogoError}
$RealLanzar = ${function:Lanzar-ModoConsola}
$script:RutaCfgDoble = Join-Path $Tmp 'config-doble.json'

$Cfg = [ordered]@{ fortiClientExe = 'C:\Fortinet\FortiClient\FortiClient.exe'; tunel = 'T'; consola = [ordered]@{ modo = ''; esperaSeg = 2; pruebaSeg = 2 } }

# Estado simulado: $D.Vpn = conectada | adaptador-up | desconectada | dns | error | sin-adaptador | descripcion-distinta |
# error-adaptadores | varios-abajo | varios-uno-up | estado-raro ; $D.Procs = ids de FortiClient ; $D.Elevacion = procesos de
# elevación vivos ; $D.AlLanzar = scriptblock que se ejecuta tras lanzar un modo ;
# $D.Escenario[id] = ok | ok-sin-form | crash | salio | nada | sin-proceso ; $D.CierreOrdenado = $true/$false.
function Nuevo-Escenario {
    $script:D = @{ Vpn = 'desconectada'; Procs = @(); Escenario = @{}; Actual = $null; Llamadas = New-Object System.Collections.Generic.List[string]
        CierreOrdenado = $true; DialogoVisible = $false; Logs = New-Object System.Collections.Generic.List[string]; Guardado = $null; Elevacion = @(); AlLanzar = $null }
}
function Log([string]$m) { $script:D.Logs.Add($m) }
# Get-Estado como el REAL de vpn.ps1: nunca lanza por no encontrar el adaptador (devuelve adaptador $null) y solo
# mira el adaptador de la descripción configurada.
function Get-Estado {
    $v = $script:D.Vpn
    if ($v -eq 'error') { throw 'sin acceso al adaptador' }
    $ip = $(if ($v -in 'conectada', 'dns') { '100.64.0.1' } else { $null })
    $ad = switch ($v) {
        'conectada' { [ordered]@{ nombre = 'Ethernet 3'; estado = 'Up' } }
        'adaptador-up' { [ordered]@{ nombre = 'Ethernet 3'; estado = 'Up' } }
        { $_ -in 'desconectada', 'dns', 'varios-abajo', 'varios-uno-up' } { [ordered]@{ nombre = 'Ethernet 3'; estado = 'Disconnected' } }
        default { $null }
    }
    $arriba = [bool]($ad -and $ad.estado -eq 'Up')
    return [ordered]@{ conectada = [bool]($arriba -and $ip); adaptador = $ad; dns = [ordered]@{ host = 'h'; ip = $ip }; tunel = $null }
}
function Obtener-AdaptadoresFortinet {
    $f = { param($n, $e) [pscustomobject]@{ Nombre = $n; Descripcion = 'Fortinet SSL VPN Virtual Ethernet Adapter'; Estado = $e } }
    switch ($script:D.Vpn) {
        'error-adaptadores' { throw 'Get-NetAdapter ha fallado' }
        'sin-adaptador' { return @() }
        'descripcion-distinta' { return @([pscustomobject]@{ Nombre = 'Ethernet 9'; Descripcion = 'Adaptador virtual VPN (otro texto)'; Estado = 'Up' }) }
        'varios-abajo' { return @((& $f 'Ethernet 3' 'Disconnected'), (& $f 'Ethernet 4' 'Not Present')) }
        'varios-uno-up' { return @((& $f 'Ethernet 3' 'Disconnected'), (& $f 'Ethernet 4' 'Up')) }
        'estado-raro' { return @((& $f 'Ethernet 3' 'Dormant')) }
        { $_ -in 'conectada', 'adaptador-up' } { return @((& $f 'Ethernet 3' 'Up')) }
        default { return @((& $f 'Ethernet 3' 'Disconnected')) }
    }
}
function Procesos-Elevacion { return @($script:D.Elevacion) }
function Ids-Forti { return @($script:D.Procs) }
function Obtener-ProcesosForti { return @($script:D.Procs | ForEach-Object { [pscustomobject]@{ Id = $_; Padre = 1; CommandLine = 'FortiClient.exe' } }) }
function Pedir-CierreForti { $script:D.Llamadas.Add('cierre-ordenado'); if ($script:D.CierreOrdenado) { $script:D.Procs = @() } }
function Matar-ProcesosForti { $script:D.Llamadas.Add('KILL'); $script:D.Procs = @() }
function Lanzar-ModoConsola($Modo) {
    $script:D.Llamadas.Add("lanzar $($Modo.id)")
    $script:D.Actual = $script:D.Escenario[$Modo.id]
    $script:D.DialogoVisible = ($script:D.Actual -eq 'crash')
    $script:D.Procs = @($(if ($script:D.Actual -ne 'sin-proceso') { 100 }))
    if ($script:D.AlLanzar) { & $script:D.AlLanzar }
}
function Buscar-DialogoErrorForti {
    if ($script:D.DialogoVisible) { return [pscustomobject]@{ Hwnd = 7; Titulo = 'Error'; Clase = '#32770'; Texto = "A JavaScript error occurred in the main process | TypeError: Cannot read properties of null (reading 'TraceLog')" } }
    return $null
}
function Cerrar-DialogoError($Dialogo, [int]$EsperaSeg = 3) { $script:D.Llamadas.Add('cerrar-dialogo'); $script:D.DialogoVisible = $false; return $true }
function Ventana-Consola { if ($script:D.Actual -in 'ok', 'ok-sin-form') { return [IntPtr]5 } return [IntPtr]::Zero }
function Comprobar-Formulario([IntPtr]$h, [int]$Segundos = 12) { return ($script:D.Actual -eq 'ok') }
# 'salio': el proceso desaparece tras dejarse ver una vez.
$script:LlamadasIds = 0
Nuevo-Escenario

# ================================================================ Es-DialogoErrorElectron
Write-Host 'Detección del diálogo de error de Electron'
Probar 'texto «A JavaScript error occurred in the main process»' { Afirmar (Es-DialogoErrorElectron 'Error' '#32770' 'A JavaScript error occurred in the main process') }
Probar 'texto con TraceLog (como el del compañero)' {
    $t = "A JavaScript error occurred in the main process`nUncaught Exception:`nTypeError: Cannot read properties of null (reading 'TraceLog')`n at new Logger (...\app.asar\assets\js\main.js)"
    Afirmar (Es-DialogoErrorElectron 'Error' '#32770' $t)
    Afirmar (Es-DialogoErrorElectron 'Cualquiera' '#32770' "Cannot read properties of null (reading 'TraceLog') at new Logger")
}
Probar 'título con el mensaje y texto vacío' { Afirmar (Es-DialogoErrorElectron 'A JavaScript error occurred in the main process' '#32770' '') }
Probar 'título «Error» en #32770 sin texto legible' { Afirmar (Es-DialogoErrorElectron 'Error' '#32770' '   ') }
Probar 'la consola (Chrome_WidgetWin_1) nunca es el diálogo' {
    Afirmar (-not (Es-DialogoErrorElectron 'FortiClient' 'Chrome_WidgetWin_1' ''))
    Afirmar (-not (Es-DialogoErrorElectron 'Error' 'Chrome_WidgetWin_1' 'A JavaScript error occurred in the main process'))
}
Probar 'otro diálogo con texto propio no cuenta' {
    Afirmar (-not (Es-DialogoErrorElectron 'Error' '#32770' 'No se puede conectar con el servidor'))
    Afirmar (-not (Es-DialogoErrorElectron 'Alerta de seguridad' '#32770' 'El certificado que está viendo no coincide'))
    Afirmar (-not (Es-DialogoErrorElectron 'Error' 'Otra' ''))
}
Probar 'diálogo «Error» cuyo texto UIA son solo botones/título (Aceptar, Copiar, Error…): cuenta como texto ilegible' {
    Afirmar (Es-DialogoErrorElectron 'Error' '#32770' 'Aceptar')
    Afirmar (Es-DialogoErrorElectron 'Error' '#32770' 'Error | OK | Copiar')
    Afirmar (Es-DialogoErrorElectron 'Error' '#32770' ' Cerrar | Copy | Close ')
    Afirmar (-not (Es-DialogoErrorElectron 'Error' '#32770' 'Aceptar | No se puede conectar con el servidor'))
}

# ================================================================ modos
Write-Host 'Modos de arranque'
Probar 'hay cuatro modos A-D: A y B con carpeta, solo A y D con flag, D es el actual (sin carpeta)' {
    $m = @(Obtener-ModosConsola)
    Igual ($m | ForEach-Object { $_.id }) 'A|B|C|D'
    Afirmar ((Obtener-ModoConsola 'A').carpeta -and (Obtener-ModoConsola 'A').flag)
    Afirmar ((Obtener-ModoConsola 'B').carpeta -and -not (Obtener-ModoConsola 'B').flag)
    Igual (Obtener-ModoConsola 'C').metodo 'explorador-cmd'
    Afirmar (-not (Obtener-ModoConsola 'D').carpeta -and (Obtener-ModoConsola 'D').flag)
}
Probar 'Ordenar-ModosConsola: sin modo A-D; con modo guardado primero y el resto en orden' {
    Igual (Ordenar-ModosConsola '') 'A|B|C|D'
    Igual (Ordenar-ModosConsola $null) 'A|B|C|D'
    Igual (Ordenar-ModosConsola 'D') 'D|A|B|C'
    Igual (Ordenar-ModosConsola ' c ') 'C|A|B|D'
    Igual (Ordenar-ModosConsola 'Z') 'A|B|C|D' 'un modo desconocido se ignora'
    Igual (Ordenar-ModosConsola 'auto') 'A|B|C|D'
}
Probar 'Elegir-ModoConsola: solo vale el que abre Y deja el formulario manejable; uno que abre sin formulario no se elige' {
    $r = @([pscustomobject]@{ modo = 'A'; resultado = 'error-electron'; formulario = $null }, [pscustomobject]@{ modo = 'B'; resultado = 'ok'; formulario = $false }, [pscustomobject]@{ modo = 'C'; resultado = 'ok'; formulario = $true })
    Igual (Elegir-ModoConsola $r) 'C'
    Igual (Elegir-ModoConsola @($r[0], $r[1])) '' 'B abre sin formulario: no se puede guardar'
    Igual (Primer-ModoQueAbre @($r[0], $r[1])) 'B'
    Igual (Elegir-ModoConsola @($r[0])) ''
    Igual (Primer-ModoQueAbre @($r[0])) ''
    Igual (Elegir-ModoConsola @()) ''
}
Probar 'Clasificar-ProcesosForti: con flag, sin flag, hijos de Electron y cerrado' {
    $p = @(
        [pscustomobject]@{ CommandLine = '"C:\Fortinet\FortiClient.exe" --force-renderer-accessibility' },
        [pscustomobject]@{ CommandLine = '"C:\Fortinet\FortiClient.exe" --type=gpu-process' })
    $c = Clasificar-ProcesosForti $p
    Afirmar ($c.abierto -and $c.conFlag -and -not $c.sinFlag); Igual $c.principales 1
    $c = Clasificar-ProcesosForti @([pscustomobject]@{ CommandLine = '"C:\Fortinet\FortiClient.exe"' }, [pscustomobject]@{ CommandLine = '"C:\Fortinet\FortiClient.exe" --type=renderer' })
    Afirmar ($c.abierto -and -not $c.conFlag -and $c.sinFlag)
    $c = Clasificar-ProcesosForti @()
    Afirmar (-not $c.abierto -and -not $c.sinFlag)
}
Probar 'Crear-ScriptConsola escribe un .cmd que fija la carpeta de trabajo y lanza el exe sin flag' {
    $exe = Join-Path $Tmp 'Forti Client\FortiClient.exe'
    $cmd = Join-Path $Tmp 'lanzar.cmd'
    Crear-ScriptConsola $cmd $exe
    # El .cmd se escribe en la página de códigos OEM de la consola (así cmd.exe entiende rutas con acentos).
    $t = [IO.File]::ReadAllText($cmd, [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage))
    Afirmar ($t -match [regex]::Escape("cd /d `"$(Split-Path -Parent $exe)`"")); Afirmar ($t -match [regex]::Escape("start `"`" `"$exe`""))
    Afirmar ($t -notmatch 'force-renderer-accessibility')
}
Probar 'Crear-AccesoConsola escribe carpeta de trabajo y flag según el modo (acceso directo real) y D no hereda la carpeta' {
    $exe = Join-Path $Tmp 'Forti Client\FortiClient.exe'
    $lnk = Join-Path $Tmp 'consola.lnk'
    $sh = New-Object -ComObject WScript.Shell
    Crear-AccesoConsola $lnk $exe (Obtener-ModoConsola 'A')
    $s = $sh.CreateShortcut($lnk)
    Igual $s.TargetPath $exe; Igual $s.WorkingDirectory (Split-Path -Parent $exe); Igual $s.Arguments '--force-renderer-accessibility'
    Crear-AccesoConsola $lnk $exe (Obtener-ModoConsola 'B')
    $s = $sh.CreateShortcut($lnk)
    Igual $s.WorkingDirectory (Split-Path -Parent $exe); Igual $s.Arguments ''
    Crear-AccesoConsola $lnk $exe (Obtener-ModoConsola 'D')   # tras A/B: sin carpeta, con flag
    $s = $sh.CreateShortcut($lnk)
    Igual $s.WorkingDirectory ''; Igual $s.Arguments '--force-renderer-accessibility'
}

# ================================================================ regla de seguridad
Write-Host 'Regla de seguridad: nunca cerrar FortiClient con VPN conectada'
Probar 'Vpn-Activa es conservadora: solo «no activa» si todos los adaptadores Fortinet están claramente desconectados y no resuelve el DNS' {
    # Estados con duda o con VPN: activa. Get-Estado real devuelve adaptador $null SIN excepción si no encuentra el adaptador.
    foreach ($v in 'conectada', 'adaptador-up', 'dns', 'error', 'sin-adaptador', 'descripcion-distinta', 'error-adaptadores', 'varios-uno-up', 'estado-raro') {
        Nuevo-Escenario; $D.Vpn = $v
        Afirmar (Vpn-Activa) "con '$v' debería contar como activa"
    }
    foreach ($v in 'desconectada', 'varios-abajo') {
        Nuevo-Escenario; $D.Vpn = $v
        Afirmar (-not (Vpn-Activa)) "con '$v' (todo claramente desconectado) no debería contar como activa"
    }
}
foreach ($vpn in 'conectada', 'adaptador-up', 'error', 'sin-adaptador', 'descripcion-distinta', 'error-adaptadores', 'estado-raro', 'varios-uno-up', 'dns') {
    Probar "Cerrar-FortiClient no toca nada con VPN '$vpn' (ni cierre ordenado ni kill)" {
        Nuevo-Escenario; $D.Vpn = $vpn; $D.Procs = @(1, 2); $D.CierreOrdenado = $false
        $r = Cerrar-FortiClient -EsperaSeg 1 -PermitirKill -IntervaloMs 10
        Afirmar (-not $r.cerrado); Igual $r.metodo 'no-cerrado'
        Igual $D.Llamadas.Count 0 "llamadas: $($D.Llamadas -join ',')"
        Igual $D.Procs.Count 2
    }
}
Probar 'Cerrar-FortiClient: cierre ordenado sin kill' {
    Nuevo-Escenario; $D.Procs = @(1, 2)
    $r = Cerrar-FortiClient -EsperaSeg 2 -PermitirKill -IntervaloMs 10
    Afirmar $r.cerrado; Igual $r.metodo 'cierre-ordenado'; Igual $D.Llamadas 'cierre-ordenado'
}
Probar 'Cerrar-FortiClient: si no estaba abierto no hace nada' {
    Nuevo-Escenario
    $r = Cerrar-FortiClient -EsperaSeg 1 -IntervaloMs 10
    Afirmar $r.cerrado; Igual $D.Llamadas.Count 0
}
Probar 'Cerrar-FortiClient: proceso terco sin -PermitirKill no se mata' {
    Nuevo-Escenario; $D.Procs = @(1); $D.CierreOrdenado = $false
    # el doble no vacía Procs en el cierre ordenado: el proceso sigue vivo
    $r = Cerrar-FortiClient -EsperaSeg 1 -IntervaloMs 10
    Afirmar (-not $r.cerrado); Afirmar ($D.Llamadas -notcontains 'KILL'); Igual $r.metodo 'no-cerrado'
}
Probar 'Cerrar-FortiClient: proceso terco con -PermitirKill solo se mata como último recurso (tras el cierre ordenado)' {
    Nuevo-Escenario; $D.Procs = @(1); $D.CierreOrdenado = $false
    $r = Cerrar-FortiClient -EsperaSeg 1 -PermitirKill -IntervaloMs 10
    Afirmar $r.cerrado; Igual $r.metodo 'kill'; Igual $D.Llamadas 'cierre-ordenado|KILL'
}
Probar 'Cerrar-FortiClient: si la VPN se conecta durante la espera, no se mata' {
    Nuevo-Escenario; $D.Procs = @(1); $D.CierreOrdenado = $false
    # el doble de Pedir-CierreForti conecta la VPN (p. ej. autoconexión de FortiClient) mientras se espera
    function Pedir-CierreForti { $script:D.Llamadas.Add('cierre-ordenado'); $script:D.Vpn = 'conectada' }
    $r = Cerrar-FortiClient -EsperaSeg 1 -PermitirKill -IntervaloMs 10
    Afirmar (-not $r.cerrado); Afirmar ($D.Llamadas -notcontains 'KILL'); Afirmar ($r.motivo -match 'VPN conectada')
}

# ================================================================ prueba de arranque
Write-Host 'Prueba de arranque por modos'
Probar 'con VPN conectada se omite y no se lanza ni cierra nada' {
    foreach ($vpn in 'conectada', 'adaptador-up', 'sin-adaptador', 'descripcion-distinta', 'error-adaptadores', 'error') {
        Nuevo-Escenario; $D.Vpn = $vpn; $D.Escenario = @{ A = 'ok' }
        $r = Probar-ModosConsola -Segundos 1 -IntervaloMs 10
        Afirmar $r.omitida; Igual $r.motivo 'vpn-conectada'; Igual $D.Llamadas.Count 0
    }
}
Probar 'FortiClient abierto sin -CerrarAbierto: omitida, sin tocarlo' {
    Nuevo-Escenario; $D.Procs = @(9); $D.Escenario = @{ A = 'ok' }
    $r = Probar-ModosConsola -Segundos 1 -IntervaloMs 10
    Afirmar $r.omitida; Igual $r.motivo 'forticlient-abierto'; Igual $D.Llamadas.Count 0
}
Probar 'FortiClient abierto con -CerrarAbierto: cierre ordenado y luego la prueba' {
    Nuevo-Escenario; $D.Procs = @(9); $D.Escenario = @{ A = 'ok' }
    $r = Probar-ModosConsola -Segundos 2 -CerrarAbierto -IntervaloMs 10
    Afirmar (-not $r.omitida); Igual $r.modoElegido 'A'
    Igual $D.Llamadas[0] 'cierre-ordenado'; Afirmar ($D.Llamadas -notcontains 'KILL')
}
Probar 'A abre sin error: se para en A (un solo lanzamiento) y cierra de forma ordenada' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'ok'; B = 'ok'; C = 'ok'; D = 'ok' }
    $r = Probar-ModosConsola -Segundos 2 -IntervaloMs 10
    Igual $r.modoElegido 'A'; Igual $r.resultados.Count 1; Igual $r.resultados[0].resultado 'ok'; Afirmar ($r.resultados[0].formulario)
    Igual $D.Llamadas 'lanzar A|cierre-ordenado'
}
Probar 'A y B fallan con el diálogo de Electron, C abre: elige C, cierra el diálogo y no mata nada' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'crash'; B = 'crash'; C = 'ok'; D = 'ok' }
    $r = Probar-ModosConsola -Segundos 2 -IntervaloMs 10
    Igual $r.modoElegido 'C'
    Igual ($r.resultados | ForEach-Object { "$($_.modo)=$($_.resultado)" }) 'A=error-electron|B=error-electron|C=ok'
    Afirmar ($r.resultados[0].detalle -match 'TraceLog')
    Igual ($D.Llamadas -join ',') 'lanzar A,cerrar-dialogo,cierre-ordenado,lanzar B,cerrar-dialogo,cierre-ordenado,lanzar C,cierre-ordenado'
    Afirmar ($D.Llamadas -notcontains 'KILL')
}
Probar 'ningún modo abre: modoElegido vacío y se han probado los cuatro' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'crash'; B = 'crash'; C = 'crash'; D = 'crash' }
    $r = Probar-ModosConsola -Segundos 2 -IntervaloMs 10
    Afirmar (-not $r.omitida); Afirmar (-not $r.modoElegido); Igual $r.resultados.Count 4
}
Probar 'abre pero sin formulario manejable: sigue probando; si ninguno lo deja manejable no hay modo elegido (solo modoSinFormulario) y no es una interrupción' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'crash'; B = 'ok-sin-form'; C = 'ok-sin-form'; D = 'ok' }
    $r = Probar-ModosConsola -Segundos 2 -IntervaloMs 10
    Igual $r.modoElegido 'D'; Igual $r.resultados.Count 4
    Nuevo-Escenario; $D.Escenario = @{ A = 'crash'; B = 'ok-sin-form'; C = 'crash'; D = 'crash' }
    $r = Probar-ModosConsola -Segundos 2 -IntervaloMs 10
    Afirmar (-not $r.modoElegido) 'un modo sin formulario manejable no debe elegirse'
    Igual $r.modoSinFormulario 'B'; Afirmar (-not $r.omitida) 'se probaron todos: no es una prueba omitida'; Igual $r.resultados.Count 4
}
Probar '-Todos prueba los cuatro aunque el primero funcione; -Solo limita' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'ok'; B = 'ok'; C = 'ok'; D = 'ok' }
    $r = Probar-ModosConsola -Segundos 2 -Todos -IntervaloMs 10
    Igual $r.resultados.Count 4; Igual $r.modoElegido 'A'
    Nuevo-Escenario; $D.Escenario = @{ A = 'ok'; B = 'ok'; C = 'ok'; D = 'ok' }
    $r = Probar-ModosConsola -Segundos 2 -Solo 'C', 'd' -IntervaloMs 10
    Igual ($r.resultados | ForEach-Object { $_.modo }) 'C'; Igual $r.modoElegido 'C'
}
Probar 'si FortiClient sale sin ventana (proceso que desaparece) se anota «salio»' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'salio'; B = 'ok' }
    $script:LlamadasIds = 0
    # Ids-Forti: antes de lanzar no hay procesos; después se ve una vez y desaparece (sale sin abrir ventana)
    function Ids-Forti { if ($script:D.Llamadas -notcontains 'lanzar A') { return @() }; $script:LlamadasIds++; if ($script:LlamadasIds -le 1) { return @(100) } return @() }
    $r = Probar-ModosConsola -Segundos 2 -IntervaloMs 10 -Solo 'A'
    Igual $r.resultados[0].resultado 'salio'
}
Probar 'interrupción por VPN conectada durante la prueba: omitida con su motivo (no «todos fallan») y no se lanzan más modos' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'crash'; B = 'ok' }
    # la VPN se conecta justo después de cerrar FortiClient tras el modo A (p. ej. autoconexión)
    function Pedir-CierreForti { $script:D.Llamadas.Add('cierre-ordenado'); $script:D.Procs = @(); $script:D.Vpn = 'conectada' }
    $r = Probar-ModosConsola -Segundos 2 -IntervaloMs 10
    Afirmar $r.omitida; Igual $r.motivo 'vpn-conectada-durante-la-prueba'; Afirmar (-not $r.modoElegido)
    Afirmar ($D.Llamadas -notcontains 'lanzar B'); Afirmar ($D.Llamadas -notcontains 'KILL')
}
Probar 'interrupción porque FortiClient no se cierra: omitida con su motivo' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'crash'; B = 'ok' }; $D.CierreOrdenado = $false
    # el proceso no se va con el cierre ordenado y no se le puede matar (VPN conectada al cerrar)
    function Matar-ProcesosForti { $script:D.Llamadas.Add('KILL-IMPOSIBLE'); $script:D.Vpn = 'conectada' }
    $r = Probar-ModosConsola -Segundos 2 -IntervaloMs 10
    Afirmar $r.omitida 'debería ser omitida'; Igual $r.motivo 'forticlient-no-cerrado'
}
Probar 'UAC pendiente (FortiElevate/consent vivos): se espera hasta el tope, no se da el modo por fallido y no se prueba otro' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'sin-proceso'; B = 'ok' }; $D.Elevacion = @('consent')
    $r = Probar-ModosConsola -Segundos 1 -IntervaloMs 10
    Afirmar $r.omitida; Igual $r.motivo 'uac-pendiente'; Igual $r.resultados[0].resultado 'uac-pendiente'
    Igual ($D.Llamadas -join ',') 'lanzar A' 'no debe cerrar FortiClient ni probar B con el UAC pendiente'
}
Probar 'UAC que se contesta durante la espera: la consola aparece y el modo vale' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'ok' }
    $t0 = Get-Date
    # El UAC se contesta a los 1,3 s (pasado el tiempo de espera de 1 s) y entonces aparece la consola
    function Procesos-Elevacion { if (((Get-Date) - $t0).TotalSeconds -lt 1.3) { return @('FortiElevate') } return @() }
    function Ventana-Consola { if (((Get-Date) - $t0).TotalSeconds -ge 1.3 -and $script:D.Actual -eq 'ok') { return [IntPtr]5 } return [IntPtr]::Zero }
    $r = Probar-ModosConsola -Segundos 1 -IntervaloMs 10
    Igual $r.modoElegido 'A'; Afirmar (-not $r.omitida); Igual $r.resultados[0].resultado 'ok'
}
Probar 'tiempo de espera completo antes de dar sin-proceso/salio por fallido; y una última comprobación de la ventana' {
    # Explorador lento: la ventana aparece justo al final de la espera, no se debe haber dado el modo por fallido antes
    Nuevo-Escenario; $D.Escenario = @{ A = 'ok'; B = 'ok' }
    $t0 = Get-Date
    function Ventana-Consola { if (((Get-Date) - $t0).TotalSeconds -ge 1.5 -and $script:D.Actual -eq 'ok') { return [IntPtr]5 } return [IntPtr]::Zero }
    $r = Abrir-ConsolaPorModos -ModoPreferido '' -Segundos 3 -IntervaloMs 20
    Igual $r.resultado 'ok'; Igual $r.modo 'A'; Igual $r.fallos.Count 0 'no debe haber hecho fallback por lentitud'
}

# ================================================================ Abrir-ConsolaPorModos (uso normal con fallback)
Write-Host 'Abrir la consola con fallback entre modos'
Probar 'modo guardado D va primero; si falla con el diálogo se pasa al siguiente y se anota cuál falló' {
    Nuevo-Escenario; $D.Escenario = @{ D = 'crash'; A = 'ok' }
    $r = Abrir-ConsolaPorModos -ModoPreferido 'D' -Segundos 2 -IntervaloMs 10
    Igual $r.resultado 'ok'; Igual $r.modo 'A'; Igual ($r.fallos | ForEach-Object { $_.modo }) 'D'; Igual $r.fallos[0].resultado 'error-electron'
    Igual ($D.Llamadas -join ',') 'lanzar D,cerrar-dialogo,cierre-ordenado,lanzar A'
    Afirmar (($D.Logs -join "`n") -match 'Modo D falló'); Afirmar ($D.Llamadas -notcontains 'KILL')
}
Probar 'sin modo guardado empieza por A; si funciona no hay fallos' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'ok' }
    $r = Abrir-ConsolaPorModos -ModoPreferido '' -Segundos 2 -IntervaloMs 10
    Igual $r.modo 'A'; Igual $r.fallos.Count 0; Igual ($D.Llamadas -join ',') 'lanzar A'
}
Probar 'todos fallan: resultado todos-fallan con los cuatro fallos' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'crash'; B = 'crash'; C = 'crash'; D = 'crash' }
    $r = Abrir-ConsolaPorModos -ModoPreferido '' -Segundos 2 -IntervaloMs 10
    Igual $r.resultado 'todos-fallan'; Igual $r.fallos.Count 4; Igual ($r.fallos | ForEach-Object { $_.modo }) 'A|B|C|D'
}
Probar 'sin ventana ni diálogo (p. ej. UAC sin aceptar) no se reintenta con otro modo' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'nada'; B = 'ok' }
    $r = Abrir-ConsolaPorModos -ModoPreferido '' -Segundos 1 -IntervaloMs 10
    Igual $r.resultado 'sin-ventana'; Igual ($D.Llamadas -join ',') 'lanzar A'
}
Probar 'un modo que no lanza ningún proceso (sin-proceso) no corta la cadena: se pasa al siguiente (incluido D) y se cuentan los segundos perdidos' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'sin-proceso'; B = 'sin-proceso'; C = 'sin-proceso'; D = 'ok' }
    $r = Abrir-ConsolaPorModos -ModoPreferido '' -Segundos 1 -IntervaloMs 10
    Igual $r.resultado 'ok'; Igual $r.modo 'D'; Igual ($r.fallos | ForEach-Object { "$($_.modo)=$($_.resultado)" }) 'A=sin-proceso|B=sin-proceso|C=sin-proceso'
    Igual ($D.Llamadas -join ',') 'lanzar A,lanzar B,lanzar C,lanzar D'
    Afirmar ($r.perdidos -ge 2) "perdidos: $($r.perdidos)"
}
Probar 'Probar-ModosConsola anota sin-proceso y sigue con el modo siguiente' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'sin-proceso'; B = 'ok' }
    $r = Probar-ModosConsola -Segundos 1 -IntervaloMs 10
    Igual $r.resultados[0].resultado 'sin-proceso'; Igual $r.modoElegido 'B'
}
Probar 'con UAC pendiente no hay fallback: sin-ventana (uac-pendiente) y no se prueba otro modo' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'sin-proceso'; B = 'ok' }; $D.Elevacion = @('FortiElevate')
    $r = Abrir-ConsolaPorModos -ModoPreferido '' -Segundos 1 -IntervaloMs 10
    Igual $r.resultado 'sin-ventana'; Igual $r.motivo 'uac-pendiente'; Igual ($D.Llamadas -join ',') 'lanzar A'
}
Probar 'si tras un modo fallido no se puede limpiar FortiClient: resultado interrumpida (no todos-fallan), sin kill con VPN' {
    Nuevo-Escenario; $D.Escenario = @{ A = 'crash'; B = 'ok' }; $D.Vpn = 'conectada'
    $r = Abrir-ConsolaPorModos -ModoPreferido '' -Segundos 2 -IntervaloMs 10
    Igual $r.resultado 'interrumpida'; Igual $r.motivo 'forticlient-no-cerrado'
    Afirmar ($D.Llamadas -notcontains 'KILL'); Afirmar ($D.Llamadas -notcontains 'lanzar B'); Igual $r.fallos.Count 1
}
# ================================================================ config.json
Write-Host 'config.json'
Probar 'Guardar-ModoConsola conserva el resto de claves (anidadas y listas) y crea/actualiza consola.modo' {
    $f = Join-Path $Tmp 'cfg1.json'
    $orig = '{"tunel":"VPN X","esperaSeg":180,"credenciales":["FortiClient","vpn-forti:{tunel}"],"certificado":{"huellas":["AB12"]},"pin":{"activado":true,"filtro":"notification\\.fortinet\\.net|AuthCode","borrarLeidos":false}}'
    [IO.File]::WriteAllText($f, $orig, (New-Object Text.UTF8Encoding($false)))
    Guardar-ModoConsola $f 'B'
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    Igual $j.consola.modo 'B'; Igual $j.tunel 'VPN X'; Igual $j.esperaSeg 180
    Igual @($j.credenciales).Count 2; Igual $j.credenciales[1] 'vpn-forti:{tunel}'
    Igual @($j.certificado.huellas).Count 1; Igual $j.pin.filtro 'notification\.fortinet\.net|AuthCode'; Afirmar ($j.pin.activado -eq $true)
    Guardar-ModoConsola $f 'D'
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    Igual $j.consola.modo 'D'
    $j.consola | Add-Member -NotePropertyName esperaSeg -NotePropertyValue 55; [IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Guardar-ModoConsola $f 'A'
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    Igual $j.consola.modo 'A'; Igual $j.consola.esperaSeg 55 'no debe perder otras claves de consola'
}
Probar 'Guardar-ModoConsola crea el fichero si no existe y no deja BOM' {
    $f = Join-Path $Tmp 'sub\cfg2.json'
    Guardar-ModoConsola $f 'C'
    $b = [IO.File]::ReadAllBytes($f)
    Afirmar ($b[0] -ne 0xEF); Igual (Get-Content $f -Raw | ConvertFrom-Json).consola.modo 'C'
}
Probar 'config.ejemplo.json es JSON válido y trae consola.modo vacío' {
    $j = Get-Content (Join-Path $Raiz 'config.ejemplo.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Igual $j.consola.modo ''; Afirmar ($j.consola.esperaSeg -gt 0 -and $j.consola.pruebaSeg -gt 0)
}

# ================================================================ Abrir-Consola de vpn.ps1 (función real, con dobles)
Write-Host 'Abrir-Consola (de vpn.ps1) con dobles'
$cs = Join-Path $Raiz 'lib\VpnForti.cs'
$astVpn = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Raiz 'vpn.ps1'), [ref]$null, [ref]$null)
$fnAbrir = $astVpn.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Abrir-Consola' }, $true) | Select-Object -First 1
$tipoCargado = $false
try { if (-not ('VpnForti.Ui' -as [type])) { Add-Type -Path $cs -ReferencedAssemblies Accessibility }; $tipoCargado = $true } catch { }
if (-not $tipoCargado) { Saltar 'Abrir-Consola' 'no se ha podido compilar lib\VpnForti.cs' }
else {
    Invoke-Expression $fnAbrir.Extent.Text
    $fnPrueba = $astVpn.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ejecutar-PruebaArranque' }, $true) | Select-Object -First 1
    Invoke-Expression $fnPrueba.Extent.Text
    function Cargar-Ayudante { }
    function Asegurar-Servicio { $script:D.Llamadas.Add('asegurar-servicio') }
    function Estado-Servicio { 'Running' }
    function Salir([int]$Codigo, $Datos) { throw "SALIR $Codigo" }
    function Guardar-ModoConsola([string]$Fichero, [string]$Modo) { $script:D.Guardado = $Modo }
    $FicheroCfg = $script:RutaCfgDoble
    function Buscar-Consola([int]$s) { if ($script:D.ConsolaAbierta) { return [IntPtr]5 } return [IntPtr]::Zero }
    function Esperar-Pantalla([IntPtr]$h, [int]$s) { return [pscustomobject]@{ Desconectar = $null; Conectar = $(if ($script:D.FormularioOk) { 1 } else { $null }); Clave = $(if ($script:D.FormularioOk) { 1 } else { $null }) } }
    function Abrir-ConsolaPorModos { param([string]$ModoPreferido, [int]$Segundos) $script:D.Llamadas.Add("modos($ModoPreferido)"); return $script:D.ResultadoModos }

    Probar 'consola ya abierta con formulario manejable: se usa tal cual, sin cerrar ni lanzar' {
        Nuevo-Escenario; $D.ConsolaAbierta = $true; $D.FormularioOk = $true; $D.Procs = @(5)
        $h = Abrir-Consola
        Igual $h ([IntPtr]5); Igual $D.Llamadas.Count 0
    }
    Probar 'consola abierta sin flag e inmanejable con VPN conectada: no se cierra (se sigue con ella)' {
        Nuevo-Escenario; $D.ConsolaAbierta = $true; $D.FormularioOk = $false; $D.Procs = @(5); $D.Vpn = 'conectada'
        function Obtener-ProcesosForti { @([pscustomobject]@{ Id = 5; Padre = 1; CommandLine = '"FortiClient.exe"' }) }
        $h = Abrir-Consola
        Igual $h ([IntPtr]5); Afirmar ($D.Llamadas -notcontains 'cierre-ordenado'); Afirmar ($D.Llamadas -notcontains 'KILL')
    }
    Probar 'todos los modos fallan: sale con el código 8 y lista los fallos' {
        Nuevo-Escenario; $D.ConsolaAbierta = $false
        $D.ResultadoModos = [pscustomobject]@{ resultado = 'todos-fallan'; h = [IntPtr]::Zero; modo = $null; fallos = @([pscustomobject]@{ modo = 'A' }, [pscustomobject]@{ modo = 'D' }); segundos = 1 }
        $cod = $null
        try { [void](Abrir-Consola) } catch { $cod = $_.Exception.Message }
        Igual $cod 'SALIR 8'
    }
    Probar 'sin ventana ni error: sale con el código 4 como antes' {
        Nuevo-Escenario; $D.ConsolaAbierta = $false
        $D.ResultadoModos = [pscustomobject]@{ resultado = 'sin-ventana'; h = [IntPtr]::Zero; modo = 'A'; fallos = @([pscustomobject]@{ modo = 'A' }); segundos = 1 }
        $cod = $null
        try { [void](Abrir-Consola) } catch { $cod = $_.Exception.Message }
        Igual $cod 'SALIR 4'
    }
    Probar 'si el modo guardado fallaba y otro funciona, NO se guarda nada: el fallback vale solo para esta ejecución' {
        Nuevo-Escenario; $D.ConsolaAbierta = $false
        $Cfg.consola.modo = 'D'
        $D.ResultadoModos = [pscustomobject]@{ resultado = 'ok'; h = [IntPtr]5; modo = 'A'; fallos = @([pscustomobject]@{ modo = 'D' }); segundos = 1; perdidos = 7 }
        $script:SegundosPerdidos = 0
        $h = Abrir-Consola
        Igual $h ([IntPtr]5); Igual $D.Guardado $null 'asegurar/conectar no deben escribir consola.modo'; Igual $Cfg.consola.modo 'D'
        Igual ($D.Llamadas -join ',') 'asegurar-servicio,modos(D)'
        Igual $script:SegundosPerdidos 7 'los segundos perdidos se anotan para no encoger esperaSeg'
        $Cfg.consola.modo = ''
    }
    Probar 'cadena interrumpida (no se pudo limpiar FortiClient): sale con 4, nunca con 8' {
        Nuevo-Escenario; $D.ConsolaAbierta = $false
        $D.ResultadoModos = [pscustomobject]@{ resultado = 'interrumpida'; h = [IntPtr]::Zero; modo = $null; fallos = @([pscustomobject]@{ modo = 'A' }); segundos = 1; perdidos = 1; motivo = 'forticlient-no-cerrado' }
        $cod = $null
        try { [void](Abrir-Consola) } catch { $cod = $_.Exception.Message }
        Igual $cod 'SALIR 4'
    }    Probar 'si el modo guardado funciona a la primera no se reescribe config.json' {
        Nuevo-Escenario; $D.ConsolaAbierta = $false; $Cfg.consola.modo = 'B'
        $D.ResultadoModos = [pscustomobject]@{ resultado = 'ok'; h = [IntPtr]5; modo = 'B'; fallos = @(); segundos = 1 }
        [void](Abrir-Consola)
        Igual $D.Guardado $null; $Cfg.consola.modo = ''
    }

    # ---- probar-arranque (Ejecutar-PruebaArranque de vpn.ps1) con Probar-ModosConsola simulado
    $script:DirDatosPrueba = Join-Path $Tmp 'datos-prueba'; New-Item -ItemType Directory -Force $script:DirDatosPrueba | Out-Null
    $DirDatos = $script:DirDatosPrueba; $ServicioForti = 'FA_Scheduler'; $Modo = $null; $Todos = $false; $EsperaSeg = 0
    function Tomar-MutexConexion { if ($script:D.MutexOcupado) { return $null }; return (New-Object System.Threading.Mutex($true)) }
    function Probar-ModosConsola { param([string]$ModoPreferido, [string[]]$Solo, [int]$Segundos, [switch]$CerrarAbierto, [switch]$Todos) $script:D.Llamadas.Add('probar-modos'); return $script:D.ResultadoPrueba }
    function Prueba-Falsa($elegido, $sinForm, $omitida, $motivo) { [pscustomobject]@{ omitida = $omitida; motivo = $motivo; modoElegido = $elegido; modoSinFormulario = $sinForm; resultados = @([pscustomobject]@{ modo = 'A'; nombre = 'x'; resultado = 'ok'; formulario = $true; detalle = "ruta C:\Users\$env:USERNAME\x"; cierre = 'cierre-ordenado' }) } }
    Probar 'probar-arranque: modo con consola abierta y formulario manejable -> código 0 y se guarda con -Guardar' {
        Nuevo-Escenario; $Cfg.fortiClientExe = $env:ComSpec; $Cfg.consola.modo = ''
        $D.ResultadoPrueba = Prueba-Falsa 'A' $null $false $null
        $r = Ejecutar-PruebaArranque -Guardar
        Igual $r.Codigo 0; Igual $D.Guardado 'A'; Afirmar ($r.Resultado.guardado -eq $true)
        $arr = Get-Content (Join-Path $DirDatos 'arranque.json') -Raw -Encoding UTF8
        Afirmar ($arr -notmatch [regex]::Escape($env:USERNAME)) 'arranque.json debe llevar el usuario enmascarado'
    }
    Probar 'probar-arranque: un modo que abre SIN formulario manejable no se guarda y da 8 (todos probados, ninguno sirve)' {
        Nuevo-Escenario; $Cfg.fortiClientExe = $env:ComSpec; $Cfg.consola.modo = ''
        $D.ResultadoPrueba = Prueba-Falsa $null 'B' $false $null
        $r = Ejecutar-PruebaArranque -Guardar
        Igual $r.Codigo 8; Igual $D.Guardado $null; Afirmar ($r.Resultado.mensaje -match 'formulario')
    }
    Probar 'probar-arranque: interrumpida/omitida (vpn, UAC, no se cierra, otra conexión) da SIEMPRE 9, nunca 8' {
        foreach ($mot in 'vpn-conectada', 'vpn-conectada-durante-la-prueba', 'forticlient-no-cerrado', 'uac-pendiente', 'forticlient-abierto') {
            Nuevo-Escenario; $Cfg.fortiClientExe = $env:ComSpec
            $D.ResultadoPrueba = Prueba-Falsa $null $null $true $mot
            $r = Ejecutar-PruebaArranque -Guardar
            Igual $r.Codigo 9 "motivo $mot"; Igual $r.Resultado.motivo $mot; Igual $D.Guardado $null
        }
    }
    Probar 'probar-arranque: todos los modos pedidos probados y fallidos da 8' {
        Nuevo-Escenario; $Cfg.fortiClientExe = $env:ComSpec
        $D.ResultadoPrueba = Prueba-Falsa $null $null $false $null
        $r = Ejecutar-PruebaArranque -Guardar
        Igual $r.Codigo 8; Afirmar ($r.Resultado.mensaje -match 'diagnostico\.txt')
    }
    Probar 'probar-arranque: con la conexión en curso (mutex ocupado) se omite con «conexion-en-curso» sin tocar FortiClient' {
        Nuevo-Escenario; $Cfg.fortiClientExe = $env:ComSpec; $D.MutexOcupado = $true
        $D.ResultadoPrueba = Prueba-Falsa 'A' $null $false $null
        $r = Ejecutar-PruebaArranque -Guardar
        Igual $r.Codigo 9; Igual $r.Resultado.motivo 'conexion-en-curso'; Afirmar ($D.Llamadas -notcontains 'probar-modos'); Igual $D.Guardado $null
    }
    Probar 'probar-arranque: una prueba parcial (-Modo) no pisa un consola.modo ya guardado; sin modo guardado sí guarda' {
        Nuevo-Escenario; $Cfg.fortiClientExe = $env:ComSpec; $Cfg.consola.modo = 'D'
        $D.ResultadoPrueba = Prueba-Falsa 'B' $null $false $null
        $script:Modo = 'B'
        try {
            $r = Ejecutar-PruebaArranque -Guardar
            Igual $r.Codigo 0; Igual $D.Guardado $null; Afirmar ($r.Resultado.mensaje -match 'prueba parcial'); Afirmar ($r.Resultado.guardado -eq $false)
            $Cfg.consola.modo = ''
            $r = Ejecutar-PruebaArranque -Guardar
            Igual $D.Guardado 'B'
        } finally { $script:Modo = $null; $Cfg.consola.modo = '' }
    }
    Probar 'probar-arranque: un fallo/éxito sin -Guardar no escribe config.json' {
        Nuevo-Escenario; $Cfg.fortiClientExe = $env:ComSpec; $Cfg.consola.modo = ''
        $D.ResultadoPrueba = Prueba-Falsa 'A' $null $false $null
        $r = Ejecutar-PruebaArranque
        Igual $r.Codigo 0; Igual $D.Guardado $null
    }
}

# ================================================================ diagnóstico: funciones puras
Write-Host 'Diagnóstico'
Probar 'Enmascarar-Texto: usuario (largo y 8.3), equipo, correo, SID y PIN' {
    $t = 'C:\Users\Marta.Lopez\AppData C:\Users\MARTAL~1\Temp AzureAD\Marta.Lopez correo marta.lopez@portic.net PC-OFICINA-07 S-1-12-1-2647612622-1117520885-996764064-1241339214 AuthCode: 123456 token code is 654321'
    $m = Enmascarar-Texto $t @('Marta.Lopez', 'MARTAL~1') @('PC-OFICINA-07')
    foreach ($x in 'Marta', 'Lopez', 'MARTAL', 'portic.net', 'PC-OFICINA', '2647612622', '123456', '654321') { Afirmar ($m -notmatch [regex]::Escape($x)) "queda '$x' en: $m" }
    Afirmar ($m -match '<usuario>' -and $m -match '<correo>' -and $m -match '<sid>' -and $m -match '<pin>' -and $m -match '<equipo>')
}
Probar 'Enmascarar-Texto: no estropea el texto sin datos privados y no enmascara nombres de menos de 3 letras' {
    $t = 'servicio FA_Scheduler en marcha; node v24.19.0 en C:\Program Files\nodejs'
    Igual (Enmascarar-Texto $t @('ab', '') @('')) $t
    Igual (Enmascarar-Texto '' @('Marta') @()) ''
}
Probar 'Enmascarar-Texto: cuentas «Admin», «Administrador», «Usuario» y DOMINIO\ana solo como palabra completa y sin re-enmascarar las etiquetas' {
    $n = @('Admin', 'Administrador', 'Usuario', 'ana')
    $t = 'Cuentas: Admin y Administrador; BUILTIN\Administradores; DOMINIO\ana; DOMINIO\Usuario; la banana y Anabel; C:\Users\ana\AppData; usuario.admin'
    $m = Enmascarar-Texto $t $n @()
    Afirmar ($m -notmatch '\bAdmin\b' -and $m -notmatch '\bAdministrador\b' -and $m -notmatch '\\ana\b' -and $m -notmatch '\\Usuario\b') "quedan cuentas: $m"
    Afirmar ($m -match 'BUILTIN\\Administradores') 'no debe tocar «Administradores»'
    Afirmar ($m -match 'banana' -and $m -match 'Anabel') 'no debe tocar palabras que solo contienen «ana»'
    Afirmar ($m -notmatch '<<' -and $m -notmatch '<usuario>>' ) "etiqueta re-enmascarada: $m"
    Afirmar ($m -match 'DOMINIO\\<usuario>') "DOMINIO\usuario: $m"
    # una cuenta llamada como las propias etiquetas no estropea las ya puestas
    $m2 = Enmascarar-Texto 'correo marta@x.es, usuario Marta, equipo PC1' @('Marta', 'usuario', 'correo', 'equipo') @('PC1')
    Afirmar ($m2 -notmatch 'marta@x') "queda el correo: $m2"
    Afirmar ($m2 -match '<correo>' -and $m2 -match '<equipo>') "etiquetas estropeadas: $m2"
}
Probar 'Enmascarar-Texto: nombres de 2 letras solo como palabra completa; el usuario del patrón «(usuario X)» del log y apóstrofos' {
    $m = Enmascarar-Texto 'ab y abc; cab; (ab)' @('ab') @()
    Igual $m '<usuario> y abc; cab; (<usuario>)'
    $log = "2026-11-16 10:00:00 [conectar] Credencial: 'vpn-forti:T' (usuario o.brien-sin-registrar). Rellenando el usuario."
    $m = Enmascarar-Texto $log @() @()
    Afirmar ($m -notmatch 'brien') "sale el usuario del log: $m"; Afirmar ($m -match 'Rellenando el usuario\.') 'no debe tocar el resto del log'
    $m = Enmascarar-Texto "cuenta O'Brien en C:\Users\O'Brien\x" @("O'Brien") @()
    Afirmar ($m -notmatch 'Brien') "apóstrofo: $m"
}
Probar 'Enmascarar-Objeto: enmascara VALORES (también con apóstrofo, que ConvertTo-Json escaparía), no toca claves ni ids y conserva la forma' {
    $n = [pscustomobject]@{ usuarios = @("O'Brien", 'Usuario'); equipos = @('PC-OFI') }
    $o = [ordered]@{ comprobaciones = @([pscustomobject]@{ id = 'usuario.admin'; estado = 'ok'; detalle = "cuenta O'Brien en PC-OFI"; datos = [ordered]@{ usuario = 'Usuario'; lista = @('Usuario', 'otro'); n = 3; b = $true } }); log = @("x O'Brien"); vacio = @(); nulo = $null }
    $m = Enmascarar-Objeto $o $n
    $c = $m.comprobaciones[0]
    Igual $c.id 'usuario.admin' 'el id no se enmascara'; Igual $c.estado 'ok'
    Afirmar ($c.detalle -notmatch 'Brien' -and $c.detalle -notmatch 'PC-OFI') $c.detalle
    Igual $c.datos.usuario '<usuario>' 'el valor sí; la CLAVE «usuario» sigue ahí'
    Igual $c.datos.lista '<usuario>|otro'; Igual $c.datos.n 3; Afirmar ($c.datos.b -eq $true)
    Igual $m.log '<usuario>'.Replace('<usuario>', 'x <usuario>'); Igual @($m.vacio).Count 0; Afirmar ($null -eq $m.nulo)
    $j = $m | ConvertTo-Json -Depth 6
    Afirmar ($j -notmatch 'Brien' -and $j -notmatch 'u0027') "JSON: $j"
}
Probar 'Enmascarar-Diagnostico mantiene la forma que usan el informe y Salir (propiedades, arrays de una sola fila)' {
    $n = [pscustomobject]@{ usuarios = @('Marta'); equipos = @() }
    $c = @((Nuevo-Chequeo 'a' 'ok' 'cuenta Marta'))
    $d = [ordered]@{ version = '1.3.0'; fecha = 'f'; resumen = (Resumir-Chequeos $c); comprobaciones = $c; arranque = $null; log = @('Marta ok') }
    $m = Enmascarar-Diagnostico $d $n
    Afirmar ($m.PSObject.Properties.Name -contains 'comprobaciones') 'propiedades'
    Igual @($m.comprobaciones).Count 1; Igual $m.comprobaciones[0].detalle 'cuenta <usuario>'; Igual @($m.log).Count 1
    Afirmar ((Formatear-InformeDiagnostico $m) -match 'cuenta <usuario>')
}
Probar 'Obtener-NombresPrivados incluye el usuario actual y el nombre de la carpeta del perfil' {
    $n = Obtener-NombresPrivados @('cuentaExtra')
    Afirmar ($n.usuarios -contains $env:USERNAME); Afirmar ($n.usuarios -contains (Split-Path -Leaf $env:USERPROFILE)); Afirmar ($n.usuarios -contains 'cuentaExtra')
}
Probar 'Info-Ruta: OneDrive, caracteres no ASCII y 8.3' {
    $a = Info-Ruta 'D:\OneDrive - EMPRESA\Proyectos\vpn-forti'; Afirmar ($a.onedrive -and -not $a.noAscii)
    $b = Info-Ruta "C:\Users\Ana\Herramientas\vpn-forti-$([char]0x00F3)"; Afirmar (-not $b.onedrive -and $b.noAscii)
    $c = Info-Ruta 'C:\Users\ANA~1\AppData\Local\Temp'; Afirmar ($c.corto83 -and -not $c.noAscii)
}
Probar 'Evaluar-VersionForti: 7.0 ok, otra versión aviso, vacía error' {
    Igual (Evaluar-VersionForti '7.0.14.585').estado 'ok'; Afirmar (Evaluar-VersionForti '7.0.14.585').es70
    Igual (Evaluar-VersionForti '7.2.4.0860').estado 'aviso'; Igual (Evaluar-VersionForti '7.4.0').estado 'aviso'
    Igual (Evaluar-VersionForti '').estado 'error'
}
Probar 'Es-AdministradorLocal: el grupo cuenta aunque sea «solo para denegar» (el SID está en el token)' {
    Afirmar (Es-AdministradorLocal @('S-1-1-0', 'S-1-5-32-544', 'S-1-5-32-545'))
    Afirmar (-not (Es-AdministradorLocal @('S-1-1-0', 'S-1-5-32-545')))
    Afirmar (-not (Es-AdministradorLocal @()))
}
Probar 'Resumir-Chequeos y Formatear-InformeDiagnostico' {
    $c = @((Nuevo-Chequeo 'a' 'ok' 'bien'), (Nuevo-Chequeo 'b' 'aviso' 'ojo'), (Nuevo-Chequeo 'c' 'error' 'mal'), (Nuevo-Chequeo 'd' 'ok' 'bien'))
    $r = Resumir-Chequeos $c
    Igual $r.ok 2; Igual $r.avisos 1; Igual $r.errores 1
    $d = [pscustomobject]@{ version = '1.3.0'; fecha = '2026-11-16 10:00:00'; resumen = $r; comprobaciones = $c; arranque = $null; log = @('linea 1', 'linea 2') }
    $t = Formatear-InformeDiagnostico $d
    Afirmar ($t -match '\[AVISO\] b' -and $t -match '\[ERROR\] c' -and $t -match 'linea 2' -and $t -match '2 correctas, 1 avisos, 1 errores')
}

# ================================================================ diagnosticar y probar-arranque reales (solo lectura / sin tocar FortiClient)
Write-Host 'vpn.ps1 diagnosticar (real, solo lectura)'
function Ejecutar-Hijo([string[]]$Argumentos, [hashtable]$Entorno = @{}, [int]$EsperaSeg = 120) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Raiz 'vpn.ps1')`"") + $Argumentos) -join ' '
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($k in $Entorno.Keys) { $psi.EnvironmentVariables[$k] = $Entorno[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($EsperaSeg * 1000)) { try { $p.Kill() } catch { }; throw "el proceso hijo no ha terminado en $EsperaSeg s" }
    $p.WaitForExit()
    return [pscustomobject]@{ codigo = $p.ExitCode; salida = $so.Result; error = $se.Result }
}
$datosHijo = Join-Path $Tmp 'localappdata'
New-Item -ItemType Directory -Force $datosHijo | Out-Null
$cfgHijo = Join-Path $Tmp 'cfg-hijo.json'
Copy-Item (Join-Path $Raiz 'config.ejemplo.json') $cfgHijo
# vpn.log sembrado con datos privados: el usuario de Windows, el usuario de la credencial (que puede no coincidir),
# un correo, un PIN, un SID y el nombre del equipo. Nada de eso puede salir en la salida ni en los ficheros.
$credUsuarioReal = $null
try {
    if (-not ('VpnForti.Cred' -as [type])) { Add-Type -Path (Join-Path $Raiz 'lib\VpnForti.cs') -ReferencedAssemblies Accessibility }
    $objetivos = @('FortiClient') + @(try { Get-ChildItem 'HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels' -ErrorAction Stop | ForEach-Object { "vpn-forti:$($_.PSChildName)" } } catch { })
    foreach ($o in $objetivos) { if (-not $credUsuarioReal) { $credUsuarioReal = [VpnForti.Cred]::Usuario($o, 1) } }
} catch { }
$usuarioSembrado = if ($credUsuarioReal) { $credUsuarioReal } else { 'cuenta-sembrada-vpn' }
$correoSembrado = 'persona.prueba@ejemplo-vpn.test'
$sidSembrado = 'S-1-12-1-1111111111-2222222222-3333333333-4444444444'
New-Item -ItemType Directory -Force (Join-Path $datosHijo 'vpn-forti') | Out-Null
$logSembrado = @(
    "2026-11-16 10:00:00 [conectar] Credencial: 'vpn-forti:T' (usuario $usuarioSembrado).",
    "2026-11-16 10:00:01 [conectar] Un mensaje de email con el token será enviado a $correoSembrado",
    "2026-11-16 10:00:02 [conectar] AuthCode: 987654 recibido; token code is 123456",
    "2026-11-16 10:00:03 [conectar] Cuenta $env:USERNAME ($sidSembrado) en $env:COMPUTERNAME en C:\Users\$env:USERNAME\Herramientas")
[IO.File]::WriteAllLines((Join-Path $datosHijo 'vpn-forti\vpn.log'), $logSembrado, (New-Object Text.UTF8Encoding($false)))
$resDiag = $null
Probar 'diagnosticar: JSON de una línea parseable con las comprobaciones esperadas' {
    $script:resDiag = Ejecutar-Hijo @('diagnosticar') @{ LOCALAPPDATA = $datosHijo; VPN_FORTI_CONFIG = $cfgHijo }
    $lineas = @($resDiag.salida -split "`r?`n" | Where-Object { $_ -like '{*' })
    Igual $lineas.Count 1 'debe haber una única línea JSON en stdout'
    $j = $lineas[0] | ConvertFrom-Json
    Igual $j.orden 'diagnosticar'; Afirmar ($j.codigo -in 0, 1); Afirmar ($resDiag.codigo -eq $j.codigo)
    $ids = @($j.comprobaciones | ForEach-Object { $_.id })
    foreach ($id in 'sistema', 'forticlient.version', 'forticlient.asar', 'forticlient.modulo', 'forticlient.runtime', 'servicio', 'tarea', 'usuario.admin', 'tuneles', 'credencial', 'node', 'navegador', 'git', 'forticlient.abierto', 'vpn', 'rutas', 'consola.modo') {
        Afirmar ($ids -contains $id) "falta la comprobación '$id'"
    }
    foreach ($c in $j.comprobaciones) { Afirmar ($c.estado -in 'ok', 'aviso', 'error') "estado raro en $($c.id): $($c.estado)"; Afirmar ($null -ne $c.detalle) "sin detalle en $($c.id)" }
    Afirmar (@($j.log).Count -le 20); Igual ($j.resumen.ok + $j.resumen.avisos + $j.resumen.errores) @($j.comprobaciones).Count
    Afirmar ($resDiag.error -match 'Resumen:') 'el informe legible debe ir a stderr'
}
Probar 'diagnosticar: escribe diagnostico.json y diagnostico.txt válidos' {
    $fj = Join-Path $datosHijo 'vpn-forti\diagnostico.json'; $ft = Join-Path $datosHijo 'vpn-forti\diagnostico.txt'
    Afirmar (Test-Path $fj); Afirmar (Test-Path $ft)
    $j = Get-Content $fj -Raw -Encoding UTF8 | ConvertFrom-Json
    Afirmar (@($j.comprobaciones).Count -ge 15)
    Afirmar ((Get-Content $ft -Raw -Encoding UTF8) -match 'Últimos mensajes de vpn.log')
}
Probar 'diagnosticar: ni la salida ni los ficheros contienen el usuario, el equipo ni credenciales' {
    $todo = $resDiag.salida + "`n" + $resDiag.error + "`n" + (Get-Content (Join-Path $datosHijo 'vpn-forti\diagnostico.json') -Raw -Encoding UTF8) + "`n" + (Get-Content (Join-Path $datosHijo 'vpn-forti\diagnostico.txt') -Raw -Encoding UTF8)
    $n = Obtener-NombresPrivados
    foreach ($u in $n.usuarios) { if ($u.Length -ge 3) { Afirmar ($todo -notmatch [regex]::Escape($u)) "aparece el usuario '$u'" } }
    foreach ($e in $n.equipos) { if ($e.Length -ge 3) { Afirmar ($todo -notmatch [regex]::Escape($e)) "aparece el equipo '$e'" } }
    Afirmar ($todo -notmatch '(?i)password|contrase.a\s*[:=]\s*\S') 'aparece una contraseña'
}
Probar 'diagnosticar enmascara el vpn.log (usuario de Windows y de la credencial, correo, PIN, SID, equipo) en stdout, stderr y los dos ficheros' {
    $todo = $resDiag.salida + "`n" + $resDiag.error + "`n" + (Get-Content (Join-Path $datosHijo 'vpn-forti\diagnostico.json') -Raw -Encoding UTF8) + "`n" + (Get-Content (Join-Path $datosHijo 'vpn-forti\diagnostico.txt') -Raw -Encoding UTF8)
    Afirmar ($todo -match 'Credencial:') 'el log sembrado debería salir (enmascarado) en el diagnóstico'
    foreach ($x in $credUsuarioReal, $correoSembrado, 'ejemplo-vpn.test', '987654', '123456', $sidSembrado, '1111111111', $env:USERNAME, $env:COMPUTERNAME) {
        if ($x -and $x.Length -ge 3) { Afirmar ($todo -notmatch [regex]::Escape($x)) "aparece '$x'" }
    }
    Afirmar ($todo -match '<usuario>' -and $todo -match '<correo>' -and $todo -match '<pin>' -and $todo -match '<sid>')
}
Probar 'diagnosticar lee consola.modo de config.json (y fusiona el bloque «consola» con los valores por defecto)' {
    $f = Join-Path $Tmp 'cfg-modo.json'
    [IO.File]::WriteAllText($f, '{"consola":{"modo":"C"},"pin":{"canal":"chrome"}}', (New-Object Text.UTF8Encoding($false)))
    $r = Ejecutar-Hijo @('diagnosticar') @{ LOCALAPPDATA = $datosHijo; VPN_FORTI_CONFIG = $f }
    $j = ($r.salida -split "`r?`n" | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json
    $c = $j.comprobaciones | Where-Object { $_.id -eq 'consola.modo' }
    Igual $c.estado 'ok'; Afirmar ($c.detalle -match "'C'") $c.detalle
}
Probar 'diagnosticar es de solo lectura: no abre FortiClient ni cambia config.json' {
    $antes = (Get-FileHash $cfgHijo).Hash
    $n0 = @(Get-Process FortiClient -ErrorAction SilentlyContinue).Count
    [void](Ejecutar-Hijo @('diagnosticar') @{ LOCALAPPDATA = $datosHijo; VPN_FORTI_CONFIG = $cfgHijo })
    Igual (Get-FileHash $cfgHijo).Hash $antes
    Igual @(Get-Process FortiClient -ErrorAction SilentlyContinue).Count $n0
}
$fortiParaMutex = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Fortinet\FortiClient\FortiClient.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $fortiParaMutex) { Saltar 'probar-arranque con la conexión en curso' 'no hay FortiClient instalado (vpn.ps1 saldría antes con sin-forticlient)' }
else {
    Probar 'probar-arranque con la conexión en curso (mutex Local\vpn-forti-conectar tomado): sale con 9 «conexion-en-curso» sin tocar nada, tenga o no VPN' {
        $mx = New-Object System.Threading.Mutex($false, 'Local\vpn-forti-conectar')
        $tengo = $false; try { $tengo = $mx.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $tengo = $true }
        if (-not $tengo) { $mx.Dispose(); throw 'no se ha podido tomar el mutex de la prueba (¿hay una conexión en curso real?)' }
        try {
            $antes = (Get-FileHash $cfgHijo).Hash
            $n0 = @(Get-Process FortiClient -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
            $r = Ejecutar-Hijo @('probar-arranque', '-Guardar') @{ LOCALAPPDATA = $datosHijo; VPN_FORTI_CONFIG = $cfgHijo }
            $j = ($r.salida -split "`r?`n" | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json
            Igual $r.codigo 9; Igual $j.motivo 'conexion-en-curso'; Afirmar ($j.omitida -eq $true)
            Igual (Get-FileHash $cfgHijo).Hash $antes
            Igual @(Get-Process FortiClient -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) $n0
        } finally { $mx.ReleaseMutex(); $mx.Dispose() }
    }
}
$vpnActivaReal = $false
try { $vpnActivaReal = [bool](Get-NetAdapter -InterfaceDescription 'Fortinet SSL VPN Virtual Ethernet Adapter' -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) } catch { }
if ($SinGui) { Saltar 'probar-arranque real' '-SinGui' }
elseif (-not $vpnActivaReal) { Saltar 'probar-arranque real' 'no hay VPN conectada: abriría FortiClient de verdad; solo se prueba con VPN activa' }
else {
    Probar 'probar-arranque real con VPN conectada: sale con 9 («vpn-conectada») sin tocar FortiClient ni config.json' {
        $antes = (Get-FileHash $cfgHijo).Hash
        $n0 = @(Get-Process FortiClient -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        $r = Ejecutar-Hijo @('probar-arranque', '-Guardar') @{ LOCALAPPDATA = $datosHijo; VPN_FORTI_CONFIG = $cfgHijo }
        $j = ($r.salida -split "`r?`n" | Where-Object { $_ -like '{*' } | Select-Object -Last 1) | ConvertFrom-Json
        Igual $r.codigo 9; Igual $j.motivo 'vpn-conectada'; Afirmar ($j.omitida -eq $true)
        Igual (Get-FileHash $cfgHijo).Hash $antes
        Igual @(Get-Process FortiClient -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) $n0
    }
}

# ================================================================ lanzamiento real de los modos con un exe inofensivo
Write-Host 'Lanzamiento real de cada modo con un ejecutable inofensivo (no se usa FortiClient)'
if ($SinGui) { Saltar 'lanzamiento real de los modos' '-SinGui' }
else {
    $dirSonda = Join-Path $Tmp 'carpeta sonda'
    New-Item -ItemType Directory -Force $dirSonda | Out-Null
    $exeSonda = Join-Path $dirSonda 'FortiClient.exe'
    $fuenteSonda = @'
using System; using System.Diagnostics; using System.IO;
public class SondaProbe { public static void Main() {
  var me = Process.GetCurrentProcess(); string padre = "?";
  try {
    using (var q = new System.Management.ManagementObjectSearcher("SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" + me.Id))
      foreach (System.Management.ManagementObject o in q.Get()) { int pp = Convert.ToInt32(o["ParentProcessId"]); try { padre = Process.GetProcessById(pp).ProcessName; } catch { padre = "ya-no-existe"; } }
  } catch (Exception) { padre = "err"; }
  File.AppendAllText(Path.Combine(Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location), "sonda.out"),
    "padre=" + padre + "|cwd=" + Directory.GetCurrentDirectory() + "|args=" + string.Join(" ", Environment.GetCommandLineArgs(), 1, Environment.GetCommandLineArgs().Length - 1) + Environment.NewLine);
} }
'@
    $compilada = $false
    try { Add-Type -TypeDefinition $fuenteSonda -OutputAssembly $exeSonda -OutputType ConsoleApplication -ReferencedAssemblies System.Management; $compilada = Test-Path $exeSonda } catch { }
    if (-not $compilada) { Saltar 'lanzamiento real de los modos' 'no se ha podido compilar el ejecutable de prueba' }
    else {
        function Lanzar-Sonda([string]$Id) {
            $out = Join-Path $dirSonda 'sonda.out'
            Remove-Item $out -ErrorAction SilentlyContinue
            $Cfg.fortiClientExe = $exeSonda
            & $RealLanzar (Obtener-ModoConsola $Id)
            $limite = (Get-Date).AddSeconds(25)
            while (-not (Test-Path $out) -and (Get-Date) -lt $limite) { Start-Sleep -Milliseconds 250 }
            if (-not (Test-Path $out)) { throw "el modo $Id no ha lanzado el ejecutable en 25 s" }
            Start-Sleep -Milliseconds 300
            $l = (Get-Content $out -Encoding UTF8 | Select-Object -First 1)
            $p = [ordered]@{}
            foreach ($par in $l -split '\|') { $k, $v = $par -split '=', 2; $p[$k] = $v }
            return [pscustomobject]$p
        }
        Probar 'modo A (acceso directo): lo lanza explorer.exe, con la carpeta del exe como carpeta de trabajo y con el flag' {
            $r = Lanzar-Sonda 'A'
            Igual $r.padre 'explorer'; Afirmar ($r.cwd.TrimEnd('\') -like '*\carpeta sonda') "cwd: $($r.cwd)"; Afirmar ($r.args -match 'force-renderer-accessibility')
        }
        Probar 'modo B: explorer.exe, carpeta del exe y sin flag' {
            $r = Lanzar-Sonda 'B'
            Igual $r.padre 'explorer'; Afirmar ($r.cwd.TrimEnd('\') -like '*\carpeta sonda') "cwd: $($r.cwd)"; Afirmar ($r.args -notmatch 'force-renderer-accessibility')
        }
        Probar 'modo C (Explorador → .cmd): no cuelga de PowerShell, carpeta del exe y sin flag' {
            $r = Lanzar-Sonda 'C'
            Afirmar ($r.padre -ne 'powershell') "el padre es $($r.padre)"; Afirmar ($r.cwd.TrimEnd('\') -like '*\carpeta sonda') "cwd: $($r.cwd)"; Afirmar ($r.args -notmatch 'force-renderer-accessibility')
        }
        Probar 'modo D (el antiguo): explorer.exe pero SIN carpeta de trabajo (System32, no la del exe) y con el flag' {
            $r = Lanzar-Sonda 'D'
            Igual $r.padre 'explorer'; Afirmar ($r.cwd -notlike '*\carpeta sonda*' -and $r.cwd -match '(?i)system32') "cwd: $($r.cwd)"; Afirmar ($r.args -match 'force-renderer-accessibility')
        }
    }
}

# ================================================================ diálogo falso real (detección y cierre)
Write-Host 'Diálogo de error falso (MessageBox de otro proceso)'
function Probar-DialogoFalso([string]$Titulo, [string]$Texto, [bool]$Detectar) {
    # Un proceso aparte muestra un MessageBox; se hace pasar por «el proceso de FortiClient» y se usan las funciones REALES.
    $cmd = "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('$Texto','$Titulo')"
    $p = Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$cmd`"" -PassThru
    try {
        $script:PidFalso = $p.Id
        function Ids-Forti { return @($script:PidFalso) }
        function Buscar-DialogoErrorForti { & $RealBuscarDialogo }
        $d = $null
        $limite = (Get-Date).AddSeconds($(if ($Detectar) { 25 } else { 6 }))
        do { $d = Buscar-DialogoErrorForti; if ($d) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $limite)
        if ($Detectar) {
            Afirmar ($null -ne $d) 'no se ha detectado el diálogo'
            Afirmar ($d.Texto -match 'TraceLog') "texto leído: '$($d.Texto)'"
            Afirmar (& $RealCerrarDialogo $d 5) 'no se ha podido cerrar el diálogo'
            Afirmar ($p.WaitForExit(10000)) 'el proceso del diálogo debería haber terminado al cerrarlo'
        } else {
            Afirmar ($null -eq $d) "se ha detectado como error un diálogo ajeno: $($d.Texto)"
        }
    } finally {
        if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    }
}
if ($SinGui) { Saltar 'diálogo falso' '-SinGui' }
else {
    if (-not ('VpnForti.Ui' -as [type])) { try { Add-Type -Path (Join-Path $Raiz 'lib\VpnForti.cs') -ReferencedAssemblies Accessibility } catch { } }
    if (-not ('VpnForti.Ui' -as [type])) { Saltar 'diálogo falso' 'no se ha podido compilar lib\VpnForti.cs' }
    else {
        Probar 'MessageBox «Error» con el texto de TraceLog: Buscar-DialogoErrorForti lo detecta y Cerrar-DialogoError lo cierra' {
            Probar-DialogoFalso 'Error' "A JavaScript error occurred in the main process. TypeError: Cannot read properties of null (reading TraceLog) at new Logger" $true
        }
        Probar 'MessageBox ajeno («Aviso» con otro texto): no se confunde con el error de Electron' {
            Probar-DialogoFalso 'Aviso' 'Todo va bien' $false
        }
        # TaskDialog REAL (TaskDialogIndirect, con título «Error», como el de Electron): ni WM_COMMAND ni WM_CLOSE lo cierran,
        # hace falta TDM_CLICK_BUTTON. Se compila un ejecutable de prueba con el manifiesto de comctl32 v6 (flags 0).
        $exeTd = Join-Path $Tmp 'td.exe'
        $fuenteTd = @'
using System; using System.Runtime.InteropServices;
public static class TdProbe {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode, Pack=4)]
  public struct CFG { public uint cbSize; public IntPtr hwndParent; public IntPtr hInstance; public int dwFlags; public int dwCommonButtons;
    public string pszWindowTitle; public IntPtr hMainIcon; public string pszMainInstruction; public string pszContent; public uint cButtons; public IntPtr pButtons;
    public int nDefaultButton; public uint cRadioButtons; public IntPtr pRadioButtons; public int nDefaultRadioButton; public string pszVerificationText;
    public string pszExpandedInformation; public string pszExpandedControlText; public string pszCollapsedControlText; public IntPtr hFooterIcon; public string pszFooter;
    public IntPtr pfCallback; public IntPtr lpCallbackData; public uint cxWidth; }
  [DllImport("comctl32.dll", CharSet=CharSet.Unicode)] public static extern int TaskDialogIndirect(ref CFG c, out int b, out int r, out bool v);
  public static int Main(string[] a) {
    var c = new CFG(); c.cbSize = (uint)Marshal.SizeOf(typeof(CFG)); c.dwFlags = 0; c.dwCommonButtons = 1;
    c.pszWindowTitle = "Error"; c.pszMainInstruction = "A JavaScript error occurred in the main process";
    c.pszContent = "Uncaught Exception:\nTypeError: Cannot read properties of null (reading 'TraceLog')\n    at new Logger";
    int b, r; bool v; TaskDialogIndirect(ref c, out b, out r, out v);
    return b;
  }
}
'@
        $manifiestoTd = Join-Path $Tmp 'td.manifest'
        [IO.File]::WriteAllText($manifiestoTd, '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"><dependency><dependentAssembly><assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/></dependentAssembly></dependency></assembly>')
        $tdCompilado = $false; $errTd = $null
        try { $cpTd = New-Object System.CodeDom.Compiler.CompilerParameters; $cpTd.GenerateExecutable = $true; $cpTd.OutputAssembly = $exeTd; $cpTd.CompilerOptions = "/win32manifest:`"$manifiestoTd`""; Add-Type -TypeDefinition $fuenteTd -CompilerParameters $cpTd; $tdCompilado = Test-Path $exeTd } catch { $errTd = $_.Exception.Message }
        if (-not $tdCompilado) { Saltar 'TaskDialog real' "no se ha podido compilar el ejecutable de prueba: $errTd" }
        else {
            Probar 'TaskDialog real «Error» (como el de Electron): se detecta, se lee su texto y Cerrar-DialogoError lo cierra con TDM_CLICK_BUTTON' {
                $p = Start-Process $exeTd -PassThru
                try {
                    $script:PidFalso = $p.Id
                    function Ids-Forti { return @($script:PidFalso) }
                    function Buscar-DialogoErrorForti { & $RealBuscarDialogo }
                    $d = $null; $limite = (Get-Date).AddSeconds(25)
                    do { $d = Buscar-DialogoErrorForti; if ($d) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $limite)
                    Afirmar ($null -ne $d) 'no se ha detectado el TaskDialog'
                    Afirmar ($d.Texto -match 'TraceLog') "texto leído: '$($d.Texto)'"
                    Afirmar (& $RealCerrarDialogo $d 5) 'Cerrar-DialogoError no ha podido cerrar el TaskDialog'
                    Afirmar ($p.WaitForExit(10000)) 'el proceso del TaskDialog debería haber terminado'
                } finally { if (-not $p.HasExited) { try { $p.Kill() } catch { } } }
            }
        }
    }
}

# ================================================================ instalador con un vpn.ps1 simulado
Write-Host 'instalar.ps1 con vpn.ps1 simulado (npm install local sin red; no toca VPN_FORTI ni FortiClient)'
$nodeExeReal = (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$fortiReal = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Fortinet\FortiClient\FortiClient.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
$tunelesReal = @(); try { $tunelesReal = @(Get-ChildItem 'HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels' -ErrorAction Stop) } catch { }
$edgeOChrome = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ } | ForEach-Object { (Join-Path $_ 'Microsoft\Edge\Application\msedge.exe'), (Join-Path $_ 'Google\Chrome\Application\chrome.exe') } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $nodeExeReal -or -not $fortiReal -or -not $edgeOChrome) { Saltar 'instalador simulado' 'faltan Node, Edge/Chrome o FortiClient en este equipo (el instalador los exige)' }
else {
    $inst = Join-Path $Tmp 'inst'
    New-Item -ItemType Directory -Force (Join-Path $inst 'stub-pw') | Out-Null
    $txtInst = [IO.File]::ReadAllText((Join-Path $Raiz 'instalar.ps1'))
    $lineaEnv = "[Environment]::SetEnvironmentVariable('VPN_FORTI', `$VpnPs1, 'User')"
    # Se anula solo la escritura de la variable de usuario VPN_FORTI (no debe cambiar al ejecutar las pruebas).
    $parcheado = $txtInst.Contains($lineaEnv)
    [IO.File]::WriteAllText((Join-Path $inst 'instalar.ps1'), $txtInst.Replace($lineaEnv, "`$null = 'no se toca VPN_FORTI'"), (New-Object Text.UTF8Encoding($true)))
    Copy-Item (Join-Path $Raiz 'config.ejemplo.json') $inst
    [IO.File]::WriteAllText((Join-Path $inst 'stub-pw\package.json'), '{"name":"playwright-core","version":"1.0.0"}')
    [IO.File]::WriteAllText((Join-Path $inst 'package.json'), '{"name":"inst-prueba","version":"1.0.0","dependencies":{"playwright-core":"file:./stub-pw"}}')
    # vpn.ps1 simulado: responde con lo que diga el escenario y apunta cada llamada en un log.
    $falso = @'
param([string]$Orden)
$e = Get-Content $env:VPN_FORTI_FAKE -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Content -Path $env:VPN_FORTI_FAKE_LOG -Value (($Orden + ' ' + ($args -join ' ')).Trim())
$r = $e.PSObject.Properties[$Orden]
if ($Orden -eq 'probar-arranque') { [Console]::Error.WriteLine('2026-11-16 10:00:00 [probar-arranque] Modo A (lnk-carpeta-flag): ok, formulario=True') }
if ($r -and $r.Value.PSObject.Properties['espera']) { Start-Sleep -Seconds ([int]$r.Value.espera) }
if (-not $r) { [Console]::Out.WriteLine('{}'); exit 0 }
[Console]::Out.WriteLine(($r.Value.json | ConvertTo-Json -Compress -Depth 8)); exit ([int]$r.Value.codigo)
'@
    [IO.File]::WriteAllText((Join-Path $inst 'vpn.ps1'), $falso, (New-Object Text.UTF8Encoding($true)))

    function Chequeo-Falso($Id, $Estado, $Datos) { @{ id = $Id; estado = $Estado; detalle = "$Id simulado"; datos = $Datos } }
    function Escenario-Instalador([string]$Servicio = 'Running', [bool]$TareaOk = $true, [bool]$Admin = $true, [bool]$Abierto = $false, [bool]$VpnActiva = $false, $Arranque = @{ codigo = 0; json = @{ modoElegido = 'B'; omitida = $false; motivo = $null; resultados = @() } }) {
        $comp = @(
            (Chequeo-Falso 'forticlient.version' 'ok' @{ version = '7.0.14.585' }),
            (Chequeo-Falso 'servicio' 'ok' @{ estado = $Servicio; inicio = 'Manual' }),
            (Chequeo-Falso 'tarea' 'ok' @{ instalada = $TareaOk; correcta = $TareaOk }),
            (Chequeo-Falso 'usuario.admin' 'ok' @{ administradorLocal = $Admin; elevado = $false }),
            (Chequeo-Falso 'forticlient.abierto' 'ok' @{ abierto = $Abierto }),
            (Chequeo-Falso 'vpn' 'ok' @{ conectada = $VpnActiva; adaptadorActivo = $VpnActiva }))
        return @{
            diagnosticar = @{ codigo = 0; json = @{ orden = 'diagnosticar'; resumen = @{ ok = 6; avisos = 0; errores = 0 }; comprobaciones = $comp } }
            estado = @{ codigo = 1; json = @{ conectada = $false; tareaServicio = @{ instalada = $TareaOk; problemas = @() } } }
            'instalar-tarea' = @{ codigo = 0; json = @{ mensaje = 'Tarea instalada' } }
            'arrancar-servicio' = @{ codigo = 0; json = @{ mensaje = 'Servicio arrancado' } }
            credencial = @{ codigo = 0; json = @{ credencial = $true; target = 'x'; usuario = 'u' } }
            'probar-arranque' = $Arranque
        }
    }
    function Ejecutar-Instalador($Escenario, [string[]]$Argumentos = @(), [string]$ModoGuardado = '', $ArranquePrevio = $null) {
        $datos = Join-Path $Tmp ('datos-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force (Join-Path $datos 'vpn-forti') | Out-Null
        $fe = Join-Path $datos 'escenario.json'; $fl = Join-Path $datos 'llamadas.log'
        [IO.File]::WriteAllText($fe, ($Escenario | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        $cfgI = Join-Path $datos 'config.json'
        $modoJson = if ($ModoGuardado) { ",`"consola`":{`"modo`":`"$ModoGuardado`"}" } else { '' }
        [IO.File]::WriteAllText($cfgI, "{`"tunel`":`"T`"$modoJson}", (New-Object Text.UTF8Encoding($false)))
        if ($ArranquePrevio) { [IO.File]::WriteAllText((Join-Path $datos 'vpn-forti\arranque.json'), ($ArranquePrevio | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false))) }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
        $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $inst 'instalar.ps1')`"", '-Silencioso') + $Argumentos) -join ' '
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.EnvironmentVariables['LOCALAPPDATA'] = $datos
        $psi.EnvironmentVariables['VPN_FORTI_CONFIG'] = $cfgI
        $psi.EnvironmentVariables['VPN_FORTI_FAKE'] = $fe
        $psi.EnvironmentVariables['VPN_FORTI_FAKE_LOG'] = $fl
        $psi.EnvironmentVariables['VPN_FORTI_FAKE'] = $fe
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; throw 'el instalador no ha terminado en 180 s' }
        $p.WaitForExit()
        $json = ($so.Result -split "`r?`n" | Where-Object { $_ -like '{*' } | Select-Object -Last 1)
        return [pscustomobject]@{ codigo = $p.ExitCode; json = $(if ($json) { $json | ConvertFrom-Json } else { $null }); llamadas = @($(if (Test-Path $fl) { Get-Content $fl -Encoding UTF8 })); error = $se.Result }
    }

    Probar 'el parche de la prueba sigue anulando solo la variable de usuario VPN_FORTI (si falla, instalar.ps1 ha cambiado esa línea)' { Afirmar $parcheado }
    Probar 'sin ser administrador local: no instala la tarea ni arranca el servicio, lo dice con el paso manual y el código sigue siendo 0' {
        $r = Ejecutar-Instalador (Escenario-Instalador -Servicio 'Stopped' -TareaOk $false -Admin $false -Arranque @{ codigo = 9; json = @{ omitida = $true; motivo = 'servicio-parado'; mensaje = 'servicio parado'; resultados = @() } })
        Igual $r.codigo 0 $r.error
        Afirmar ($r.json.avisos -match 'no es administrador local' -and $r.json.avisos -match 'sc start FA_Scheduler') "avisos: $($r.json.avisos -join ' / ')"
        Igual $r.json.tarea $false
        Afirmar ($r.llamadas -notcontains 'instalar-tarea' -and $r.llamadas -notcontains 'arrancar-servicio')
    }
    Probar 'administrador con -Silencioso sin -InstalarTarea: solo avisa (no provoca un UAC inesperado)' {
        $r = Ejecutar-Instalador (Escenario-Instalador -Servicio 'Stopped' -TareaOk $false -Admin $true)
        Igual $r.codigo 0 $r.error
        Afirmar ($r.llamadas -notcontains 'instalar-tarea'); Afirmar ($r.json.avisos -match 'Falta la tarea')
    }
    $versionRealForti = ''; try { $versionRealForti = [string](Get-Item $fortiReal).VersionInfo.ProductVersion } catch { }
    Probar 'administrador con -InstalarTarea y servicio parado: instala la tarea, arranca el servicio y prueba el arranque (con -ProbarArranque)' {
        $r = Ejecutar-Instalador (Escenario-Instalador -Servicio 'Stopped' -TareaOk $false -Admin $true) @('-InstalarTarea', '-ProbarArranque')
        Igual $r.codigo 0 $r.error
        Igual $r.json.servicio.estado 'Running'; Igual $r.json.tarea $true; Igual $r.json.arranque.modo 'B'
        $orden = @($r.llamadas | ForEach-Object { ($_ -split ' ')[0] })
        Afirmar ($orden.IndexOf('instalar-tarea') -lt $orden.IndexOf('arrancar-servicio') -and $orden.IndexOf('arrancar-servicio') -lt $orden.IndexOf('probar-arranque')) "orden: $($orden -join ',')"
        Afirmar ($r.llamadas -contains 'probar-arranque -Guardar')
    }
    Probar 'tarea ya instalada y servicio parado: lo arranca con la tarea sin tocar la tarea' {
        $r = Ejecutar-Instalador (Escenario-Instalador -Servicio 'Stopped' -TareaOk $true -Admin $false)
        Igual $r.codigo 0 $r.error
        Afirmar ($r.llamadas -contains 'arrancar-servicio' -and $r.llamadas -notcontains 'instalar-tarea'); Igual $r.json.servicio.estado 'Running'
    }
    Probar 'ningún modo sirve (código 8 de vpn.ps1): código nuevo 5 con mensaje que pide enviar diagnostico.txt' {
        $r = Ejecutar-Instalador (Escenario-Instalador -Arranque @{ codigo = 8; json = @{ omitida = $false; motivo = $null; modoElegido = $null; mensaje = 'ninguno'; resultados = @(@{ modo = 'A'; resultado = 'error-electron' }) } }) @('-ProbarArranque')
        Igual $r.codigo 5 $r.error
        Afirmar ($r.json.ok -eq $false -and $r.json.codigo -eq 5); Afirmar ($r.json.mensaje -match 'diagnostico\.txt' -and $r.json.mensaje -match 'TraceLog')
    }
    Probar 'prueba omitida o interrumpida (código 9 de vpn.ps1, con cualquier motivo): NUNCA da el 5' {
        foreach ($mot in 'vpn-conectada-durante-la-prueba', 'forticlient-no-cerrado', 'conexion-en-curso', 'uac-pendiente') {
            $r = Ejecutar-Instalador (Escenario-Instalador -Arranque @{ codigo = 9; json = @{ omitida = $true; motivo = $mot; modoElegido = $null; mensaje = $mot; resultados = @() } }) @('-ProbarArranque')
            Igual $r.codigo 0 "motivo $mot`: $($r.error)"; Igual $r.json.arranque.omitida $true; Igual $r.json.arranque.motivo $mot
        }
    }
    Probar 'FortiClient abierto sin VPN: no se pide cerrarlo salvo con -CerrarForti' {
        # (solo se puede probar si en este equipo no hay un FortiClient abierto de verdad: el instalador mira los procesos)
        $e = Escenario-Instalador -Abierto $true
        $r = Ejecutar-Instalador $e @('-ProbarArranque')
        Afirmar ($r.llamadas -contains 'probar-arranque -Guardar') "llamadas: $($r.llamadas -join ' / ')"
        Afirmar ($r.llamadas -notcontains 'probar-arranque -Guardar -CerrarAbierto')
        $r = Ejecutar-Instalador $e @('-ProbarArranque', '-CerrarForti')
        Afirmar (($r.llamadas -contains 'probar-arranque -Guardar -CerrarAbierto') -or ($r.llamadas -contains 'probar-arranque -Guardar')) "llamadas: $($r.llamadas -join ' / ')"
    }
    Probar 'con -Silencioso y SIN -ProbarArranque no se abre FortiClient: arranque.omitida = true, motivo silencioso-sin-prueba, código 0' {
        $r = Ejecutar-Instalador (Escenario-Instalador)
        Igual $r.codigo 0 $r.error
        Afirmar ($r.llamadas -notcontains 'probar-arranque -Guardar') 'no debe lanzar la prueba'
        Igual $r.json.arranque.omitida $true; Igual $r.json.arranque.motivo 'silencioso-sin-prueba'; Igual $r.json.arranque.hecha $false
        Afirmar ($r.json.avisos -match 'ProbarArranque')
    }
    Probar 'idempotente: con consola.modo guardado y prueba previa de esta versión no vuelve a abrir FortiClient (salvo -RepetirPrueba)' {
        $previo = @{ fecha = '2026-11-16 10:00:00'; fortiClientVersion = $versionRealForti; modoElegido = 'A'; omitida = $false }
        $e = Escenario-Instalador
        $r = Ejecutar-Instalador $e @('-ProbarArranque') 'A' $previo
        Igual $r.codigo 0 $r.error; Afirmar ($r.llamadas -notcontains 'probar-arranque -Guardar'); Igual $r.json.arranque.hecha $false; Igual $r.json.arranque.motivo 'ya-probada'
        $r = Ejecutar-Instalador $e @('-ProbarArranque', '-RepetirPrueba') 'A' $previo
        Afirmar ($r.llamadas -contains 'probar-arranque -Guardar')
        $r = Ejecutar-Instalador $e @('-ProbarArranque') 'A' @{ fecha = 'x'; fortiClientVersion = '0.0.0.1'; modoElegido = 'A'; omitida = $false }
        Afirmar ($r.llamadas -contains 'probar-arranque -Guardar') 'una versión nueva de FortiClient debe repetir la prueba'
    }
    Probar 'si "diagnosticar" falla (no devuelve JSON): el rol de administrador se averigua por whoami, se instala la tarea como en la 1.2.2 y la versión no hace repetir la prueba cada vez' {
        $e = Escenario-Instalador -Servicio 'Stopped' -TareaOk $false -Admin $true
        $e['diagnosticar'] = @{ codigo = 1; json = $null }
        $e.Remove('diagnosticar')   # el simulado responde «{}» con código 0: sin comprobaciones
        $esAdminReal = Es-AdministradorLocal (Obtener-SidsToken)
        $r = Ejecutar-Instalador $e @('-InstalarTarea', '-ProbarArranque')
        Igual $r.codigo 0 $r.error
        Afirmar ($r.json.avisos -match 'diagnóstico no ha devuelto') "avisos: $($r.json.avisos -join ' / ')"
        Afirmar (-not ($r.json.avisos -match 'no es administrador local')) 'sin diagnóstico no debe darse por no administrador'
        if ($esAdminReal) { Afirmar ($r.llamadas -contains 'instalar-tarea') "debería intentar instalar la tarea (1.2.2): $($r.llamadas -join ' / ')" }
        # con prueba previa de esta versión y modo guardado, sin diagnóstico tampoco se repite
        $previo = @{ fecha = '2026-11-16 10:00:00'; fortiClientVersion = $versionRealForti; modoElegido = 'A'; omitida = $false }
        $r = Ejecutar-Instalador $e @('-ProbarArranque') 'A' $previo
        Afirmar ($r.llamadas -notcontains 'probar-arranque -Guardar') 'sin diagnóstico la versión de FortiClient debe salir del exe'
    }
    Probar 'la prueba tiene un tope de tiempo y va mostrando el progreso (stderr) de cada modo' {
        $e = Escenario-Instalador -Arranque @{ codigo = 0; espera = 25; json = @{ modoElegido = 'A'; omitida = $false; motivo = $null; resultados = @() } }
        $t0 = Get-Date
        $r = Ejecutar-Instalador $e @('-ProbarArranque', '-TopePruebaSeg', '3')
        Afirmar (((Get-Date) - $t0).TotalSeconds -lt 60) 'no debía esperar los 25 s del simulado'
        Igual $r.codigo 0 $r.error
        Igual $r.json.arranque.omitida $true; Igual $r.json.arranque.motivo 'tiempo-agotado'; Afirmar ($r.json.avisos -match 'no ha terminado')
        Afirmar ($r.error -match 'Modo A') "el progreso del modo no llegó a stderr: $($r.error)"
    }
    Probar '-SinPruebaArranque no la ejecuta' {
        $r = Ejecutar-Instalador (Escenario-Instalador) @('-SinPruebaArranque', '-ProbarArranque')
        Igual $r.codigo 0 $r.error; Afirmar ($r.llamadas -notcontains 'probar-arranque -Guardar')
    }
}
# ================================================================ sintaxis
Write-Host 'Sintaxis'
Probar 'todos los .ps1 se analizan sin errores' {
    $fallos = @()
    foreach ($f in Get-ChildItem -Path $Raiz -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\node_modules\\' }) {
        $e = $null
        [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
        if ($e.Count -gt 0) { $fallos += "$($f.Name): $($e[0].Message) (línea $($e[0].Extent.StartLineNumber))" }
    }
    Afirmar ($fallos.Count -eq 0) ($fallos -join '; ')
}
Probar 'los .ps1 con caracteres no ASCII llevan BOM (PowerShell 5.1 los lee como ANSI si no)' {
    $mal = @()
    foreach ($f in Get-ChildItem -Path $Raiz -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\node_modules\\' }) {
        $b = [IO.File]::ReadAllBytes($f.FullName)
        $tieneBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        $noAscii = ($b | Where-Object { $_ -gt 127 } | Select-Object -First 1)
        if ($noAscii -and -not $tieneBom) { $mal += $f.Name }
    }
    Afirmar ($mal.Count -eq 0) "sin BOM: $($mal -join ', ')"
}
Probar 'node --check de los .mjs' {
    $node = (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $node) { throw 'node no está instalado' }
    foreach ($f in Get-ChildItem -Path $Raiz -Filter *.mjs) {
        & $node --check $f.FullName 2>&1 | Out-Null
        Afirmar ($LASTEXITCODE -eq 0) "node --check falla en $($f.Name)"
    }
}

# ---------------------------------------------------------------- final
Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
$color = if ($script:Fallos -eq 0) { 'Green' } else { 'Red' }
Write-Host "$($script:Total - $script:Fallos) de $($script:Total) pruebas correctas, $($script:Fallos) fallos, $($script:Saltadas) saltadas." -ForegroundColor $color
exit $script:Fallos
