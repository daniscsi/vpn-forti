# Diagnóstico de vpn-forti (vpn.cmd diagnosticar): solo lectura. Reúne el estado del equipo en comprobaciones
# ok / aviso / error, con el usuario y los datos personales enmascarados, para que se pueda enviar tal cual.
#
# Solo funciones: no ejecuta nada al cargarse. Lo cargan vpn.ps1 y las pruebas (pruebas\pruebas.ps1) con punto.
# Usan, de vpn.ps1: $Cfg, $Raiz, $DirDatos, $FicheroLog, $TunelesRegistro, $Targets, $ServicioForti, $TareaServicio,
# Get-Estado, Estado-Servicio, Info-Tarea, Cargar-Ayudante, Obtener-ProcesosForti (Consola.ps1).
# NUNCA incluye contraseñas, PIN ni contenido del correo; de la credencial solo dice si existe.

# ---------------------------------------------------------------- funciones puras
function Nuevo-Chequeo([string]$Id, [string]$Estado, [string]$Detalle, $Datos = $null) {
    $c = [ordered]@{ id = $Id; estado = $Estado; detalle = $Detalle }
    if ($null -ne $Datos) { $c['datos'] = $Datos }
    return [pscustomobject]$c
}

function Evaluar-VersionForti([string]$Version) {
    # FortiClient 7.0: es la que automatiza vpn-forti. Otra versión solo avisa.
    if (-not $Version) { return [pscustomobject]@{ estado = 'error'; detalle = 'no se ha podido leer la versión de FortiClient.exe'; es70 = $false } }
    $es70 = [bool]($Version -match '^7\.0(\.|$)')
    if ($es70) { return [pscustomobject]@{ estado = 'ok'; detalle = "$Version (7.0)"; es70 = $true } }
    return [pscustomobject]@{ estado = 'aviso'; detalle = "${Version}: vpn-forti está probado con FortiClient 7.0"; es70 = $false }
}

function Info-Ruta([string]$Ruta) {
    # Se calcula ANTES de enmascarar: el usuario puede aparecer en la ruta.
    return [pscustomobject]@{
        onedrive = [bool]($Ruta -match 'OneDrive')
        noAscii  = [bool]($Ruta -match '[^\x00-\x7F]')
        corto83  = [bool]($Ruta -match '~\d')
        longitud = $Ruta.Length
    }
}

function Es-AdministradorLocal([string[]]$Sids) {
    # El grupo Administradores (S-1-5-32-544) está en el token aunque sea «solo para denegar» (UAC sin elevar).
    return [bool](@($Sids) -contains 'S-1-5-32-544')
}

function Obtener-SidsToken {
    # WindowsIdentity.Groups no lista los grupos «solo para denegar»; whoami /groups sí.
    try {
        $filas = @(& whoami.exe /groups /fo csv /nh 2>$null | ConvertFrom-Csv -Header nombre, tipo, sid, atributos)
        return @($filas | ForEach-Object { $_.sid } | Where-Object { $_ })
    } catch { return @() }
}

