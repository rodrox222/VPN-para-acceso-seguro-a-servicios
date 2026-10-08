# ADM001 — Instalar y configurar el servidor WireGuard (entorno de pruebas)

**Requerimiento:** instalar y configurar el servidor WireGuard en el entorno de pruebas, estableciendo la interfaz `wg0` y el túnel cifrado base.
**Sprint:** 1 · **Prioridad:** 1 · **Esfuerzo estimado:** 5

## 1. Prerrequisitos

- VM `vpn-servidor` con Ubuntu 22.04 LTS lista según [`ENTORNO-VM.md`](ENTORNO-VM.md) (VirtualBox o VMware): adaptador 1 NAT + adaptador 2 solo-anfitrión.
- Anotada la **IP de la VM** en la red solo-anfitrión (`ip -br -4 addr` dentro de la VM).
- Repositorio clonado dentro de la VM (`git clone ...`).
- Un cliente de prueba: el propio anfitrión (recomendado) u otra máquina.

## 2. Parámetros del diseño (coherentes con la sección 8 del informe)

| Parámetro | Valor |
|---|---|
| Interfaz del servidor | `wg0` |
| IP del servidor en el túnel | `10.0.0.1/24` |
| Puerto | UDP `51820` |
| Cliente de prueba | `10.0.0.2/32` (interfaz `wgtest` en el cliente) |

Estos valores son el **contrato** que las demás HU asumen; no cambiarlos sin avisar al equipo.

## 3. Servidor (dentro de la VM)

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

### 4.1 Cliente Linux (p. ej. CachyOS) — con script
```bash
sudo pacman -S wireguard-tools      # Arch/CachyOS. En Ubuntu: sudo apt install wireguard
sudo ./scripts/03-cliente-prueba.sh <CLAVE_PUBLICA_SERVIDOR> <IP_DE_LA_VM>
```
El script genera las claves del cliente, crea `/etc/wireguard/wgtest.conf` e **imprime los comandos exactos** para registrar el cliente en el servidor (sección 4.3).

### 4.2 Cliente Windows / macOS — app oficial WireGuard
1. Instalar la app *WireGuard* → *Añadir túnel vacío…* (la app genera el par de claves y muestra la **clave pública**).
2. Dejar el contenido así (conservando la línea `PrivateKey` que ya generó la app):
```ini
[Interface]
PrivateKey = <la que generó la app>
Address = 10.0.0.2/24

[Peer]
PublicKey = <clave pública del servidor>
Endpoint = <IP_DE_LA_VM>:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```
3. Guardar y pulsar *Activar* (después de registrar el cliente en el servidor, 4.3).

### 4.3 Registrar el cliente en el servidor
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
| 3 | Tráfico cifrado en la red | servidor: `sudo tcpdump -i any -n udp port 51820 -c 10` (mientras corre el ping) | Paquetes UDP/51820 sin contenido legible |
| 4 | Tráfico descifrado dentro del túnel | servidor: `sudo tcpdump -i wg0 -n icmp -c 4` | ICMP entre 10.0.0.2 y 10.0.0.1 |
| 5 | Persistencia | servidor: `sudo reboot`; luego `sudo ./scripts/99-verificar-servidor.sh` | `wg0` activa tras reiniciar |

Las pruebas 3 y 4 juntas evidencian que por la red viaja tráfico cifrado y que solo es legible dentro de `wg0`.

## 6. Evidencias para `evidencias/ADM001/`

- Salida de `99-verificar-servidor.sh`.
- Salida de `sudo wg show` con el handshake.
- Capturas de las pruebas 3 y 4.

> ⚠ **No guardar** la salida de `wg showconf` ni el contenido de ningún `.conf` real: incluyen la clave privada. `wg show` solo muestra claves públicas y es seguro.

## 7. Solución de problemas

| Síntoma | Causa probable |
|---|---|
| El anfitrión no hace ping a la IP de la VM | El adaptador 2 no es solo-anfitrión, o no recibió IP (DHCP de la red solo-anfitrión deshabilitado) |
| No aparece `latest handshake` | `Endpoint` con IP incorrecta; UDP/51820 bloqueado en la VM o en el firewall del anfitrión; clave pública del servidor copiada con errores |
| Handshake OK pero no hay ping | `AllowedIPs` mal definidos o IP del cliente distinta a la registrada en el servidor |
| `wg0` no arranca | `sudo journalctl -u wg-quick@wg0`; revisar sintaxis de `wg0.conf` |
| `wg-quick up wgtest` falla en el anfitrión | Revisar que `wireguard-tools` esté instalado y que el kernel del anfitrión incluya WireGuard (`sudo modprobe wireguard`) |

## 8. Criterio de aceptación (ADM001)

- [ ] `wg0` activa con `10.0.0.1/24` y escuchando en UDP/51820.
- [ ] Servicio habilitado en el arranque.
- [ ] Al menos 1 cliente de prueba con handshake exitoso y ping a `10.0.0.1`.
- [ ] Evidencia de tráfico cifrado en la red (prueba 3).
- [ ] Evidencias subidas a `evidencias/ADM001/`; ninguna clave privada ni `.conf` real en el repositorio.
- [ ] Reproducido desde cero por **otro integrante** en su VM (revisión cruzada).

## 9. Cierre de la HU en Git

```bash
git checkout -b feature/ADM001-servidor-wireguard
git add .
git status                      # verificar: ningún .key ni .conf
git commit -m "feat(ADM001): servidor WireGuard base + guía de entorno y evidencias"
git push -u origin feature/ADM001-servidor-wireguard
```
Abrir un Pull Request hacia `main` y pedir revisión a otro integrante. Al aprobarse y fusionarse, ADM001 queda cerrada.
