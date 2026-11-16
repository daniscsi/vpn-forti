<#
.SYNOPSIS
  Instala (o repara/actualiza) vpn-forti en este PC. Se puede ejecutar tantas veces como haga falta.

.DESCRIPTION
  1. Comprueba los requisitos: Node 18 o posterior, Microsoft Edge o Google Chrome y FortiClient.
     No instala programas: si falta alguno, lo dice y sale con el código 2.
  2. Instala las dependencias de Node (npm ci, o npm install si no hay package-lock.json).
  3. Crea config.json a partir de config.ejemplo.json si no existe, con el túnel detectado en el
     registro de FortiClient (si hay varios, el primero, y lo avisa).
  4. Fija la variable de entorno de usuario VPN_FORTI con la ruta de vpn.ps1 (y también en este proceso).
  5. Si falta la tarea que arranca el servicio de FortiClient sin UAC, lanza "vpn.ps1 instalar-tarea"
     (un único UAC). Con -Silencioso solo lo hace con -InstalarTarea (si no, lo avisa); con -SinTarea
     nunca. Si no se instala, queda en "avisos" y "tarea": false (no cambia el código de salida).
  6. Con -PedirCredencial, abre el diálogo de "vpn.ps1 guardar-credencial" si aún no hay credencial genérica.
  7. Ejecuta "vpn.ps1 diagnosticar" (solo lectura; deja diagnostico.json/.txt en %LOCALAPPDATA%\vpn-forti, sin
     contraseñas ni PIN y con el usuario enmascarado) y opera según el resultado:
     - tarea ausente: la instala si el usuario es administrador local (con el aviso del UAC); si no lo es, dice
       claramente el paso manual y sigue (no cambia el código de salida);
     - servicio FA_Scheduler parado y tarea instalada: lo arranca con la tarea (sin UAC).
  8. Prueba de arranque de la consola de FortiClient ("vpn.ps1 probar-arranque -Guardar"): abre y cierra la consola
     por modos (A-D), detecta el diálogo de error de Electron («reading 'TraceLog'») y guarda en config.json
     (consola.modo) el primero que funciona. Solo se hace la primera vez, tras cambiar la versión de FortiClient o
     con -ProbarArranque. Se omite (con aviso, sin cambiar el código) si hay VPN conectada, si el servicio no está
     en marcha o si FortiClient está abierto y no se ha permitido cerrarlo (-CerrarForti; sin -Silencioso lo pregunta).
     Nunca cierra FortiClient con la VPN conectada.

  Con -Silencioso no muestra nada salvo el diálogo de la credencial (y el UAC con -InstalarTarea), y escribe en stdout una única línea JSON:
    {"ok":true,"codigo":0,"version":"1.0.0","vpnForti":"...\vpn.ps1","tunel":"...","credencial":true,...}

  Códigos de salida:
    0 instalado (o ya lo estaba)          1 error inesperado
    2 falta un requisito (ver "faltan")   3 ha fallado npm
    4 instalado, pero se ha pedido la credencial y no se ha guardado (cancelada)
    5 instalado, pero ningún modo de arranque abre la consola de FortiClient sin el error de Electron
      («reading 'TraceLog'»): enviar diagnostico.txt (ruta en "diagnostico.ficheros")
