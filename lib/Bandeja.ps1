# Icono de vpn-forti en el área de notificación (orden «bandeja» de vpn.ps1, que carga este fichero
# con dot-source). Menú de botón derecho: estado, Reconectar, «Borrar los correos leídos», registro y Salir.
# Leer-/Guardar-BorrarLeidos e Icono-ConPunto no dependen de vpn.ps1 y se pueden probar por separado;
# Iniciar-Bandeja usa Get-Estado, Log, Salir, $FicheroCfg, $FicheroLog y $Cfg de vpn.ps1.

# Lógica pura del aviso «hay una versión nueva» (huella del código, commits por bajar...).
. (Join-Path $PSScriptRoot 'Actualizacion.ps1')

# ---------------------------------------------------------------- preferencia «Borrar los correos leídos»
function Leer-BorrarLeidos([string]$Fichero) {
    try {
        if (-not (Test-Path $Fichero)) { return $false }
        $j = Get-Content $Fichero -Raw -Encoding UTF8 | ConvertFrom-Json
        return [bool]($j.pin -and $j.pin.borrarLeidos -eq $true)
    } catch { return $false }
}

function Guardar-BorrarLeidos([string]$Fichero, [bool]$Valor) {
    # Mismo patrón que aceptar-certificado: solo cambia pin.borrarLeidos, el resto de claves se conserva.
    $obj = if (Test-Path $Fichero) { Get-Content $Fichero -Raw -Encoding UTF8 | ConvertFrom-Json } else { New-Object psobject }
    if (-not $obj.PSObject.Properties['pin'] -or -not $obj.pin) { $obj | Add-Member -Force pin ([pscustomobject]@{}) }
    if ($obj.pin.PSObject.Properties['borrarLeidos']) { $obj.pin.borrarLeidos = $Valor } else { $obj.pin | Add-Member borrarLeidos $Valor }
    # Se escribe en un temporal y se sustituye: nunca queda un config.json vacío o a medias.
    $Fichero = [IO.Path]::GetFullPath($Fichero)
    $tmp = "$Fichero.tmp"
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path $Fichero) { [IO.File]::Replace($tmp, $Fichero, [NullString]::Value) } else { [IO.File]::Move($tmp, $Fichero) }
}

# ---------------------------------------------------------------- iconos por estado
$ColoresBandeja = [ordered]@{ conectada = @(0x10, 0x7C, 0x10); reconectando = @(0xF7, 0xA8, 0x00); sinvpn = @(0xC5, 0x0F, 0x1F) }

function Imagen-DeIco([string]$Ruta, [int]$Ancho) {
    # Imagen de un .ico: la entrada más pequeña que llegue a $Ancho (o la mayor). System.Drawing.Icon
    # no sabe pintar las entradas PNG (vpn.ico es un único PNG de 256 px), así que esas se decodifican aparte.
    $b = [IO.File]::ReadAllBytes($Ruta)
    $n = [BitConverter]::ToUInt16($b, 4)
    $mejor = $null
    for ($i = 0; $i -lt $n; $i++) {
        $o = 6 + 16 * $i
        $e = [pscustomobject]@{ w = $(if ($b[$o] -eq 0) { 256 } else { [int]$b[$o] }); tam = [BitConverter]::ToInt32($b, $o + 8); off = [BitConverter]::ToInt32($b, $o + 12) }
        if (-not $mejor -or ($mejor.w -lt $Ancho -and $e.w -gt $mejor.w) -or ($e.w -ge $Ancho -and $e.w -lt $mejor.w)) { $mejor = $e }
    }
    if ($mejor -and $b[$mejor.off] -eq 0x89 -and $b[$mejor.off + 1] -eq 0x50) {
        $ms = New-Object IO.MemoryStream($b, $mejor.off, $mejor.tam)
        return New-Object System.Drawing.Bitmap($ms)
    }
    $ico = New-Object System.Drawing.Icon($Ruta, $Ancho, $Ancho)
    try { return $ico.ToBitmap() } finally { $ico.Dispose() }
}

