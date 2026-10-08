# VPN WireGuard para acceso seguro a servicios — Grupo 35

Proyecto de *Servicios Telemáticos* (UMSS). Implementación de una VPN basada en WireGuard que protege el acceso a una API REST.

## Estructura del repositorio

```
.
├── README.md
├── .gitignore                       # bloquea claves y configs reales
├── config/wg0.conf.example          # plantilla SIN claves
├── scripts/
│   ├── 01-instalar-wireguard.sh     # instala WireGuard + verifica kernel
│   ├── 02-configurar-servidor.sh    # genera claves, crea wg0.conf, levanta wg0
│   ├── 03-cliente-prueba.sh         # (en el CLIENTE Linux) claves + config del cliente
│   └── 99-verificar-servidor.sh     # checklist automático (evidencia)
├── docs/
│   ├── ENTORNO-VM.md                # VirtualBox (CachyOS) y VMware: red, VM, snapshot
│   └── ADM001-servidor-wireguard.md
└── evidencias/ADM001/               # capturas/logs para el informe
```

## Avance por historia (Product Backlog)

| ID | Requerimiento | Estado |
|---|---|---|
| HU01 | Instalar y configurar servidor WireGuard (wg0 + túnel base) | En curso |

## Inicio rápido

1. Crear la VM `vpn-servidor` (Ubuntu 22.04) siguiendo [`docs/ENTORNO-VM.md`](docs/ENTORNO-VM.md) (VirtualBox o VMware).
2. Dentro de la VM:

```bash
git clone https://github.com/<usuario>/<repositorio>.git
cd <repositorio>
sudo ./scripts/01-instalar-wireguard.sh
sudo ./scripts/02-configurar-servidor.sh
sudo ./scripts/99-verificar-servidor.sh
```

3. Probar el túnel con un cliente: [`docs/HU01-servidor-wireguard.md`](docs/HU01-servidor-wireguard.md).

## Contrato de red (lo asumen todas las HU)

| Elemento | Valor |
|---|---|
| Interfaz VPN del servidor | `wg0` — `10.0.0.1/24` |
| Puerto WireGuard | UDP `51820` |
| API REST (HU posteriores) | `10.0.0.1:5000`, solo desde la VPN |
| Clientes | `10.0.0.x/32` (cliente de prueba: `10.0.0.2`) |

## Punto de partida para continuar tras HU01

Cada integrante, en su propia VM: `git pull` de `main` → ejecutar los scripts 01, 02 y 99 → tomar el snapshot `base-HU01`. Todos quedan en el mismo estado sin depender de la VM de otro. Las VM no se comparten entre hipervisores; el repositorio es la fuente de verdad.

## ⚠ Regla de seguridad del equipo

**Jamás se suben claves privadas ni archivos `.conf` reales.** Cada integrante genera sus propias claves en su máquina. Solo se versionan scripts, plantillas `*.conf.example` y documentación. Si alguien sube una clave privada por error, esa clave debe considerarse comprometida y **regenerarse** (borrarla del último commit no basta: queda en el historial de Git).

# HU1 — Instalar y configurar el servidor WireGuard (entorno de pruebas)

**Requerimiento:** instalar y configurar el servidor WireGuard en el entorno de pruebas, estableciendo la interfaz `wg0` y el túnel cifrado base.
**Sprint:** 1 · **Prioridad:** 1 · **Esfuerzo estimado:** 5

## 1. Prerrequisitos y Distribución del Entorno (.ova)

Para mantener la consistencia en el equipo, el servidor base ya ha sido configurado, depurado y exportado. 

**Para el equipo (Importar el entorno):**
1. Descargar el archivo `Ubuntu-WireGuard-Server.ova` compartido.
2. Importarlo en VirtualBox (Archivo > Importar servicio virtual).
3. **CRÍTICO:** Antes de encender la máquina, ir a la configuración de Red de la VM. Asegurarse de que el **Adaptador 2 (Solo-Anfitrión)** esté conectado a la red virtual de su propia máquina anfitriona (ej. `vboxnet0`).
4. La interfaz en Ubuntu debe conservar el nombre `enp0s8` para que las reglas de red funcionen.

## 2. Parámetros del diseño (coherentes con la sección 8 del informe)

| Parámetro | Valor |
|---|---|
| Interfaz del servidor | `wg0` |
| IP del servidor en el túnel | `10.0.0.1/24` |
| Puerto | UDP `51820` |
| Cliente de prueba | `10.0.0.2/32` (interfaz `wgtest` en el cliente) |

Estos valores son el **contrato** que las demás HU asumen; no cambiarlos sin avisar al equipo.

## 3. Servidor (dentro de la VM)

*(Nota: Estos pasos ya fueron ejecutados en la VM exportada en el archivo .ova. Se documentan aquí para referencia o reconstrucción desde cero).*

```bash
sudo ./scripts/01-instalar-wireguard.sh
sudo ./scripts/02-configurar-servidor.sh     # imprime la CLAVE PÚBLICA del servidor: cópiala
sudo ./scripts/99-verificar-servidor.sh
```

1. **01**: instala `wireguard` y `tcpdump`; comprueba que el módulo del kernel carga.
2. **02**: crea `/etc/wireguard` (700), genera las claves del servidor (privada con permisos 600), escribe `wg0.conf`, abre UDP/51820 solo si `ufw` está activo, habilita y arranca `wg-quick@wg0`.
3. **99**: checklist automático; guardar su salida como evidencia.

> No se activa el reenvío de paquetes (IP forwarding): para llegar a servicios del propio servidor (`10.0.0.1`) no hace falta. Se retomará cuando la API corra en Docker.

## 4. Cliente de prueba

