# CLI001 — Configurar 3 clientes WireGuard con autenticación por claves (HU02)

**Requerimiento:** configurar al menos 3 clientes (peers) WireGuard, cada uno con su propio par de claves y una IP dentro de la subred VPN, conectados de forma simultánea al servidor.
**Sprint:** 1 · **Depende de:** HU01 (`wg0` activa en el servidor)

## 1. Prerrequisitos

- Servidor `vpn-servidor` con `wg0` activa (`10.0.0.1/24`, UDP/51820), según [`ADM001-servidor-wireguard.md`](ADM001-servidor-wireguard.md).
- Anotados, en el servidor:
  - Su **IP en la red solo-anfitrión**: `ip -br -4 addr` (interfaz de la red solo-anfitrión).
  - Su **clave pública**: `sudo wg show wg0 public-key`.
- Tres clientes: un equipo anfitrión (Windows/Linux) y dos VMs Ubuntu en la misma red solo-anfitrión.

## 2. Parámetros del diseño

| Peer | Equipo | IP en el túnel | AllowedIPs en el servidor |
|---|---|---|---|
| peer1 | Anfitrión Windows (app WireGuard) | `10.0.0.2/24` | `10.0.0.2/32` |
| peer2 | VM Ubuntu (clon) | `10.0.0.3/24` | `10.0.0.3/32` |
| peer3 | VM Ubuntu (clon) | `10.0.0.4/24` | `10.0.0.4/32` |

Cada peer usa **su propio par de claves**; la clave privada nunca sale del equipo que la generó.

## 3. Preparar una VM cliente (peer2 / peer3)

Si la VM es un clon del servidor, hay que neutralizarla para que no actúe como segundo servidor:

```bash
sudo systemctl disable --now wg-quick@wg0
sudo hostnamectl set-hostname peer2        # peer3 en el otro clon
ip -br -4 addr                             # su IP debe ser distinta a la del servidor
```

> Al clonar en VirtualBox/VMware se debe generar **nueva dirección MAC**; si no, la IP puede coincidir con la del servidor.

## 4. Generar las claves del cliente

**Linux:**
```bash
cd ~
umask 077
wg genkey | tee peer2_private.key | wg pubkey > peer2_public.key
cat peer2_public.key                       # esta es la que se registra en el servidor
```

**Windows:** app *WireGuard* → *Añadir túnel vacío…* (genera el par y muestra la clave pública).

## 5. Configuración del cliente

**Linux** — `/etc/wireguard/peer2.conf` (peer3: `Address = 10.0.0.4/24`):
```bash
sudo bash -c 'cat > /etc/wireguard/peer2.conf << EOF
[Interface]
PrivateKey = $(cat /home/<usuario>/peer2_private.key)
Address = 10.0.0.3/24

[Peer]
PublicKey = <CLAVE_PUBLICA_DEL_SERVIDOR>
Endpoint = <IP_DEL_SERVIDOR>:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF'
sudo chmod 600 /etc/wireguard/peer2.conf
```

**Windows** — contenido del túnel (conservando la `PrivateKey` que generó la app):
```ini
[Interface]
PrivateKey = <la que generó la app>
Address = 10.0.0.2/24

[Peer]
PublicKey = <CLAVE_PUBLICA_DEL_SERVIDOR>
Endpoint = <IP_DEL_SERVIDOR>:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

`AllowedIPs = 10.0.0.0/24` envía por el túnel solo el tráfico de la VPN (no todo Internet).

## 6. Registrar cada peer en el servidor

En el servidor, sustituyendo la clave pública y la IP de cada peer:

```bash
sudo tee -a /etc/wireguard/wg0.conf > /dev/null << 'PEER'

