# Arranque de la consola de FortiClient por modos, con detección del diálogo de error de Electron
# («A JavaScript error occurred in the main process … Cannot read properties of null (reading 'TraceLog')»).
#
# Solo funciones: no ejecuta nada al cargarse. Lo cargan vpn.ps1 y las pruebas (pruebas\pruebas.ps1) con punto.
# Usan, de vpn.ps1: $Cfg, Log, Get-Estado, Esperar-Pantalla, $FicheroCfg. Las pruebas las sustituyen por dobles.
#
# REGLA DE SEGURIDAD: FortiClient solo se cierra a través de Cerrar-FortiClient, y esta no hace nada
# (ni cierre ordenado ni kill) si hay una VPN conectada o hay dudas (Vpn-Activa).

# Modos de arranque, en el orden en que se prueban. D es el comportamiento de las versiones anteriores.
$script:ModosConsola = @(
    [pscustomobject]@{ id = 'A'; nombre = 'lnk-carpeta-flag';    metodo = 'lnk';        carpeta = $true;  flag = $true;  descripcion = 'acceso directo con carpeta de trabajo y --force-renderer-accessibility' }
    [pscustomobject]@{ id = 'B'; nombre = 'lnk-carpeta';         metodo = 'lnk';        carpeta = $true;  flag = $false; descripcion = 'acceso directo con carpeta de trabajo, sin el flag' }
    [pscustomobject]@{ id = 'C'; nombre = 'explorador-cmd-carpeta'; metodo = 'explorador-cmd'; carpeta = $true; flag = $false; descripcion = 'lanzado por el Explorador a través de un .cmd que fija la carpeta de trabajo, sin el flag' }
    [pscustomobject]@{ id = 'D'; nombre = 'lnk-flag';            metodo = 'lnk';        carpeta = $false; flag = $true;  descripcion = 'acceso directo sin carpeta de trabajo y con el flag (comportamiento anterior)' }
)
$script:FlagAccesibilidad = '--force-renderer-accessibility'
# Con FortiElevate.exe/consent.exe vivos (UAC pendiente) se sigue esperando hasta este tope extra: no se da el modo por
# fallido ni se prueba otro mientras el UAC esté sin contestar (las pruebas lo bajan).
$script:ElevacionSegPorDefecto = 120
# Segundos que se espera al cierre ordenado de FortiClient antes del último recurso (las pruebas lo bajan).
$script:CierreEsperaSeg = 10
# Dónde se escriben el acceso directo y el .cmd de arranque (las pruebas los llevan a una carpeta temporal).
$script:DirLanzamiento = $null

# ---------------------------------------------------------------- funciones puras
function Obtener-ModosConsola { return @($script:ModosConsola) }

