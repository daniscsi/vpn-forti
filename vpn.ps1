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
    aceptar-certificado  Muestra el certificado del servidor y, si lo confirmas, añade su huella a config.json.
    volcar               Diagnóstico: árbol de accesibilidad de la consola (sin valores de campos).
    probar-bandeja       Diagnóstico: comprueba que Outlook web llega a la bandeja (no abre correos).
    probar-pin           Diagnóstico: lista los correos del PIN de Outlook web (dígitos enmascarados).
    aviso                Prueba el aviso visible (notificación + ventanita + pitido).
    credencial           Comprueba si hay credencial genérica utilizable (0 sí, 3 no). No muestra la contraseña.
    version              Muestra la versión de la herramienta (fichero VERSION).
    instalar-tarea       Una sola vez: registra la tarea programada "vpn-forti-servicio" (privilegios más
                         altos) que arranca el servicio de FortiClient (FA_Scheduler) sin UAC. Pide un UAC
                         esta única vez. Sin la tarea y con el servicio parado, conectar/asegurar/volcar
                         notifican y salen con 7 si los llama una app (salida redirigida); desde una
                         consola visible (doble clic en vpn.cmd) abren FortiClient como antes y sale el UAC.
    desinstalar-tarea    Borra esa tarea programada.

  Por qué hace falta la tarea: tras reiniciar, el servicio FA_Scheduler (inicio manual) está parado
  y un usuario sin elevar no puede arrancarlo; al abrir FortiClient.exe en ese estado, FortiClient
  pide elevación (UAC) para arrancarlo. Con el servicio ya en marcha no la pide.

  El túnel sale de -Tunel, de "tunel" en config.json o, si no, del registro de FortiClient
  (HKLM\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels): si hay varios se usa el primero y se avisa.
  El usuario sale de la credencial guardada.

  Salida: una única línea JSON en stdout. Los mensajes de progreso van a stderr y al log
  %LOCALAPPDATA%\vpn-forti\vpn.log. La contraseña y el PIN nunca se escriben.

  Códigos de salida:
    0 conectada (o la orden ha ido bien)   1 no conectada / error genérico
    2 tiempo agotado                       3 no hay credencial utilizable
    4 no se encuentra la interfaz          5 FortiClient muestra un error al conectar
    6 certificado del servidor inesperado (se pulsa «No» en la alerta de seguridad)
    7 (conectar, asegurar, volcar) el servicio de FortiClient está parado y no hay tarea para
      arrancarlo sin UAC (ejecuta una vez "vpn.ps1 instalar-tarea"), o la tarea no lo ha arrancado
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('estado', 'conectar', 'asegurar', 'guardar-credencial', 'borrar-credencial', 'volcar', 'aceptar-certificado', 'probar-bandeja', 'probar-pin', 'aviso', 'version', 'credencial', 'instalar-tarea', 'desinstalar-tarea', 'ayuda')]
    [string]$Orden = 'ayuda',
    [string]$Tunel,
    [int]$EsperaSeg,
    [string]$Target,
    [string]$Usuario,
    [switch]$SinPinCorreo,
    [switch]$NoPulsar,
    [string]$Mensaje,
    [switch]$Ventana,
    # Internos: los pasa instalar-tarea/desinstalar-tarea al relanzarse elevado.
    [string]$CuentaTarea,
    [string]$FicheroConfig
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---------------------------------------------------------------- configuración
$Raiz = $PSScriptRoot
$DirDatos = Join-Path $env:LOCALAPPDATA 'vpn-forti'
if (-not (Test-Path $DirDatos)) { New-Item -ItemType Directory -Force $DirDatos | Out-Null }
$FicheroLog = Join-Path $DirDatos 'vpn.log'

