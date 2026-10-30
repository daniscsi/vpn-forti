<#
.SYNOPSIS
  vpn-forti: comprueba y reconecta la VPN SSL de FortiClient 7.0 automatizando su consola.

.DESCRIPTION
  Órdenes (primer argumento):
    estado               {conectada, adaptador, dns, tunel}. Sale 0 si está conectada, 1 si no.
    conectar             Abre la consola, rellena usuario y contraseña, pulsa Conectar, mete el PIN
                         del correo (Outlook web) y espera a que la VPN esté arriba.
    asegurar             Si ya está conectada sale 0 al instante; si no, hace "conectar".
    guardar-credencial   Pide usuario y contraseña y los guarda como credencial genérica.
    borrar-credencial    Borra la credencial genérica.
    volcar               Diagnóstico: árbol de accesibilidad de la consola (sin valores de campos).
    probar-bandeja       Diagnóstico: comprueba que Outlook web llega a la bandeja (no abre correos).
    probar-pin           Diagnóstico: lista los correos del PIN de Outlook web (dígitos enmascarados).
    aviso                Prueba el aviso visible (notificación + ventanita + pitido).

  Salida: una única línea JSON en stdout. Los mensajes de progreso van a stderr y al log
  %LOCALAPPDATA%\vpn-forti\vpn.log. La contraseña y el PIN nunca se escriben.

  Códigos de salida:
    0 conectada (o la orden ha ido bien)   1 no conectada / error genérico
    2 tiempo agotado                       3 no hay credencial utilizable
    4 no se encuentra la interfaz          5 FortiClient muestra un error al conectar
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('estado', 'conectar', 'asegurar', 'guardar-credencial', 'borrar-credencial', 'volcar', 'probar-bandeja', 'probar-pin', 'aviso', 'ayuda')]
    [string]$Orden = 'ayuda',
    [string]$Tunel,
    [int]$EsperaSeg,
    [string]$Target,
    [string]$Usuario,
    [switch]$SinPinCorreo,
    [switch]$NoPulsar,
    [string]$Mensaje,
    [switch]$Ventana
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---------------------------------------------------------------- configuración
$Raiz = $PSScriptRoot
$DirDatos = Join-Path $env:LOCALAPPDATA 'vpn-forti'
if (-not (Test-Path $DirDatos)) { New-Item -ItemType Directory -Force $DirDatos | Out-Null }
$FicheroLog = Join-Path $DirDatos 'vpn.log'

$Cfg = [ordered]@{
    tunel             = 'VPN Cerdanyola'
    esperaSeg         = 180
    hostDns           = 'transportistas-desa.portic.net'
    adaptador         = 'Fortinet SSL VPN Virtual Ethernet Adapter'
    credenciales      = @('FortiClient', 'vpn-forti:{tunel}')
    fortiClientExe    = 'C:\Program Files\Fortinet\FortiClient\FortiClient.exe'
    regexErrorForti   = 'incorrect|err[oó]ne|error|fallid|fall[oó]|denegad|denied|failed|inv[aá]lid|no v[aá]lid|caducad|expired'
    regexCampoToken   = 'token|c[oó]digo|code|respuesta|answer|pin'
    regexBotonToken   = '^(OK|Aceptar|Continuar|Enviar|Confirmar|Submit)$'
    pin               = [ordered]@{
        activado            = $true
        url                 = 'https://outlook.office.com/mail/?realm=portic.net'
        canal               = 'msedge'
        perfil              = (Join-Path $DirDatos 'perfil-outlook')
        filtro              = 'FortiToken|FortiGate|Fortinet|FortiAuthenticator|AuthCode|token|c[oó]digo|\bPIN\b'
        regexPin            = '(?:token|c[oó]digo|code|PIN|clave)\D{0,60}?(\d{4,10})\b'
        regexPinAlternativa = '\b(\d{6})\b'
        timeoutSeg          = 120
        loginTimeoutSeg     = 600
        accion              = 'ninguna'
    }
}