function Icono-ConPunto([string]$Base, [System.Drawing.Size]$Tam, [int[]]$Rgb) {
    # $Base (.ico) al tamaño pedido con un punto de color abajo a la derecha (GDI+, sin dependencias).
    # Sin $Rgb, solo redimensiona (iconos propios por estado).
    $bmp = New-Object System.Drawing.Bitmap($Tam.Width, $Tam.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.InterpolationMode = 'HighQualityBicubic'
        try {
            $img = Imagen-DeIco $Base $Tam.Width
            $g.DrawImage($img, 0, 0, $Tam.Width, $Tam.Height)
            $img.Dispose()
        } catch { $g.Clear([System.Drawing.Color]::FromArgb(0x44, 0x44, 0x44)) }
        if ($Rgb) {
            $d = [int][Math]::Round($Tam.Width * 0.5)
            $x = $Tam.Width - $d; $y = $Tam.Height - $d
            $g.FillEllipse([System.Drawing.Brushes]::White, $x, $y, $d, $d)
            $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($Rgb[0], $Rgb[1], $Rgb[2]))
            $g.FillEllipse($b, $x + 1, $y + 1, $d - 2, $d - 2)
            $b.Dispose()
        }
    } finally { $g.Dispose() }
    # Solo se crean tres, una vez: el handle de GetHicon se libera al salir del proceso.
    $i = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $i
}

function Iconos-Bandeja([string]$Carpeta) {
    # Si hay vpn_conectada.ico, vpn_reconectando.ico y vpn_sinvpn.ico junto a vpn.ico, se usan tal cual
    # (así cambiar de icono es copiar tres ficheros); si no, se generan a partir de vpn.ico.
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    $tam = [System.Windows.Forms.SystemInformation]::SmallIconSize
    $r = @{}
    foreach ($e in $ColoresBandeja.Keys) {
        $propio = Join-Path $Carpeta "vpn_$e.ico"
        if (Test-Path $propio) { $r[$e] = Icono-ConPunto $propio $tam $null; continue }
        $r[$e] = Icono-ConPunto (Join-Path $Carpeta 'vpn.ico') $tam $ColoresBandeja[$e]
    }
    return $r
}

# ---------------------------------------------------------------- bandeja
function Conectando-OtraInstancia {
    # ¿Hay un conectar/asegurar en marcha? El mutex de Conectar solo existe mientras vive ese proceso.
    # No se intenta coger: si una app entrara justo en ese hueco, creería que otra instancia conecta.
    try { [System.Threading.Mutex]::OpenExisting('Local\vpn-forti-conectar').Dispose(); return $true } catch { return $false }
}

function Poner-EstadoBandeja([string]$Estado) {
    if ($script:BEstado -eq $Estado) { return }
    $script:BEstado = $Estado
    $t = @{ conectada = 'VPN conectada'; reconectando = 'Reconectando la VPN…'; sinvpn = 'Sin VPN' }[$Estado]
    $script:BIcono.Icon = $script:BIconos[$Estado]
    $script:BMiEstado.Text = $t
    Poner-TextoBandeja
}

function Poner-TextoBandeja {
    $t = @{ conectada = 'VPN conectada'; reconectando = 'Reconectando la VPN…'; sinvpn = 'Sin VPN' }[$script:BEstado]
    if ($script:BAviso) { $t += ' · versión nueva' }
    $x = "vpn-forti: $t"
    $script:BIcono.Text = $x.Substring(0, [Math]::Min(63, $x.Length))   # NotifyIcon.Text admite como mucho 63 caracteres
}