$Cfg = [ordered]@{
    tunel             = ''
    esperaSeg         = 180
    hostDns           = 'transportistas-desa.portic.net'
    adaptador         = 'Fortinet SSL VPN Virtual Ethernet Adapter'
    credenciales      = @('FortiClient', 'vpn-forti:{tunel}')
    fortiClientExe    = ''
    esperaServicioSeg = 30
    regexErrorForti   = 'incorrect|err[oó]ne|error|fallid|fall[oó]|denegad|denied|failed|inv[aá]lid|no v[aá]lid|caducad|expired'
    regexCampoToken   = 'token|c[oó]digo|code|respuesta|answer|pin'
    regexBotonToken   = '^(OK|Aceptar|Continuar|Enviar|Confirmar|Submit)$'
    certificado       = [ordered]@{ huellas = @('5E6F397764845E5EB3D2AB88A471A9E50F41F659') }
    pin               = [ordered]@{
        activado            = $true
        url                 = 'https://outlook.office.com/mail/?realm=portic.net'
        canal               = 'msedge'
        perfil              = (Join-Path $DirDatos 'perfil-outlook')
        filtro              = 'notification\.fortinet\.net|AuthCode'
        regexPin            = '(?:AuthCode:|token code is)\s*(\d{4,10})\b'
        regexPinAlternativa = '\b(\d{6})\b'
        timeoutSeg          = 120
        loginTimeoutSeg     = 600
        accion              = 'ninguna'
    }
}

$FicheroCfg = if ($FicheroConfig) { $FicheroConfig } elseif ($env:VPN_FORTI_CONFIG) { $env:VPN_FORTI_CONFIG } else { Join-Path $Raiz 'config.json' }
if (Test-Path $FicheroCfg) {
    $json = Get-Content $FicheroCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) {
        if ($p.Name -eq 'pin' -and $p.Value) {
            foreach ($q in $p.Value.PSObject.Properties) { $Cfg.pin[$q.Name] = $q.Value }
        } else { $Cfg[$p.Name] = $p.Value }
    }
}
if ($EsperaSeg -gt 0) { $Cfg.esperaSeg = $EsperaSeg }
if ($SinPinCorreo) { $Cfg.pin.activado = $false }

# Avisos que se añaden a la salida JSON (y al log).
$script:Avisos = New-Object System.Collections.Generic.List[string]
foreach ($k in 'servicioForti', 'tareaServicio') {
    if ($Cfg.Contains($k)) { $script:Avisos.Add("La clave ""$k"" de config.json no se usa: el servicio (FA_Scheduler) y la tarea (vpn-forti-servicio) son fijos.") }
}

# Túnel: -Tunel > config.json > registro de FortiClient (el primero si hay varios).
$ClaveTuneles = 'HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels'
$TunelesRegistro = @()
try { $TunelesRegistro = @(Get-ChildItem $ClaveTuneles -ErrorAction Stop | ForEach-Object { $_.PSChildName } | Sort-Object) } catch { }
if ($Tunel) { $Cfg.tunel = $Tunel }
if (-not $Cfg.tunel) {
    if ($TunelesRegistro.Count -ge 1) {
        $Cfg.tunel = $TunelesRegistro[0]
        if ($TunelesRegistro.Count -gt 1) {
            $script:Avisos.Add("Hay varios túneles en FortiClient ($($TunelesRegistro -join ', ')); se usa '$($Cfg.tunel)'. Indica otro con ""tunel"" en config.json o con -Tunel.")
        }
    }
} elseif ($TunelesRegistro.Count -gt 0 -and $TunelesRegistro -notcontains $Cfg.tunel) {
    $script:Avisos.Add("El túnel '$($Cfg.tunel)' no está en el registro de FortiClient (hay: $($TunelesRegistro -join ', ')).")
}

# FortiClient.exe: config.json o las rutas de instalación habituales.
if (-not $Cfg.fortiClientExe) {
    $cand = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Fortinet\FortiClient\FortiClient.exe' }
    $Cfg.fortiClientExe = @($cand | Where-Object { Test-Path $_ }) + @($cand) | Select-Object -First 1
}

$Targets = @($Cfg.credenciales | Where-Object { $Cfg.tunel -or $_ -notmatch '\{tunel\}' } | ForEach-Object { $_ -replace '\{tunel\}', $Cfg.tunel })
$TargetPropio = if ($Cfg.tunel) { "vpn-forti:$($Cfg.tunel)" } else { 'vpn-forti' }

function Exigir-Tunel {
    if (-not $Cfg.tunel) { Salir 4 @{ mensaje = "No hay ningún túnel configurado en FortiClient ($ClaveTuneles). Crea el túnel en la consola de FortiClient o indica ""tunel"" en config.json." } }
}

# ---------------------------------------------------------------- utilidades
function Log([string]$m) {
    $l = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Orden, $m
    try { [Console]::Error.WriteLine($l) } catch { }
    try { Add-Content -Path $FicheroLog -Value $l -Encoding UTF8 } catch { }
}

