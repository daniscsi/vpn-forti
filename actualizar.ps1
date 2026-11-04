# Comprueba al arrancar si hay una versión nueva en origin y, si la hay, la descarga (git pull --ff-only).
# Se comprueba SIEMPRE que se lanza (sin límite de tiempo; opcional: ACTUALIZAR_CADA_MIN=N para comprobar como mucho
# cada N minutos). Silencioso (nada en stdout: los llamadores leen el JSON de la herramienta); deja rastro en actualizar.log
# y, tras un pull correcto, el marcador .actualizado (version=, de=, a=, hora=) para que el .cmd lo avise y reinicie lo que haga falta.
# Si hay commits nuevos pero el árbol tiene cambios locales, no toca nada y deja .actualizacion-pendiente con el motivo.
# Sin red el fetch se corta a los 15 s. Desactivar: ACTUALIZAR_SIN=1.
param([switch]$Forzar)
$ErrorActionPreference = 'Continue'
# Ningún git de este script pregunta nada ni abre la ventana del Git Credential Manager (corre oculto en cada arranque).
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'
if ($env:ACTUALIZAR_SIN -and -not $Forzar) { return }
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$marca = Join-Path $aqui '.ultima-comprobacion'
$marcador = Join-Path $aqui '.actualizado'
$pendiente = Join-Path $aqui '.actualizacion-pendiente'
$log = Join-Path $aqui 'actualizar.log'
function Log($m) { try { Add-Content -Encoding UTF8 $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" } catch {} }
# git con tope de tiempo (si se pasa, se mata el árbol de procesos). Devuelve el código de salida o $null si se cortó.
function Git-Con-Tope([int]$segundos, [string[]]$argumentos) {
    $sal = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process git -ArgumentList $argumentos -NoNewWindow -PassThru -RedirectStandardOutput $sal -RedirectStandardError $err
        $null = $p.Handle
        if (-not $p.WaitForExit($segundos * 1000)) { & taskkill /F /T /PID $p.Id *> $null; return $null }
        return $p.ExitCode
    } finally { Remove-Item $sal, $err -Force -ErrorAction SilentlyContinue }
}
try {
    if (-not (Test-Path (Join-Path $aqui '.git')) -or -not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $cadaMin = 0; [void][int]::TryParse("$env:ACTUALIZAR_CADA_MIN", [ref]$cadaMin)
    if (-not $Forzar -and $cadaMin -gt 0 -and (Test-Path $marca) -and ((Get-Date) - (Get-Item $marca).LastWriteTime).TotalMinutes -lt $cadaMin) { return }
    New-Item -ItemType File -Force $marca | Out-Null; (Get-Item $marca).LastWriteTime = Get-Date
    $env:GIT_TERMINAL_PROMPT = '0'
    $rc = Git-Con-Tope 15 @('-C', "`"$aqui`"", '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=15', 'fetch', '--quiet')
    if ($null -eq $rc) { Log 'fetch: sin respuesta en 15 s; se sigue sin actualizar'; return }
    if ($rc -ne 0) { Log "fetch: código $rc"; return }
    $detras = [int](git -C $aqui rev-list --count 'HEAD..@{u}' 2>$null)
    if ($detras -eq 0) { Remove-Item $pendiente -Force -ErrorAction SilentlyContinue; return }
    if (git -C $aqui status --porcelain --untracked-files=no) {
        $motivo = "hay $detras commits nuevos pero el árbol tiene cambios locales; no se actualiza"
        Log $motivo
        Set-Content -Encoding UTF8 $pendiente @("commits=$detras", "motivo=$motivo", "hora=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        return
    }
    $antes = git -C $aqui rev-parse HEAD
    git -C $aqui pull --ff-only --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Log "pull: código $LASTEXITCODE"
        Set-Content -Encoding UTF8 $pendiente @("commits=$detras", "motivo=el pull ha fallado (código $LASTEXITCODE)", "hora=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        return
    }
    $despues = git -C $aqui rev-parse HEAD
    $version = ''
    try { $version = (Get-Content (Join-Path $aqui 'VERSION') -TotalCount 1).Trim() } catch {}
    if (-not $version) { $version = $despues.Substring(0, 7) }
    Remove-Item $pendiente -Force -ErrorAction SilentlyContinue
    # ASCII sin BOM: lo lee el .cmd con for /f
    Set-Content -Encoding ASCII $marcador @("version=$version", "de=$($antes.Substring(0,7))", "a=$($despues.Substring(0,7))", "hora=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    Log "ACTUALIZADO a la versión $version ($($antes.Substring(0,7)) -> $($despues.Substring(0,7)))"
    $cambios = @(git -C $aqui diff --name-only $antes $despues)
    if ($cambios -contains 'package-lock.json' -or $cambios -contains 'package.json') {
        if (Get-Command npm -ErrorAction SilentlyContinue) { Push-Location $aqui; npm ci --silent *> $null; Pop-Location; Log 'npm ci' }
    }
} catch { Log "error: $($_.Exception.Message)" }
