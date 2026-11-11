# actualizar-git.ps1: la puesta al día común de un clon de git (visor-pruebas, vpn-forti y QA_Assistant llevan una
# copia IDÉNTICA de este fichero; un test del visor vigila que no diverjan).
#
# Invoke-ActualizacionGit deja el clon en la última versión de su rama aunque tenga trabajo local, sin perderlo nunca:
#   a) fetch de origin con tope de tiempo; si no hay commits nuevos, no hace nada más.
#   b) fast-forward (merge --ff-only, sin pisar ficheros ignorados). Con cambios locales (seguidos, o sin seguimiento que
#      choquen con lo que llega): primero COPIA DE SEGURIDAD fuera del repo (ACTUALIZAR_RESPALDO_DIR o
#      %USERPROFILE%\Herramientas\_respaldo-local\<app>\<fecha-hora>: HEAD, parche binario de lo seguido, copia de lo sin
#      seguimiento y estado), luego `git stash push -u -m "auto-actualizacion ..."`, fast-forward y `git stash pop` (por
#      sha, nunca stash@{0} a ciegas). Si el pop choca, el árbol queda limpio en la versión nueva y el stash se conserva.
#   c) si había trabajo local, apunta un pendiente PRIORITARIO para el visor en un JSON fuera de git:
#      <datos del visor>\pendientes-prioritarios\<app>-<equipo>-<huella del repo>.json (datos del visor: VISOR_DATOS o
#      %LOCALAPPDATA%\visor-pruebas). Se quita solo cuando el árbol está limpio y ya no queda ningún stash
#      «auto-actualizacion» (el trabajo se ha revisado y resuelto).
#   e) otra rama: avisa y no toca. HEAD separado, merge/rebase/cherry-pick a medias o commits locales sin subir
#      (divergido): respaldo + pendiente prioritario + aviso, sin tocar nada.
# Nunca reset --hard sobre trabajo sin respaldar, nunca borra un stash ni un respaldo, nunca hace push. Un candado en
# .git (auto-actualizacion.lock) evita que dos actualizaciones (p. ej. el visor y ejecutar_app.bat) se pisen.
#
# Uso: dot-source (`. actualizar-git.ps1`; sus parámetros quedan como variables del llamador: no usar $Repo, $App,
# $Rama, $Visible, $FicheroLog ni $TopeFetch a nivel de script) y llamar a Invoke-ActualizacionGit, o directamente:
#   powershell -File actualizar-git.ps1 -Repo <carpeta> -App <nombre> [-Rama <rama>|*] [-Visible] [-FicheroLog <fichero>]
#   Código de salida: 0 al día o actualizado sin trabajo local; 2 actualizado y había trabajo local (pendiente
#   apuntado); 1 NO se ha podido actualizar (sin red, otra rama, divergido, operación a medias, error...).
param([string]$Repo = '', [string]$App = '', [string]$Rama = '*', [switch]$Visible, [string]$FicheroLog = '',
      [int]$TopeFetch = 15)

$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'

function AG-Ahora { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }

