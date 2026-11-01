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
  5. Con -PedirCredencial, abre el diálogo de "vpn.ps1 guardar-credencial" si aún no hay credencial genérica.

  Con -Silencioso no muestra nada salvo el diálogo de la credencial, y escribe en stdout una única línea JSON:
    {"ok":true,"codigo":0,"version":"1.0.0","vpnForti":"...\vpn.ps1","tunel":"...","credencial":true,...}

  Códigos de salida:
    0 instalado (o ya lo estaba)          1 error inesperado
    2 falta un requisito (ver "faltan")   3 ha fallado npm
    4 instalado, pero se ha pedido la credencial y no se ha guardado (cancelada)
#>
[CmdletBinding()]
param(
    [switch]$PedirCredencial,
    [switch]$Silencioso,
    [string]$Tunel
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

    Terminar 0 $null
} catch {
    Terminar 1 "Error inesperado: $($_.Exception.Message)"
}