function Obtener-ModoConsola([string]$Id) {
    return ($script:ModosConsola | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Ordenar-ModosConsola([string]$Preferido) {
    # Orden en que se prueban: el modo guardado en config.json primero (si es válido) y luego el resto en orden A-D.
    $ids = @($script:ModosConsola | ForEach-Object { $_.id })
    $p = if ($Preferido) { $Preferido.Trim().ToUpper() } else { '' }
    if ($ids -contains $p) { return @(@($p) + @($ids | Where-Object { $_ -ne $p })) }
    return $ids
}

function Es-DialogoErrorElectron([string]$Titulo, [string]$Clase, [string]$Texto) {
    # ¿Es la ventana el diálogo de error de Electron del proceso principal? La consola (Chrome_WidgetWin_1) nunca lo es.
    if ($Clase -eq 'Chrome_WidgetWin_1') { return $false }
    if ($Texto -match 'A JavaScript error occurred in the main process') { return $true }
    if ($Titulo -match 'A JavaScript error occurred') { return $true }
    if ($Texto -match 'Cannot read properties of null' -and $Texto -match 'TraceLog|new Logger') { return $true }
    # Título «Error» en un diálogo Win32 de FortiClient.exe cuyo texto no se ha podido leer: UIA puede devolver solo
    # los nombres de los botones y del título (OK, Aceptar, Copiar…), que no cuentan como texto. Un falso positivo
    # aquí es inocuo (se cierra un diálogo y se prueba otro modo, nunca con VPN); un falso negativo deja bloqueado.
    if ($Titulo -eq 'Error' -and $Clase -eq '#32770') {
        $partes = @(([string]$Texto) -split '\s*\|\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^(OK|Aceptar|Cancelar|Cancel|Copiar|Copy|Cerrar|Close|S[ií]|No|Yes|Error|Cerrar este mensaje|Detalles|Details)$' })
        if ($partes.Count -eq 0) { return $true }
    }
    return $false
}

function Clasificar-ProcesosForti($Procesos) {
    # Procesos = objetos con CommandLine. Los hijos de Electron llevan --type=; el principal no.
    $todos = @($Procesos | Where-Object { $_ })
    $principales = @($todos | Where-Object { ([string]$_.CommandLine) -notmatch '--type=' })
    $conFlag = @($todos | Where-Object { ([string]$_.CommandLine) -match 'force-renderer-accessibility' }).Count -gt 0
    return [pscustomobject]@{
        abierto     = ($todos.Count -gt 0)
        total       = $todos.Count
        principales = $principales.Count
        conFlag     = $conFlag
        sinFlag     = ($principales.Count -gt 0 -and -not $conFlag)
    }
}

function Elegir-ModoConsola($Resultados) {
    # El primero que deja la consola abierta Y con el formulario manejable. Un modo que abre sin formulario manejable
    # NO sirve (conectar acabaría en el código 4) y nunca se guarda: ver Primer-ModoQueAbre.
    $conFormulario = @($Resultados | Where-Object { $_.resultado -eq 'ok' -and $_.formulario -eq $true })
    if ($conFormulario.Count -gt 0) { return $conFormulario[0].modo }
    return $null
}

function Primer-ModoQueAbre($Resultados) {
    $ok = @($Resultados | Where-Object { $_.resultado -eq 'ok' })
    if ($ok.Count -gt 0) { return $ok[0].modo }
    return $null
}

# ---------------------------------------------------------------- acceso al sistema (puntos de inyección para las pruebas)
function Ids-Forti {
    return @(Get-Process FortiClient -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}

function Obtener-ProcesosForti {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='FortiClient.exe'" -ErrorAction Stop |
            ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; Padre = [int]$_.ParentProcessId; CommandLine = [string]$_.CommandLine } })
    } catch { return @() }
}

function Obtener-AdaptadoresFortinet {
    # Todos los adaptadores que parezcan de Fortinet por nombre o descripción (no solo el de la descripción configurada).
    # Lanza si no se pueden leer los adaptadores.
    $todos = @(Get-NetAdapter -ErrorAction Stop)
    $desc = ''; try { $desc = [string]$Cfg.adaptador } catch { }
    return @($todos | Where-Object { $_.InterfaceDescription -match 'Forti' -or $_.Name -match 'Forti' -or ($desc -and $_.InterfaceDescription -eq $desc) } |
        ForEach-Object { [pscustomobject]@{ Nombre = [string]$_.Name; Descripcion = [string]$_.InterfaceDescription; Estado = [string]$_.Status } })
}

function Vpn-Activa {
    # ¿Puede haber una VPN conectada? Criterio CONSERVADOR: cualquier duda cuenta como conectada. Es activa si Get-Estado
    # dice conectada, si el DNS de la VPN resuelve, o si algún adaptador Fortinet (por nombre o descripción, todos los
    # que haya) está Up o en un estado que no sea claramente desconectado. Si no hay ningún adaptador Fortinet que
    # mirar, si no se pueden leer o si algo falla, también es activa. Solo es «no activa» si TODOS los adaptadores
    # Fortinet están claramente desconectados y el DNS no resuelve. (Get-Estado devuelve adaptador $null, sin
    # excepción, cuando no encuentra el de la descripción configurada: eso NO prueba que no haya VPN.)
    try {
        $e = Get-Estado
        if ($e -and $e.conectada) { return $true }
        if ($e -and $e.dns -and $e.dns.ip) { return $true }
        if ($e -and $e.adaptador -and $e.adaptador.estado -eq 'Up') { return $true }
        $ads = @(Obtener-AdaptadoresFortinet)
        if ($ads.Count -eq 0) { return $true }
        foreach ($a in $ads) { if ([string]$a.Estado -notin 'Disconnected', 'Disabled', 'Not Present', 'Down') { return $true } }
        return $false
    } catch { return $true }
}

