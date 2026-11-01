# Crea el acceso directo "VPN FortiClient" (con icono) en el Escritorio y en la carpeta del proyecto.
# Un .cmd no puede llevar icono: el acceso directo apunta a vpn.cmd y usa vpn.ico.
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$sh = New-Object -ComObject WScript.Shell
foreach ($dir in @([Environment]::GetFolderPath('Desktop'), $aqui)) {
    $lnk = $sh.CreateShortcut((Join-Path $dir 'VPN FortiClient.lnk'))
    $lnk.TargetPath = Join-Path $aqui 'vpn.cmd'
    $lnk.WorkingDirectory = $aqui
    $lnk.IconLocation = (Join-Path $aqui 'vpn.ico') + ',0'
    $lnk.Description = 'Conectar la VPN de PORTIC (vpn-forti)'
    $lnk.Save()
    "Creado: $(Join-Path $dir 'VPN FortiClient.lnk')"
}
