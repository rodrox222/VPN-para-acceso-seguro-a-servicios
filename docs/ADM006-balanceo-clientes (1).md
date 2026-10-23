# ADM006 (HU-15): Balanceo de clientes entre servidores VPN

## Objetivo
Distribuir los clientes WireGuard entre dos servidores VPN redundantes y garantizar la continuidad del servicio ante la caída de uno de ellos. Depende de la HU-14 (ADM005, servidor secundario) y sienta las bases para la HU-16 (failover) y la HU-17 (gestión centralizada de peers).

## Diseño
Cada servidor tiene **su propio par de claves** (requisito de la HU-14), por lo que no se usa DNS round-robin con un único `Endpoint`: el handshake solo sería válido con el servidor cuya clave pública figura en el `[Peer]` del cliente. En su lugar:

* **Balanceo por asignación (round-robin):** al crear un cliente, `agregar-cliente.sh` alterna el servidor principal (S1, S2, S1, S2...) y lo registra en `/var/lib/wg-balance/asignaciones.log`.
* **Dos configuraciones por cliente:** `wgS1.conf` (servidor 1) y `wgS2.conf` (servidor 2), con la misma clave de cliente y la misma IP VPN en ambos.
* **Failover en el cliente:** un watchdog (`wg-failover.ps1`) consulta la API cada pocos segundos; tras 3 fallos seguidos baja el túnel activo y levanta el otro.
* **Misma URL en ambos servidores:** los dos servidores usan `wg0 = 10.0.0.1/24` y publican la API en `10.0.0.1:5000`, por lo que el cliente siempre consume `http://10.0.0.1:5000`.

```
            Cliente Windows (un túnel activo a la vez)
            C:\wg\wgS1.conf        C:\wg\wgS2.conf
                   |                      |
            UDP 51820              UDP 51820
        Servidor 1 (vpn-servidor)   Servidor 2 (vpn-servidor-2)
        wg0 = 10.0.0.1/24           wg0 = 10.0.0.1/24
        API + BD (Docker)           API + BD (Docker, independiente)
```

## Entorno
| | Servidor 1 | Servidor 2 |
|---|---|---|
| Hostname | `vpn-servidor` | `vpn-servidor-2` |
| IP (red local) | `192.168.220.130` | `192.168.220.131` |
| `wg0` | `10.0.0.1/24` | `10.0.0.1/24` |
| Puerto VPN | UDP `51820` | UDP `51820` |
| API | `10.0.0.1:5000` | `10.0.0.1:5000` |
| Claves | propias | propias |

El servidor 2 usado en estas pruebas es un servidor **provisional** (clon del servidor 1). Equivale al servidor secundario de la HU-14: para integrarlo basta cambiar `WG_ENDPOINT_2` y `WG_PUBKEY_2` al ejecutar el script (ver más abajo).

### Creación del servidor 2 provisional
1. Regenerar las claves del servidor 1 y tomar un snapshot de la VM.
2. Clonar la VM (clon completo, con MAC nueva).
3. En el clon, cambiar la identidad y las claves:
```bash
sudo hostnamectl set-hostname vpn-servidor-2
sudo rm /etc/machine-id && sudo systemd-machine-id-setup
sudo reboot
# tras reiniciar, como root:
cd /etc/wireguard
systemctl stop wg-quick@wg0
umask 077
wg genkey | tee server_private.key | wg pubkey > server_public.key
# poner la nueva PrivateKey en wg0.conf
systemctl start wg-quick@wg0
```
4. Verificar que las claves públicas de ambos servidores sean distintas y que la API responda en `10.0.0.1:5000` (`docker ps`, `docker port api-rest`).

## DHCP (dnsmasq) en el servidor 1
El script de clientes obtiene la IP de cada cliente mediante DHCP (ver ADM002). Requiere `dnsmasq`:
```bash
sudo apt install -y dnsmasq
sudo cp config/dnsmasq-wireguard-dhcp.conf.example /etc/dnsmasq.d/wireguard-dhcp.conf
sudo systemctl restart dnsmasq
```
Contenido de `config/dnsmasq-wireguard-dhcp.conf.example` (se guarda con extensión `.example` porque el `.gitignore` del repositorio excluye los archivos `*.conf`):
```
interface=br-wg-dhcp
bind-interfaces
dhcp-range=10.255.0.10,10.255.0.253,255.255.255.0,infinite
dhcp-option=3
dhcp-option=6
port=0
```
* `port=0` desactiva la parte DNS: el puerto 53 ya está ocupado por otro servicio del sistema y `dnsmasq` no arrancaría.
* El rango empieza en `.10` para no chocar con los peers `10.0.0.2` a `10.0.0.9` que ya existían.

## Script `agregar-cliente.sh` (servidor 1)
Cambios respecto a la versión de ADM002:
* Variables nuevas obligatorias: `WG_ENDPOINT_2` (endpoint del servidor 2) y `WG_PUBKEY_2` (su clave pública).
* Asignación round-robin del servidor principal mediante `/var/lib/wg-balance/next`, con registro en `/var/lib/wg-balance/asignaciones.log`.
* Genera **dos** archivos por cliente: `<Nombre>_wgS1.conf` y `<Nombre>_wgS2.conf`.
* Al terminar imprime el bloque `[Peer]` listo para registrar al cliente en el servidor 2.

