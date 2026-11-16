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
     Si "diagnosticar" falla o su salida no es JSON válido, el rol de administrador local se averigua por cuenta
     propia (whoami /groups) y, si tampoco se puede, se actúa como en la 1.2.2 (intentar instalar la tarea).
  8. Prueba de arranque de la consola de FortiClient ("vpn.ps1 probar-arranque -Guardar"): abre y cierra la consola
     por modos (A-D), detecta el diálogo de error de Electron («reading 'TraceLog'») y guarda en config.json
     (consola.modo) el primero que deja la consola abierta Y con el formulario manejable. Solo se hace la primera
     vez, tras cambiar la versión de FortiClient o con -RepetirPrueba. Se omite (con aviso, sin cambiar el código) si
     hay VPN conectada, una conexión en curso, el servicio no está en marcha o FortiClient está abierto y no se ha
     permitido cerrarlo (-CerrarForti; sin -Silencioso lo pregunta). Nunca cierra FortiClient con la VPN conectada.
     CON -Silencioso NO SE HACE si no se pasa -ProbarArranque (abre y cierra FortiClient, hasta varios minutos): el
     JSON lleva arranque.omitida = true y arranque.motivo = "silencioso-sin-prueba". La prueba tiene un tope de
     5 minutos y va escribiendo en stderr (y en instalar.log) lo que hace cada modo.

  Con -Silencioso no muestra mensajes ni ventanas propios, salvo el diálogo de la credencial, el UAC (con
  -InstalarTarea) y, solo con -ProbarArranque, las ventanas de FortiClient que se abren y cierran durante la prueba.
  El progreso va a stderr y a instalar.log. Escribe en stdout una única línea JSON:
    {"ok":true,"codigo":0,"version":"1.0.0","vpnForti":"...\vpn.ps1","tunel":"...","credencial":true,...}

  Códigos de salida:
    0 instalado (o ya lo estaba)          1 error inesperado
    2 falta un requisito (ver "faltan")   3 ha fallado npm
    4 instalado, pero se ha pedido la credencial y no se ha guardado (cancelada)
    5 instalado, pero la prueba de arranque ha probado TODOS los modos y ninguno deja la consola abierta y manejable
      sin el error de Electron («reading 'TraceLog'»): enviar diagnostico.txt (ruta en "diagnostico.ficheros").
      Una prueba omitida o interrumpida (VPN conectada, FortiClient abierto, UAC pendiente, tiempo agotado…)
      NUNCA da el 5: queda en "avisos" y en arranque.omitida/motivo.
