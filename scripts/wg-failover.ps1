# wg-failover.ps1 - HU15 (ADM006): failover de cliente entre servidores VPN
# Ejecutar en PowerShell COMO ADMINISTRADOR.
# Requiere C:\wg\wgS1.conf y C:\wg\wgS2.conf (el nombre del archivo = nombre del tunel).
# Uso:  .\wg-failover.ps1 [-Inicial wgS1|wgS2]   (el servidor principal lo indica agregar-cliente.sh)

param([ValidateSet("wgS1","wgS2")][string]$Inicial = "wgS1")   # servidor principal asignado a este cliente

$wg     = "C:\Program Files\WireGuard\wireguard.exe"
$url    = "http://10.0.0.1:5000/api/status"
$tuns   = @("wgS1", "wgS2")
$umbral = 3          # fallos seguidos antes de cambiar de servidor
$fallos = 0
$tFallo = $null

function Get-Activo {
    foreach ($t in $tuns) {
        $s = Get-Service -Name "WireGuardTunnel`$$t" -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq "Running") { return $t }
    }
    return $null
}

# Usa curl.exe (igual que las pruebas manuales): evita la lentitud/proxy de Invoke-WebRequest
function Test-Api {
    & curl.exe -s -m 2 -o NUL $url
    return ($LASTEXITCODE -eq 0)
}

function Set-Tunel($de, $a) {
    if ($de) {
        & $wg /uninstalltunnelservice $de | Out-Null
        Start-Sleep -Seconds 2
    }
    & $wg /installtunnelservice "C:\wg\$a.conf" | Out-Null
}

$activo = Get-Activo
if (-not $activo) {
    $activo = $Inicial
    Set-Tunel $null $activo
}
Write-Host ("{0} Tunel inicial: {1}" -f (Get-Date -Format "HH:mm:ss"), $activo)

# Espera de arranque (hasta ~20 s) para que el primer handshake no cuente como fallo
for ($i = 0; $i -lt 10; $i++) {
    if (Test-Api) { break }
    Start-Sleep -Seconds 1
}
Write-Host ("{0} Monitoreando {1} ..." -f (Get-Date -Format "HH:mm:ss"), $url)

while ($true) {
    if (Test-Api) {
        if ($fallos -gt 0) {
            Write-Host ("{0} API respondio de nuevo en {1} (no hubo cambio)" -f (Get-Date -Format "HH:mm:ss"), $activo)
        }
        $fallos = 0
        $tFallo = $null
    } else {
        $fallos++
        if ($fallos -eq 1) { $tFallo = Get-Date }
        Write-Host ("{0} API sin respuesta ({1}/{2}) en {3}" -f (Get-Date -Format "HH:mm:ss"), $fallos, $umbral, $activo)
    }

    if ($fallos -ge $umbral) {
        $nuevo = if ($activo -eq "wgS1") { "wgS2" } else { "wgS1" }
        Write-Host ("{0} CAIDA en {1} -> cambiando a {2}" -f (Get-Date -Format "HH:mm:ss"), $activo, $nuevo)
        Set-Tunel $activo $nuevo
        $activo = $nuevo
        $fallos = 0

        for ($i = 0; $i -lt 30; $i++) {
            if (Test-Api) {
                $seg = [math]::Round(((Get-Date) - $tFallo).TotalSeconds, 1)
                Write-Host ("{0} RECUPERADO en {1}. Tiempo total desde el primer fallo: {2} s" -f (Get-Date -Format "HH:mm:ss"), $activo, $seg)
                break
            }
            Start-Sleep -Seconds 1
        }
        $tFallo = $null
    }
    Start-Sleep -Seconds 1
}