Ejecución (desde `~/clientes`, en el servidor 1):
```bash
sudo env WG_ENDPOINT=192.168.220.130:51820 \
         WG_ENDPOINT_2=192.168.220.131:51820 \
         WG_PUBKEY_2='<CLAVE_PUBLICA_SERVIDOR_2>' \
         ~/VPN-para-acceso-seguro-a-servicios/scripts/agregar-cliente.sh <Nombre>
```
Los `.conf` y `.key` generados contienen claves privadas: **no se suben al repositorio**.

### Registro del cliente en el servidor 2
Copiar y pegar en el servidor 2 el bloque que imprime el script (misma clave pública y misma IP que en el servidor 1). Equivale a:
```bash
sudo tee -a /etc/wireguard/wg0.conf > /dev/null <<'PEER'

# Cliente: <Nombre>
[Peer]
PublicKey = <CLAVE_PUBLICA_DEL_CLIENTE>
AllowedIPs = 10.0.0.X/32
PEER
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
```
Este paso es manual hasta que la HU-17 automatice la sincronización de peers.

## Cliente Windows y watchdog
1. Copiar los dos `.conf` del cliente a `C:\wg\`, renombrados como `wgS1.conf` y `wgS2.conf` (WireGuard toma el nombre del túnel del nombre del archivo).
2. Con la app WireGuard, comprobar cada túnel por separado (nunca los dos activos a la vez, comparten IP): `curl.exe http://10.0.0.1:5000/api/status`.
3. Dejar ambos túneles **desactivados** y ejecutar el watchdog en PowerShell como administrador:
```powershell
cd C:\wg
Unblock-File .\wg-failover.ps1
Set-ExecutionPolicy -Scope Process Bypass
.\wg-failover.ps1
```
Funcionamiento de `scripts/wg-failover.ps1`:
* Levanta `wgS1` si no hay ningún túnel activo y espera el primer handshake.
* Cada ~1 s consulta `http://10.0.0.1:5000/api/status` con `curl.exe` (límite de 2 s).
* Tras **3 fallos seguidos** baja el túnel activo, levanta el otro y mide el tiempo hasta que la API vuelve a responder.
* No vuelve solo al servidor principal: se queda en el servidor que tomó el relevo hasta que este falle.

## Pruebas y resultados

### Distribución de clientes
Registro de `/var/lib/wg-balance/asignaciones.log`:

| Cliente | IP VPN | Servidor principal |
|---|---|---|
| Ana | 10.0.0.103 | S1 |
| Beto | 10.0.0.93 | S2 |
| Carla | 10.0.0.107 | S1 |
| Dani | 10.0.0.159 | S2 |

Los cuatro clientes están registrados en ambos servidores (`sudo wg show`).

### Conectividad por servidor
Con `wgS1` y con `wgS2` activos por separado, `GET /api/status` responde `200 OK` con `client_ip: 10.0.0.103`. El campo `hostname` es el mismo en ambos servidores porque el servidor 2 es un clon; el servidor que atiende se comprueba con `latest handshake` en `sudo wg show`.

### Failover
| Prueba | Acción | Resultado | Tiempo hasta recuperar la API |
|---|---|---|---|
| S1 -> S2 | `sudo wg-quick down wg0` en el servidor 1 | El watchdog cambia a `wgS2` y la API responde | **14,5 s** |
| S2 -> S1 | `sudo wg-quick down wg0` en el servidor 2 | El watchdog cambia a `wgS1` y la API responde | **13,5 s** |

Prueba complementaria con `ping -t 10.0.0.1`: los tiempos de espera agotados duraron aproximadamente **12 s** en la caída S1 -> S2 y **10 s** en S2 -> S1, hasta recuperar la conectividad por el otro servidor.

El tiempo total depende del umbral de 3 fallos, del intervalo de consulta y del tiempo de arranque del nuevo túnel (handshake).

### Evidencias
Carpeta `evidencias/ADM006/`:
* `asignaciones.txt` (copia de `/var/lib/wg-balance/asignaciones.log` del servidor 1) y captura de la salida del script (asignación S1/S2 alternada).
* `wg show` de ambos servidores con los clientes registrados.
* Failover S1 -> S2: salida del watchdog y `latest handshake` en el servidor 2.
* Failover S2 -> S1: salida del watchdog y `latest handshake` en el servidor 1.
* Captura del `ping -t 10.0.0.1` junto al watchdog.

## Limitaciones
* El balanceo es **por asignación al crear el cliente**, no en tiempo real: un cliente permanece en su servidor principal hasta que este falle.
* Las **bases de datos de los dos servidores son independientes** (no hay replicación): los datos escritos en uno no aparecen en el otro.
* El watchdog **no regresa automáticamente** al servidor principal cuando este se recupera.
* La conmutación **corta las conexiones abiertas** y tarda unos segundos (detección + nuevo handshake).
* El registro de cada cliente en el servidor 2 es **manual** hasta la HU-17.
* La misma clave de cliente se registra en ambos servidores.
* Los resultados se obtuvieron con un servidor 2 provisional en un entorno de laboratorio local.