#>
[CmdletBinding()]
param(
    [switch]$PedirCredencial,
    [switch]$Silencioso,
    [string]$Tunel,
    [switch]$InstalarTarea,
    [switch]$SinTarea,
    [switch]$SinPruebaArranque,
    [switch]$ProbarArranque,    # autoriza la prueba (obligatorio con -Silencioso); se hace si hace falta
    [switch]$RepetirPrueba,     # la repite aunque ya haya un modo guardado verificado
    [switch]$CerrarForti,
    [int]$TopePruebaSeg = 300   # tope de la prueba de arranque (segundos)
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

function Es-AdminLocalPropio {
    # Rol de administrador local sin depender de "diagnosticar": whoami /groups lista el grupo Administradores
    # (S-1-5-32-544) aunque sea «solo para denegar» (UAC sin elevar). $null si no se puede determinar.
    try {
        $sids = @(& whoami.exe /groups /fo csv /nh 2>$null | ConvertFrom-Csv -Header nombre, tipo, sid, atributos | ForEach-Object { $_.sid } | Where-Object { $_ })
        if ($sids.Count -eq 0) { return $null }
        return [bool]($sids -contains 'S-1-5-32-544')
    } catch { return $null }
}

function Ejecutar-PruebaConProgreso([string[]]$Argumentos, [int]$TimeoutSeg = 300) {
    # "vpn.ps1 probar-arranque": proceso aparte con tope de tiempo. Su progreso (una línea por modo, que vpn.ps1 escribe
    # en stderr) se va mostrando según llega: en pantalla, o en stderr y en instalar.log con -Silencioso.
    $fo = Join-Path $DirDatos 'prueba-arranque.out'; $fe = Join-Path $DirDatos 'prueba-arranque.err'
    Remove-Item $fo, $fe -ErrorAction SilentlyContinue
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$VpnPs1`"") + $Argumentos
    $p = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardOutput $fo -RedirectStandardError $fe
    $null = $p.Handle   # Start-Process -PassThru: sin tocar el Handle, ExitCode puede quedar vacío (0) en PowerShell 5.1
    $script:vistas = 0; $agotado = $false
    $limite = (Get-Date).AddSeconds($TimeoutSeg)
    $mostrar = {
        $l = @(if (Test-Path $fe) { Get-Content $fe -Encoding UTF8 -ErrorAction SilentlyContinue })
        for ($i = $script:vistas; $i -lt $l.Count; $i++) { Log "  vpn.ps1: $($l[$i])" }
        $script:vistas = $l.Count
    }
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 700
        & $mostrar
        if ((Get-Date) -gt $limite) { $agotado = $true; try { $p.Kill() } catch { }; break }
    }
    [void]$p.WaitForExit(5000)
    & $mostrar
    $json = $null
    $todas = @(if (Test-Path $fo) { Get-Content $fo -Encoding UTF8 -ErrorAction SilentlyContinue })
    $linea = @($todas | Where-Object { $_ -like '{*' }) | Select-Object -Last 1
    if ($linea) { try { $json = $linea | ConvertFrom-Json } catch { } }
    # El código sale del proceso y, si no, del campo "codigo" de su JSON (vpn.ps1 lo escribe siempre).
    $cod = $(if ($agotado) { -1 } elseif ($null -ne $p.ExitCode) { [int]$p.ExitCode } else { 0 })
    if (-not $agotado -and $json -and $null -ne $json.codigo -and $cod -eq 0) { $cod = [int]$json.codigo }
    return [pscustomobject]@{ codigo = $cod; json = $json; agotado = $agotado }
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
    }
    $diagOk = [bool]($dg.json -and $dg.json.comprobaciones -and @($dg.json.comprobaciones).Count -gt 0)
    if (-not $diagOk) { Aviso "El diagnóstico no ha devuelto un JSON válido (código $($dg.codigo)): se averiguan por otra vía el rol de administrador, el servicio y la versión de FortiClient." }
    $huboCambios = $false

    # ------------------------------------------------------------ tarea del servicio de FortiClient
    # Sin ella, tras reiniciar FortiClient pide un UAC para arrancar su servicio (FA_Scheduler).
    $e = Ejecutar-VpnPs1 @('estado')
    # Administrador local: del diagnóstico o, si falta, de whoami /groups; si no se puede saber se actúa como la 1.2.2
    # (intentar instalar la tarea): nunca se da por «no administrador» sin saberlo.
    $adminDiag = Dato-Chequeo $chk 'usuario.admin' 'administradorLocal'
    $esAdmin = $(if ($null -ne $adminDiag) { [bool]$adminDiag } else { Es-AdminLocalPropio })
    if ($null -eq $esAdmin) { $esAdmin = $true; Log 'No se ha podido determinar si el usuario es administrador local: se intenta como en la 1.2.2.' }
    $estServicio = Dato-Chequeo $chk 'servicio' 'estado'
    if (-not $estServicio -and $e.json -and $e.json.servicioForti) { $estServicio = [string]$e.json.servicioForti.estado }
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
    # Abre y cierra la consola por modos y guarda en config.json (consola.modo) el primero que deja la consola abierta y
    # manejable sin el error de Electron («reading 'TraceLog'»). Solo la primera vez, si cambia la versión de FortiClient,
    # si no hay modo guardado o con -RepetirPrueba: así reinstalar no abre FortiClient cada vez (idempotente).
    # Con -Silencioso solo con -ProbarArranque explícito (abre y cierra FortiClient unos minutos).
    $codigoFinal = 0; $mensajeFinal = $null
    $fArranque = Join-Path $DirDatos 'arranque.json'
    $previo = Leer-JsonFichero $fArranque
    $cfgActual = Leer-JsonFichero $cfg
    $modoGuardado = if ($cfgActual -and $cfgActual.consola) { [string]$cfgActual.consola.modo } else { '' }
    # Versión de FortiClient: del propio exe (si no, del diagnóstico), para que la comparación no falle si falta el diagnóstico.
    $versionForti = ''
    try { $versionForti = [string](Get-Item $forti).VersionInfo.ProductVersion } catch { }
    if (-not $versionForti) { $versionForti = [string](Dato-Chequeo $chk 'forticlient.version' 'version') }
    $hizoFalta = (-not $modoGuardado) -or (-not $previo) -or [bool]$previo.omitida -or (-not $previo.modoElegido) -or ($versionForti -and [string]$previo.fortiClientVersion -ne $versionForti)
    $quiere = $RepetirPrueba -or $hizoFalta
    if ($SinPruebaArranque) {
        $R.arranque = [ordered]@{ hecha = $false; omitida = $true; motivo = 'desactivada'; modo = $modoGuardado }
    } elseif (-not $quiere) {
        $R.arranque = [ordered]@{ hecha = $false; omitida = $false; motivo = 'ya-probada'; modo = $modoGuardado }
        Log "Prueba de arranque ya hecha con esta versión de FortiClient: consola.modo = '$modoGuardado' (-RepetirPrueba la repite)." 'ok'
    } elseif ($Silencioso -and -not $ProbarArranque) {
        $R.arranque = [ordered]@{ hecha = $false; omitida = $true; motivo = 'silencioso-sin-prueba'; modo = $modoGuardado }
        Aviso 'Con -Silencioso no se abre FortiClient: falta probar cómo abre la consola. Ejecútalo con -ProbarArranque (abre y cierra FortiClient unos minutos) o ejecuta "vpn.cmd probar-arranque -Guardar".'
    } else {
        $argumentos = @('probar-arranque', '-Guardar')
        # Estado local, sin depender del diagnóstico: FortiClient abierto y, ante la duda, VPN activa.
        $abierto = (@(Get-Process FortiClient -ErrorAction SilentlyContinue).Count -gt 0)
        $vpnDiag = Dato-Chequeo $chk 'vpn' 'adaptadorActivo'
        $vpnActiva = $(if ($null -ne $vpnDiag) { [bool]$vpnDiag } elseif ($e.json -and $null -ne $e.json.conectada) { [bool]$e.json.conectada } else { $true })
        if ($abierto -and -not $vpnActiva) {
            if ($CerrarForti -or (Preguntar-SiNo 'FortiClient está abierto. La prueba de arranque lo cerrará (cierre ordenado) y lo abrirá varias veces. ¿Lo cierro ahora?')) { $argumentos += '-CerrarAbierto' }
        }
        Log "Voy a abrir y cerrar FortiClient durante unos minutos para probar cómo abre su consola (no se pulsa «Conectar» ni se escribe nada; nunca con la VPN conectada). Tope: $TopePruebaSeg s."
        $pa = Ejecutar-PruebaConProgreso $argumentos $TopePruebaSeg
        $huboCambios = $true
        $j = $pa.json
        $mot = if ($pa.agotado) { 'tiempo-agotado' } elseif ($j) { $j.motivo } else { $null }
        $R.arranque = [ordered]@{ hecha = ($pa.codigo -ne 9 -and -not $pa.agotado); omitida = [bool]($pa.agotado -or $pa.codigo -eq 9); codigo = $pa.codigo; modo = $(if ($j) { $j.modoElegido } else { $null }); motivo = $mot; resultados = $(if ($j) { @($j.resultados) } else { @() }) }
        if ($pa.agotado) {
            Aviso "La prueba de arranque no ha terminado en $TopePruebaSeg s y se ha cortado. Si FortiClient ha quedado abierto, ciérralo y repite con ""vpn.cmd probar-arranque -Guardar""."
        } else {
            switch ($pa.codigo) {
                0 { Log "Consola de FortiClient: el modo $($j.modoElegido) la deja abierta y manejable$(if ($j.guardado) { ' (consola.modo guardado en config.json)' })." 'ok' }
                9 { Aviso "No se ha hecho o se ha interrumpido la prueba de arranque de la consola ($(if ($j -and $j.mensaje) { $j.mensaje } else { 'omitida' })) Repítela con ""vpn.cmd probar-arranque -Guardar"" o instalar.ps1 -ProbarArranque -RepetirPrueba." }
                8 {
                    $codigoFinal = 5
                    $mensajeFinal = "Instalado, pero ningún modo de arranque deja la consola de FortiClient abierta y manejable sin el error de Electron («reading 'TraceLog'»). Envía $($R.diagnostico.ficheros.texto) (sin contraseñas ni PIN, usuario enmascarado) a quien te instaló la herramienta."
                }
                default { Aviso "La prueba de arranque ha terminado con el código $($pa.codigo)$(if ($j -and $j.mensaje) { ": $($j.mensaje)" })." }
            }
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
