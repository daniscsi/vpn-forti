<#
.SYNOPSIS
  Desinstala vpn-forti de este PC: quita la variable de entorno de usuario VPN_FORTI y la tarea
  programada vpn-forti-servicio ("vpn.ps1 desinstalar-tarea"; si Windows no deja borrarla sin
  elevar, pide un UAC).

.DESCRIPTION
  Con -BorrarCredencial borra también las credenciales genéricas que guarda la herramienta
  ("vpn-forti:<túnel>" de cada túnel de FortiClient y del de config.json) y el perfil de
  Outlook web de %LOCALAPPDATA%\vpn-forti\perfil-outlook.
  No borra la carpeta del código, ni la credencial genérica "FortiClient" (puede ser de otro uso),
  ni el log.

  Con -Silencioso escribe en stdout una única línea JSON con el resultado.
  Códigos: 0 bien, 1 error (por ejemplo, el perfil de Outlook está en uso: cierra Edge y repite).
#>
[CmdletBinding()]
param(
    [switch]$BorrarCredencial,
    [switch]$Silencioso
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Raiz = $PSScriptRoot
$DirDatos = Join-Path $env:LOCALAPPDATA 'vpn-forti'
$R = [ordered]@{ ok = $false; codigo = 1; variable = $null; tarea = $null; credenciales = @(); perfilOutlook = $null; mensaje = $null }

function Log([string]$m) {
    if ($Silencioso) { try { [Console]::Error.WriteLine($m) } catch { } } else { Write-Host $m }
}

function Terminar([int]$Codigo, [string]$Mensaje) {
    $R.codigo = $Codigo; $R.ok = ($Codigo -eq 0); if ($Mensaje) { $R.mensaje = $Mensaje }
    if ($Silencioso) { [Console]::Out.WriteLine(($R | ConvertTo-Json -Compress -Depth 4)) }
    elseif ($Mensaje) { Write-Host $Mensaje -ForegroundColor $(if ($Codigo -eq 0) { 'Green' } else { 'Red' }) }
    exit $Codigo
}

try {
    $errores = @()

    # Tarea programada que arranca el servicio de FortiClient sin UAC.
    $vpnPs1 = Join-Path $Raiz 'vpn.ps1'
    if (Test-Path $vpnPs1) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $sal = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vpnPs1 desinstalar-tarea 2>$null; $rcT = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
        $jt = $null; $lin = @($sal | Where-Object { $_ -like '{*' }) | Select-Object -Last 1
        if ($lin) { try { $jt = $lin | ConvertFrom-Json } catch { } }
        if ($rcT -eq 0) { $R.tarea = $(if ($jt -and $jt.borrada) { 'borrada' } else { 'no existía' }); Log "Tarea vpn-forti-servicio: $($R.tarea)." }
        else { $R.tarea = 'sigue'; $errores += "No se ha podido borrar la tarea vpn-forti-servicio (código $rcT$(if ($jt) { ": $($jt.mensaje)" }))" }
    }

    if ($null -ne [Environment]::GetEnvironmentVariable('VPN_FORTI', 'User')) {
        [Environment]::SetEnvironmentVariable('VPN_FORTI', $null, 'User')
        $R.variable = 'quitada'; Log 'Variable de usuario VPN_FORTI quitada.'
    } else { $R.variable = 'no existía'; Log 'La variable VPN_FORTI no existía.' }
    Remove-Item Env:\VPN_FORTI -ErrorAction SilentlyContinue

    if ($BorrarCredencial) {
        if (-not ('VpnForti.Cred' -as [type])) {
            Add-Type -Path (Join-Path $Raiz 'lib\VpnForti.cs') -ReferencedAssemblies Accessibility
        }
        $tuneles = @()
        try { $tuneles = @(Get-ChildItem 'HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels' -ErrorAction Stop | ForEach-Object { $_.PSChildName }) } catch { }
        $cfg = if ($env:VPN_FORTI_CONFIG) { $env:VPN_FORTI_CONFIG } else { Join-Path $Raiz 'config.json' }
        if (Test-Path $cfg) { try { $t = (Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).tunel; if ($t) { $tuneles += $t } } catch { } }
        $targets = @(@($tuneles | ForEach-Object { "vpn-forti:$_" }) + 'vpn-forti' | Select-Object -Unique)
        foreach ($t in $targets) {
            if ($null -ne [VpnForti.Cred]::Usuario($t, 1)) {
                if ([VpnForti.Cred]::Borrar($t, 1)) { $R.credenciales += $t; Log "Credencial '$t' borrada." }
                else { $errores += "No se ha podido borrar la credencial '$t'" }
            }
        }
        if ($R.credenciales.Count -eq 0) { Log 'No había credenciales de vpn-forti.' }

        $perfil = Join-Path $DirDatos 'perfil-outlook'
        if (Test-Path $perfil) {
            try { Remove-Item $perfil -Recurse -Force; $R.perfilOutlook = 'borrado'; Log "Perfil de Outlook borrado ($perfil)." }
            catch { $R.perfilOutlook = 'en uso'; $errores += "No se ha podido borrar $perfil (¿Edge abierto con ese perfil?): $($_.Exception.Message)" }
        } else { $R.perfilOutlook = 'no existía' }
    }

    if ($errores.Count) { Terminar 1 ($errores -join ' | ') }
    Terminar 0 "vpn-forti desinstalado. La carpeta $Raiz se conserva: bórrala a mano si ya no la quieres."
} catch {
    Terminar 1 "Error inesperado: $($_.Exception.Message)"
}
