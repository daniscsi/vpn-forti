# Comprueba al arrancar si hay una versión nueva en origin y, si la hay, la descarga (fast-forward), con la lógica común
# de actualizar-git.ps1 (copia idéntica en visor-pruebas, vpn-forti y QA_Assistant).
# Se comprueba SIEMPRE que se lanza (sin límite de tiempo; opcional: ACTUALIZAR_CADA_MIN=N para comprobar como mucho
# cada N minutos). Silencioso (nada en stdout: los llamadores leen el JSON de la herramienta); deja rastro en actualizar.log
# y, tras actualizar, el marcador .actualizado (version=, de=, a=, hora=) para que el .cmd lo avise y reinicie lo que haga falta.
# Con trabajo local se actualiza IGUAL sin perderlo: copia de seguridad fuera del repo, stash, fast-forward y stash pop
# (si choca, el árbol queda limpio en la versión nueva y el trabajo sigue en el stash), y se apunta un pendiente
# PRIORITARIO que muestra el visor de pruebas (ver actualizar-git.ps1). Si no se puede (otra rama, commits locales sin
# subir, merge a medias...) no toca nada y deja .actualizacion-pendiente con el motivo.
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
# La lógica común de puesta al día (copia de seguridad, stash, fast-forward, pop y pendiente prioritario)
. (Join-Path $aqui 'actualizar-git.ps1')
try {
    if (-not (Test-Path (Join-Path $aqui '.git')) -or -not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $cadaMin = 0; [void][int]::TryParse("$env:ACTUALIZAR_CADA_MIN", [ref]$cadaMin)
    if (-not $Forzar -and $cadaMin -gt 0 -and (Test-Path $marca) -and ((Get-Date) - (Get-Item $marca).LastWriteTime).TotalMinutes -lt $cadaMin) { return }
    New-Item -ItemType File -Force $marca | Out-Null; (Get-Item $marca).LastWriteTime = Get-Date
    $res = Invoke-ActualizacionGit -Repo $aqui -App 'vpn-forti' -RamaEsperada '' -TopeFetch 15 -LogFn { param($m) Log $m } | Select-Object -Last 1
    if ($res.estado -eq 'al-dia') { Remove-Item $pendiente -Force -ErrorAction SilentlyContinue; return }
    if (-not $res.ok -or -not ("$($res.estado)" -like 'actualizado*')) {
        if ($res.detras -gt 0) { Set-Content -Encoding UTF8 $pendiente @("commits=$($res.detras)", "motivo=$($res.mensaje)", "hora=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") }
        return
    }
    $antes = $res.antes
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