function Procesos-Elevacion {
    # Procesos de elevación (UAC) vivos: FortiElevate.exe de FortiClient y consent.exe de Windows.
    return @(Get-Process FortiElevate, consent -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
}

function Ventana-Consola {
    $ids = @(Ids-Forti)
    if ($ids.Count -eq 0) { return [IntPtr]::Zero }
    return [VpnForti.Ui]::VentanaConsola([int[]]$ids)
}

function Texto-Ventana([IntPtr]$h) {
    $partes = New-Object System.Collections.Generic.List[string]
    try { $t = [VpnForti.Ui]::TextoHijos($h); if ($t) { $partes.Add($t) } } catch { }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $A = [System.Windows.Automation.AutomationElement]
        $el = $A::FromHandle($h)
        foreach ($d in $el.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition)) {
            $n = $d.Current.Name
            if ($n) { $partes.Add($n) }
        }
    } catch { }
    return (($partes | Select-Object -Unique) -join ' | ')
}

function Buscar-DialogoErrorForti {
    # Diálogo de error de Electron: ventana de nivel superior de un proceso FortiClient.exe que no es la consola.
    $ids = @(Ids-Forti)
    if ($ids.Count -eq 0) { return $null }
    foreach ($v in [VpnForti.Ui]::VentanasDe([int[]]$ids)) {
        $clase = [string]$v[1]; $titulo = [string]$v[2]
        if ($clase -eq 'Chrome_WidgetWin_1') { continue }
        $h = [IntPtr][int64]$v[0]
        $texto = Texto-Ventana $h
        if (Es-DialogoErrorElectron $titulo $clase $texto) {
            return [pscustomobject]@{ Hwnd = [int64]$v[0]; Titulo = $titulo; Clase = $clase; Texto = $texto }
        }
    }
    return $null
}

function Cerrar-DialogoError($Dialogo, [int]$EsperaSeg = 3) {
    # Aceptar el diálogo y, si sigue, probar otra vía: TDM_CLICK_BUTTON con IDOK (TaskDialog, el que usa Electron; un
    # WM_COMMAND o WM_CLOSE no lo cierran), WM_COMMAND/BN_CLICKED del botón clásico (id 1) y WM_CLOSE. No mata nada:
    # el proceso termina solo al cerrar el diálogo.
    $h = [IntPtr][int64]$Dialogo.Hwnd
    foreach ($paso in 'taskdialog', 'aceptar', 'cerrar') {
        switch ($paso) {
            'taskdialog' { [void][VpnForti.Ui]::ClicBotonTaskDialog($h, 1) }
            'aceptar' { [void][VpnForti.Ui]::PulsarBotonDialogo($h, 1) }
            default { [void][VpnForti.Ui]::CerrarVentana($h) }
        }
        $limite = (Get-Date).AddSeconds($EsperaSeg)
        do {
            if (-not (Buscar-DialogoErrorForti)) { return $true }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $limite)
    }
    return $false
}

function Crear-AccesoConsola([string]$Lnk, [string]$Exe, $Modo) {
    # Se borra antes: CreateShortcut sobre un .lnk existente lo carga y conservaría una carpeta de trabajo anterior.
    if (Test-Path $Lnk) { Remove-Item $Lnk -Force -ErrorAction SilentlyContinue }
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($Lnk)
    $sc.TargetPath = $Exe
    $sc.Arguments = if ($Modo.flag) { $script:FlagAccesibilidad } else { '' }
    $sc.WorkingDirectory = if ($Modo.carpeta) { Split-Path -Parent $Exe } else { '' }
    $sc.Save()
}

function Crear-ScriptConsola([string]$Cmd, [string]$Exe) {
    # .cmd que fija la carpeta de trabajo y lanza el exe. Explorador no admite carpeta de trabajo en su línea de
    # comandos (comprobado: usa System32 aunque se le pase una), así que la fija el .cmd.
    $dir = Split-Path -Parent $Exe
    $txt = "@echo off`r`ncd /d `"$dir`"`r`nstart `"`" `"$Exe`"`r`n"
    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [IO.File]::WriteAllText($Cmd, $txt, $oem)
}

