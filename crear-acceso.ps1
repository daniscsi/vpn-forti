# Crea el acceso directo "Reconectar VPN" (con icono) en el Escritorio y en la carpeta del proyecto.
# Abre la bandeja de vpn-forti (vpn.ps1 bandeja): reconecta si no hay VPN y se queda en el área de
# notificación. Si la bandeja ya está abierta, le pide que reconecte.
# Otro icono: -Icono <ruta .ico> (por defecto vpn.ico), o sustituye vpn.ico y vuelve a ejecutarlo.
param(
    [string]$Icono,
    [string]$Nombre = 'Reconectar VPN',
    [string[]]$Destinos
)
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Icono) { $Icono = Join-Path $aqui 'vpn.ico' }
$Icono = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Icono)   # relativa: contra $PWD
if (-not $Destinos) { $Destinos = @([Environment]::GetFolderPath('Desktop'), $aqui) }
$sh = New-Object -ComObject WScript.Shell
foreach ($dir in $Destinos) {
    # El acceso antiguo "VPN FortiClient" (a vpn.cmd) se sustituye por este.
    $viejo = Join-Path $dir 'VPN FortiClient.lnk'
    if (Test-Path $viejo) {
        if ($sh.CreateShortcut($viejo).TargetPath -eq (Join-Path $aqui 'vpn.cmd')) { Remove-Item $viejo -Force; "Borrado: $viejo" }
    }
    $ruta = Join-Path $dir "$Nombre.lnk"
    $lnk = $sh.CreateShortcut($ruta)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $aqui 'vpn.ps1')`" bandeja"
    $lnk.WorkingDirectory = $aqui
    $lnk.WindowStyle = 7   # minimizada: no se ve la consola mientras se oculta
    $lnk.IconLocation = "$Icono,0"
    $lnk.Description = 'Reconectar la VPN de PORTIC y dejar su icono en el área de notificación (vpn-forti)'
    $lnk.Save()
    "Creado: $ruta"
}