function Salir([int]$Codigo, [System.Collections.IDictionary]$Datos) {
    $o = [ordered]@{ orden = $Orden; codigo = $Codigo }
    if ($Datos) { foreach ($k in @($Datos.Keys)) { $o[$k] = $Datos[$k] } }
    if ($script:Avisos.Count -gt 0) { $o['avisos'] = @($script:Avisos) }
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 6))
    exit $Codigo
}

function Unir([System.Collections.IDictionary]$A, [System.Collections.IDictionary]$B) {
    $r = [ordered]@{}
    foreach ($k in @($A.Keys)) { $r[$k] = $A[$k] }
    foreach ($k in @($B.Keys)) { $r[$k] = $B[$k] }
    return $r
}

foreach ($a in $script:Avisos) { Log "Aviso: $a" }

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
function Pedir-Credencial {
    Cargar-Ayudante
    $t = if ($Target) { $Target } else { $TargetPropio }
    $def = $Usuario
    if (-not $def) { foreach ($x in @($Targets) + @($t)) { foreach ($tipo in 1, 2) { if (-not $def) { $def = [VpnForti.Cred]::Usuario($x, $tipo) } } } }
    $c = Get-Credential -UserName $def -Message "vpn-forti: usuario y contraseña de la VPN «$($Cfg.tunel)». Se guardan en el Administrador de credenciales ($t)."
    if (-not $c -or $c.Password.Length -eq 0) { return $null }
    $u = $c.UserName.TrimStart('\')
    [VpnForti.Cred]::Guardar($t, $u, $c.Password)
    $c.Password.Dispose()
    return [ordered]@{ target = $t; usuario = $u }
}

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
    # Primera vez o sin credencial: abre el diálogo y guarda, salvo que se haya desactivado.
    if (-not $script:YaPedida -and [Environment]::UserInteractive -and -not $env:VPN_FORTI_SIN_DIALOGO) {
        $script:YaPedida = $true
        Log 'No hay credencial utilizable; se pide al usuario.'
        if (Pedir-Credencial) { return (Resolver-Credencial) }
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

# ---------------------------------------------------------------- servicio de FortiClient y tarea programada
# FA_Scheduler es de inicio manual y su ACL no deja a un usuario sin elevar arrancarlo. Si está
# parado (tras reiniciar), FortiClient.exe pide elevación (UAC) para arrancarlo. La tarea
# programada, registrada una vez con privilegios más altos, solo ejecuta "sc.exe start FA_Scheduler"
# (ruta y argumentos fijos, nada de scripts del usuario), y el usuario puede lanzarla sin UAC.
# Servicio y tarea son constantes: el proceso elevado no toma nada de config.json.
$ServicioForti = 'FA_Scheduler'
$TareaServicio = 'vpn-forti-servicio'
$ScExe = Join-Path ([Environment]::SystemDirectory) 'sc.exe'
$ArgumentosTarea = "start $ServicioForti"
# Bits que el usuario no debe tener sobre la tarea: escritura de datos/atributos/EA, WRITE_DAC,
# WRITE_OWNER, GENERIC_ALL y GENERIC_WRITE.
$BitsEscritura = 0x2 -bor 0x4 -bor 0x10 -bor 0x100 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000

function Estado-Servicio {
    try { return [string](Get-Service -Name $ServicioForti -ErrorAction Stop).Status } catch { return $null }
}

function Carpeta-Tareas {
    $s = New-Object -ComObject Schedule.Service
    $s.Connect()
    return $s.GetFolder('\')
}

function Obtener-Tarea {
    try { return (Carpeta-Tareas).GetTask($TareaServicio) } catch { return $null }
}

function Problemas-Tarea($t, [string]$Sid) {
    # Lista de motivos por los que la tarea no es la que registra vpn-forti (vacía = correcta).
    $p = New-Object System.Collections.Generic.List[string]
    $d = $t.Definition
    $acc = @($d.Actions)
    if ($acc.Count -ne 1 -or $acc[0].Type -ne 0 -or $acc[0].Path -ne $ScExe -or $acc[0].Arguments -ne $ArgumentosTarea) {
        $p.Add("la acción no es exactamente '$ScExe $ArgumentosTarea'")
    }
    if ($d.Principal.RunLevel -ne 1) { $p.Add('no tiene privilegios más altos') }
    $sddl = $null
    try { $sddl = $t.GetSecurityDescriptor(5) } catch { $p.Add("no se puede leer su seguridad: $($_.Exception.Message)"); return $p }
    $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor($sddl)
    if (-not $sd.Owner -or $sd.Owner.Value -ne 'S-1-5-32-544') { $p.Add("el propietario no es Administradores (O:BA): $sddl") }
    $confiables = @('S-1-5-18', 'S-1-5-32-544')
    foreach ($ace in @($sd.DiscretionaryAcl)) {
        if ($ace.AceQualifier -ne [System.Security.AccessControl.AceQualifier]::AccessAllowed) { continue }
        $quien = $ace.SecurityIdentifier.Value
        if ($confiables -contains $quien) { continue }
        if (($ace.AccessMask -band $BitsEscritura) -ne 0) { $p.Add("$quien tiene permiso de escritura (0x{0:X}): $sddl" -f $ace.AccessMask) }
    }
    if ($Sid -and -not (@($sd.DiscretionaryAcl) | Where-Object { $_.SecurityIdentifier.Value -eq $Sid })) { $p.Add("el usuario ($Sid) no tiene permiso para lanzarla") }
    return $p
}

function Info-Tarea {
    $t = Obtener-Tarea
    if (-not $t) { return [ordered]@{ instalada = $false; nombre = $TareaServicio } }
    $d = $t.Definition
    $acc = @($d.Actions | ForEach-Object { "$($_.Path) $($_.Arguments)".Trim() })
    $ult = if ($t.LastRunTime -and $t.LastRunTime.Year -gt 2000) { $t.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return [ordered]@{
        instalada        = $true
        nombre           = $TareaServicio
        privilegiosAltos = [bool]($d.Principal.RunLevel -eq 1)
        cuenta           = $d.Principal.UserId
        accion           = $acc
        ultimaEjecucion  = $ult
        ultimoResultado  = ('0x{0:X}' -f [int]$t.LastTaskResult)
        seguridad        = $(try { $t.GetSecurityDescriptor(5) } catch { $null })
        problemas        = @(Problemas-Tarea $t $sid)
    }
}

function Consola-Interactiva {
    # Doble clic en vpn.cmd o llamada desde una consola: la salida va a la pantalla. Las apps la capturan.
    try { return [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected } catch { return $false }
}

function Asegurar-Servicio {
    $st = Estado-Servicio
    if ($null -eq $st) { Log "No existe el servicio '$ServicioForti'; se abre FortiClient sin comprobarlo."; return }
    if ($st -eq 'Running') { return }
    $base = [ordered]@{ servicio = $ServicioForti; estadoServicio = $st; tarea = $TareaServicio }
    $t = Obtener-Tarea
    if (-not $t) {
        $aviso = 'Falta la tarea de vpn-forti: ejecuta una vez «vpn.cmd instalar-tarea» (un único UAC) para que no vuelva a salir el UAC.'
        if (Consola-Interactiva) {
            # Hay alguien delante: como antes, FortiClient pedirá el UAC y se acepta a mano.
            Log "El servicio '$ServicioForti' está $st y no hay tarea: FortiClient pedirá el UAC (acéptalo). $aviso"
            Mostrar-Notificacion 'VPN: acepta el UAC de FortiClient' $aviso
            $script:Avisos.Add($aviso)
            return
        }
        Mostrar-Notificacion 'VPN: falta la tarea de vpn-forti' $aviso
        Salir 7 (Unir $base @{ tareaInstalada = $false; mensaje = "El servicio de FortiClient ($ServicioForti) está parado y FortiClient pediría permiso de administrador (UAC) para arrancarlo. Ejecuta una vez ``vpn.cmd instalar-tarea`` (acepta ese UAC) y no volverá a salir." })
    }
    Log "El servicio '$ServicioForti' está $st; lo arranco con la tarea '$TareaServicio'."
    try { [void]$t.Run($null) } catch {
        Salir 7 (Unir $base @{ tareaInstalada = $true; mensaje = "No se ha podido lanzar la tarea '$TareaServicio': $($_.Exception.Message). Vuelve a registrarla con ``vpn.cmd instalar-tarea``." })
    }
    $limite = (Get-Date).AddSeconds([int]$Cfg.esperaServicioSeg)
    do {
        Start-Sleep -Milliseconds 500
        $st = Estado-Servicio
        if ($st -eq 'Running') { Log 'Servicio de FortiClient arrancado.'; Start-Sleep -Seconds 2; return }
    } while ((Get-Date) -lt $limite)
    $res = $(try { '0x{0:X}' -f [int](Obtener-Tarea).LastTaskResult } catch { $null })
    Salir 7 (Unir $base @{ estadoServicio = $st; tareaInstalada = $true; ultimoResultado = $res; mensaje = "La tarea '$TareaServicio' no ha arrancado el servicio $ServicioForti en $($Cfg.esperaServicioSeg) s." })
}

function Es-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Relanzar-Elevado([string]$OrdenElevada) {
    # Un único UAC, aceptado a mano. La salida del proceso elevado va al log (mismo usuario);
    # se devuelve su código de salida.
    $cuenta = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"", $OrdenElevada,
        '-CuentaTarea', "`"$cuenta`"", '-FicheroConfig', "`"$([IO.Path]::GetFullPath($FicheroCfg))`"")
    Log "Relanzo '$OrdenElevada' elevado (aparecerá el Control de cuentas de usuario una vez)."
    try { $p = Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList $a -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop }
    catch { Salir 1 @{ mensaje = 'Cancelado: no se ha aceptado el Control de cuentas de usuario (UAC)' } }
    return [int]$p.ExitCode
}

function Registrar-Tarea {
    # Solo en el proceso elevado.
    if ($null -eq (Estado-Servicio)) { Salir 4 @{ mensaje = "No existe el servicio '$ServicioForti' (¿está instalado FortiClient?)" } }
    $cuenta = if ($CuentaTarea) { $CuentaTarea } else { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    $sid = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value
    $s = New-Object -ComObject Schedule.Service
    $s.Connect()
    $d = $s.NewTask(0)
    $d.RegistrationInfo.Author = 'vpn-forti'
    $d.RegistrationInfo.Description = "vpn-forti: arranca el servicio de FortiClient ($ServicioForti) sin UAC. Solo ejecuta sc.exe start. Se borra con «vpn.ps1 desinstalar-tarea»."
    $d.Principal.UserId = $cuenta
    $d.Principal.LogonType = 3          # TASK_LOGON_INTERACTIVE_TOKEN: solo con la sesión abierta
    $d.Principal.RunLevel = 1           # TASK_RUNLEVEL_HIGHEST
    $d.Settings.Enabled = $true
    $d.Settings.AllowDemandStart = $true
    $d.Settings.DisallowStartIfOnBatteries = $false
    $d.Settings.StopIfGoingOnBatteries = $false
    $d.Settings.ExecutionTimeLimit = 'PT2M'
    $d.Settings.MultipleInstances = 2   # TASK_INSTANCES_IGNORE_NEW
    $act = $d.Actions.Create(0)
    $act.Path = $ScExe
    $act.Arguments = $ArgumentosTarea
    # Propietario Administradores; SYSTEM y Administradores, control total; el usuario, leer,
    # ejecutar y borrar (no modificar: nada sin elevar puede cambiar la acción de una tarea elevada).
    $sddl = "O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGXSD;;;$sid)"
    $carpeta = Carpeta-Tareas
    # Se borra antes y se crea (flag 2, TASK_CREATE): nunca se reutiliza una tarea ya existente.
    if (Obtener-Tarea) { $carpeta.DeleteTask($TareaServicio, 0); Log "Tarea '$TareaServicio' anterior borrada." }
    [void]$carpeta.RegisterTaskDefinition($TareaServicio, $d, 2, $cuenta, $null, 3, $sddl)
    $t = Obtener-Tarea
    $prob = if ($t) { @(Problemas-Tarea $t $sid) } else { @('no aparece tras registrarla') }
    if ($prob.Count -gt 0) {
        if ($t) { try { $carpeta.DeleteTask($TareaServicio, 0) } catch { } }
        Log "Tarea '$TareaServicio' rechazada y borrada: $($prob -join '; ')"
        Salir 1 @{ mensaje = 'La tarea registrada no es la esperada; se ha borrado'; problemas = $prob }
    }
    Log "Tarea '$TareaServicio' registrada y comprobada para $cuenta."
}

function Abrir-Consola {
    Cargar-Ayudante
    $h = Buscar-Consola 1
    if ($h -ne [IntPtr]::Zero) {
        # Sin --force-renderer-accessibility la consola (Electron) no expone el formulario por MSAA
        # en algunos PC: se cierra y se vuelve a abrir con el flag.
        $sinFlag = @(Get-CimInstance Win32_Process -Filter "Name='FortiClient.exe'" | Where-Object { $_.CommandLine -notmatch 'force-renderer-accessibility' -and $_.CommandLine -notmatch '--type=(crashpad|gpu|utility)' })
        $conFlag = @(Get-CimInstance Win32_Process -Filter "Name='FortiClient.exe'" | Where-Object { $_.CommandLine -match 'force-renderer-accessibility' })
        if ($conFlag.Count -eq 0 -and $sinFlag.Count -gt 0) {
            Log 'Reabriendo la consola de FortiClient con accesibilidad forzada.'
            Get-Process FortiClient -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $h = [IntPtr]::Zero
        }
    }
    if ($h -eq [IntPtr]::Zero) {
        # Con el servicio parado FortiClient.exe pediría UAC: se arranca antes con la tarea.
        Asegurar-Servicio
        # Lanzado directamente desde otro proceso, FortiClient.exe sale con 0 sin abrir ventana;
        # a través del Explorador sí se abre (como un doble clic), y con un acceso directo admite argumentos.
        Log 'Abriendo la consola de FortiClient.'
        $lnk = Join-Path $env:TEMP 'vpn-forti-consola.lnk'
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $sc.TargetPath = $Cfg.fortiClientExe; $sc.Arguments = '--force-renderer-accessibility'; $sc.Save()
        Start-Process explorer.exe -ArgumentList "`"$lnk`"" | Out-Null
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
# ---------------------------------------------------------------- certificado del servidor
function Servidor-Tunel {
    $clave = "HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\$($Cfg.tunel)"
    try { $s = (Get-ItemProperty $clave -ErrorAction Stop).Server } catch { return $null }
    if ($s -notmatch '^(?<h>[^:]+)(:(?<p>\d+))?$') { return $null }
    $puerto = if ($Matches.p) { [int]$Matches.p } else { 443 }
    return [pscustomobject]@{ host = $Matches.h; puerto = $puerto; texto = $s }
}

function Leer-Certificado {
    $srv = Servidor-Tunel
    if (-not $srv) { Log 'No se encuentra el servidor del túnel en el registro.'; return $null }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($srv.host, $srv.puerto, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(8000)) { throw "Sin respuesta de $($srv.texto)" }
        $tcp.EndConnect($iar)
        # Se acepta cualquier certificado solo para poder leerlo; la decisión se toma con la huella.
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, ([System.Net.Security.RemoteCertificateValidationCallback] { $true }))
        $ssl.ReadTimeout = 8000; $ssl.WriteTimeout = 8000
        $ssl.AuthenticateAsClient($srv.host)
        $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $cadenaValida = (New-Object System.Security.Cryptography.X509Certificates.X509Chain).Build($c)
        $ssl.Dispose()
        return [pscustomobject]@{
            servidor = $srv.texto; sujeto = $c.Subject; emisor = $c.Issuer; huella = $c.Thumbprint.ToUpper()
            caduca = $c.NotAfter.ToString('yyyy-MM-dd'); cadenaValida = [bool]$cadenaValida
            comodinPortic = [bool]($c.Subject -match '(^|,\s*)CN=\*\.portic\.net(,|$)')
        }
    } catch { Log "No se pudo leer el certificado: $($_.Exception.Message)"; return $null }
    finally { $tcp.Close() }
}

function Huellas-Aceptadas { @($Cfg.certificado.huellas | ForEach-Object { ([string]$_).ToUpper() -replace '[^0-9A-F]', '' }) }

function Buscar-AlertaSeguridad {
    # Diálogo Win32 (#32770) «Alerta de seguridad» que abre FortiTray al conectar por IP.
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $A = [System.Windows.Automation.AutomationElement]
    foreach ($w in $A::RootElement.FindAll('Children', [System.Windows.Automation.Condition]::TrueCondition)) {
        try {
            if ($w.Current.ClassName -ne '#32770' -or $w.Current.Name -notmatch '^(Alerta de seguridad|Security Alert)$') { continue }
            $proc = (Get-Process -Id $w.Current.ProcessId -ErrorAction Stop).ProcessName
            if ($proc -match '^Forti') { return [IntPtr]$w.Current.NativeWindowHandle }
        } catch { }
    }
    return [IntPtr]::Zero
}

function Resolver-AlertaSeguridad([IntPtr]$dlg) {
    # Botones de dibujo propio: id 1 = «Sí», id 2 = «No».
    $c = Leer-Certificado
    if ($c -and (Huellas-Aceptadas) -contains $c.huella) {
        Log "Alerta de seguridad: certificado conocido ($($c.sujeto), $($c.huella)); pulso «Sí»."
        [void][VpnForti.Ui]::PulsarBotonDialogo($dlg, 1)
        return $c
    }
    Log 'Alerta de seguridad con certificado no aceptado; pulso «No».'
    [void][VpnForti.Ui]::PulsarBotonDialogo($dlg, 2)
    if (-not $c) {
        Mostrar-Notificacion 'VPN: certificado' 'No se ha podido comprobar el certificado del servidor; conexión cancelada.'
        Salir 6 @{ mensaje = 'certificado inesperado: no se ha podido leer el certificado del servidor' }
    }
    $renovado = $c.comodinPortic -and $c.cadenaValida
    $msg = if ($renovado) { "certificado renovado: $($c.sujeto) $($c.huella). Revísalo y acéptalo con «vpn.cmd aceptar-certificado»" } else { "certificado inesperado: $($c.sujeto) $($c.huella)" }
    Mostrar-Notificacion 'VPN: certificado' $msg
    [void](Abrir-Ventanita "VPN: $msg")
    Salir 6 @{ mensaje = $msg; certificado = $c; renovado = $renovado }
}

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
                    Mostrar-Notificacion 'VPN' 'VPN conectada'
                    Salir 0 (Unir $e @{ mensaje = 'VPN conectada'; segundos = [int]((Get-Date) - $inicio).TotalSeconds; pinCorreo = $tokenMetido })
                }
            }
            if ($lector) {
                $ev = Leer-EventoPin $lector
                if ($ev -and $ev.evento -eq 'pin') {
                    $pin = [string]$ev.pin; $ev = $null; Log 'PIN recibido.'
                    Parar-LectorPin $lector; $lector = $null   # ya ha terminado su trabajo
                }
                elseif ($ev -and $ev.evento -in 'sin_pin', 'error', 'fin_proceso') {
                    Log "No llega el PIN por correo ($($ev.evento)); paso a aviso manual."
                    Parar-LectorPin $lector; $lector = $null
                    Mostrar-Notificacion 'VPN: segundo factor' 'No ha llegado el PIN por correo: introdúcelo en FortiClient.'
                    $ventanita = Abrir-Ventanita 'VPN: introduce el código del segundo factor en FortiClient'
                }
            }
            $dlg = Buscar-AlertaSeguridad
            if ($dlg -ne [IntPtr]::Zero) {
                [void](Resolver-AlertaSeguridad $dlg)
                Start-Sleep -Milliseconds 800
                continue
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
        $e['servicioForti'] = [ordered]@{ nombre = $ServicioForti; estado = (Estado-Servicio) }
        $e['tareaServicio'] = $(try { Info-Tarea } catch { [ordered]@{ nombre = $TareaServicio; error = $_.Exception.Message } })
        Salir ($(if ($e.conectada) { 0 } else { 1 })) $e
    }
    'instalar-tarea' {
        if (-not (Es-Admin)) {
            $rc = Relanzar-Elevado 'instalar-tarea'
            $i = $(try { Info-Tarea } catch { [ordered]@{ nombre = $TareaServicio; error = $_.Exception.Message } })
            if ($rc -ne 0) { Salir $rc @{ mensaje = "El proceso elevado ha salido con $rc (detalle en $FicheroLog)"; tareaServicio = $i } }
            if ($i.instalada -and @($i.problemas).Count -eq 0) { Salir 0 @{ mensaje = 'Tarea instalada: el servicio de FortiClient se arrancará sin UAC'; tareaServicio = $i } }
            Salir 1 @{ mensaje = "La tarea no ha quedado bien registrada (detalle en $FicheroLog)"; tareaServicio = $i }
        }
        try { Registrar-Tarea } catch { Log "Error al registrar la tarea: $($_.Exception.Message)"; Salir 1 @{ mensaje = "Error al registrar la tarea: $($_.Exception.Message)" } }
        Salir 0 @{ mensaje = 'Tarea instalada'; tareaServicio = (Info-Tarea) }
    }
    'desinstalar-tarea' {
        if (-not (Obtener-Tarea)) { Salir 0 @{ mensaje = 'La tarea no estaba instalada'; tarea = $TareaServicio; borrada = $false } }
        try { (Carpeta-Tareas).DeleteTask($TareaServicio, 0) } catch {
            Log "No se pudo borrar la tarea sin elevar: $($_.Exception.Message)"
            if (Es-Admin) { Salir 1 @{ mensaje = "No se pudo borrar la tarea: $($_.Exception.Message)" } }
            $rc = Relanzar-Elevado 'desinstalar-tarea'
            if ($rc -ne 0 -and (Obtener-Tarea)) { Salir $rc @{ mensaje = "El proceso elevado ha salido con $rc (detalle en $FicheroLog)"; tarea = $TareaServicio; borrada = $false } }
        }
        $sigue = [bool](Obtener-Tarea)
        Salir ($(if ($sigue) { 1 } else { 0 })) @{ tarea = $TareaServicio; borrada = -not $sigue }
    }
    'conectar' { Exigir-Tunel; Conectar }
    'asegurar' {
        $e = Get-Estado
        if ($e.conectada) { Salir 0 $e }
        Exigir-Tunel
        Conectar
    }
    'guardar-credencial' {
        Exigir-Tunel
        $r = Pedir-Credencial
        if (-not $r) { Salir 1 @{ mensaje = 'Cancelado o contraseña vacía' } }
        Salir 0 @{ mensaje = 'Credencial guardada'; target = $r.target; usuario = $r.usuario }
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
    'aceptar-certificado' {
        Exigir-Tunel
        Cargar-Ayudante
        $c = Leer-Certificado
        if (-not $c) { Salir 1 @{ mensaje = 'No se ha podido leer el certificado del servidor' } }
        if ((Huellas-Aceptadas) -contains $c.huella) { Salir 0 @{ mensaje = 'El certificado ya estaba aceptado'; certificado = $c } }
        Add-Type -AssemblyName System.Windows.Forms
        $texto = "Servidor: $($c.servidor)`nSujeto: $($c.sujeto)`nEmisor: $($c.emisor)`nHuella SHA1: $($c.huella)`nCaduca: $($c.caduca)`nCadena válida: $(if ($c.cadenaValida) { 'sí' } else { 'NO' })`n`n¿Aceptar este certificado para la VPN?"
        $r = [System.Windows.Forms.MessageBox]::Show($texto, 'vpn-forti: aceptar certificado', 'YesNo', 'Question', 'Button2', 'DefaultDesktopOnly')
        if ($r -ne 'Yes') { Salir 1 @{ mensaje = 'No aceptado'; certificado = $c } }
        $fichero = $FicheroCfg
        $obj = if (Test-Path $fichero) { Get-Content $fichero -Raw -Encoding UTF8 | ConvertFrom-Json } else { New-Object psobject }
        if (-not $obj.PSObject.Properties['certificado']) { $obj | Add-Member certificado ([pscustomobject]@{ huellas = @() }) }
        $obj.certificado.huellas = @(@(Huellas-Aceptadas) + $c.huella | Select-Object -Unique)
        [IO.File]::WriteAllText($fichero, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        Salir 0 @{ mensaje = "Certificado añadido a $fichero"; certificado = $c }
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
    'credencial' {
        $c = Resolver-Credencial
        Salir 0 @{ credencial = $true; target = $c.target; usuario = $c.usuario }
    }
    'version' {
        $fv = Join-Path $Raiz 'VERSION'
        $v = if (Test-Path $fv) { (Get-Content $fv -Raw -Encoding UTF8).Trim() } else { $null }
        if (-not $v) { Salir 1 @{ mensaje = 'No se encuentra el fichero VERSION' } }
        Salir 0 ([ordered]@{ version = $v; ruta = $PSCommandPath; tunel = $(if ($Cfg.tunel) { $Cfg.tunel } else { $null }); tunelesRegistro = $TunelesRegistro })
    }
    default {
        Get-Help $PSCommandPath -Detailed | Out-String | ForEach-Object { [Console]::Error.WriteLine($_) }
        Salir 1 @{ mensaje = 'Orden no indicada. Órdenes: estado, conectar, asegurar, guardar-credencial, borrar-credencial, aceptar-certificado, volcar, probar-bandeja, probar-pin, aviso, version, credencial, instalar-tarea, desinstalar-tarea' }
    }
}