# git sin tope; devuelve @{rc; salida} (stdout y stderr juntos, como texto)
function AG-Git([string]$repo, [string[]]$a) {
    $ErrorActionPreference = 'Continue'
    # git escribe UTF-8: sin esto, las rutas con acentos llegan mal (página de códigos de la consola)
    $codif = $null
    try { $codif = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
    try {
        $salida = & git -C $repo -c core.quotepath=off @a 2>&1 | ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
    } finally { if ($codif) { try { [Console]::OutputEncoding = $codif } catch {} } }
    return @{ rc = $rc; salida = (@($salida) -join "`n").Trim() }
}

# git con tope de tiempo (mata el árbol de procesos si se pasa): código de salida o $null si se cortó
function AG-GitTope([int]$segundos, [string[]]$argumentos) {
    $sal = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
    $script:AGErrorGit = ''
    try {
        $p = Start-Process git -ArgumentList $argumentos -NoNewWindow -PassThru -RedirectStandardOutput $sal -RedirectStandardError $err
        $null = $p.Handle
        if (-not $p.WaitForExit($segundos * 1000)) { & taskkill /F /T /PID $p.Id *> $null; return $null }
        try { $script:AGErrorGit = (((Get-Content -Raw $err) -replace '\s+', ' ').Trim() -replace '://[^/@\s]+@', '://') } catch {}
        if ($script:AGErrorGit.Length -gt 300) { $script:AGErrorGit = $script:AGErrorGit.Substring(0, 300) }
        return $p.ExitCode
    } finally { Remove-Item $sal, $err -Force -ErrorAction SilentlyContinue }
}

function AG-DirRespaldo { if ($env:ACTUALIZAR_RESPALDO_DIR) { $env:ACTUALIZAR_RESPALDO_DIR } else { Join-Path $env:USERPROFILE 'Herramientas\_respaldo-local' } }
function AG-DirPendientes {
    $datos = if ($env:VISOR_DATOS) { $env:VISOR_DATOS } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'visor-pruebas' } else { Join-Path $HOME '.local\share\visor-pruebas' }
    return (Join-Path $datos 'pendientes-prioritarios')
}
function AG-Equipo { if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName } }
function AG-Hash8([string]$texto) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($texto))
    return (-join ($b[0..3] | ForEach-Object { $_.ToString('x2') }))
}
function AG-ClaveRepo([string]$repo) { return AG-Hash8 ([IO.Path]::GetFullPath($repo).TrimEnd('\', '/').ToLowerInvariant()) }
function AG-FicheroPendiente([string]$repo, [string]$app, [string]$sufijo = '') {
    $seguro = ($app -replace '[^A-Za-z0-9_.-]', '_')
    $equipo = ((AG-Equipo) -replace '[^A-Za-z0-9_.-]', '_')
    return (Join-Path (AG-DirPendientes) "$seguro-$equipo-$(AG-ClaveRepo $repo)$sufijo.json")
}

# Pendiente PRIORITARIO aparte (otro fichero, otro id) cuando la app NO se ha podido actualizar y no hay trabajo local
# que lo explique (HEAD separado, rama sin origin, fast-forward fallido...). Se quita en cuanto se actualiza o está al día.
function AG-ApuntarSinActualizar([string]$repo, [string]$app, [string]$rama, [string]$mensaje) {
    $fichero = AG-FicheroPendiente $repo $app '-sin-actualizar'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fichero) | Out-Null
    $equipo = AG-Equipo
    $datos = [ordered]@{
        id = "prioritario-$($app -replace '[^A-Za-z0-9]+', '-')-$(AG-ClaveRepo $repo)-sin-actualizar".ToLowerInvariant()
        app = $app; equipo = $equipo; repo = $repo; rama = $rama
        titulo = "PRIORITARIO: $app no se ha podido actualizar en $equipo"
        detalle = "$app ($repo, rama $(if ($rama) { $rama } else { 'ninguna' })) se está usando en una versión que NO es la última: $mensaje. Este aviso se quita solo en cuanto se actualice."
        situacion = $mensaje; respaldo = ''; stash = ''; hora = (AG-Ahora)
    }
    $tmp = "$fichero.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($datos | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $fichero -Force
}

# merge, rebase, cherry-pick o revert a medias (o entradas sin fusionar en el índice): texto o ''
function AG-OperacionEnCurso([string]$repo) {
    $gd = (AG-Git $repo @('rev-parse', '--absolute-git-dir')).salida
    if (-not $gd) { return '' }
    $gd = $gd -replace '/', '\'
    if (Test-Path -LiteralPath (Join-Path $gd 'rebase-merge')) { return 'un rebase a medias' }
    if (Test-Path -LiteralPath (Join-Path $gd 'rebase-apply')) { return 'un rebase/am a medias' }
    if (Test-Path -LiteralPath (Join-Path $gd 'MERGE_HEAD')) { return 'un merge a medias' }
    if (Test-Path -LiteralPath (Join-Path $gd 'CHERRY_PICK_HEAD')) { return 'un cherry-pick a medias' }
    if (Test-Path -LiteralPath (Join-Path $gd 'REVERT_HEAD')) { return 'un revert a medias' }
    if ((AG-Git $repo @('ls-files', '-u')).salida) { return 'conflictos sin resolver en el índice' }
    return ''
}

function AG-StashesAuto([string]$repo) {
    $r = AG-Git $repo @('stash', 'list', '--format=%gd%x09%H%x09%s')
    return @($r.salida -split "`n" | Where-Object { $_ -match '(^|\s)auto-actualizacion ' })
}

# Copia de seguridad fuera del repo. Devuelve la carpeta (o '' si no se pudo escribir). $huella: si el último respaldo
# del pendiente tiene la misma huella y sigue existiendo, se reutiliza (no se duplica en cada arranque).
function AG-Respaldar([string]$repo, [string]$app, [string]$motivo, [string]$upstream, [int]$delante, [string]$previo) {
    $ErrorActionPreference = 'Continue'
    $head = (AG-Git $repo @('rev-parse', 'HEAD')).salida
    $status = (AG-Git $repo @('status', '--porcelain', '--untracked-files=all')).salida
    $tmpDiff = [IO.Path]::GetTempFileName()
    try {
        $null = AG-Git $repo @('diff', 'HEAD', '--binary', "--output=$tmpDiff")
        $hDiff = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmpDiff).Hash
    } finally { Remove-Item -LiteralPath $tmpDiff -Force -ErrorAction SilentlyContinue }
    $huella = AG-Hash8 "$head|$status|$hDiff|$delante|$motivo"
    if ($previo -and (Test-Path -LiteralPath (Join-Path $previo 'HEAD.txt'))) {
        $vieja = (Get-Content -LiteralPath (Join-Path $previo 'HEAD.txt') -Encoding UTF8 | Where-Object { $_ -like 'huella=*' } | Select-Object -First 1)
        if ($vieja -eq "huella=$huella") { return $previo }
    }
    $base = Join-Path (AG-DirRespaldo) ($app -replace '[^A-Za-z0-9_.-]', '_')
    $sello = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $base $sello
    for ($n = 2; Test-Path -LiteralPath $dir; $n++) { $dir = Join-Path $base "$sello-$n" }
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $null = AG-Git $repo @('diff', 'HEAD', '--binary', "--output=$(Join-Path $dir 'cambios.patch')")
        $null = AG-Git $repo @('diff', '--cached', '--binary', "--output=$(Join-Path $dir 'preparados.patch')")
        [IO.File]::WriteAllText((Join-Path $dir 'status.txt'), "$status`n", (New-Object Text.UTF8Encoding $false))
        # Sin seguimiento (no ignorados), con su ruta relativa
        $sinSeguir = (AG-Git $repo @('ls-files', '--others', '--exclude-standard', '-z')).salida -split "`0" | Where-Object { $_ }
        $fallos = @()
        foreach ($rel in $sinSeguir) {
            try {
                $origen = Join-Path $repo $rel
                $destino = Join-Path (Join-Path $dir 'sin-seguimiento') $rel
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destino) | Out-Null
                Copy-Item -LiteralPath $origen -Destination $destino -Force -ErrorAction Stop
            } catch { $fallos += "$rel : $($_.Exception.Message)" }
        }
        if ($fallos) { [IO.File]::WriteAllLines((Join-Path $dir 'sin-copiar.txt'), [string[]]$fallos, (New-Object Text.UTF8Encoding $false)) }
        # Commits locales sin subir: un bundle (además siguen en la rama)
        if ($delante -gt 0 -and $upstream) {
            $null = AG-Git $repo @('bundle', 'create', (Join-Path $dir 'commits-locales.bundle'), 'HEAD', "^$upstream")
        }
        # Operación a medias: sus ficheros de estado
        $gd = ((AG-Git $repo @('rev-parse', '--absolute-git-dir')).salida) -replace '/', '\'
        foreach ($f in @('MERGE_HEAD', 'MERGE_MSG', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'ORIG_HEAD')) {
            $p = Join-Path $gd $f
            if (Test-Path -LiteralPath $p) { New-Item -ItemType Directory -Force -Path (Join-Path $dir 'operacion') | Out-Null; Copy-Item -LiteralPath $p -Destination (Join-Path $dir 'operacion') -Force }
        }
        $rama = (AG-Git $repo @('symbolic-ref', '--quiet', '--short', 'HEAD')).salida
        [IO.File]::WriteAllLines((Join-Path $dir 'HEAD.txt'), [string[]]@(
            "app=$app", "equipo=$(AG-Equipo)", "repo=$repo", "rama=$rama", "head=$head", "upstream=$upstream",
            "motivo=$motivo", "hora=$(AG-Ahora)", "huella=$huella"), (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllLines((Join-Path $dir 'LEEME.txt'), [string[]]@(
            "Copia de seguridad del trabajo local de $app en $(AG-Equipo), hecha antes de actualizar ($(AG-Ahora)).",
            "Repo: $repo   rama: $rama   HEAD: $head",
            "- cambios.patch: todo lo seguido respecto a HEAD (git apply --binary cambios.patch)",
            "- preparados.patch: solo lo que estaba en el índice",
            "- sin-seguimiento\: copia de los ficheros sin seguimiento (no ignorados)",
            "- commits-locales.bundle: commits sin subir, si los había (git fetch <bundle> HEAD)",
            "- Además, si se apartó con stash: git stash list (mensaje «auto-actualizacion ...») en el repo."),
            (New-Object Text.UTF8Encoding $false))
    } catch { return '' }
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'HEAD.txt')) -or -not (Test-Path -LiteralPath (Join-Path $dir 'cambios.patch'))) { return '' }
    return $dir
}

