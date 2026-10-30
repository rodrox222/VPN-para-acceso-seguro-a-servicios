# ADM007 (HU-16) — Procedimiento de failover entre servidores VPN

**Requerimiento:** documentar y probar el mecanismo de conmutación por error (failover) entre los servidores VPN redundantes, incluyendo el tiempo de recuperación observado.
**Sprint:** 4 · **Depende de:** HU-14 (servidor secundario), HU-15 (balanceo y watchdog) y HU-17 (gestión de peers).

---

## 1. Objetivo

Comprobar que un cliente configurado con dos túneles (uno por servidor) conserva el acceso a la API cuando el servidor activo deja de responder, y medir cuánto tarda en recuperarse.

## 2. Diseño del mecanismo

El cliente tiene dos configuraciones, `wgS1.conf` y `wgS2.conf`, con la **misma clave de cliente y la misma IP VPN** (`10.0.0.224/32`). Solo cambian la clave pública y el endpoint del servidor. Como ambos túneles comparten IP, **nunca deben estar activos a la vez**.

El script `scripts/wg-failover.ps1` (PowerShell como administrador) funciona así:

| Parámetro | Valor |
|---|---|
| URL monitoreada | `http://10.0.0.1:5000/api/status` |
| Método de chequeo | `curl.exe -s -m 2` (tiempo límite de 2 s) |
| Intervalo entre chequeos | 1 s (≈3 s por ciclo fallido) |
| Umbral de conmutación | 3 fallos consecutivos |
| Acción | Desinstala el túnel activo e instala el otro |
| Failback | **No automático**: se queda en el servidor que tomó el relevo |

Ambos servidores usan `wg0 = 10.0.0.1/24` y publican la API en `10.0.0.1:5000`, por lo que el cliente siempre consume la misma URL.

## 3. Entorno de la prueba

| Elemento | S1 (principal) | S2 (secundario) |
|---|---|---|
| Ubicación | AWS EC2 `t3.small`, Ubuntu 24.04 | VM local (VirtualBox), Ubuntu 22.04 |
| Endpoint | `77.113.155.184:51820` | `192.168.43.129:51820` |
| `wg0` | `10.0.0.1/24` | `10.0.0.1/24` |
| Claves | propias | propias |
| API + BD | Docker (`api-rest`, `api-db`) | Docker (`api-rest`, `api-db`) |
| Identificador en `hostname` de `/api/status` | `c45c7d31e938`* | `ef0d43997552` |

\* El `hostname` es el ID del contenedor. Tras recrear los contenedores de S1 pasó a ser `d968a5627c3c`.

**Cliente:** Windows con la app WireGuard, PowerShell como administrador, `curl.exe` y los archivos `C:\wg\wgS1.conf`, `C:\wg\wgS2.conf` y `C:\wg\wg-failover.ps1`.

El campo `hostname` de `/api/status` permite saber qué servidor atiende en cada momento.

## 4. Preparación

1. **Firewall en S2.** S2 no tenía reglas en `DOCKER-USER`. Se aplicaron con:
   ```bash
   sudo ./scripts/09-reglas-docker-user.sh aplicar
   sudo ./scripts/09-reglas-docker-user.sh instalar-servicio
   ```
2. **Alineación de peers.** S2 conservaba 8 peers antiguos (`10.0.0.2` a `10.0.0.9`). Se reemplazaron por los 5 peers de S1 con `wg-aplicar-peers.sh`:
   ```bash
   # En S1:
   sudo ./scripts/wg-aplicar-peers.sh leer
   # En S2, pegando el resultado:
   sudo ./scripts/wg-aplicar-peers.sh aplicar << 'EOF'
   ...bloques [Peer] de S1...
   EOF
   ```
   Se hizo de forma manual porque S1 (AWS) no puede llegar por SSH a S2 (VM local sin IP pública), así que `gestionar-peers.sh sync` no era viable.
3. **Cliente.** Se crearon `wgS1.conf` y `wgS2.conf` con la misma clave privada del cliente y se descargó el watchdog:
   ```powershell
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/rodrox222/VPN-para-acceso-seguro-a-servicios/main/scripts/wg-failover.ps1" -OutFile C:\wg\wg-failover.ps1
   Unblock-File C:\wg\wg-failover.ps1
   ```