### 4.1 Cliente Linux (p. ej. CachyOS / Arch) — con script
```bash
sudo pacman -S wireguard-tools      # Arch/CachyOS. En Ubuntu: sudo apt install wireguard
sudo ./scripts/03-cliente-prueba.sh <CLAVE_PUBLICA_SERVIDOR> <IP_DE_LA_VM>
```
El script genera las claves del cliente, crea `/etc/wireguard/wgtest.conf` e **imprime los comandos exactos** para registrar el cliente en el servidor (sección 4.3).

### 4.2 Registrar el cliente en el servidor
En la VM, sustituyendo la clave pública del cliente:
```bash
sudo tee -a /etc/wireguard/wg0.conf > /dev/null << 'PEER'

[Peer]
PublicKey = <CLAVE_PUBLICA_DEL_CLIENTE>
AllowedIPs = 10.0.0.2/32
PEER
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
```
Luego levantar el túnel en el cliente (Linux: `sudo wg-quick up wgtest`).

## 5. Validación del túnel

| # | Prueba | Comando | Resultado esperado |
|---|---|---|---|
| 1 | Conectividad por el túnel | cliente: `ping -c 4 10.0.0.1` | 0 % pérdida |
| 2 | Handshake | servidor: `sudo wg show` | `latest handshake` reciente y `transfer` > 0 |
| 3 | Tráfico cifrado en la red | servidor: `sudo tcpdump -i enp0s8 -n udp port 51820` (mientras corre el ping) | Paquetes UDP/51820 sin contenido legible |
| 4 | Tráfico descifrado dentro del túnel | servidor: `sudo tcpdump -i wg0 -n icmp` | ICMP entre 10.0.0.2 y 10.0.0.1 |
| 5 | Persistencia | servidor: `sudo reboot`; luego `sudo ./scripts/99-verificar-servidor.sh` | `wg0` activa tras reiniciar |

## 6. Evidencias para `evidencias/ADM001/`

- Salida de `99-verificar-servidor.sh`.
- Salida de `sudo wg show` con el handshake.
- Capturas de las pruebas 3 y 4.

> ⚠ **No guardar** la salida de `wg showconf` ni el contenido de ningún `.conf` real: incluyen la clave privada. `wg show` solo muestra claves públicas y es seguro.

## 7. Solución de problemas avanzados (Guía de Depuración Paso a Paso)

Durante la implementación en VirtualBox pueden surgir bloqueos donde los paquetes llegan físicamente pero WireGuard los descarta sin avisar. Sigue esta guía de aislamiento en orden si el ping a `10.0.0.1` arroja 100% de pérdida:

### Paso 7.1: Descartar desfase de reloj (Timestamps)
WireGuard descarta paquetes automáticamente si el reloj de la VM se desfasó (común tras pausar VirtualBox).
1. En la VM, forzar sincronización NTP:
   ```bash
   sudo timedatectl set-ntp true
   sudo systemctl restart systemd-timesyncd
   ```
2. Reiniciar el túnel en ambas máquinas para limpiar la caché de timestamps:
   ```bash
   sudo wg-quick down wg0 && sudo wg-quick up wg0
   ```

### Paso 7.2: Aislar el bloqueo con TCPDump
Determinar en qué punto exacto mueren los paquetes. Abrir **dos terminales** en el servidor:
- **Terminal 1 (Red física):** `sudo tcpdump -i enp0s8 -n udp port 51820`
- **Terminal 2 (Túnel VPN):** `sudo tcpdump -i wg0 -n icmp`
- *Acción:* Lanzar ping desde el cliente y observar.

### Paso 7.3: Superar bloqueos del Kernel y VirtualBox
Si en el paso 7.2 los paquetes llegan a `enp0s8` pero la terminal de `wg0` está vacía, aplicar estas soluciones en la VM:

**A. Desactivar el filtro de ruta inversa (rp_filter)**
El kernel de Linux puede destruir los paquetes si asume que deberían salir por otra interfaz.
```bash
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.default.rp_filter=0
sudo sysctl -w net.ipv4.conf.enp0s8.rp_filter=0
```

**B. Reparar el Checksum de VirtualBox**
VirtualBox a menudo corrompe las sumas de verificación UDP. El kernel recibe el paquete, lo ve "dañado" y lo destruye. Inyectar esta regla de iptables para repararlo al vuelo:
```bash
sudo iptables -t mangle -A PREROUTING -p udp --dport 51820 -j CHECKSUM --checksum-fill
```

### Paso 7.4: Depuración profunda de WireGuard (dmesg)
Si tras el paso 7.3 `wg0` sigue vacío, encender los logs internos del kernel para obligar a WireGuard a confesar por qué descarta el tráfico:
```bash
sudo modprobe wireguard
sudo bash -c 'echo module wireguard +p > /sys/kernel/debug/dynamic_debug/control'
sudo dmesg -wT | grep wireguard
```
- *Fallo común (`Invalid MAC of handshake`):* Las claves criptográficas no coinciden. Revisar carácter por carácter la clave pública del servidor en el archivo `/etc/wireguard/wgtest.conf` del cliente (cuidado con confundir `I` con `1`, o `B` con `8`).

## 8. Criterio de aceptación (HU01)

- [x] `wg0` activa con `10.0.0.1/24` y escuchando en UDP/51820.
- [x] Servicio habilitado en el arranque.
- [x] Al menos 1 cliente de prueba con handshake exitoso y ping a `10.0.0.1`.
- [x] Evidencia de tráfico cifrado en la red (prueba 3).
- [x] Evidencias subidas a `evidencias/ADM001/`; ninguna clave privada ni `.conf` real en el repositorio.
- [ ] Reproducido desde cero por **otro integrante** en su VM usando el archivo `.ova` (revisión cruzada).
