# Lógica pura (sin WinForms ni vpn.ps1) del aviso «hay una versión nueva» de la bandeja. Se carga con
# dot-source desde lib\Bandeja.ps1 y se puede probar por separado.

function Huella-Codigo([string]$Raiz) {
    # Huella barata del código que carga la bandeja: nombre, fecha de escritura y tamaño de vpn.ps1,
    # VERSION y lib\*. No lee el contenido (un git pull cambia fecha y/o tamaño de lo que toca).
    $r = New-Object System.Collections.Generic.List[string]
    $ficheros = @(
        (Join-Path $Raiz 'vpn.ps1'), (Join-Path $Raiz 'VERSION')
        $(try { Get-ChildItem -LiteralPath (Join-Path $Raiz 'lib') -File -ErrorAction Stop | Sort-Object Name | ForEach-Object { $_.FullName } } catch { @() })
    )
    foreach ($f in $ficheros) {
        try { $i = Get-Item -LiteralPath $f -ErrorAction Stop; $r.Add("$($i.Name):$($i.LastWriteTimeUtc.Ticks):$($i.Length)") } catch { $r.Add("$([IO.Path]::GetFileName($f)):-") }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($r -join '|')))).Replace('-', '') } finally { $sha.Dispose() }
}

function Codigo-Cambiado([string]$HuellaInicial, [string]$HuellaActual) {
    return (-not [string]::IsNullOrEmpty($HuellaInicial)) -and ($HuellaInicial -ne $HuellaActual)
}

function Git-Disponible { return [bool](Get-Command git -ErrorAction SilentlyContinue) }

function Contar-CommitsPorBajar([string]$Raiz) {
    # Commits de origin por bajar (HEAD..@{u}). 0 si no hay; -1 si no se puede saber (sin git, sin upstream...).
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Raiz '.git')) -or -not (Git-Disponible)) { return -1 }
        $s = git -C $Raiz rev-list --count 'HEAD..@{u}' 2>$null
        if ($LASTEXITCODE -ne 0) { return -1 }
        $n = 0
        if ([int]::TryParse(("$s").Trim(), [ref]$n)) { return $n } else { return -1 }
    } catch { return -1 }
}

function Arbol-Sucio([string]$Raiz) {
    # Como actualizar.ps1: solo cuentan los ficheros versionados modificados.
    try { return [bool](git -C $Raiz status --porcelain --untracked-files=no 2>$null) } catch { return $false }
}

function Resolver-Aviso([bool]$CodigoNuevo, [int]$PorBajar) {
    # $null (nada que avisar), 'disco' (el código en disco es más nuevo que el cargado) o 'remoto' (origin va por delante).
    if ($CodigoNuevo) { return 'disco' }
    if ($PorBajar -gt 0) { return 'remoto' }
    return $null
}

function Clave-Aviso([string]$Raiz, [string]$Tipo, [string]$HuellaActual) {
    # Identifica «la versión detectada» para avisar con globo una sola vez por versión.
    if (-not $Tipo) { return $null }
    if ($Tipo -eq 'disco') { return "disco:$HuellaActual" }
    $sha = try { "$(git -C $Raiz rev-parse '@{u}' 2>$null)".Trim() } catch { '' }
    return "remoto:$sha"
}

function Obtener-ClaveAviso([hashtable]$Cache, [string]$Raiz, [string]$Tipo, [int]$PorBajar, [string]$Huella) {
    # Clave-Aviso con caché: solo se recalcula (y se lanza git) si cambia el tipo, los commits por bajar o la huella.
    $entrada = "$Tipo|$PorBajar|$Huella"
    if ($Cache.Entrada -ne $entrada) { $Cache.Entrada = $entrada; $Cache.Clave = Clave-Aviso $Raiz $Tipo $Huella }
    return $Cache.Clave
}

function Matar-Arbol([int]$ProcId) {
    # Mata el proceso y sus hijos (git fetch lanza git-remote-https, que Process.Kill() dejaría vivo).
    try { & taskkill.exe /T /F /PID $ProcId *> $null } catch { }
}

function Decidir-Accion([bool]$CodigoNuevo, [int]$PorBajar, [bool]$Sucio) {
    # 'reiniciar' (solo relanzar) o 'actualizar' (actualizar.ps1 y relanzar). Con el árbol sucio también se actualiza:
    # actualizar.ps1 respalda el trabajo local, lo aparta con stash, actualiza y lo reaplica (actualizar-git.ps1).
    if ($CodigoNuevo) { return 'reiniciar' }
    if ($PorBajar -gt 0) { return 'actualizar' }
    return 'nada'
}

function Iniciar-FetchSegundoPlano([string]$Raiz) {
    # git fetch en un proceso aparte y oculto; el llamador lo vigila y lo mata pasado el tope. $null si no hay git.
    if (-not (Test-Path -LiteralPath (Join-Path $Raiz '.git')) -or -not (Git-Disponible)) { return $null }
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
    try {
        $p = Start-Process git -ArgumentList @('-C', "`"$Raiz`"", '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=15', 'fetch', '--quiet') -WindowStyle Hidden -PassThru
        [void]$p.Handle   # sin tocar Handle, en PS 5.1 ExitCode sale vacío
        return $p
    } catch { return $null }
}

function Argumentos-RelanzarBandeja([string]$Carpeta, [bool]$SinConectar) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $Carpeta 'vpn.ps1')`"", 'bandeja')
    if ($SinConectar) { $a += '-SinConectar' }
    return $a
}

function Relanzar-Desacoplado([string]$Carpeta, [bool]$SinConectar, [int]$PidViejo) {
    # Proceso auxiliar que espera a que muera el viejo (suelta el mutex de la bandeja) y lanza la nueva.
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args2 = (Argumentos-RelanzarBandeja $Carpeta $SinConectar | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $cmd = "try { Wait-Process -Id $PidViejo -Timeout 30 -ErrorAction Stop } catch { }; Start-Process '$($ps -replace "'", "''")' -ArgumentList @($args2) -WindowStyle Hidden"
    Start-Process $ps -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', "`"$($cmd -replace '"', '\"')`"") -WindowStyle Hidden
}