## 5. Procedimiento de prueba

### 5.1 Prueba base (cada servidor por separado)

Con un único túnel instalado cada vez:

```powershell
$wg = "C:\Program Files\WireGuard\wireguard.exe"
& $wg /installtunnelservice C:\wg\wgS1.conf
Start-Sleep -Seconds 5
curl.exe -s -m 5 http://10.0.0.1:5000/api/status
& $wg /uninstalltunnelservice wgS1
```

Se repite con `wgS2`. Resultado: `status: ok`, `client_ip: 10.0.0.224` y el `hostname` propio de cada servidor.

> **Precaución:** interrumpir con Ctrl+C un comando `uninstalltunnelservice` puede dejar el túnel instalado. Si luego se instala el otro, hay dos túneles con la misma IP y la prueba responde con el servidor equivocado. Antes de cada prueba se comprueba con `Get-Service "WireGuardTunnel*"` que no queda ningún túnel.

### 5.2 Failover con caída provocada

1. En el cliente, arrancar el watchdog sobre el túnel activo:
   ```powershell
   cd C:\wg
   Set-ExecutionPolicy -Scope Process Bypass
   .\wg-failover.ps1 -Inicial wgS1
   ```
2. En una segunda ventana, `ping -t 10.0.0.1` como referencia.
3. En el servidor activo, programar su restauración automática (red de seguridad, ya que la caída corta la sesión de administración):
   ```bash
   sudo systemd-run --on-active=420 --unit=restaurar-wg0 /usr/bin/wg-quick up wg0
   ```
4. Provocar la caída anotando la hora:
   ```bash
   date +%T; sudo wg-quick down wg0
   ```
5. Observar el watchdog y verificar con `curl.exe -s -m 5 http://10.0.0.1:5000/api/status` que responde el otro servidor.
6. Esperar a que el timer restaure el servidor caído y comprobar que el cliente **se mantiene** en el servidor que tomó el relevo.

## 6. Resultados

| # | Prueba | Causa | Desde el primer fallo | Desde la caída real | Failback |
|---|---|---|---|---|---|
| 1 | S1 → S2 | `wg-quick down wg0` provocado en S1 | **11,7 s** | ≈ 15 s | No automático |
| 2 | S2 → S1 | `wg-quick down wg0` provocado en S2 | **12,3 s** | ≈ 16 s | No automático |
| 3 | S1 → S2 | Recreación de contenedores en S1 con el túnel arriba (no planificada) | **11,7 s** | no medido* | No automático |

\* No se conoce la hora exacta en que la API dejó de responder, solo la del primer fallo del watchdog.

### 6.1 Registro del watchdog

Prueba 1 (S1 → S2):
```
16:24:47 Tunel inicial: wgS1
16:25:18 API sin respuesta (1/3) en wgS1
16:25:21 API sin respuesta (2/3) en wgS1
16:25:24 API sin respuesta (3/3) en wgS1
16:25:24 CAIDA en wgS1 -> cambiando a wgS2
16:25:29 RECUPERADO en wgS2. Tiempo total desde el primer fallo: 11,7 s
```
La caída se provocó a las 16:25:14.

Prueba 2 (S2 → S1):
```
16:37:01 API sin respuesta (1/3) en wgS2
16:37:04 API sin respuesta (2/3) en wgS2
16:37:07 API sin respuesta (3/3) en wgS2
16:37:07 CAIDA en wgS2 -> cambiando a wgS1
16:37:14 RECUPERADO en wgS1. Tiempo total desde el primer fallo: 12,3 s
```
La caída se provocó a las 16:36:58.

Prueba 3 (caída de la API con el túnel arriba):
```
16:44:20 API sin respuesta (1/3) en wgS1
16:44:23 API sin respuesta (2/3) en wgS1
16:44:26 API sin respuesta (3/3) en wgS1
16:44:26 CAIDA en wgS1 -> cambiando a wgS2
16:44:32 RECUPERADO en wgS2. Tiempo total desde el primer fallo: 11,7 s
```
Los datos de Docker en S1 muestran la imagen creada a las 20:44:32 UTC y los contenedores a las 20:44:33 UTC, es decir, un `docker compose up -d --build`. Esto dejó la API sin responder mientras `wg0` seguía activa. El watchdog lo detectó igualmente.

