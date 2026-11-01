# Comprueba al arrancar si hay una versión nueva en origin y, si la hay, la descarga (git pull --ff-only).
# Silencioso (nada en stdout: los llamadores leen el JSON de la herramienta), como mucho una vez por hora,
# sin tocar nada si el árbol tiene cambios locales o no hay red/git. Desactivar: ACTUALIZAR_SIN=1.
param([switch]$Forzar)
$ErrorActionPreference = 'Stop'
if ($env:ACTUALIZAR_SIN -and -not $Forzar) { return }
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$marca = Join-Path $aqui '.ultima-comprobacion'
$log = Join-Path $aqui 'actualizar.log'
function Log($m) { try { Add-Content -Encoding UTF8 $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" } catch {} }
try {
    if (-not (Test-Path (Join-Path $aqui '.git')) -or -not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    if (-not $Forzar -and (Test-Path $marca) -and ((Get-Date) - (Get-Item $marca).LastWriteTime).TotalMinutes -lt 60) { return }
    New-Item -ItemType File -Force $marca | Out-Null; (Get-Item $marca).LastWriteTime = Get-Date
    $env:GIT_TERMINAL_PROMPT = '0'
    git -C $aqui -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 fetch --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Log "fetch: código $LASTEXITCODE"; return }
    $detras = [int](git -C $aqui rev-list --count 'HEAD..@{u}' 2>$null)
    if ($detras -eq 0) { return }
    if (git -C $aqui status --porcelain --untracked-files=no) { Log "hay $detras commits nuevos pero el árbol tiene cambios locales; no se actualiza"; return }
    $antes = git -C $aqui rev-parse HEAD
    git -C $aqui pull --ff-only --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Log "pull: código $LASTEXITCODE"; return }
    Log "actualizado $($antes.Substring(0,7)) -> $((git -C $aqui rev-parse --short HEAD))"
    $cambios = @(git -C $aqui diff --name-only $antes HEAD)
    if ($cambios -contains 'package-lock.json' -or $cambios -contains 'package.json') {
        if (Get-Command npm -ErrorAction SilentlyContinue) { Push-Location $aqui; npm ci --silent *> $null; Pop-Location; Log 'npm ci' }
    }
} catch { Log "error: $($_.Exception.Message)" }