#>
[CmdletBinding()]
param(
    [switch]$PedirCredencial,
    [switch]$Silencioso,
    [string]$Tunel,
    [switch]$InstalarTarea,
    [switch]$SinTarea,
    [switch]$SinPruebaArranque,
    [switch]$ProbarArranque,
    [switch]$CerrarForti
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Raiz = $PSScriptRoot
$VpnPs1 = Join-Path $Raiz 'vpn.ps1'
$DirDatos = Join-Path $env:LOCALAPPDATA 'vpn-forti'
if (-not (Test-Path $DirDatos)) { New-Item -ItemType Directory -Force $DirDatos | Out-Null }
$FicheroLog = Join-Path $DirDatos 'instalar.log'

$R = [ordered]@{
    ok          = $false
    codigo      = 1
    version     = $null
    vpnForti    = $VpnPs1
    raiz        = $Raiz
    node        = $null
    navegador   = $null
    fortiClient = $null
    tunel       = $null
    tuneles     = @()
    config      = $null
    dependencias = $null
    credencial  = $null
    usuario     = $null
    tarea       = $null
    servicio    = $null
    diagnostico = $null
    arranque    = $null
    faltan      = @()
    avisos      = @()
    mensaje     = $null
}

function Log([string]$m, [string]$Nivel = 'info') {
    $l = '{0:yyyy-MM-dd HH:mm:ss} [instalar] {1}' -f (Get-Date), $m
    try { Add-Content -Path $FicheroLog -Value $l -Encoding UTF8 } catch { }
    if ($Silencioso) { try { [Console]::Error.WriteLine($l) } catch { } ; return }
    $color = switch ($Nivel) { 'ok' { 'Green' } 'aviso' { 'Yellow' } 'error' { 'Red' } default { 'Gray' } }
    Write-Host $m -ForegroundColor $color
}

function Aviso([string]$m) { $script:R.avisos += $m; Log "Aviso: $m" 'aviso' }

function Terminar([int]$Codigo, [string]$Mensaje) {
    $R.codigo = $Codigo
    $R.ok = ($Codigo -eq 0)
    if ($Mensaje) { $R.mensaje = $Mensaje }
    if ($Silencioso) {
        [Console]::Out.WriteLine(($R | ConvertTo-Json -Compress -Depth 5))
    } else {
        Write-Host ''
        if ($Codigo -eq 0) { Write-Host "vpn-forti $($R.version) instalado en $Raiz" -ForegroundColor Green }
        elseif ($Mensaje) { Write-Host $Mensaje -ForegroundColor Red }
        if ($Codigo -eq 0 -and -not $R.credencial) {
            Write-Host 'Falta la credencial de la VPN: ejecuta  vpn.cmd guardar-credencial  (o instalar.ps1 -PedirCredencial).' -ForegroundColor Yellow
        }
    }
    Log "Fin con código $Codigo$(if ($Mensaje) { ": $Mensaje" })"
    exit $Codigo
}

function Ejecutar-VpnPs1([string[]]$Argumentos) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $salida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VpnPs1 @Argumentos 2>$null
        $codigo = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $json = $null
    $linea = @($salida | Where-Object { $_ -like '{*' }) | Select-Object -Last 1
    if ($linea) { try { $json = $linea | ConvertFrom-Json } catch { } }
    return [pscustomobject]@{ codigo = $codigo; json = $json }
}

function Buscar-Exe([string[]]$Rutas, [string]$AppPath) {
    foreach ($r in $Rutas) { if ($r -and (Test-Path $r)) { return $r } }
    foreach ($h in 'HKCU', 'HKLM') {
        try {
            $v = (Get-ItemProperty "$($h):\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$AppPath" -ErrorAction Stop).'(default)'
            if ($v) { $v = $v.Trim('"'); if (Test-Path $v) { return $v } }
        } catch { }
    }
    return $null
}