### 6.2 Verificación con ping

Durante la prueba 1, el ping mostró 3 `Tiempo de espera agotado` y luego una caída de latencia de ≈145 ms (AWS) a 1–47 ms (VM local), lo que confirma el cambio de servidor.

### 6.3 Ausencia de failback automático

Tras restaurar el servidor caído (timer a las 20:30:04 UTC en la prueba 1 y 20:42:28 UTC en la prueba 2), el cliente siguió en el servidor que tomó el relevo:

- Prueba 1: `hostname: ef0d43997552` (S2) a las 20:32:03 UTC, con S1 ya restaurado.
- Prueba 2: `hostname: c45c7d31e938` (S1) a las 20:43:56 UTC, con S2 ya restaurado.

### 6.4 Desglose del tiempo

| Fase | Duración aproximada |
|---|---|
| Hasta el primer chequeo fallido | ≈ 4 s |
| Detección (3 fallos × ≈3 s) | ≈ 6 s |
| Cambio de túnel y nuevo handshake | ≈ 5–7 s |

El tiempo total desde el primer fallo es casi idéntico en las tres pruebas (11,7 a 12,3 s). Está dominado por el umbral de 3 fallos y por el arranque del nuevo túnel, no por qué servidor cae.

### 6.5 Consistencia de peers

Tras las pruebas se comparó la lista de peers de ambos servidores:
```bash
sudo wg show wg0 allowed-ips | LC_ALL=C sort | sha256sum
```
Resultado idéntico en S1 y S2 (`a32d07dffda0e56d18f285347fbe8eee41f67c6b66be2bfa1316c49c4a446739`): los 5 peers y sus IP coinciden. Debe usarse `LC_ALL=C`, porque `sort` con la configuración regional por defecto ordena distinto en cada máquina y produce hashes diferentes con el mismo contenido.

## 7. Cómo restaurar un servidor caído (failback manual)

1. Levantar el servidor caído: `sudo wg-quick up wg0`.
2. Verificar que responde y que sus contenedores están `healthy`.
3. En el cliente, detener el watchdog (Ctrl+C) y cambiar de túnel a mano, **un comando a la vez**:
   ```powershell
   $wg = "C:\Program Files\WireGuard\wireguard.exe"
   & $wg /uninstalltunnelservice wgS2
   Start-Sleep -Seconds 3
   & $wg /installtunnelservice C:\wg\wgS1.conf
   Start-Sleep -Seconds 5
   curl.exe -s -m 5 http://10.0.0.1:5000/api/status
   ```
4. Volver a arrancar el watchdog.

## 8. Limitaciones

- **Failback manual.** El watchdog no vuelve al servidor principal cuando este se recupera.
- **Bases de datos independientes.** No hay replicación: los datos escritos en un servidor no aparecen en el otro. Tras un failover el cliente ve la base del servidor que tomó el relevo.
- **Corte de conexiones abiertas.** La conmutación interrumpe las sesiones en curso (por ejemplo SSH) y tarda unos 15 s.
- **Sensibilidad del umbral.** Por diseño, 3 chequeos fallidos de 2 s bastan para conmutar. En enlaces con latencia alta o variable (≈140–390 ms hacia AWS), un bache de red del cliente podría provocar un cambio innecesario. Aumentar el umbral reduce ese riesgo, pero alarga el tiempo de recuperación.
- **Un solo túnel activo.** Ambos túneles comparten IP; el watchdog debe ser el único que los gestiona.
- **Peers sincronizados a mano.** S2 es una VM local sin IP pública, por lo que S1 no puede alcanzarla por SSH y `gestionar-peers.sh sync` no aplica en este entorno. Los peers se copiaron con `wg-aplicar-peers.sh`.
- **Clave SSH distinta por servidor.** S1 y S2 usan la misma IP `10.0.0.1` pero claves de host SSH diferentes, así que el cliente recibe `REMOTE HOST IDENTIFICATION HAS CHANGED` al cambiar de servidor. Se resuelve usando un archivo de claves conocidas por servidor (`-o UserKnownHostsFile=...`).
- **Entorno de laboratorio.** S2 es una VM local alcanzable solo desde su red; no equivale a un segundo servidor en la nube.