[Peer]
# peer2
PublicKey = <CLAVE_PUBLICA_DEL_PEER>
AllowedIPs = 10.0.0.3/32
PEER
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
sudo wg show
```

`wg syncconf` aplica el cambio **sin reiniciar la VPN**: los peers ya conectados no se interrumpen.

## 7. Levantar el túnel en cada cliente

```bash
sudo wg-quick up peer2        # Windows: botón "Activar"
ping -c 4 10.0.0.1
sudo wg show
```

## 8. Validación

Con los 3 clientes activos al mismo tiempo:

| # | Prueba | Dónde / Comando | Resultado esperado |
|---|---|---|---|
| 1 | Peers registrados y conectados | servidor: `sudo wg show` | 3 peers con `latest handshake` reciente y `transfer` > 0 |
| 2 | Conectividad al servidor | cada cliente: `ping -c 4 10.0.0.1` | 0 % de pérdida |
| 3 | Conexión simultánea | los 3 clientes lanzan el ping a la vez | Los 3 responden |
| 4 | IP única por peer | servidor: `sudo wg show` | `allowed ips`: 10.0.0.2/32, 10.0.0.3/32, 10.0.0.4/32 |
| 5 | Autenticación (prueba negativa) | ver 8.1 | Sin handshake y 100 % de pérdida |

> Los clientes **no se alcanzan entre sí** (por ejemplo, peer2 → 10.0.0.2): el servidor tiene el reenvío de paquetes (IP forwarding) desactivado por diseño. Basta con alcanzar `10.0.0.1`, donde correrá la API.

### 8.1 Prueba negativa: cliente con clave no registrada

En un cliente (ej. peer3), sustituir temporalmente su clave privada por una generada al azar:

```bash
sudo wg-quick down peer3
sudo sed -i "s|^PrivateKey = .*|PrivateKey = $(wg genkey)|" /etc/wireguard/peer3.conf
sudo wg-quick up peer3
ping -c 3 10.0.0.1        # debe fallar: 100 % de pérdida
sudo wg show              # sin "latest handshake"
```

Esto demuestra que el servidor solo acepta peers cuya clave pública está registrada.

**Restaurar** la clave original y verificar que vuelve a conectar:
```bash
sudo wg-quick down peer3
sudo sed -i "s|^PrivateKey = .*|PrivateKey = $(cat /home/<usuario>/peer3_private.key)|" /etc/wireguard/peer3.conf
sudo wg-quick up peer3
ping -c 3 10.0.0.1
```

## 9. Evidencias para `evidencias/CLI001/`

- `wg show` del servidor con los 3 peers y sus handshakes.
- Captura del ping a `10.0.0.1` desde cada cliente.
- Captura de la prueba negativa (8.1).

> ⚠ **No guardar** la salida de `wg showconf` ni el contenido de ningún `.conf` o `.key` real: incluyen claves privadas. `wg show` solo muestra claves públicas y es seguro.

## 10. Solución de problemas

| Síntoma | Causa probable |
|---|---|
| No hay `latest handshake` | `Endpoint` con IP incorrecta; clave pública del servidor mal copiada (confundir `I`/`1`, `O`/`0`); peer no registrado en el servidor |
| Handshake OK pero sin ping | `AllowedIPs` del servidor distinto a la IP del cliente (`Address`) |
| El clon responde como servidor | `wg-quick@wg0` sigue activo: `sudo systemctl disable --now wg-quick@wg0` |
| Dos máquinas con la misma IP en la red solo-anfitrión | Clon creado sin regenerar la dirección MAC |
| `wg-quick up` falla | `sudo journalctl -xe`; revisar sintaxis del `.conf` y permisos 600 |

## 11. Criterio de aceptación (HU02)

- [ ] 3 peers con par de claves propio y handshake simultáneo.
- [ ] Cada peer con IP única dentro de `10.0.0.0/24`.
- [ ] Ping exitoso a `10.0.0.1` desde los 3 clientes.
- [ ] Prueba negativa documentada (cliente no registrado sin acceso).
- [ ] Evidencias subidas a `evidencias/CLI001/`; ninguna clave privada ni `.conf` real en el repositorio.
- [ ] Revisado por **otro integrante** mediante Pull Request.

## 12. Cierre de la HU en Git

```bash
git checkout -b feature/CLI001-clientes-wireguard
git add .
git status                      # verificar: ningún .key ni .conf real
git commit -m "feat(CLI001): 3 clientes WireGuard autenticados y validación simultánea"
git push -u origin feature/CLI001-clientes-wireguard
```
Abrir un Pull Request hacia `main` y pedir revisión a otro integrante.