function AG-LeerPendiente([string]$fichero) {
    if (-not (Test-Path -LiteralPath $fichero)) { return $null }
    try { return (Get-Content -Raw -Encoding UTF8 -LiteralPath $fichero -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

# Alta o actualización (upsert) del pendiente prioritario de este repo y equipo; escritura atómica
function AG-ApuntarPendiente([string]$repo, [string]$app, [string]$rama, [string]$respaldo, [string]$stash, [string]$situacion) {
    $fichero = AG-FicheroPendiente $repo $app
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fichero) | Out-Null
    $previo = AG-LeerPendiente $fichero
    $respaldos = @()
    if ($previo -and $previo.respaldos) { $respaldos = @($previo.respaldos | Where-Object { $_.ruta -ne $respaldo }) }
    $respaldos = @(@($respaldos) + @([ordered]@{ ruta = $respaldo; stash = $stash; situacion = $situacion; hora = (AG-Ahora) }))
    if ($respaldos.Count -gt 10) { $respaldos = $respaldos[($respaldos.Count - 10)..($respaldos.Count - 1)] }
    $equipo = AG-Equipo
    $detalle = "Trabajo local de $app en $equipo ($repo, rama $rama): $situacion Copia de seguridad: $respaldo."
    if ($stash) { $detalle += " Stash: «auto-actualizacion» $($stash.Substring(0, [Math]::Min(10, $stash.Length))) (git stash list)." }
    $detalle += ' Revísalo y resuélvelo (confirmar, descartar o reaplicar); este aviso se quita solo cuando el árbol está limpio y no queda ningún stash «auto-actualizacion».'
    $datos = [ordered]@{
        id = "prioritario-$($app -replace '[^A-Za-z0-9]+', '-')-$(AG-ClaveRepo $repo)".ToLowerInvariant()
        app = $app; equipo = $equipo; repo = $repo; rama = $rama
        titulo = "PRIORITARIO: revisar y resolver trabajo local pendiente de $app en $equipo"
        detalle = $detalle; situacion = $situacion; respaldo = $respaldo; stash = $stash
        hora = (AG-Ahora); respaldos = $respaldos
    }
    $json = $datos | ConvertTo-Json -Depth 5
    $tmp = "$fichero.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $fichero -Force
    return $fichero
}

# Quita el pendiente de este repo si ya está resuelto: árbol limpio, sin operación a medias, sin stash
# «auto-actualizacion» y sin commits locales sin subir
function AG-QuitarPendienteResuelto([string]$repo, [string]$app) {
    $fichero = AG-FicheroPendiente $repo $app
    if (-not (Test-Path -LiteralPath $fichero)) { return }
    if ((AG-Git $repo @('status', '--porcelain', '--untracked-files=no')).salida) { return }
    if (AG-OperacionEnCurso $repo) { return }
    if (AG-StashesAuto $repo) { return }
    $delante = AG-Git $repo @('rev-list', '--count', '@{u}..HEAD')
    if ($delante.rc -eq 0 -and [int]$delante.salida -gt 0) { return }
    Remove-Item -LiteralPath $fichero -Force -ErrorAction SilentlyContinue
}

function AG-Candado([string]$repo) {
    $gd = ((AG-Git $repo @('rev-parse', '--absolute-git-dir')).salida) -replace '/', '\'
    if (-not $gd) { return $null }
    $ruta = Join-Path $gd 'auto-actualizacion.lock'
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $fs = [IO.File]::Open($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $b = [Text.Encoding]::ASCII.GetBytes("pid=$PID`nhora=$(AG-Ahora)`n"); $fs.Write($b, 0, $b.Length); $fs.Close()
            return $ruta
        } catch {
            # uno de hace más de 10 min es de un proceso que murió: se quita y se reintenta una vez
            try { if (((Get-Date) - (Get-Item -LiteralPath $ruta).LastWriteTime).TotalMinutes -gt 10) { Remove-Item -LiteralPath $ruta -Force } else { return $null } } catch { return $null }
        }
    }
    return $null
}

# Pone al día $Repo. $RamaEsperada: '*' la rama activa sea cual sea; '' la rama por defecto de origin (origin/HEAD; si
# no se sabe, la activa); otra: solo esa. $LogFn: scriptblock que recibe cada línea de registro.
# Devuelve un hashtable: estado, ok (está en la última versión), detras, antes, despues, respaldo, stash, mensaje,
# trabajoLocal (se ha apuntado pendiente prioritario).
function Invoke-ActualizacionGit([string]$Repo, [string]$App, [string]$RamaEsperada = '*', [int]$TopeFetch = 15, [scriptblock]$LogFn = $null) {
    $ErrorActionPreference = 'Continue'
    $r = @{ estado = 'error'; ok = $false; detras = 0; antes = ''; despues = ''; respaldo = ''; stash = ''; mensaje = ''; trabajoLocal = $false; rama = '' }
    function L([string]$m) { if ($LogFn) { try { & $LogFn $m } catch {} } }
    function Fin([string]$estado, [string]$mensaje, [bool]$ok = $false) {
        $r.estado = $estado; $r.mensaje = $mensaje; $r.ok = $ok
        if ($mensaje) { L $mensaje }
        # Sin actualizar y sin trabajo local que lo explique: pendiente prioritario aparte. Sin red u otra rama no (no se
        # sabe si hay novedades / se avisa sin tocar); ocupado tampoco (es pasajero)
        try {
            if (Test-Path -LiteralPath (Join-Path $Repo '.git')) {
                if ($ok) { Remove-Item -LiteralPath (AG-FicheroPendiente $Repo $App '-sin-actualizar') -Force -ErrorAction SilentlyContinue }
                elseif ($estado -in @('sin-rama', 'sin-upstream', 'error') -and -not $r.trabajoLocal) { AG-ApuntarSinActualizar $Repo $App $r.rama $mensaje }
            }
        } catch {}
        return $r
    }
    $candado = $null
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return (Fin 'error' 'git no está instalado o no está en el PATH') }
        if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { return (Fin 'error' "$Repo no es un clon de git") }
        $candado = AG-Candado $Repo
        if (-not $candado) { return (Fin 'ocupado' 'otra actualización de este repo está en marcha; no se toca') }
        AG-QuitarPendienteResuelto $Repo $App
        $rama = (AG-Git $Repo @('symbolic-ref', '--quiet', '--short', 'HEAD')).salida
        $r.rama = $rama
        $rc = AG-GitTope $TopeFetch @('-C', "`"$Repo`"", '-c', 'http.lowSpeedLimit=1000', '-c', "http.lowSpeedTime=$TopeFetch", 'fetch', '--quiet', 'origin')
        if ($null -eq $rc) { return (Fin 'sin-red' "fetch sin respuesta en $TopeFetch s (¿sin red?); no se actualiza") }
        if ($rc -ne 0) { return (Fin 'sin-red' "fetch: código $rc (¿sin red o sin acceso a GitHub?): $script:AGErrorGit") }
        if ($RamaEsperada -eq '') {
            $def = (AG-Git $Repo @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')).salida
            $RamaEsperada = if ($def -match '^origin/(.+)$') { $Matches[1] } else { '*' }
        }
        if ($RamaEsperada -ne '*' -and $rama -ne $RamaEsperada) {
            # Otra rama o HEAD separado: no se toca; solo se avisa si hay commits nuevos de origin/<esperada> por bajar
            $base = if ((AG-Git $Repo @('rev-parse', '--verify', '--quiet', "refs/heads/$RamaEsperada")).rc -eq 0) { "refs/heads/$RamaEsperada" } else { 'HEAD' }
            $n = 0; [void][int]::TryParse((AG-Git $Repo @('rev-list', '--count', "$base..refs/remotes/origin/$RamaEsperada")).salida, [ref]$n)
            $r.detras = $n
            if ($n -le 0) { return (Fin 'al-dia' '' $true) }
            $donde = if ($rama) { "en la rama $rama (no en $RamaEsperada)" } else { 'en HEAD separado' }
            return (Fin 'otra-rama' "hay $n commits nuevos en origin/$RamaEsperada pero el repo de $App está $donde; no se actualiza")
        }
        if (-not $rama) { return (Fin 'sin-rama' "el repo de $App está en HEAD separado (sin rama); no se actualiza") }
        $up = (AG-Git $Repo @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'))
        $upstream = if ($up.rc -eq 0 -and $up.salida) { $up.salida } elseif ((AG-Git $Repo @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$rama")).rc -eq 0) { "origin/$rama" } else { '' }
        if (-not $upstream) { return (Fin 'sin-upstream' "la rama $rama de $App no tiene rama en origin; no se actualiza") }
        $detras = 0; [void][int]::TryParse((AG-Git $Repo @('rev-list', '--count', "HEAD..$upstream")).salida, [ref]$detras)
        $delante = 0; [void][int]::TryParse((AG-Git $Repo @('rev-list', '--count', "$upstream..HEAD")).salida, [ref]$delante)
        $r.detras = $detras
        if ($detras -eq 0) { return (Fin 'al-dia' '' $true) }
        $fPend = AG-FicheroPendiente $Repo $App
        $previo = AG-LeerPendiente $fPend
        $respaldoPrevio = if ($previo) { "$($previo.respaldo)" } else { '' }

        $op = AG-OperacionEnCurso $Repo
        if ($op -or $delante -gt 0) {
            $que = if ($op) { "tiene $op" } else { "ha divergido de $upstream ($delante commits locales sin subir, $detras nuevos)" }
            $resp = AG-Respaldar $Repo $App $que $upstream $delante $respaldoPrevio
            $r.respaldo = $resp
            $situacion = "NO se ha actualizado: $que (hay $detras commits nuevos). No se ha tocado nada."
            if ($resp) { $null = AG-ApuntarPendiente $Repo $App $rama $resp '' $situacion; $r.trabajoLocal = $true }
            $estado = if ($op) { 'operacion-a-medias' } else { 'divergido' }
            $extra = if ($resp) { "; copia de seguridad en $resp y pendiente prioritario apuntado" } else { '; NO se pudo escribir la copia de seguridad' }
            return (Fin $estado "el repo de $App $que; no se actualiza$extra")
        }

        $antes = (AG-Git $Repo @('rev-parse', 'HEAD')).salida
        $r.antes = $antes
        $lineas = @((AG-Git $Repo @('status', '--porcelain', '--untracked-files=all')).salida -split "`n" | Where-Object { $_ })
        $seguidos = @($lineas | Where-Object { -not $_.StartsWith('??') })
        $sinSeguir = @($lineas | Where-Object { $_.StartsWith('??') })
        if ($seguidos.Count -eq 0) {
            $m = AG-Git $Repo @('merge', '--ff-only', '--no-overwrite-ignore', '--quiet', $upstream)
            if ($m.rc -eq 0) {
                $r.despues = (AG-Git $Repo @('rev-parse', 'HEAD')).salida
                return (Fin 'actualizado' "actualizado ($detras commits nuevos de $upstream)" $true)
            }
            $det = ($m.salida -replace '\s+', ' ').Trim(); if ($det.Length -gt 200) { $det = $det.Substring(0, 200) }
            if ($sinSeguir.Count -eq 0) { return (Fin 'error' "la actualización del repo de $App ha fallado (código $($m.rc)): $det") }
            L "el fast-forward choca con ficheros sin seguimiento ($det); se aparta el trabajo local"
        }

        # Trabajo local: copia de seguridad (verificada) -> stash -> fast-forward -> pop
        $resp = AG-Respaldar $Repo $App 'cambios locales antes de actualizar' $upstream 0 ''
        if (-not $resp) { return (Fin 'error' "hay $detras commits nuevos pero no se pudo escribir la copia de seguridad del trabajo local de $App; no se toca nada") }
        $r.respaldo = $resp
        $cimaAntes = (AG-Git $Repo @('rev-parse', '-q', '--verify', 'refs/stash')).salida
        $etiqueta = "auto-actualizacion $App $(AG-Ahora)"
        $s = AG-Git $Repo @('stash', 'push', '-u', '-m', $etiqueta)
        $cima = (AG-Git $Repo @('rev-parse', '-q', '--verify', 'refs/stash')).salida
        if ($s.rc -ne 0 -or -not $cima -or $cima -eq $cimaAntes) {
            $situacion = "NO se ha actualizado: no se pudo apartar el trabajo local con stash ($(($s.salida -replace '\s+', ' ').Trim()))."
            $null = AG-ApuntarPendiente $Repo $App $rama $resp '' $situacion; $r.trabajoLocal = $true
            return (Fin 'error' "no se pudo apartar el trabajo local de $App (stash); no se actualiza. Copia de seguridad en $resp")
        }
        $r.stash = $cima
        L "trabajo local apartado en el stash $($cima.Substring(0, 10)) («$etiqueta»); copia de seguridad en $resp"
        $m = AG-Git $Repo @('merge', '--ff-only', '--no-overwrite-ignore', '--quiet', $upstream)
        $ffOk = ($m.rc -eq 0)
        if ($ffOk) { $r.despues = (AG-Git $Repo @('rev-parse', 'HEAD')).salida }
        # pop por sha: el stash@{n} cuyo commit es el nuestro
        $ref = ''
        foreach ($l in ((AG-Git $Repo @('stash', 'list', '--format=%gd %H')).salida -split "`n")) { $c = $l.Trim() -split ' '; if ($c.Count -eq 2 -and $c[1] -eq $cima) { $ref = $c[0] } }
        $p = if ($ref) { AG-Git $Repo @('stash', 'pop', $ref) } else { @{ rc = 1; salida = 'no se encuentra el stash' } }
        $reaplicado = ($p.rc -eq 0)
        $resp2 = ''
        if (-not $reaplicado) {
            # Lo que haya ahora en el árbol (la reaplicación a medias y lo que alguien escribiera entretanto) también se
            # respalda antes de limpiar: así el reset --hard nunca pisa nada sin copia
            $resp2 = AG-Respaldar $Repo $App 'estado tras la reaplicación fallida, antes de dejar el árbol limpio' $upstream 0 ''
        }
        if (-not $reaplicado -and -not $resp2) {
            L "no se pudo respaldar el estado tras la reaplicación fallida; el árbol se deja tal cual (con conflictos) y el stash se conserva"
        } elseif (-not $reaplicado) {
            # Deshacer la reaplicación a medias: el trabajo está en el stash (se conserva) y en las copias de seguridad
            $null = AG-Git $Repo @('reset', '--hard', '--quiet', 'HEAD')
            $enStash = @((AG-Git $Repo @('ls-tree', '-r', '--name-only', "$cima^3")).salida -split "`n" | Where-Object { $_ })
            if ($enStash.Count) {
                $sueltos = @((AG-Git $Repo @('ls-files', '--others', '--exclude-standard', '-z')).salida -split "`0" | Where-Object { $_ })
                foreach ($f in $sueltos) { if ($enStash -contains $f) { Remove-Item -LiteralPath (Join-Path $Repo $f) -Force -ErrorAction SilentlyContinue } }
            }
            $sucio = (AG-Git $Repo @('status', '--porcelain')).salida
            if ($sucio) { L "tras deshacer la reaplicación el árbol no ha quedado limpio: $($sucio -replace '\s+', ' ')" }
        }
        $corto = $cima.Substring(0, 10)
        if (-not $ffOk) {
            $det = ($m.salida -replace '\s+', ' ').Trim(); if ($det.Length -gt 200) { $det = $det.Substring(0, 200) }
            $situacion = if ($reaplicado) { "NO se ha actualizado (el fast-forward ha fallado: $det); el trabajo local se ha devuelto a su sitio." } else { "NO se ha actualizado (el fast-forward ha fallado: $det) y el trabajo local NO se ha podido devolver: sigue en el stash $corto." }
            $null = AG-ApuntarPendiente $Repo $App $rama $resp $(if ($reaplicado) { '' } else { $cima }) $situacion; $r.trabajoLocal = $true
            if ($reaplicado) { $r.stash = '' }
            return (Fin 'error' "la actualización del repo de $App ha fallado (código $($m.rc)): $det. Copia de seguridad en $resp")
        }
        if ($reaplicado) {
            $r.stash = ''
            $situacion = "se ha actualizado a la última versión y el trabajo local se ha reaplicado encima (sigue sin confirmar)."
            $null = AG-ApuntarPendiente $Repo $App $rama $resp '' $situacion; $r.trabajoLocal = $true
            return (Fin 'actualizado-con-local' "actualizado ($detras commits nuevos de $upstream); el trabajo local se ha reaplicado encima. Copia de seguridad en $resp" $true)
        }
        $situacion = "se ha actualizado a la última versión, pero el trabajo local CHOCA con lo nuevo y NO se ha reaplicado: el árbol ha quedado limpio en la versión nueva y el trabajo sigue en el stash $corto («$etiqueta») y en la copia de seguridad."
        if ($resp2) { $situacion += " Lo que quedó en el árbol tras el intento de reaplicarlo está en $resp2." } else { $situacion = $situacion -replace 'el árbol ha quedado limpio en la versión nueva', 'el árbol ha quedado CON CONFLICTOS (no se pudo respaldar para limpiarlo)' }
        $null = AG-ApuntarPendiente $Repo $App $rama $resp $cima $situacion; $r.trabajoLocal = $true
        return (Fin 'actualizado-conflicto' "actualizado ($detras commits nuevos de $upstream), pero el trabajo local choca con lo nuevo: queda en el stash $corto y en $resp" $true)
    } catch {
        return (Fin 'error' "error al actualizar $App`: $($_.Exception.Message)")
    } finally {
        if ($candado) { Remove-Item -LiteralPath $candado -Force -ErrorAction SilentlyContinue }
    }
}