function Json-Cadena([string]$s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

# ---- Ayudas para leer el JSON de "vpn.ps1 diagnosticar" (comprobaciones con id, estado, detalle y datos).
function Indexar-Chequeos($Json) {
    $h = @{}
    if ($Json -and $Json.comprobaciones) { foreach ($c in @($Json.comprobaciones)) { $h[[string]$c.id] = $c } }
    return $h
}

function Dato-Chequeo($Indice, [string]$Id, [string]$Dato) {
    $c = $Indice[$Id]
    if ($c -and $c.datos -and $c.datos.PSObject.Properties[$Dato]) { return $c.datos.$Dato }
    return $null
}

function Resumir-Diagnostico($Json) {
    $r = [ordered]@{ resumen = $null; problemas = @(); ficheros = [ordered]@{ texto = (Join-Path $DirDatos 'diagnostico.txt'); json = (Join-Path $DirDatos 'diagnostico.json') } }
    if ($Json -and $Json.resumen) {
        $r.resumen = $Json.resumen
        $r.problemas = @(@($Json.comprobaciones) | Where-Object { $_.estado -ne 'ok' } | ForEach-Object { [ordered]@{ id = $_.id; estado = $_.estado; detalle = $_.detalle } })
    }
    return $r
}

function Preguntar-SiNo([string]$Pregunta) {
    # Sin consola interactiva (o con -Silencioso) se contesta que no.
    if ($Silencioso) { return $false }
    try { return ([string](Read-Host "$Pregunta (s/N)")) -match '^(s|si|sí|y|yes)$' } catch { return $false }
}

function Leer-JsonFichero([string]$Ruta) {
    if (-not (Test-Path $Ruta)) { return $null }
    try { return (Get-Content $Ruta -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

try {
    Log "Instalando vpn-forti en $Raiz"
    $fv = Join-Path $Raiz 'VERSION'
    if (Test-Path $fv) { $R.version = (Get-Content $fv -Raw -Encoding UTF8).Trim() }
    if (-not (Test-Path $VpnPs1)) { Terminar 1 "No se encuentra vpn.ps1 en $Raiz" }

    # ------------------------------------------------------------ requisitos
    $pf = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ }

    $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $nodeExe) { $nodeExe = Buscar-Exe @($pf | ForEach-Object { Join-Path $_ 'nodejs\node.exe' }) 'node.exe' }
    if (-not $nodeExe) {
        $R.faltan += 'node'; Log 'Falta Node.js (18 o posterior).' 'error'
    } else {
        $v = (& $nodeExe -v 2>$null | Select-Object -First 1)
        $R.node = [ordered]@{ ruta = $nodeExe; version = $v }
        if ($v -notmatch '^v?(\d+)\.' -or [int]$Matches[1] -lt 18) {
            $R.faltan += 'node'; Log "Node $v es demasiado antiguo: hace falta la 18 o posterior." 'error'
        } else { Log "Node $v ($nodeExe)" 'ok' }
    }

    $edge = Buscar-Exe @($pf | ForEach-Object { Join-Path $_ 'Microsoft\Edge\Application\msedge.exe' }) 'msedge.exe'
    $chrome = Buscar-Exe @($pf | ForEach-Object { Join-Path $_ 'Google\Chrome\Application\chrome.exe' }) 'chrome.exe'
    if ($edge) { $R.navegador = [ordered]@{ canal = 'msedge'; ruta = $edge } }
    elseif ($chrome) { $R.navegador = [ordered]@{ canal = 'chrome'; ruta = $chrome } }
    if ($R.navegador) { Log "Navegador: $($R.navegador.canal) ($($R.navegador.ruta))" 'ok' }
    else { $R.faltan += 'navegador'; Log 'Falta Microsoft Edge o Google Chrome.' 'error' }

    $forti = Buscar-Exe @($pf | ForEach-Object { Join-Path $_ 'Fortinet\FortiClient\FortiClient.exe' }) 'FortiClient.exe'
    if ($forti) { $R.fortiClient = $forti; Log "FortiClient: $forti" 'ok' }
    else { $R.faltan += 'forticlient'; Log 'Falta FortiClient (VPN).' 'error' }

    try { $R.tuneles = @(Get-ChildItem 'HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels' -ErrorAction Stop | ForEach-Object { $_.PSChildName } | Sort-Object) } catch { }
    if ($R.faltan.Count -gt 0) {
        Terminar 2 "Faltan requisitos: $($R.faltan -join ', '). Instálalos y vuelve a ejecutar instalar.ps1."
    }
    if ($R.tuneles.Count -eq 0) { Aviso 'FortiClient no tiene ningún túnel SSL VPN configurado: créalo en la consola de FortiClient y vuelve a ejecutar instalar.ps1.' }

    # ------------------------------------------------------------ dependencias de Node
    $npm = Join-Path (Split-Path $nodeExe) 'npm.cmd'
    if (-not (Test-Path $npm)) { $npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $npm) { Terminar 3 'No se encuentra npm (debería venir con Node).' }
    $suborden = if (Test-Path (Join-Path $Raiz 'package-lock.json')) { 'ci' } else { 'install' }
    Log "npm $suborden..."
    Push-Location $Raiz
    try {
        $salidaNpm = & cmd.exe /d /c "`"$npm`" $suborden --no-audit --no-fund --loglevel=error 2>&1"
        $rcNpm = $LASTEXITCODE
    } finally { Pop-Location }
    $salidaNpm | ForEach-Object { try { Add-Content -Path $FicheroLog -Value "  npm: $_" -Encoding UTF8 } catch { } }
    $pw = Join-Path $Raiz 'node_modules\playwright-core\package.json'
    if ($rcNpm -ne 0 -or -not (Test-Path $pw)) {
        if (-not $Silencioso) { $salidaNpm | Select-Object -Last 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
        Terminar 3 "npm $suborden ha fallado (código $rcNpm). Detalle en $FicheroLog"
    }
    $vpw = (Get-Content $pw -Raw -Encoding UTF8 | ConvertFrom-Json).version
    $R.dependencias = [ordered]@{ orden = "npm $suborden"; playwrightCore = $vpw }
    Log "Dependencias instaladas (playwright-core $vpw)" 'ok'

    # ------------------------------------------------------------ config.json
    $cfg = if ($env:VPN_FORTI_CONFIG) { $env:VPN_FORTI_CONFIG } else { Join-Path $Raiz 'config.json' }
    $tunelElegido = if ($Tunel) { $Tunel } elseif ($R.tuneles.Count) { $R.tuneles[0] } else { '' }
    if (Test-Path $cfg) {
        $R.config = [ordered]@{ ruta = $cfg; estado = 'existente' }
        Log "config.json ya existe; no se toca ($cfg)."
        try {
            $c = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.tunel) { $tunelElegido = $c.tunel }
            if ($Tunel -and $c.tunel -ne $Tunel) { Aviso "config.json indica el túnel '$($c.tunel)'; -Tunel '$Tunel' no lo cambia. Edita config.json si quieres otro." ; $tunelElegido = $c.tunel }
            $canal = if ($c.pin -and $c.pin.canal) { $c.pin.canal } else { 'msedge' }
            if ($canal -eq 'msedge' -and -not $edge) { Aviso "config.json usa Edge (pin.canal = msedge) pero solo está Chrome: cambia pin.canal a ""chrome""." }
        } catch { Aviso "config.json no es un JSON válido: $($_.Exception.Message)" }
    } else {
        $ejemplo = Join-Path $Raiz 'config.ejemplo.json'
        if (-not (Test-Path $ejemplo)) { Terminar 1 'No se encuentra config.ejemplo.json' }
        $texto = Get-Content $ejemplo -Raw -Encoding UTF8
        $texto = [regex]::Replace($texto, '"tunel"\s*:\s*"(?:[^"\\]|\\.)*"', { param($m) '"tunel": ' + (Json-Cadena $tunelElegido) })
        if ($R.navegador.canal -ne 'msedge') { $texto = [regex]::Replace($texto, '"canal"\s*:\s*"msedge"', '"canal": "chrome"') }
        [void]($texto | ConvertFrom-Json)   # comprueba que sigue siendo JSON válido
        $dirCfg = Split-Path $cfg
        if ($dirCfg -and -not (Test-Path $dirCfg)) { New-Item -ItemType Directory -Force $dirCfg | Out-Null }
        [IO.File]::WriteAllText($cfg, $texto, (New-Object System.Text.UTF8Encoding($false)))
        $R.config = [ordered]@{ ruta = $cfg; estado = 'creado' }
        Log "config.json creado con el túnel '$tunelElegido'." 'ok'
    }
    if ($tunelElegido) { $R.tunel = $tunelElegido }
    if ($R.tuneles.Count -gt 1) { Aviso "Hay varios túneles en FortiClient ($($R.tuneles -join ', ')); se usa '$tunelElegido'. Cámbialo con ""tunel"" en config.json." }
    if ($tunelElegido -and $R.tuneles.Count -and $R.tuneles -notcontains $tunelElegido) { Aviso "El túnel '$tunelElegido' no está en FortiClient (hay: $($R.tuneles -join ', '))." }

    # ------------------------------------------------------------ variable de entorno
    if ([Environment]::GetEnvironmentVariable('VPN_FORTI', 'User') -ne $VpnPs1) {
        [Environment]::SetEnvironmentVariable('VPN_FORTI', $VpnPs1, 'User')
        Log "Variable de usuario VPN_FORTI = $VpnPs1" 'ok'
    } else { Log "VPN_FORTI ya apuntaba a $VpnPs1" }
    $env:VPN_FORTI = $VpnPs1
    if (-not $Silencioso) { try { & (Join-Path $Raiz 'crear-acceso.ps1') | Out-Null; Log 'Acceso directo con icono creado.' } catch { Log "No se pudo crear el acceso directo: $($_.Exception.Message)" } }

    # ------------------------------------------------------------ diagnóstico (solo lectura)
    $dg = Ejecutar-VpnPs1 @('diagnosticar')
    $chk = Indexar-Chequeos $dg.json
    $R.diagnostico = Resumir-Diagnostico $dg.json
    if ($R.diagnostico.resumen) {
        Log "Diagnóstico: $($R.diagnostico.resumen.ok) correctas, $($R.diagnostico.resumen.avisos) avisos, $($R.diagnostico.resumen.errores) errores (detalle en $($R.diagnostico.ficheros.texto))." $(if ($R.diagnostico.resumen.errores -gt 0) { 'error' } elseif ($R.diagnostico.resumen.avisos -gt 0) { 'aviso' } else { 'ok' })
        foreach ($p in @($R.diagnostico.problemas)) { Log "  [$($p.estado)] $($p.id): $($p.detalle)" $(if ($p.estado -eq 'error') { 'error' } else { 'aviso' }) }
    } else { Aviso 'No se ha podido ejecutar el diagnóstico (vpn.cmd diagnosticar).' }
    $esAdmin = [bool](Dato-Chequeo $chk 'usuario.admin' 'administradorLocal')
    $estServicio = Dato-Chequeo $chk 'servicio' 'estado'
    $huboCambios = $false

    # ------------------------------------------------------------ tarea del servicio de FortiClient
    # Sin ella, tras reiniciar FortiClient pide un UAC para arrancar su servicio (FA_Scheduler).
    $e = Ejecutar-VpnPs1 @('estado')
    $ts = if ($e.json) { $e.json.tareaServicio } else { $null }
    $pasoManual = 'un administrador del equipo debe arrancar el servicio de FortiClient (FA_Scheduler) desde una consola de administrador con "sc start FA_Scheduler" (queda en marcha hasta reiniciar), o instalar la tarea con "vpn.cmd instalar-tarea" desde esa cuenta.'
    if ($ts -and $ts.instalada -and @($ts.problemas).Count -eq 0) { $R.tarea = $true; Log 'Tarea vpn-forti-servicio ya instalada.' 'ok' }
    elseif ($SinTarea -or ($Silencioso -and -not $InstalarTarea)) {
        $R.tarea = $false
        Aviso 'Falta la tarea que arranca el servicio de FortiClient sin UAC: ejecuta una vez "vpn.cmd instalar-tarea" (o instalar.ps1 -InstalarTarea) y acepta el UAC.'
    } elseif (-not $esAdmin) {
        $R.tarea = $false
        Aviso "Tu usuario no es administrador local: no se puede instalar la tarea que arranca el servicio de FortiClient. Paso manual: $pasoManual"
    } else {
        Log 'Instalando la tarea vpn-forti-servicio: acepta el Control de cuentas de usuario (solo esta vez).'
        $t = Ejecutar-VpnPs1 @('instalar-tarea')
        $R.tarea = ($t.codigo -eq 0)
        $huboCambios = $true
        if ($R.tarea) { Log 'Tarea instalada: la VPN se reconectará sin UAC.' 'ok' }
        else { Aviso "No se ha instalado la tarea ($(if ($t.json) { $t.json.mensaje } else { "código $($t.codigo)" })). Ejecuta ""vpn.cmd instalar-tarea"" cuando quieras." }
    }

    # ------------------------------------------------------------ servicio de FortiClient parado
    # Con la tarea se arranca sin UAC. Sin servicio en marcha no se hace la prueba de arranque (provocaría el UAC).
    if ($estServicio -and $estServicio -ne 'Running') {
        if ($R.tarea) {
            Log "El servicio FA_Scheduler está ${estServicio}: lo arranco con la tarea."
            $a = Ejecutar-VpnPs1 @('arrancar-servicio')
            $huboCambios = $true
            if ($a.codigo -eq 0) { $estServicio = 'Running'; Log 'Servicio FA_Scheduler en marcha.' 'ok' }
            else { Aviso "No se ha podido arrancar el servicio FA_Scheduler ($(if ($a.json) { $a.json.mensaje } else { "código $($a.codigo)" }))." }
        } elseif (-not $esAdmin) {
            Aviso "El servicio FA_Scheduler está parado y tu usuario no es administrador local. Paso manual: $pasoManual"
        } else {
            Aviso 'El servicio FA_Scheduler está parado y no hay tarea que lo arranque: FortiClient pedirá el UAC al abrirse.'
        }
    }
    $R.servicio = [ordered]@{ estado = $estServicio; inicio = (Dato-Chequeo $chk 'servicio' 'inicio') }

    # ------------------------------------------------------------ credencial
    $rc = Ejecutar-VpnPs1 @('credencial')
    if ($rc.codigo -eq 0 -and $rc.json) {
        $R.credencial = $true; $R.usuario = $rc.json.usuario
        Log "Credencial encontrada ($($rc.json.target), usuario $($rc.json.usuario))." 'ok'
    } else {
        $R.credencial = $false
        if ($PedirCredencial) {
            if (-not $R.tunel) { Aviso 'No se puede pedir la credencial sin un túnel de FortiClient configurado.' }
            else {
                Log 'Pidiendo la credencial de la VPN...'
                $g = Ejecutar-VpnPs1 @('guardar-credencial')
                if ($g.codigo -eq 0) {
                    $R.credencial = $true; if ($g.json) { $R.usuario = $g.json.usuario }
                    Log 'Credencial guardada.' 'ok'
                } else {
                    Terminar 4 'No se ha guardado la credencial de la VPN (cancelado). Ejecuta vpn.cmd guardar-credencial cuando quieras.'
                }
            }
        } else {
            Aviso 'No hay credencial de la VPN: ejecuta "vpn.cmd guardar-credencial" (o instalar.ps1 -PedirCredencial).'
        }
    }

    # ------------------------------------------------------------ prueba de arranque de la consola de FortiClient
    # Abre y cierra la consola por modos y guarda en config.json (consola.modo) el primero que no muestra el error de
    # Electron («reading 'TraceLog'»). Solo la primera vez, si cambia la versión de FortiClient, si no hay modo guardado
    # o con -ProbarArranque: así reinstalar no abre FortiClient cada vez (idempotente).
    $codigoFinal = 0; $mensajeFinal = $null
    $fArranque = Join-Path $DirDatos 'arranque.json'
    $previo = Leer-JsonFichero $fArranque
    $cfgActual = Leer-JsonFichero $cfg
    $modoGuardado = if ($cfgActual -and $cfgActual.consola) { [string]$cfgActual.consola.modo } else { '' }
    $versionForti = [string](Dato-Chequeo $chk 'forticlient.version' 'version')
    $hacer = (-not $SinPruebaArranque) -and ($ProbarArranque -or -not $modoGuardado -or -not $previo -or $previo.omitida -or -not $previo.modoElegido -or ([string]$previo.fortiClientVersion -ne $versionForti))
    if ($SinPruebaArranque) { $R.arranque = [ordered]@{ hecha = $false; motivo = 'desactivada (-SinPruebaArranque)'; modo = $modoGuardado } }
    elseif (-not $hacer) {
        $R.arranque = [ordered]@{ hecha = $false; motivo = 'ya probada con esta versión de FortiClient'; modo = $modoGuardado }
        Log "Prueba de arranque ya hecha: consola.modo = '$modoGuardado' (-ProbarArranque la repite)." 'ok'
    } else {
        $argumentos = @('probar-arranque', '-Guardar')
        $abierto = [bool](Dato-Chequeo $chk 'forticlient.abierto' 'abierto')
        $vpnActiva = [bool](Dato-Chequeo $chk 'vpn' 'adaptadorActivo')
        if ($abierto -and -not $vpnActiva) {
            if ($CerrarForti -or (Preguntar-SiNo 'FortiClient está abierto. La prueba de arranque lo cerrará (cierre ordenado) y lo abrirá varias veces. ¿Lo cierro ahora?')) { $argumentos += '-CerrarAbierto' }
        }
        if (-not $Silencioso) { Log 'Probando cómo abre FortiClient (verás abrirse y cerrarse su ventana; no se pulsa Conectar)...' }
        $pa = Ejecutar-VpnPs1 $argumentos
        $huboCambios = $true
        $j = $pa.json
        $R.arranque = [ordered]@{ hecha = ($pa.codigo -ne 9); codigo = $pa.codigo; modo = $(if ($j) { $j.modoElegido } else { $null }); motivo = $(if ($j) { $j.motivo } else { $null }); resultados = $(if ($j) { @($j.resultados) } else { @() }) }
        switch ($pa.codigo) {
            0 { Log "Consola de FortiClient: el modo $($j.modoElegido) la abre sin error (consola.modo guardado en config.json)." 'ok' }
            9 { Aviso "No se ha hecho la prueba de arranque de la consola ($(if ($j -and $j.mensaje) { $j.mensaje } else { 'omitida' })) Repítela con ""vpn.cmd probar-arranque -Guardar"" o instalar.ps1 -ProbarArranque." }
            8 {
                $codigoFinal = 5
                $mensajeFinal = "Instalado, pero FortiClient muestra el error de Electron («reading 'TraceLog'») con todos los modos de arranque probados. Envía $($R.diagnostico.ficheros.texto) (sin contraseñas ni PIN, usuario enmascarado) a quien te instaló la herramienta."
            }
            default { Aviso "La prueba de arranque ha terminado con el código $($pa.codigo)$(if ($j -and $j.mensaje) { ": $($j.mensaje)" })." }
        }
    }

    # Refresca diagnostico.txt/json con el estado final (tarea, servicio y prueba de arranque).
    if ($huboCambios) {
        $dg2 = Ejecutar-VpnPs1 @('diagnosticar')
        if ($dg2.json) { $R.diagnostico = Resumir-Diagnostico $dg2.json }
    }

    Terminar $codigoFinal $mensajeFinal
} catch {
    Terminar 1 "Error inesperado: $($_.Exception.Message)"
}