function Lanzar-ModoConsola($Modo) {
    # Lanzado directamente desde otro proceso (también con Shell.Application.ShellExecute desde PowerShell: el padre
    # sigue siendo PowerShell), FortiClient.exe sale sin abrir ventana: hay que pasar por el Explorador. Con un acceso
    # directo el padre es explorer.exe y la carpeta de trabajo la del acceso directo; sin carpeta, System32.
    $exe = [string]$Cfg.fortiClientExe
    $dirTmp = if ($script:DirLanzamiento) { $script:DirLanzamiento } else { $env:TEMP }
    if ($Modo.metodo -eq 'lnk') {
        $lnk = Join-Path $dirTmp 'vpn-forti-consola.lnk'
        Crear-AccesoConsola $lnk $exe $Modo
        Start-Process explorer.exe -ArgumentList "`"$lnk`"" | Out-Null
    } else {
        $cmd = Join-Path $dirTmp 'vpn-forti-consola.cmd'
        Crear-ScriptConsola $cmd $exe
        Start-Process explorer.exe -ArgumentList "`"$cmd`"" | Out-Null
    }
}

function Pedir-CierreForti {
    foreach ($p in @(Get-Process FortiClient -ErrorAction SilentlyContinue)) { try { [void]$p.CloseMainWindow() } catch { } }
}