function Argumentos-Reconectar([string]$Carpeta) {
    # Ojo: aquí $PSCommandPath sería este fichero (lib\Bandeja.ps1), no vpn.ps1.
    return @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $Carpeta 'vpn.ps1')`"", 'asegurar')
}

function Reconectar-Bandeja {
    if ($script:BHijo -and -not $script:BHijo.HasExited) { return }
    # Proceso aparte: Conectar/Salir hacen exit y cerrarían la bandeja. Relee config.json al arrancar,
    # así que la casilla «Borrar los correos leídos» vale para la siguiente conexión.
    $a = Argumentos-Reconectar $Raiz
    try {
        $script:BHijo = Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $a -WindowStyle Hidden -PassThru
        [void]$script:BHijo.Handle   # sin tocar Handle, en PS 5.1 ExitCode sale vacío
        Log 'Bandeja: reconectando (asegurar).'
        Poner-EstadoBandeja 'reconectando'
    } catch { Log "Bandeja: no se pudo lanzar la reconexión: $($_.Exception.Message)"; $script:BHijo = $null }
}

function Tic-Bandeja {
    try {
        if (-not $script:BActualizando) { Comprobar-Actualizacion }
        if ($script:BSenal.WaitOne(0)) { Reconectar-Bandeja }
        if ($script:BHijo) {
            if (-not $script:BHijo.HasExited) { Poner-EstadoBandeja 'reconectando'; return }
            $rc = $script:BHijo.ExitCode; $script:BHijo = $null
            Log "Bandeja: la reconexión ha terminado con el código $rc."
            if ($rc -ne 0) { $script:BIcono.ShowBalloonTip(8000, 'vpn-forti', "No se ha podido reconectar la VPN (código $rc). Detalle en el registro.", 'Warning') }
            $script:BUltima = [datetime]::MinValue
        }
        if (Conectando-OtraInstancia) { Poner-EstadoBandeja 'reconectando'; $script:BOtra = $true; return }
        if ($script:BOtra) { $script:BOtra = $false; $script:BUltima = [datetime]::MinValue }
        if (((Get-Date) - $script:BUltima).TotalSeconds -ge [int]$Cfg.intervaloBandejaSeg) {
            $script:BUltima = Get-Date
            Poner-EstadoBandeja $(if ((Get-Estado).conectada) { 'conectada' } else { 'sinvpn' })
        }
    } catch { Log "Bandeja: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- aviso de versión nueva
function Actualizar-AvisoVersion {
    # Refleja en menú, tooltip y globo (una vez por versión detectada) lo que digan las variables de estado.
    $aviso = Resolver-Aviso ([bool]$script:BCodigoNuevo) ([int]$script:BPorBajar)
    if ($aviso -ne $script:BAviso) {
        $script:BAviso = $aviso
        $script:BMiActualizar.Visible = [bool]$aviso
        Poner-TextoBandeja
    }
    if ($aviso) {
        $clave = Obtener-ClaveAviso $script:BClaveCache $Raiz $aviso ([int]$script:BPorBajar) $script:BHuellaAct   # sin git salvo que algo cambie
        if ($clave -and $clave -ne $script:BClaveGlobo) {
            $script:BClaveGlobo = $clave
            Log "Bandeja: versión nueva detectada ($aviso)."
            $script:BIcono.ShowBalloonTip(10000, 'vpn-forti', 'Hay una versión nueva de vpn-forti. Usa «Hay una versión nueva: reiniciar» en el menú del icono.', 'Info')
        }
    }
}

function Comprobar-Actualizacion {
    # Se llama desde el temporizador de 1 s; todo lo caro va espaciado o en un proceso aparte.
    $ahora = Get-Date
    if (($ahora - $script:BUltDisco).TotalSeconds -ge 30) {
        $script:BUltDisco = $ahora
        $script:BHuellaAct = Huella-Codigo $Raiz
        $script:BCodigoNuevo = Codigo-Cambiado $script:BHuella0 $script:BHuellaAct
    }
    if ($script:BFetch) {
        if ($script:BFetch.HasExited) {
            $rc = $script:BFetch.ExitCode; $script:BFetch = $null
            if ($rc -eq 0) { $script:BPorBajar = Contar-CommitsPorBajar $Raiz; $script:BClaveCache.Entrada = $null } else { Log "Bandeja: git fetch ha terminado con el código $rc." }
        } elseif (($ahora - $script:BFetchIni).TotalSeconds -gt 15) {
            Matar-Arbol $script:BFetch.Id
            $script:BFetch = $null
            Log 'Bandeja: git fetch sin respuesta en 15 s; se cancela.'
        }
    } elseif (-not $env:ACTUALIZAR_SIN -and ($ahora - $script:BFetchIni).TotalMinutes -ge 10) {
        $script:BFetchIni = $ahora
        $script:BFetch = Iniciar-FetchSegundoPlano $Raiz
    }
    Actualizar-AvisoVersion
}

function Aplicar-Actualizacion {
    if ($script:BActualizando) { return }
    $script:BActualizando = $true
    try {
        $sucio = if ($script:BPorBajar -gt 0) { Arbol-Sucio $Raiz } else { $false }
        $accion = Decidir-Accion ([bool]$script:BCodigoNuevo) ([int]$script:BPorBajar) $sucio
        $mb = [System.Windows.Forms.MessageBox]
        if ($accion -eq 'nada') { $script:BAviso = $null; $script:BMiActualizar.Visible = $false; Poner-TextoBandeja; return }
        if ($accion -eq 'bloqueado') {
            [void]$mb::Show("Hay una versión nueva en origin, pero vpn-forti tiene cambios locales sin confirmar y no se puede actualizar solo. Resuélvelo a mano (git status) y vuelve a intentarlo.", 'vpn-forti', 'OK', 'Warning')
            return
        }
        $local = if ($sucio) { ' Tus cambios locales se guardan antes (copia de seguridad y stash) y se vuelven a aplicar encima.' } else { '' }
        $txt = if ($accion -eq 'actualizar') { "Hay $($script:BPorBajar) cambio(s) nuevo(s) en origin.$local ¿Actualizar vpn-forti y reiniciar la bandeja?" } else { '¿Reiniciar la bandeja para usar la versión nueva ya descargada?' }
        if ($mb::Show($txt, 'vpn-forti', 'YesNo', 'Question') -ne 'Yes') { return }
        if ($accion -eq 'actualizar') {
            $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $p = Start-Process $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $Raiz 'actualizar.ps1')`"", '-Forzar') -WindowStyle Hidden -PassThru
            [void]$p.Handle
            $lim = (Get-Date).AddSeconds(90)
            while (-not $p.WaitForExit(200)) {
                [System.Windows.Forms.Application]::DoEvents()   # la interfaz sigue viva (BActualizando evita reentradas)
                if ((Get-Date) -gt $lim) { Matar-Arbol $p.Id; break }
            }
            $script:BPorBajar = Contar-CommitsPorBajar $Raiz
            if ($script:BPorBajar -gt 0) {
                Log 'Bandeja: la actualización no se ha completado.'
                [void]$mb::Show('No se ha podido actualizar (sin red, otra rama o commits locales sin subir). Detalle en actualizar.log.', 'vpn-forti', 'OK', 'Warning')
                return
            }
        }
        Log 'Bandeja: relanzando con la versión nueva.'
        Relanzar-Desacoplado $Raiz $script:BSinConectar $PID
        [System.Windows.Forms.Application]::Exit()   # el finally de Iniciar-Bandeja quita el icono
    } catch {
        Log "Bandeja: no se pudo actualizar: $($_.Exception.Message)"
    } finally { $script:BActualizando = $false }
}