$FicheroCfg = if ($env:VPN_FORTI_CONFIG) { $env:VPN_FORTI_CONFIG } else { Join-Path $Raiz 'config.json' }
if (Test-Path $FicheroCfg) {
    $json = Get-Content $FicheroCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) {
        if ($p.Name -eq 'pin' -and $p.Value) {
            foreach ($q in $p.Value.PSObject.Properties) { $Cfg.pin[$q.Name] = $q.Value }
        } else { $Cfg[$p.Name] = $p.Value }
    }
}
if ($Tunel) { $Cfg.tunel = $Tunel }
if ($EsperaSeg -gt 0) { $Cfg.esperaSeg = $EsperaSeg }
if ($SinPinCorreo) { $Cfg.pin.activado = $false }
$Targets = @($Cfg.credenciales | ForEach-Object { $_ -replace '\{tunel\}', $Cfg.tunel })
$TargetPropio = "vpn-forti:$($Cfg.tunel)"

# ---------------------------------------------------------------- utilidades
function Log([string]$m) {
    $l = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Orden, $m
    try { [Console]::Error.WriteLine($l) } catch { }
    try { Add-Content -Path $FicheroLog -Value $l -Encoding UTF8 } catch { }
}

function Salir([int]$Codigo, [System.Collections.IDictionary]$Datos) {
    $o = [ordered]@{ orden = $Orden; codigo = $Codigo }
    if ($Datos) { foreach ($k in @($Datos.Keys)) { $o[$k] = $Datos[$k] } }
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 6))
    exit $Codigo
}

function Unir([System.Collections.IDictionary]$A, [System.Collections.IDictionary]$B) {
    $r = [ordered]@{}
    foreach ($k in @($A.Keys)) { $r[$k] = $A[$k] }
    foreach ($k in @($B.Keys)) { $r[$k] = $B[$k] }
    return $r
}

$script:AyudanteCargado = $false
function Cargar-Ayudante {
    if ($script:AyudanteCargado) { return }
    if (-not ('VpnForti.Ui' -as [type])) {
        Add-Type -Path (Join-Path $Raiz 'lib\VpnForti.cs') -ReferencedAssemblies Accessibility
    }
    $script:AyudanteCargado = $true
}

function Mostrar-Notificacion([string]$Titulo, [string]$Texto) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $x = New-Object Windows.Data.Xml.Dom.XmlDocument
        $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
        $x.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$(& $esc $Titulo)</text><text>$(& $esc $Texto)</text></binding></visual></toast>")
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show((New-Object Windows.UI.Notifications.ToastNotification $x))
        Log "Notificación: $Titulo - $Texto"
    } catch { Log "No se pudo mostrar la notificación: $($_.Exception.Message)" }
}

function Abrir-Ventanita([string]$Texto) {
    # Proceso aparte para no bloquear la espera; se cierra al conectar.
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", 'aviso', '-Ventana', '-Mensaje', "`"$Texto`"")
    try { return Start-Process powershell.exe -ArgumentList $a -PassThru -WindowStyle Hidden } catch { Log "No se pudo abrir la ventanita: $($_.Exception.Message)"; return $null }
}

function Cerrar-Proceso($p) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } } }

# ---------------------------------------------------------------- estado
function Get-Estado {
    $ad = $null
    try { $ad = Get-NetAdapter -InterfaceDescription $Cfg.adaptador -ErrorAction Stop | Select-Object -First 1 } catch { }
    $ip = $null
    try {
        $r = Resolve-DnsName -Name $Cfg.hostDns -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        $ip = ($r | Where-Object { $_.Section -eq 'Answer' -and $_.IPAddress } | Select-Object -First 1).IPAddress
    } catch { }
    $arriba = [bool]($ad -and $ad.Status -eq 'Up')
    $conectada = [bool]($arriba -and $ip)
    [ordered]@{
        conectada = $conectada
        adaptador = if ($ad) { [ordered]@{ nombre = $ad.Name; estado = [string]$ad.Status } } else { $null }
        dns       = [ordered]@{ host = $Cfg.hostDns; ip = $ip }
        tunel     = if ($conectada) { $Cfg.tunel } else { $null }
    }
}