# Uso directo (no dot-source): -Repo y -App
if ($Repo -and $MyInvocation.InvocationName -ne '.') {
    $logFn = $null
    if ($FicheroLog) { $logFn = { param($m) Add-Content -Encoding UTF8 -LiteralPath $FicheroLog "$(AG-Ahora) $m" }.GetNewClosure() }
    $res = Invoke-ActualizacionGit -Repo ([IO.Path]::GetFullPath($Repo)) -App $App -RamaEsperada $Rama -TopeFetch $TopeFetch -LogFn $logFn
    if ($Visible) {
        $raya = '=' * 78
        if ($res.estado -eq 'al-dia') { Write-Host 'Ya tienes la última versión.' }
        elseif ($res.estado -eq 'actualizado') { Write-Host "Actualizado a la última versión ($($res.detras) cambios nuevos)." -ForegroundColor Green }
        else {
            $color = if ($res.ok) { 'Yellow' } else { 'Red' }
            $titulo = if ($res.ok) { 'ACTUALIZADO, PERO HABÍA TRABAJO LOCAL' } else { "NO SE HA PODIDO ACTUALIZAR $App" }
            Write-Host ''; Write-Host $raya -ForegroundColor $color
            Write-Host "  $titulo" -ForegroundColor $color
            Write-Host "  $($res.mensaje)" -ForegroundColor $color
            if ($res.trabajoLocal) { Write-Host '  Apuntado como pendiente PRIORITARIO en el visor de pruebas.' -ForegroundColor $color }
            if (-not $res.ok) { Write-Host '  Se abre la versión que tienes ahora (NO es la última).' -ForegroundColor $color }
            Write-Host $raya -ForegroundColor $color; Write-Host ''
        }
    }
    if (-not $res.ok) { exit 1 }
    if ($res.trabajoLocal) { exit 2 }
    exit 0
}