function Matar-ProcesosForti {
    Get-Process FortiClient -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Comprobar-Formulario([IntPtr]$h, [int]$Segundos = 12) {
    # Solo lectura del árbol de accesibilidad (nombres y roles): sin clics ni texto en los campos.
    try {
        $p = Esperar-Pantalla $h $Segundos
        return [bool]($p.Desconectar -or ($p.Conectar -and $p.Clave))
    } catch { return $false }
}

# ---------------------------------------------------------------- cierre ordenado
function Cerrar-FortiClient {
    # Única vía para cerrar FortiClient. Cierre ordenado (CloseMainWindow) y espera; el kill solo con
    # -PermitirKill, como último recurso, y nunca con una VPN conectada (se comprueba antes de cada paso).
    param([int]$EsperaSeg = $script:CierreEsperaSeg, [switch]$PermitirKill, [int]$IntervaloMs = 500)
    $r = [ordered]@{ cerrado = $false; metodo = 'ninguno'; motivo = $null }
    if (@(Ids-Forti).Count -eq 0) { $r.cerrado = $true; $r.motivo = 'no estaba abierto'; return [pscustomobject]$r }
    if (Vpn-Activa) { $r.metodo = 'no-cerrado'; $r.motivo = 'VPN conectada: no se cierra FortiClient'; return [pscustomobject]$r }

    Pedir-CierreForti
    $limite = (Get-Date).AddSeconds($EsperaSeg)
    do {
        if (@(Ids-Forti).Count -eq 0) { $r.cerrado = $true; $r.metodo = 'cierre-ordenado'; return [pscustomobject]$r }
        Start-Sleep -Milliseconds $IntervaloMs
    } while ((Get-Date) -lt $limite)

    if (-not $PermitirKill) { $r.metodo = 'no-cerrado'; $r.motivo = "FortiClient no se ha cerrado en $EsperaSeg s"; return [pscustomobject]$r }
    if (Vpn-Activa) { $r.metodo = 'no-cerrado'; $r.motivo = 'VPN conectada: no se mata FortiClient'; return [pscustomobject]$r }
    Matar-ProcesosForti
    $limite = (Get-Date).AddSeconds([Math]::Min(5, $EsperaSeg))
    do {
        if (@(Ids-Forti).Count -eq 0) { $r.cerrado = $true; $r.metodo = 'kill'; return [pscustomobject]$r }
        Start-Sleep -Milliseconds $IntervaloMs
    } while ((Get-Date) -lt $limite)
    $r.metodo = 'no-cerrado'; $r.motivo = 'FortiClient sigue abierto tras el kill'
    return [pscustomobject]$r
}

# ---------------------------------------------------------------- espera de la consola o del error
function Esperar-ConsolaOError {
    # Estados: ok (hay ventana de la consola), error-electron (diálogo de error de Electron, se detecta al momento),
    # y, solo al agotar el tiempo ($Segundos, 40 s como en la 1.2.2: el Explorador puede ser lento) tras una última
    # comprobación de ventana y diálogo: salio (hubo proceso de FortiClient pero ya no hay), sin-proceso (no se vio
    # ninguno: el modo no lanzó nada) o sin-ventana (hay proceso pero sin ventana). Si hay procesos de elevación
    # (FortiElevate.exe/consent.exe) vivos no se da ninguno por fallido: se espera hasta $ElevacionSeg más y, si el UAC
    # sigue sin contestar, uac-pendiente (no se prueba ningún otro modo).
    param([int]$Segundos = 40, [int]$IntervaloMs = 500, [int]$ElevacionSeg = $script:ElevacionSegPorDefecto)
    $t0 = Get-Date
    $limite = $t0.AddSeconds($Segundos)
    $tope = $limite.AddSeconds($ElevacionSeg)
    $visto = $false
    $res = { param($estado, $h, $d) [pscustomobject]@{ estado = $estado; h = $h; dialogo = $d; segundos = [int]((Get-Date) - $t0).TotalSeconds; visto = $visto } }
    while ($true) {
        $d = Buscar-DialogoErrorForti
        if ($d) { $visto = $true; return (& $res 'error-electron' ([IntPtr]::Zero) $d) }
        $h = Ventana-Consola
        if ($h -ne [IntPtr]::Zero) { $visto = $true; return (& $res 'ok' $h $null) }
        $hay = (@(Ids-Forti).Count -gt 0)
        if ($hay) { $visto = $true }
        if ((Get-Date) -ge $limite) {
            if (@(Procesos-Elevacion).Count -gt 0) {
                if ((Get-Date) -ge $tope) { return (& $res 'uac-pendiente' ([IntPtr]::Zero) $null) }
            } else {
                # Última comprobación antes de dar el modo por fallido (ya hecha arriba con este mismo estado).
                if ($hay) { return (& $res 'sin-ventana' ([IntPtr]::Zero) $null) }
                if ($visto) { return (& $res 'salio' ([IntPtr]::Zero) $null) }
                return (& $res 'sin-proceso' ([IntPtr]::Zero) $null)
            }
        }
        Start-Sleep -Milliseconds $IntervaloMs
    }
}

function Texto-Corto([string]$Texto, [int]$Max = 300) {
    $t = ($Texto -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { return $t.Substring(0, $Max) + '…' }
    return $t
}

# ---------------------------------------------------------------- uso normal: abrir la consola con fallback entre modos
function Abrir-ConsolaPorModos {
    # Lanza la consola con el modo preferido y, si FortiClient muestra el diálogo de error de Electron, o (pasado el
    # tiempo de espera, 40 s) termina sin ventana o el modo no lanza nada, lo cierra y reintenta con el siguiente modo,
    # anotando cuál ha fallado. El fallback vale SOLO para esta ejecución: aquí nunca se escribe consola.modo.
    # Devuelve resultado: ok | sin-ventana (hay proceso sin ventana o UAC pendiente: no se reintenta) |
    # interrumpida (no se pudo limpiar FortiClient para seguir; con `motivo`) | todos-fallan (los modos
    # pedidos se probaron todos y fallaron). `perdidos` = segundos gastados en modos fallidos.
    param([string]$ModoPreferido, [int]$Segundos = 40, [int]$IntervaloMs = 500)
    $fallos = @()
    $perdidos = 0
    $t0 = Get-Date
    foreach ($id in @(Ordenar-ModosConsola $ModoPreferido)) {
        $modo = Obtener-ModoConsola $id
        $tm = Get-Date
        Log "Abriendo la consola de FortiClient (modo ${id}: $($modo.nombre))."
        try { Lanzar-ModoConsola $modo }
        catch {
            Log "Modo ${id}: no se ha podido lanzar: $($_.Exception.Message)"
            $fallos += [pscustomobject]@{ modo = $id; resultado = 'error-lanzar'; detalle = $_.Exception.Message }
            continue
        }
        $e = Esperar-ConsolaOError -Segundos $Segundos -IntervaloMs $IntervaloMs
        $seg = [int]((Get-Date) - $t0).TotalSeconds
        if ($e.estado -eq 'ok') {
            if ($fallos.Count -gt 0) { Log "Consola abierta con el modo $id tras fallar: $((@($fallos | ForEach-Object { $_.modo })) -join ', '). Solo vale para esta ejecución: consola.modo no se cambia (usa «vpn.cmd probar-arranque -Guardar»)." }
            return [pscustomobject]@{ resultado = 'ok'; h = $e.h; modo = $id; fallos = $fallos; segundos = $seg; perdidos = $perdidos; motivo = $null }
        }
        if ($e.estado -in 'sin-ventana', 'uac-pendiente') {
            $fallos += [pscustomobject]@{ modo = $id; resultado = $e.estado; detalle = $(if ($e.estado -eq 'uac-pendiente') { 'UAC de FortiClient pendiente de contestar' } else { "hay proceso de FortiClient pero no ha aparecido la ventana en $Segundos s" }) }
            return [pscustomobject]@{ resultado = 'sin-ventana'; h = [IntPtr]::Zero; modo = $id; fallos = $fallos; segundos = $seg; perdidos = $perdidos; motivo = $e.estado }
        }
        $detalle = if ($e.dialogo) { Texto-Corto $e.dialogo.Texto } elseif ($e.estado -eq 'sin-proceso') { 'el modo no ha lanzado ningún proceso de FortiClient' } else { 'FortiClient ha terminado sin abrir la ventana' }
        Log "Modo $id falló ($($e.estado)): $detalle"
        $fallos += [pscustomobject]@{ modo = $id; resultado = $e.estado; detalle = $detalle }
        if ($e.dialogo) { [void](Cerrar-DialogoError $e.dialogo) }
        $c = Cerrar-FortiClient -PermitirKill -IntervaloMs $IntervaloMs
        $perdidos += [int]((Get-Date) - $tm).TotalSeconds
        if (-not $c.cerrado) {
            Log "No se puede limpiar FortiClient antes del siguiente modo: $($c.motivo)"
            return [pscustomobject]@{ resultado = 'interrumpida'; h = [IntPtr]::Zero; modo = $null; fallos = $fallos; segundos = [int]((Get-Date) - $t0).TotalSeconds; perdidos = $perdidos; motivo = 'forticlient-no-cerrado' }
        }
    }
    return [pscustomobject]@{ resultado = 'todos-fallan'; h = [IntPtr]::Zero; modo = $null; fallos = $fallos; segundos = [int]((Get-Date) - $t0).TotalSeconds; perdidos = $perdidos; motivo = $null }
}

# ---------------------------------------------------------------- prueba de arranque
function Probar-ModoConsola {
    # Un modo: lanzar, esperar consola o diálogo de error, anotar y cerrar de forma ordenada.
    param($Modo, [int]$Segundos = 30, [int]$IntervaloMs = 500)
    $r = [ordered]@{ modo = $Modo.id; nombre = $Modo.nombre; resultado = $null; formulario = $null; segundos = 0; cierre = $null; detalle = $null }
    $t0 = Get-Date
    try { Lanzar-ModoConsola $Modo }
    catch { $r.resultado = 'error-lanzar'; $r.detalle = $_.Exception.Message; return [pscustomobject]$r }
    $e = Esperar-ConsolaOError -Segundos $Segundos -IntervaloMs $IntervaloMs
    $r.resultado = $e.estado
    if ($e.estado -eq 'ok') { $r.formulario = [bool](Comprobar-Formulario $e.h) }
    elseif ($e.estado -eq 'error-electron') {
        $r.detalle = Texto-Corto $e.dialogo.Texto
        $r.cierreDialogo = [bool](Cerrar-DialogoError $e.dialogo)
    }
    elseif ($e.estado -eq 'salio') { $r.detalle = 'FortiClient terminó sin abrir la ventana' }
    elseif ($e.estado -eq 'sin-proceso') { $r.detalle = 'el modo no lanzó ningún proceso de FortiClient' }
    elseif ($e.estado -eq 'uac-pendiente') { $r.detalle = 'UAC de FortiClient pendiente de contestar: se deja FortiClient como está' }
    else { $r.detalle = "hay proceso de FortiClient pero no apareció la ventana en $Segundos s" }
    if ($e.estado -eq 'uac-pendiente') { $r.cierre = 'no-cerrado'; $r.segundos = [int]((Get-Date) - $t0).TotalSeconds; return [pscustomobject]$r }
    $c = Cerrar-FortiClient -PermitirKill -IntervaloMs $IntervaloMs
    $r.cierre = $c.metodo
    if (-not $c.cerrado) { $r.detalle = ((@($r.detalle) + @("no se ha podido cerrar: $($c.motivo)")) | Where-Object { $_ }) -join '; ' }
    $r.segundos = [int]((Get-Date) - $t0).TotalSeconds
    return [pscustomobject]$r
}

function Probar-ModosConsola {
    # Prueba los modos en orden (A, B, C, D) y se para en el primero que deja la consola abierta con el formulario
    # manejable (con -Todos los prueba todos). Devuelve:
    #   modoElegido      el primero que abre Y deja el formulario manejable (null si ninguno); es el único que se puede guardar
    #   modoSinFormulario  si ninguno sirve, el primero que al menos abrió sin error (informativo, no se guarda)
    #   omitida/motivo   la prueba no se ha hecho o se ha INTERRUMPIDA antes de probar los modos pedidos: hay VPN conectada,
    #                    FortiClient abierto y no se permite cerrarlo, no se puede cerrar, la VPN se conectó durante la
    #                    prueba o hay un UAC pendiente. Nunca se confunde con «todos los modos fallan» (modoElegido null y
    #                    omitida false, es decir, todos los pedidos se probaron y dieron error).
    param([string]$ModoPreferido, [string[]]$Solo, [int]$Segundos = 30, [switch]$CerrarAbierto, [switch]$Todos, [int]$IntervaloMs = 500)
    $res = [ordered]@{ omitida = $false; motivo = $null; modoElegido = $null; modoSinFormulario = $null; resultados = @() }
    if (Vpn-Activa) {
        $res.omitida = $true; $res.motivo = 'vpn-conectada'
        return [pscustomobject]$res
    }
    if (@(Ids-Forti).Count -gt 0) {
        if (-not $CerrarAbierto) { $res.omitida = $true; $res.motivo = 'forticlient-abierto'; return [pscustomobject]$res }
        $c = Cerrar-FortiClient -EsperaSeg 15 -PermitirKill -IntervaloMs $IntervaloMs
        if (-not $c.cerrado) { $res.omitida = $true; $res.motivo = 'forticlient-no-cerrado'; $res.detalle = $c.motivo; return [pscustomobject]$res }
    }
    $orden = if ($Solo -and @($Solo).Count -gt 0) { @($Solo | ForEach-Object { ([string]$_).ToUpper() } | Where-Object { Obtener-ModoConsola $_ }) } else { @(Ordenar-ModosConsola $ModoPreferido) }
    if (@($orden).Count -eq 0) { $res.omitida = $true; $res.motivo = 'modo-desconocido'; return [pscustomobject]$res }
    $resultados = @()
    foreach ($id in $orden) {
        if (Vpn-Activa) { $res.motivo = 'vpn-conectada-durante-la-prueba'; break }
        $r = Probar-ModoConsola -Modo (Obtener-ModoConsola $id) -Segundos $Segundos -IntervaloMs $IntervaloMs
        $resultados += $r
        if (-not $Todos -and $r.resultado -eq 'ok' -and $r.formulario -eq $true) { break }
        if ($r.resultado -eq 'uac-pendiente') { $res.motivo = 'uac-pendiente'; break }
        if ($r.cierre -eq 'no-cerrado') { $res.motivo = 'forticlient-no-cerrado'; break }
    }
    $res.resultados = $resultados
    $res.modoElegido = Elegir-ModoConsola $resultados
    if (-not $res.modoElegido) { $res.modoSinFormulario = Primer-ModoQueAbre $resultados }
    # Interrumpida (motivo) sin ningún modo válido: omitida, nunca «todos fallan».
    if ($res.motivo -and -not $res.modoElegido) { $res.omitida = $true }
    return [pscustomobject]$res
}

# ---------------------------------------------------------------- config.json
function Guardar-ModoConsola([string]$Fichero, [string]$Modo) {
    # Escribe consola.modo conservando el resto de claves (mismo patrón que aceptar-certificado).
    $obj = if (Test-Path $Fichero) { Get-Content $Fichero -Raw -Encoding UTF8 | ConvertFrom-Json } else { New-Object psobject }
    if (-not $obj.PSObject.Properties['consola'] -or -not $obj.consola) {
        if ($obj.PSObject.Properties['consola']) { $obj.PSObject.Properties.Remove('consola') }
        $obj | Add-Member -NotePropertyName consola -NotePropertyValue ([pscustomobject]@{})
    }
    if ($obj.consola.PSObject.Properties['modo']) { $obj.consola.modo = $Modo }
    else { $obj.consola | Add-Member -NotePropertyName modo -NotePropertyValue $Modo }
    $dir = Split-Path -Parent $Fichero
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [IO.File]::WriteAllText($Fichero, ($obj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
}