# ---------------------------------------------------------------- credencial
function Resolver-Credencial {
    Cargar-Ayudante
    foreach ($t in $Targets) {
        $u = [VpnForti.Cred]::Usuario($t, 1)
        if ($null -ne $u) {
            $n = [VpnForti.Cred]::LongitudSecreto($t, 1)
            if ($n -gt 0) { return [ordered]@{ target = $t; usuario = $u; longitud = $n } }
            Log "La credencial genérica '$t' no tiene contraseña; se ignora."
        }
    }
    foreach ($t in $Targets) {
        $u = [VpnForti.Cred]::Usuario($t, 2)
        if ($null -ne $u) {
            Salir 3 @{ mensaje = "La credencial `"$t`" está guardada como credencial de Windows; guárdala como credencial genérica o ejecuta ``vpn.ps1 guardar-credencial``"; target = $t; usuario = $u; tipo = 'dominio' }
        }
    }
    Salir 3 @{ mensaje = "No hay credencial guardada. Ejecuta ``vpn.ps1 guardar-credencial`` (o crea una credencial genérica `"FortiClient`")."; buscadas = $Targets }
}

# ---------------------------------------------------------------- consola de FortiClient
function Buscar-Consola([int]$Segundos) {
    $limite = (Get-Date).AddSeconds($Segundos)
    do {
        $pids = @(Get-Process FortiClient -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        if ($pids.Count -gt 0) {
            $h = [VpnForti.Ui]::VentanaConsola([int[]]$pids)
            if ($h -ne [IntPtr]::Zero) { return $h }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $limite)
    return [IntPtr]::Zero
}

function Abrir-Consola {
    Cargar-Ayudante
    $h = Buscar-Consola 1
    if ($h -eq [IntPtr]::Zero) {
        # Lanzado directamente desde otro proceso, FortiClient.exe sale con 0 sin abrir ventana;
        # a través del Explorador sí se abre (como un doble clic).
        Log 'Abriendo la consola de FortiClient.'
        Start-Process explorer.exe -ArgumentList "`"$($Cfg.fortiClientExe)`"" | Out-Null
        $h = Buscar-Consola 40
    }
    if ($h -eq [IntPtr]::Zero) { Salir 4 @{ mensaje = 'No se encuentra la ventana de la consola de FortiClient' } }
    [void][VpnForti.Ui]::AlFrente($h)
    return $h
}

function Leer-Pantalla([IntPtr]$h) {
    $nodos = [VpnForti.Ui]::Arbol($h)
    $editables = @($nodos | Where-Object { $_.Rol -eq 42 -and $_.Enfocable -and -not $_.Invisible })
    $botones = @($nodos | Where-Object { $_.Rol -eq 43 -and -not $_.Invisible })
    [pscustomobject]@{
        Nodos       = $nodos
        Combo       = $nodos | Where-Object { $_.Rol -eq 46 } | Select-Object -First 1
        Usuario     = $editables | Where-Object { $_.Nombre -match '^(Nombre de Usuario|Username|User ?name)$' } | Select-Object -First 1
        Clave       = $editables | Where-Object { $_.Protegido -and $_.Nombre -match '^(Contraseña|Password)$' } | Select-Object -First 1
        Conectar    = $botones | Where-Object { $_.Nombre -match '^(Conectar|Connect)$' } | Select-Object -First 1
        Desconectar = $botones | Where-Object { $_.Nombre -match '^(Desconectar|Disconnect)$' } | Select-Object -First 1
        Token       = $editables | Where-Object { $_.Nombre -notmatch '^(Nombre de Usuario|Username|User ?name|Contraseña|Password)$' -and ($_.Nombre -match $Cfg.regexCampoToken -or -not $_.Nombre) } | Select-Object -First 1
        BotonToken  = $botones | Where-Object { $_.Nombre -match $Cfg.regexBotonToken } | Select-Object -First 1
        Errores     = @($nodos | Where-Object { $_.Rol -eq 41 -and $_.Nombre -and $_.Nombre -match $Cfg.regexErrorForti } | ForEach-Object { $_.Nombre })
    }
}

function Esperar-Pantalla([IntPtr]$h, [int]$Segundos) {
    $limite = (Get-Date).AddSeconds($Segundos)
    do {
        $p = Leer-Pantalla $h
        if ($p.Desconectar -or ($p.Conectar -and $p.Clave)) { return $p }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $limite)
    return $p
}

function Teclear-En([IntPtr]$h, $Nodo, [scriptblock]$Accion) {
    if (-not [VpnForti.Ui]::AlFrente($h)) { Salir 4 @{ mensaje = 'No se puede traer FortiClient al primer plano' } }
    [void][VpnForti.Ui]::Enfocar($Nodo)
    Start-Sleep -Milliseconds 250
    if (-not [VpnForti.Ui]::EstaEnfocado($Nodo)) { Salir 4 @{ mensaje = "No se puede enfocar el campo '$($Nodo.Nombre)'" } }
    [void][VpnForti.Ui]::Vaciar($h)
    & $Accion
}

# ---------------------------------------------------------------- PIN por Outlook web
function Comillas([string]$s) { '"' + (($s -replace '(\\+)$', '$1$1') -replace '"', '\"') + '"' }

function Iniciar-LectorPin {
    if (-not $Cfg.pin.activado) { return $null }
    $node = Get-Command node -ErrorAction SilentlyContinue
    $mjs = Join-Path $Raiz 'pin-outlook.mjs'
    if (-not $node) { Log 'Node no está instalado: modo semiautomático.'; return $null }
    if (-not (Test-Path (Join-Path $Raiz 'node_modules\playwright-core'))) { Log 'Falta playwright-core (npm install): modo semiautomático.'; return $null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node.Source
    $psi.Arguments = (@((Comillas $mjs),
            '--url', (Comillas $Cfg.pin.url), '--canal', (Comillas $Cfg.pin.canal), '--perfil', (Comillas $Cfg.pin.perfil),
            '--filtro', (Comillas $Cfg.pin.filtro), '--regex-pin', (Comillas $Cfg.pin.regexPin),
            '--regex-pin-alternativa', (Comillas $Cfg.pin.regexPinAlternativa),
            '--timeout-seg', ([int]$Cfg.esperaSeg), '--login-timeout-seg', ([int]$Cfg.pin.loginTimeoutSeg),
            '--accion', (Comillas $Cfg.pin.accion)) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.WorkingDirectory = $Raiz
    $p = [System.Diagnostics.Process]::Start($psi)
    $script:LecturaPin = $p.StandardOutput.ReadLineAsync()
    Log 'Lector del PIN (Outlook web) iniciado.'
    return $p
}

function Leer-EventoPin($p) {
    if (-not $p -or -not $script:LecturaPin -or -not $script:LecturaPin.IsCompleted) { return $null }
    $linea = $script:LecturaPin.Result
    if ($null -eq $linea) { $script:LecturaPin = $null; return [pscustomobject]@{ evento = 'fin_proceso' } }
    $script:LecturaPin = $p.StandardOutput.ReadLineAsync()
    try { return ($linea | ConvertFrom-Json) } catch { return $null }
}

function Parar-LectorPin($p) {
    if (-not $p) { return }
    try { if (-not $p.HasExited) { $p.StandardInput.WriteLine('fin'); $p.StandardInput.Flush() } } catch { }
    if (-not $p.WaitForExit(5000)) { Cerrar-Proceso $p }
}

# ---------------------------------------------------------------- conectar
function Conectar {
    $inicio = Get-Date
    $e = Get-Estado
    if ($e.conectada) { Salir 0 (Unir $e @{ mensaje = 'Ya estaba conectada' }) }

    # Evita que dos apps lancen la reconexión a la vez: la segunda espera a la primera.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\vpn-forti-conectar')
    $tengo = $false
    try { $tengo = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $tengo = $true }
    if (-not $tengo) {
        Log 'Otra instancia está conectando; espero a que termine.'
        try { [void]$mutex.WaitOne([int]$Cfg.esperaSeg * 1000) } catch [System.Threading.AbandonedMutexException] { }
        $e = Get-Estado
        if ($e.conectada) { Salir 0 (Unir $e @{ mensaje = 'Conectada por otra instancia' }) }
        Salir 2 (Unir $e @{ mensaje = 'La otra instancia no llegó a conectar' })
    }

    $lector = $null; $ventanita = $null
    try {
        $cred = Resolver-Credencial
        Log "Credencial: '$($cred.target)' (usuario $($cred.usuario))."
        $h = Abrir-Consola
        $pan = Esperar-Pantalla $h 20
        if ($pan.Desconectar) { Log 'La consola ya muestra la VPN conectada; espero al DNS.' }
        elseif (-not ($pan.Conectar -and $pan.Clave -and $pan.Combo)) {
            Salir 4 @{ mensaje = 'No se encuentra el formulario de conexión (Nombre de VPN, Contraseña, Conectar). Ejecuta "vpn.ps1 volcar" para diagnosticar.' }
        } else {
            $auto = $false
            if ($Cfg.pin.activado -and -not $NoPulsar) {
                Mostrar-Notificacion 'VPN' 'Reconectando VPN…'
                $lector = Iniciar-LectorPin
                if ($lector) {
                    # Hay que tener la bandeja cargada (línea base) antes de pulsar Conectar.
                    $limite = (Get-Date).AddSeconds([int]$Cfg.pin.loginTimeoutSeg + 60)
                    while ((Get-Date) -lt $limite) {
                        $ev = Leer-EventoPin $lector
                        if ($ev -and $ev.evento -eq 'listo') { $auto = $true; break }
                        if ($ev -and $ev.evento -eq 'login_necesario') { Mostrar-Notificacion 'VPN: inicia sesión en Outlook' 'Se ha abierto Outlook web; inicia sesión y la reconexión seguirá sola.' }
                        if ($ev -and $ev.evento -in 'error', 'fin_proceso') { Log "Lector del PIN: $($ev.evento) $($ev.mensaje)"; break }
                        Start-Sleep -Milliseconds 300
                    }
                    if (-not $auto) { Parar-LectorPin $lector; $lector = $null; Log 'Sin lector del PIN: modo semiautomático.' }
                    else { [void][VpnForti.Ui]::AlFrente($h) }
                }
            }

            # 1) Túnel
            $pan = Leer-Pantalla $h
            $actual = [VpnForti.Ui]::Valor($pan.Combo)
            if ($actual -ne $Cfg.tunel) {
                Log "Seleccionando el túnel '$($Cfg.tunel)' (estaba '$actual')."
                Teclear-En $h $pan.Combo { [void][VpnForti.Ui]::Escribir($h, $Cfg.tunel) }
                Start-Sleep -Milliseconds 500
                $pan = Leer-Pantalla $h
                if ([VpnForti.Ui]::Valor($pan.Combo) -ne $Cfg.tunel) { Salir 4 @{ mensaje = "El túnel '$($Cfg.tunel)' no está en el desplegable de FortiClient" } }
            }
            # 2) Usuario, solo si está vacío
            if ($pan.Usuario -and -not [VpnForti.Ui]::Valor($pan.Usuario)) {
                Log 'Rellenando el usuario.'
                Teclear-En $h $pan.Usuario { [void][VpnForti.Ui]::Escribir($h, $cred.usuario) }
                Start-Sleep -Milliseconds 400
                $pan = Leer-Pantalla $h
                if ([VpnForti.Ui]::Valor($pan.Usuario) -ne $cred.usuario) { Salir 4 @{ mensaje = 'No se ha podido escribir el usuario' } }
            }
            # 3) Contraseña, tecleada directamente desde el Administrador de credenciales
            Log 'Rellenando la contraseña.'
            Teclear-En $h $pan.Clave {
                $n = [VpnForti.Ui]::EscribirSecreto($h, $cred.target)
                if ($n -lt 0) { Salir 4 @{ mensaje = 'Se perdió el primer plano al escribir la contraseña' } }
            }
            Start-Sleep -Milliseconds 400
            $pan = Leer-Pantalla $h
            $len = [VpnForti.Ui]::LongitudProtegido($pan.Clave)
            if ($len -ne $cred.longitud) { Salir 4 @{ mensaje = "La contraseña no ha quedado completa en el campo ($len de $($cred.longitud) caracteres)" } }

            if ($NoPulsar) {
                Teclear-En $h $pan.Clave { }  # vacía de nuevo el campo
                Salir 0 @{ mensaje = 'Formulario preparado sin pulsar Conectar (-NoPulsar); contraseña borrada del campo'; longitudContrasena = $len }
            }

            # 4) Conectar
            Log 'Pulsando Conectar.'
            if (-not [VpnForti.Ui]::AccionPorDefecto($pan.Conectar)) { Salir 4 @{ mensaje = 'No se pudo pulsar Conectar' } }

            # 5) Aviso
            if (-not $auto) {
                Mostrar-Notificacion 'VPN: segundo factor' 'Introduce el código del segundo factor en FortiClient.'
                $ventanita = Abrir-Ventanita 'VPN: introduce el código del segundo factor en FortiClient'
            }
        }

        # 6) Espera: PIN del correo, errores de FortiClient y estado
        $limite = $inicio.AddSeconds([int]$Cfg.esperaSeg)
        $pin = $null; $tokenMetido = $false; $ultimoEstado = [datetime]::MinValue
        while ((Get-Date) -lt $limite) {
            if (((Get-Date) - $ultimoEstado).TotalSeconds -ge 2) {
                $ultimoEstado = Get-Date
                $e = Get-Estado
                if ($e.conectada) {
                    if ($lector -or -not $ventanita) { Mostrar-Notificacion 'VPN' 'VPN conectada' }
                    Salir 0 (Unir $e @{ mensaje = 'VPN conectada'; segundos = [int]((Get-Date) - $inicio).TotalSeconds; pinCorreo = $tokenMetido })
                }
            }
            if ($lector) {
                $ev = Leer-EventoPin $lector
                if ($ev -and $ev.evento -eq 'pin') { $pin = [string]$ev.pin; $ev = $null; Log 'PIN recibido.' }
                elseif ($ev -and $ev.evento -in 'sin_pin', 'error', 'fin_proceso') {
                    Log "No llega el PIN por correo ($($ev.evento)); paso a aviso manual."
                    Parar-LectorPin $lector; $lector = $null
                    Mostrar-Notificacion 'VPN: segundo factor' 'No ha llegado el PIN por correo: introdúcelo en FortiClient.'
                    $ventanita = Abrir-Ventanita 'VPN: introduce el código del segundo factor en FortiClient'
                }
            }
            $pan = Leer-Pantalla $h
            if ($pan.Errores.Count -gt 0 -and -not $pan.Desconectar) {
                Salir 5 @{ mensaje = 'FortiClient muestra un error'; errores = $pan.Errores }
            }
            if ($pin -and -not $tokenMetido -and $pan.Token) {
                Log 'Escribiendo el PIN en FortiClient.'
                Teclear-En $h $pan.Token { [void][VpnForti.Ui]::Escribir($h, $pin) }
                $pin = $null
                Start-Sleep -Milliseconds 300
                $pan = Leer-Pantalla $h
                if ($pan.BotonToken) { [void][VpnForti.Ui]::AccionPorDefecto($pan.BotonToken) } else { [void][VpnForti.Ui]::Pulsar($h, 0x0D, $false) }
                $tokenMetido = $true
            }
            Start-Sleep -Milliseconds 700
        }
        Salir 2 (Unir (Get-Estado) @{ mensaje = "La VPN no se ha conectado en $($Cfg.esperaSeg) s" })
    } finally {
        Parar-LectorPin $lector
        Cerrar-Proceso $ventanita
        try { $mutex.ReleaseMutex() } catch { }
    }
}

# ---------------------------------------------------------------- órdenes
switch ($Orden) {
    'estado' {
        $e = Get-Estado
        Salir ($(if ($e.conectada) { 0 } else { 1 })) $e
    }
    'conectar' { Conectar }
    'asegurar' {
        $e = Get-Estado
        if ($e.conectada) { Salir 0 $e }
        Conectar
    }
    'guardar-credencial' {
        Cargar-Ayudante
        $t = if ($Target) { $Target } else { $TargetPropio }
        $def = if ($Usuario) { $Usuario } else { [VpnForti.Cred]::Usuario('FortiClient', 2) }
        $c = Get-Credential -UserName $def -Message "vpn-forti: usuario y contraseña de la VPN «$($Cfg.tunel)». Se guardan en el Administrador de credenciales ($t)."
        if (-not $c) { Salir 1 @{ mensaje = 'Cancelado' } }
        $u = $c.UserName.TrimStart('\')
        if ($c.Password.Length -eq 0) { Salir 1 @{ mensaje = 'La contraseña está vacía' } }
        [VpnForti.Cred]::Guardar($t, $u, $c.Password)
        $c.Password.Dispose()
        Salir 0 @{ mensaje = 'Credencial guardada'; target = $t; usuario = $u }
    }
    'borrar-credencial' {
        Cargar-Ayudante
        $t = if ($Target) { $Target } else { $TargetPropio }
        $ok = [VpnForti.Cred]::Borrar($t, 1)
        Salir ($(if ($ok) { 0 } else { 1 })) @{ target = $t; borrada = $ok }
    }
    'volcar' {
        Cargar-Ayudante
        $h = Abrir-Consola
        $n = @([VpnForti.Ui]::Arbol($h) | ForEach-Object { [ordered]@{ p = $_.Profundidad; rol = $_.Rol; nombre = $_.Nombre; estado = ('0x{0:X}' -f $_.Estado); rect = "$($_.X),$($_.Y),$($_.W),$($_.H)" } })
        Salir ($(if ($n.Count) { 0 } else { 4 })) @{ nodos = $n }
    }
    'probar-bandeja' {
        $node = (Get-Command node -ErrorAction SilentlyContinue).Source
        if (-not $node) { Salir 1 @{ mensaje = 'Node no está instalado' } }
        $r = & $node (Join-Path $Raiz 'pin-outlook.mjs') --solo-bandeja --url $Cfg.pin.url --canal $Cfg.pin.canal --perfil $Cfg.pin.perfil --filtro $Cfg.pin.filtro --login-timeout-seg $Cfg.pin.loginTimeoutSeg
        $j = $r | Where-Object { $_ -like '{"bandeja"*' } | Select-Object -Last 1
        if ($j) { $o = $j | ConvertFrom-Json; Salir 0 @{ bandeja = $true; canal = $o.canal; host = $o.host; filasQuePasanElFiltro = $o.filasQuePasanElFiltro } }
        Salir 1 @{ bandeja = $false; mensaje = 'No se ha llegado a la bandeja de Outlook web' }
    }
    'probar-pin' {
        $node = (Get-Command node -ErrorAction SilentlyContinue).Source
        if (-not $node) { Salir 1 @{ mensaje = 'Node no está instalado' } }
        & $node (Join-Path $Raiz 'pin-outlook.mjs') --explorar --url $Cfg.pin.url --canal $Cfg.pin.canal --perfil $Cfg.pin.perfil --filtro $Cfg.pin.filtro --regex-pin $Cfg.pin.regexPin --regex-pin-alternativa $Cfg.pin.regexPinAlternativa --login-timeout-seg $Cfg.pin.loginTimeoutSeg
        exit $LASTEXITCODE
    }
    'aviso' {
        $texto = if ($Mensaje) { $Mensaje } else { 'VPN: introduce el código del segundo factor en FortiClient' }
        if ($Ventana) {
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $f = New-Object System.Windows.Forms.Form
            $f.Text = 'vpn-forti'; $f.TopMost = $true; $f.StartPosition = 'CenterScreen'
            $f.Width = 560; $f.Height = 200; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
            $f.BackColor = [System.Drawing.Color]::FromArgb(255, 244, 206)
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $texto; $l.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
            $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'
            $b = New-Object System.Windows.Forms.Button
            $b.Text = 'Cerrar'; $b.Dock = 'Bottom'; $b.Height = 36; $b.Add_Click({ $f.Close() })
            $f.Controls.Add($l); $f.Controls.Add($b)
            $f.Add_Shown({ $f.Activate(); [System.Media.SystemSounds]::Exclamation.Play(); try { [Console]::Beep(880, 250); [Console]::Beep(660, 250) } catch { } })
            [void]$f.ShowDialog()
            exit 0
        }
        Mostrar-Notificacion 'VPN: segundo factor' $texto
        $p = Abrir-Ventanita $texto
        Salir 0 @{ mensaje = 'Aviso mostrado'; pidVentanita = $(if ($p) { $p.Id } else { $null }) }
    }
    default {
        Get-Help $PSCommandPath -Detailed | Out-String | ForEach-Object { [Console]::Error.WriteLine($_) }
        Salir 1 @{ mensaje = 'Orden no indicada. Órdenes: estado, conectar, asegurar, guardar-credencial, borrar-credencial, volcar, probar-bandeja, probar-pin, aviso' }
    }
}