function Iniciar-Bandeja([bool]$Conectar) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $creado = $false
    $unica = New-Object System.Threading.Mutex($true, 'Local\vpn-forti-bandeja', [ref]$creado)
    $script:BSenal = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\vpn-forti-bandeja-reconectar')
    if (-not $creado) {
        # Ya hay una bandeja (p. ej. doble clic otra vez en el acceso directo): se le pide reconectar.
        if ($Conectar) { [void]$script:BSenal.Set() }
        Salir 0 @{ mensaje = 'La bandeja ya estaba abierta' + $(if ($Conectar) { '; se le ha pedido reconectar' } else { '' }) }
    }
    try {
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $script:BIconos = Iconos-Bandeja $Raiz
        $script:BSinConectar = -not $Conectar
        $script:BHuella0 = Huella-Codigo $Raiz; $script:BHuellaAct = $script:BHuella0; $script:BCodigoNuevo = $false
        $script:BPorBajar = 0; $script:BAviso = $null; $script:BClaveGlobo = $null; $script:BClaveCache = @{ Entrada = $null; Clave = $null }; $script:BFetch = $null; $script:BActualizando = $false
        $script:BUltDisco = Get-Date; $script:BFetchIni = [datetime]::MinValue
        $script:BEstado = $null; $script:BHijo = $null; $script:BOtra = $false; $script:BUltima = [datetime]::MinValue

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $script:BMiEstado = New-Object System.Windows.Forms.ToolStripMenuItem 'Comprobando la VPN…'
        $script:BMiEstado.Enabled = $false
        $script:BMiReconectar = New-Object System.Windows.Forms.ToolStripMenuItem 'Reconectar'
        $script:BMiReconectar.Add_Click({ Reconectar-Bandeja })
        $script:BMiBorrar = New-Object System.Windows.Forms.ToolStripMenuItem 'Borrar los correos leídos'
        $script:BMiBorrar.CheckOnClick = $true
        $script:BMiBorrar.ToolTipText = 'Tras leer el PIN, manda ese correo a Elementos eliminados'
        $script:BMiBorrar.Add_Click({
                # CheckOnClick ya ha cambiado Checked al llegar aquí.
                try {
                    Guardar-BorrarLeidos $FicheroCfg $script:BMiBorrar.Checked
                    Log "Bandeja: «Borrar los correos leídos» = $($script:BMiBorrar.Checked)."
                } catch {
                    $script:BMiBorrar.Checked = -not $script:BMiBorrar.Checked
                    Log "Bandeja: no se pudo guardar la preferencia: $($_.Exception.Message)"
                    $script:BIcono.ShowBalloonTip(8000, 'vpn-forti', "No se ha podido guardar la opción en $FicheroCfg.", 'Error')
                }
            })
        $script:BMiActualizar = New-Object System.Windows.Forms.ToolStripMenuItem 'Hay una versión nueva: reiniciar'
        $script:BMiActualizar.Visible = $false
        $script:BMiActualizar.Font = New-Object System.Drawing.Font($script:BMiActualizar.Font, [System.Drawing.FontStyle]::Bold)
        $script:BMiActualizar.Add_Click({ Aplicar-Actualizacion })
        $miRegistro = New-Object System.Windows.Forms.ToolStripMenuItem 'Abrir el registro'
        $miRegistro.Add_Click({ try { Start-Process notepad.exe -ArgumentList "`"$FicheroLog`"" } catch { } })
        $miSalir = New-Object System.Windows.Forms.ToolStripMenuItem 'Salir'
        $miSalir.Add_Click({ [System.Windows.Forms.Application]::Exit() })
        foreach ($i in @($script:BMiEstado, (New-Object System.Windows.Forms.ToolStripSeparator), $script:BMiActualizar, $script:BMiReconectar, $script:BMiBorrar,
                (New-Object System.Windows.Forms.ToolStripSeparator), $miRegistro, $miSalir)) { [void]$menu.Items.Add($i) }
        $menu.Add_Opening({
                # Se relee al abrir el menú por si se ha cambiado config.json a mano.
                $script:BMiBorrar.Checked = Leer-BorrarLeidos $FicheroCfg
                $script:BMiReconectar.Enabled = -not ($script:BHijo -and -not $script:BHijo.HasExited)
            })

        $script:BIcono = New-Object System.Windows.Forms.NotifyIcon
        $script:BIcono.ContextMenuStrip = $menu
        Poner-EstadoBandeja 'sinvpn'
        $script:BIcono.Visible = $true
        Log 'Bandeja iniciada.'

        $e = Get-Estado
        $script:BUltima = Get-Date
        Poner-EstadoBandeja $(if ($e.conectada) { 'conectada' } else { 'sinvpn' })
        if ($Conectar -and -not $e.conectada) { Reconectar-Bandeja }

        $timer = New-Object System.Windows.Forms.Timer   # en el hilo de la interfaz (no System.Timers.Timer)
        $timer.Interval = 1000
        $timer.Add_Tick({ Tic-Bandeja })
        $timer.Start()
        [System.Windows.Forms.Application]::Run()
        $timer.Stop()
    } finally {
        if ($script:BIcono) { $script:BIcono.Visible = $false; $script:BIcono.Dispose() }   # sin icono fantasma
        Log 'Bandeja cerrada.'
        try { $unica.ReleaseMutex() } catch { }
    }
}