function Es-Elevado {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return [bool]$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Obtener-NombresPrivados([string[]]$Extra = @()) {
    # Usuario (largo y 8.3), equipo y los que se pasen (usuario de la credencial) para enmascarar.
    $u = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($env:USERNAME) + @($Extra)) { if ($n) { $u.Add(([string]$n).Trim('\')) } }
    try { $id = [Security.Principal.WindowsIdentity]::GetCurrent().Name; if ($id) { $u.Add(($id -split '\\')[-1]) } } catch { }
    if ($env:USERPROFILE) {
        $u.Add((Split-Path -Leaf $env:USERPROFILE))
        try { $u.Add((New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:USERPROFILE).ShortName) } catch { }
    }
    foreach ($ruta in @($env:TEMP, $env:TMP, $env:LOCALAPPDATA, $env:APPDATA)) {
        if ($ruta -match '(?i)\\Users\\([^\\]+)\\') { $u.Add($Matches[1]) }
    }
    return [pscustomobject]@{
        usuarios = @($u | Where-Object { $_ } | Select-Object -Unique)
        equipos  = @($env:COMPUTERNAME | Where-Object { $_ })
    }
}

function Enmascarar-Texto([string]$Texto, [string[]]$Usuarios = @(), [string[]]$Equipos = @()) {
    # Correos, SID, nombres de usuario/equipo y PIN. Los nombres de menos de 3 letras no se enmascaran
    # (se llevarían por delante medio texto).
    if (-not $Texto) { return $Texto }
    $t = $Texto
    $t = [regex]::Replace($t, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '<correo>')
    $t = [regex]::Replace($t, 'S-1-(?:5-21|12-1)(?:-\d+){3,5}', '<sid>')
    $t = [regex]::Replace($t, '(?i)(AuthCode:|token code is)\s*\d+', '$1 <pin>')
    $nombres = @($Usuarios | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Select-Object -Unique | Sort-Object { $_.Length } -Descending)
    foreach ($n in $nombres) { $t = [regex]::Replace($t, [regex]::Escape($n), '<usuario>', 'IgnoreCase') }
    $maq = @($Equipos | Where-Object { $_ -and $_.Trim().Length -ge 3 } | Select-Object -Unique)
    foreach ($n in $maq) { $t = [regex]::Replace($t, [regex]::Escape($n), '<equipo>', 'IgnoreCase') }
    return $t
}

function Resumir-Chequeos($Chequeos) {
    $l = @($Chequeos)
    return [ordered]@{
        ok     = @($l | Where-Object { $_.estado -eq 'ok' }).Count
        avisos = @($l | Where-Object { $_.estado -eq 'aviso' }).Count
        errores = @($l | Where-Object { $_.estado -eq 'error' }).Count
    }
}

function Formatear-InformeDiagnostico($Diag) {
    # Texto legible (diagnostico.txt y stderr) a partir del objeto ya enmascarado.
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("vpn-forti $($Diag.version) - diagnóstico del $($Diag.fecha)")
    $r = $Diag.resumen
    $l.Add("Resumen: $($r.ok) correctas, $($r.avisos) avisos, $($r.errores) errores")
    $l.Add('')
    foreach ($c in @($Diag.comprobaciones)) {
        $et = switch ($c.estado) { 'ok' { '[ OK  ]' } 'aviso' { '[AVISO]' } 'error' { '[ERROR]' } default { '[  ?  ]' } }
        $l.Add(('{0} {1,-22} {2}' -f $et, $c.id, $c.detalle))
    }
    if ($Diag.arranque) {
        $a = $Diag.arranque
        $l.Add('')
        $l.Add("Última prueba de arranque de la consola ($($a.fecha)): modo elegido = $(if ($a.modoElegido) { $a.modoElegido } else { 'ninguno' })$(if ($a.omitida) { ", omitida ($($a.motivo))" })")
        foreach ($m in @($a.resultados)) {
            $l.Add(("  modo {0} ({1}): {2}{3}{4}" -f $m.modo, $m.nombre, $m.resultado, $(if ($null -ne $m.formulario) { ", formulario=$($m.formulario)" } else { '' }), $(if ($m.detalle) { " - $($m.detalle)" } else { '' })))
        }
    }
    $l.Add('')
    $l.Add('Últimos mensajes de vpn.log:')
    foreach ($x in @($Diag.log)) { $l.Add("  $x") }
    return ($l -join "`r`n")
}

# ---------------------------------------------------------------- recogida de datos (solo lectura)
function Buscar-AccesoInicioForti {
    # Acceso directo de FortiClient del menú Inicio: la referencia que sí funciona con doble clic.
    $dirs = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs") | Where-Object { $_ -and (Test-Path $_) }
    $sh = New-Object -ComObject WScript.Shell
    foreach ($d in $dirs) {
        foreach ($f in @(Get-ChildItem -Path $d -Filter '*Forti*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
            $s = $sh.CreateShortcut($f.FullName)
            if ($s.TargetPath -match 'FortiClient\.exe$') {
                return [pscustomobject]@{ ruta = $f.FullName; destino = $s.TargetPath; argumentos = $s.Arguments; carpetaTrabajo = $s.WorkingDirectory }
            }
        }
    }
    return $null
}

function Version-Windows {
    try {
        $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return "$($o.Caption) $($o.Version)"
    } catch { return [string][Environment]::OSVersion.VersionString }
}

function Obtener-Diagnostico {
    param([string]$Version, [string]$FicheroArranque)
    $c = New-Object System.Collections.Generic.List[object]
    $exe = [string]$Cfg.fortiClientExe
    $dirForti = if ($exe) { Split-Path -Parent $exe } else { '' }
    $existeExe = [bool]($exe -and (Test-Path $exe))

    # --- sistema
    $psv = $PSVersionTable.PSVersion.ToString()
    $cult = (Get-Culture).Name
    $c.Add((Nuevo-Chequeo 'sistema' 'ok' "$(Version-Windows); PowerShell $psv; cultura $cult" ([ordered]@{ powershell = $psv; cultura = $cult })))

    # --- FortiClient: versión y recursos
    if (-not $existeExe) {
        $c.Add((Nuevo-Chequeo 'forticlient.version' 'error' "no se encuentra FortiClient.exe ($exe)"))
    } else {
        $v = $null
        try { $v = (Get-Item $exe).VersionInfo.ProductVersion } catch { }
        $ev = Evaluar-VersionForti $v
        $c.Add((Nuevo-Chequeo 'forticlient.version' $ev.estado $ev.detalle ([ordered]@{ version = $v; es70 = $ev.es70; exe = $exe })))
        $asar = Join-Path $dirForti 'resources\app.asar'
        if (Test-Path $asar) { $c.Add((Nuevo-Chequeo 'forticlient.asar' 'ok' "resources\app.asar presente ($([int]((Get-Item $asar).Length / 1MB)) MB)")) }
        else { $c.Add((Nuevo-Chequeo 'forticlient.asar' 'error' 'falta resources\app.asar: la consola no es la de FortiClient 7.0 (Electron)')) }
        # Módulo nativo cuyo fallo de carga provoca el diálogo «reading 'TraceLog'» (loader.js deja Messenger.sender en null).
        $addon = Join-Path $dirForti 'resources\app.asar.unpacked\assets\js\guimessenger64.node'
        if (Test-Path $addon) { $c.Add((Nuevo-Chequeo 'forticlient.modulo' 'ok' 'guimessenger64.node presente en app.asar.unpacked')) }
        else { $c.Add((Nuevo-Chequeo 'forticlient.modulo' 'error' 'falta resources\app.asar.unpacked\assets\js\guimessenger64.node: la consola no puede cargar su módulo nativo')) }
        # Runtime de Visual C++ que importa ese módulo: dónde está cada DLL.
        $sys = Join-Path $env:SystemRoot 'System32'
        $dlls = [ordered]@{}
        foreach ($n in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
            $donde = @()
            if (Test-Path (Join-Path $sys $n)) { $donde += 'System32' }
            if ($dirForti -and (Test-Path (Join-Path $dirForti $n))) { $donde += 'carpeta de FortiClient' }
            if ($dirForti -and (Test-Path (Join-Path $dirForti "resources\app.asar.unpacked\assets\js\$n"))) { $donde += 'junto al módulo' }
            $dlls[$n] = $donde
        }
        $faltan = @($dlls.Keys | Where-Object { @($dlls[$_]).Count -eq 0 })
        $sinSistema = @($dlls.Keys | Where-Object { @($dlls[$_]) -notcontains 'System32' })
        $resumenDll = (($dlls.Keys | ForEach-Object { "$_ : $(if (@($dlls[$_]).Count) { @($dlls[$_]) -join ' + ' } else { 'NO' })" }) -join '; ')
        if ($faltan.Count -gt 0) { $c.Add((Nuevo-Chequeo 'forticlient.runtime' 'error' "faltan DLL de Visual C++: $($faltan -join ', ') ($resumenDll)" $dlls)) }
        elseif ($sinSistema.Count -gt 0) { $c.Add((Nuevo-Chequeo 'forticlient.runtime' 'aviso' "solo están junto a FortiClient (no en System32): $($sinSistema -join ', '); depende de la carpeta de trabajo. $resumenDll" $dlls)) }
        else { $c.Add((Nuevo-Chequeo 'forticlient.runtime' 'ok' $resumenDll $dlls)) }
    }

    # --- acceso directo del menú Inicio (referencia)
    try {
        $a = Buscar-AccesoInicioForti
        if ($a) { $c.Add((Nuevo-Chequeo 'forticlient.acceso' 'ok' "menú Inicio: carpeta de trabajo '$($a.carpetaTrabajo)', argumentos '$($a.argumentos)'" $a)) }
        else { $c.Add((Nuevo-Chequeo 'forticlient.acceso' 'aviso' 'no se encuentra el acceso directo de FortiClient en el menú Inicio')) }
    } catch { $c.Add((Nuevo-Chequeo 'forticlient.acceso' 'aviso' "no se ha podido leer el menú Inicio: $($_.Exception.Message)")) }

    # --- servicio y tarea
    $st = $null; $inicio = $null
    try { $st = Estado-Servicio } catch { }
    try { $inicio = [string](Get-CimInstance Win32_Service -Filter "Name='$ServicioForti'" -ErrorAction Stop).StartMode } catch { }
    $tarea = $null; $tareaOk = $false; $tareaTxt = $null
    try {
        $tarea = Info-Tarea
        $tareaOk = [bool]($tarea.instalada -and @($tarea.problemas).Count -eq 0)
        $tareaTxt = if (-not $tarea.instalada) { "no instalada (falta '$TareaServicio')" }
                    elseif ($tareaOk) { "instalada y correcta (último resultado $($tarea.ultimoResultado))" }
                    else { "instalada pero distinta de la esperada: $(@($tarea.problemas) -join '; ')" }
    } catch { $tareaTxt = "no se ha podido leer: $($_.Exception.Message)" }
    $c.Add((Nuevo-Chequeo 'tarea' $(if ($tareaOk) { 'ok' } elseif ($tarea -and $tarea.instalada) { 'error' } else { 'aviso' }) $tareaTxt ([ordered]@{ instalada = [bool]($tarea -and $tarea.instalada); correcta = $tareaOk })))
    if ($null -eq $st) { $c.Add((Nuevo-Chequeo 'servicio' 'error' "no existe el servicio $ServicioForti" ([ordered]@{ estado = $null; inicio = $null }))) }
    elseif ($st -eq 'Running') { $c.Add((Nuevo-Chequeo 'servicio' 'ok' "$ServicioForti en marcha (inicio $inicio)" ([ordered]@{ estado = $st; inicio = $inicio }))) }
    elseif ($tareaOk) { $c.Add((Nuevo-Chequeo 'servicio' 'aviso' "$ServicioForti $st (inicio $inicio); la tarea puede arrancarlo sin UAC" ([ordered]@{ estado = $st; inicio = $inicio }))) }
    else { $c.Add((Nuevo-Chequeo 'servicio' 'error' "$ServicioForti $st (inicio $inicio) y sin tarea que lo arranque: FortiClient pedirá UAC y un usuario sin permisos no podrá abrir la consola" ([ordered]@{ estado = $st; inicio = $inicio }))) }

    # --- usuario administrador local
    $sids = @(Obtener-SidsToken)
    $admin = Es-AdministradorLocal $sids
    $elev = Es-Elevado
    $c.Add((Nuevo-Chequeo 'usuario.admin' $(if ($admin) { 'ok' } else { 'aviso' }) $(if ($admin) { "administrador local$(if (-not $elev) { ' (sin elevar: UAC)' })" } else { 'NO es administrador local: no puede registrar la tarea ni arrancar el servicio; lo debe hacer un administrador' }) ([ordered]@{ administradorLocal = $admin; elevado = $elev })))

    # --- túneles
    $tun = @($TunelesRegistro | ForEach-Object { [string]$_ })
    if ($tun.Count -eq 0) { $c.Add((Nuevo-Chequeo 'tuneles' 'error' 'no hay ningún túnel SSL VPN en el registro de FortiClient' ([ordered]@{ tuneles = @() }))) }
    elseif ($tun.Count -gt 1) { $c.Add((Nuevo-Chequeo 'tuneles' 'aviso' "varios túneles: $($tun -join ', ') (se usa '$($Cfg.tunel)')" ([ordered]@{ tuneles = $tun }))) }
    else { $c.Add((Nuevo-Chequeo 'tuneles' 'ok' "$($tun[0])" ([ordered]@{ tuneles = $tun }))) }

    # --- credencial genérica: solo existencia
    $credTxt = 'no hay credencial genérica utilizable'; $credEstado = 'aviso'; $credUsuario = $null
    try {
        Cargar-Ayudante
        foreach ($t in @($Targets)) {
            $u = [VpnForti.Cred]::Usuario($t, 1)
            if ($null -ne $u -and [VpnForti.Cred]::LongitudSecreto($t, 1) -gt 0) { $credTxt = "existe (target '$t')"; $credEstado = 'ok'; $credUsuario = $u; break }
        }
        if ($credEstado -ne 'ok') {
            foreach ($t in @($Targets)) { if ($null -ne [VpnForti.Cred]::Usuario($t, 2)) { $credTxt = "'$t' está guardada como credencial de Windows, no genérica: no sirve"; break } }
        }
    } catch { $credTxt = "no se ha podido comprobar: $($_.Exception.Message)" }
    $c.Add((Nuevo-Chequeo 'credencial' $credEstado $credTxt))

    # --- Node, navegador, git
    $node = (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $node) { $c.Add((Nuevo-Chequeo 'node' 'error' 'Node.js no está instalado (hace falta la 18 o posterior)')) }
    else {
        $nv = (& $node -v 2>$null | Select-Object -First 1)
        $nokv = [bool]($nv -match '^v?(\d+)\.' -and [int]$Matches[1] -ge 18)
        $c.Add((Nuevo-Chequeo 'node' $(if ($nokv) { 'ok' } else { 'error' }) "$nv ($node)"))
    }
    $pf = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ }
    $edge = @($pf | ForEach-Object { Join-Path $_ 'Microsoft\Edge\Application\msedge.exe' } | Where-Object { Test-Path $_ }) | Select-Object -First 1
    $chrome = @($pf | ForEach-Object { Join-Path $_ 'Google\Chrome\Application\chrome.exe' } | Where-Object { Test-Path $_ }) | Select-Object -First 1
    $nav = @(@(if ($edge) { 'Edge' }) + @(if ($chrome) { 'Chrome' }))
    $c.Add((Nuevo-Chequeo 'navegador' $(if ($nav.Count) { 'ok' } else { 'error' }) $(if ($nav.Count) { $nav -join ' + ' } else { 'ni Edge ni Chrome instalados' }) ([ordered]@{ edge = [bool]$edge; chrome = [bool]$chrome })))
    $git = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    $c.Add((Nuevo-Chequeo 'git' $(if ($git) { 'ok' } else { 'aviso' }) $(if ($git) { $git } else { 'git no está instalado: no funcionará la autoactualización' })))

    # --- FortiClient abierto y con qué línea de comandos
    $procs = @(Obtener-ProcesosForti)
    $cl = Clasificar-ProcesosForti $procs
    if (-not $cl.abierto) { $c.Add((Nuevo-Chequeo 'forticlient.abierto' 'ok' 'FortiClient no está abierto' ([ordered]@{ abierto = $false }))) }
    else {
        $lineas = @($procs | Where-Object { ([string]$_.CommandLine) -notmatch '--type=' } | ForEach-Object { $_.CommandLine })
        $c.Add((Nuevo-Chequeo 'forticlient.abierto' 'ok' "abierto ($($cl.total) procesos), $(if ($cl.conFlag) { 'con' } else { 'sin' }) --force-renderer-accessibility" ([ordered]@{ abierto = $true; conFlag = $cl.conFlag; sinFlag = $cl.sinFlag; lineaDeComandos = $lineas })))
    }

    # --- VPN
    $est = $null; $vpnActiva = $true
    try { $est = Get-Estado; $vpnActiva = [bool]($est.conectada -or ($est.adaptador -and $est.adaptador.estado -eq 'Up')) } catch { }
    $c.Add((Nuevo-Chequeo 'vpn' 'ok' $(if ($est -and $est.conectada) { 'VPN conectada' } elseif ($vpnActiva) { 'adaptador activo pero sin DNS: se trata como conectada' } else { 'VPN no conectada' }) ([ordered]@{ conectada = [bool]($est -and $est.conectada); adaptadorActivo = $vpnActiva })))

    # --- rutas
    $rutaTemp = [string]$env:TEMP; $rutaInst = [string]$Raiz
    $it = Info-Ruta $rutaTemp; $ii = Info-Ruta $rutaInst
    $notas = @()
    if ($it.onedrive) { $notas += '%TEMP% está en OneDrive' }
    if ($it.noAscii) { $notas += '%TEMP% tiene caracteres no ASCII' }
    if ($ii.onedrive) { $notas += 'la instalación está en OneDrive (mejor fuera: sincroniza node_modules)' }
    if ($ii.noAscii) { $notas += 'la instalación tiene caracteres no ASCII' }
    $c.Add((Nuevo-Chequeo 'rutas' $(if ($notas.Count) { 'aviso' } else { 'ok' }) $(if ($notas.Count) { $notas -join '; ' } else { 'rutas sin OneDrive ni caracteres especiales' }) ([ordered]@{ temp = $rutaTemp; instalacion = $rutaInst; tempOneDrive = $it.onedrive; tempNoAscii = $it.noAscii; instalacionOneDrive = $ii.onedrive; instalacionNoAscii = $ii.noAscii })))

    # --- modo de arranque de la consola
    $modoCfg = [string]$Cfg.consola.modo
    $arranque = $null
    if ($FicheroArranque -and (Test-Path $FicheroArranque)) { try { $arranque = Get-Content $FicheroArranque -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $txtModo = "consola.modo = '$modoCfg'"
    $estModo = 'ok'
    if (-not $modoCfg) { $estModo = 'aviso'; $txtModo = 'consola.modo sin fijar: ejecuta "vpn.cmd probar-arranque -Guardar" (o instalar.ps1)' }
    elseif ($arranque -and -not $arranque.omitida -and -not $arranque.modoElegido) { $estModo = 'error'; $txtModo += '; la última prueba no ha abierto la consola con ningún modo' }
    $c.Add((Nuevo-Chequeo 'consola.modo' $estModo $txtModo))

    # --- log
    $log = @()
    # [string]: las líneas de Get-Content llevan propiedades (PSDrive, PSProvider…) que ConvertTo-Json recorre sin fin.
    if ($FicheroLog -and (Test-Path $FicheroLog)) { try { $log = @(Get-Content $FicheroLog -Tail 20 -Encoding UTF8 | ForEach-Object { [string]$_ }) } catch { } }

    $d = [ordered]@{
        version        = $Version
        fecha          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        resumen        = (Resumir-Chequeos $c.ToArray())
        comprobaciones = $c.ToArray()   # no @($c): en PowerShell 5.1 falla con una lista de objetos
        arranque       = $arranque
        log            = $log
    }
    $nombres = Obtener-NombresPrivados @($credUsuario)
    return [pscustomobject]@{ diagnostico = $d; nombres = $nombres }
}

function Enmascarar-Diagnostico($Diag, $Nombres) {
    # Serializa, enmascara el texto completo y vuelve a leer: así no se escapa ningún campo.
    $json = $Diag | ConvertTo-Json -Depth 9
    $json = Enmascarar-Texto $json $Nombres.usuarios $Nombres.equipos
    return ($json | ConvertFrom-Json)
}

function Escribir-Diagnostico($Diag, [string]$Dir) {
    # diagnostico.json y diagnostico.txt (ya enmascarados) para enviarlos tal cual.
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force $Dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $fj = Join-Path $Dir 'diagnostico.json'
    $ft = Join-Path $Dir 'diagnostico.txt'
    [IO.File]::WriteAllText($fj, ($Diag | ConvertTo-Json -Depth 9), $enc)
    [IO.File]::WriteAllText($ft, (Formatear-InformeDiagnostico $Diag), $enc)
    return [pscustomobject]@{ json = $fj; texto = $ft }
}
