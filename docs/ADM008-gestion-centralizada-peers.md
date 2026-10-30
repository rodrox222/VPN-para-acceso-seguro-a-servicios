# ADM008 — Gestión centralizada de peers entre servidores VPN (HU-17)

**Requerimiento:** implementar un mecanismo (script o panel simple) que permita administrar la lista de peers autorizados de forma centralizada entre ambos servidores VPN, evitando configuraciones divergentes.
**Sprint:** 4 · **Prioridad:** 17 · **Esfuerzo estimado:** 7
**Depende de:** HU-14 (ADM005, servidor secundario) y HU-15 (ADM006, balanceo de clientes). Complementa a HU-16 (failover).

---

## 1. Problema que resuelve

Con dos servidores VPN (HU-14/HU-15), cada cliente debe estar registrado en **ambos**: si no, el failover falla porque el servidor de relevo no conoce su clave pública. Hasta HU-15 el registro en el servidor 2 era **manual** (copiar y pegar un bloque `[Peer]`), lo que provoca divergencias: clientes que existen en un servidor y no en el otro, IP distintas para la misma clave, o peers revocados que siguen activos en el secundario.

## 2. Diseño

| Decisión | Detalle |
|---|---|
| Fuente de verdad | El **servidor principal (S1)**. La lista de peers se administra solo allí. |
| Qué se sincroniza | Únicamente los bloques `[Peer]`. Cada servidor conserva su propio `[Interface]` y su clave privada (requisito de HU-14). |
| Cómo se aplica | En caliente con `wg syncconf`: no se reinicia `wg0` ni se corta a los clientes conectados. |
| Transporte | SSH desde S1 hacia S2 con una clave dedicada (ed25519). |
| Seguridad en S2 | Usuario `wgsync` sin contraseña; clave con opción `restrict`; `sudo` limitado a un único comando (`/usr/local/sbin/wg-aplicar-peers`, propiedad de root). |
| Autocorrección | Timer de systemd cada 5 min que ejecuta `sync`. |

```
 S1 (principal)                                   S2 (secundario)
 /etc/wireguard/wg0.conf  ← fuente de verdad
        │  gestionar-peers.sh (listar/agregar/revocar/sync)
        │                         ssh wgsync@S2  (clave restringida)
        └──── bloques [Peer] ───────────────────► sudo wg-aplicar-peers aplicar
                                                  ├─ valida (lista blanca)
                                                  ├─ respaldo del wg0.conf
                                                  ├─ conserva [Interface] propio
                                                  └─ wg syncconf (sin cortes)
```

### 2.1 Formato de `wg0.conf` resultante

El receptor deja una zona gestionada al final del archivo:

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <clave propia del servidor>

# >>> PEERS-GESTIONADOS (generado por gestionar-peers.sh; no editar a mano)
# Cliente: Ana
[Peer]
PublicKey = <clave pública>
AllowedIPs = 10.0.0.103/32
# <<< FIN PEERS-GESTIONADOS
```

Es compatible con los formatos anteriores del proyecto (`# Cliente: X` antes del `[Peer]`, o `# peer2` dentro del bloque).

## 3. Archivos entregados

| Archivo | Dónde se ejecuta | Función |
|---|---|---|
| `scripts/gestionar-peers.sh` | S1 (con `sudo`) | Herramienta central: `init`, `estado`, `listar`, `verificar`, `sync`, `agregar`, `revocar`, `instalar-timer`, `quitar-timer`. |
| `scripts/wg-aplicar-peers.sh` | S1 (desde el repo) y S2 (instalado en `/usr/local/sbin/wg-aplicar-peers`) | Receptor: `aplicar` (peers por stdin) y `leer` (nunca expone la clave privada). |
| `scripts/13-peers-preparar-secundario.sh` | S2 (con `sudo`) | Crea el usuario `wgsync`, instala el receptor, autoriza la clave SSH y configura `sudoers`. |
| `docs/ADM008-gestion-centralizada-peers.md` | — | Este documento. |

## 4. Medidas de seguridad

1. **Lista blanca de directivas:** el receptor solo acepta `PublicKey`, `AllowedIPs`, `PersistentKeepalive` y `Endpoint`. Rechaza `PostUp`, `PreUp`, `PrivateKey`, otro `[Interface]`, etc. Un S1 comprometido no puede ejecutar código ni cambiar la clave de S2.
2. **Acceso mínimo:** `wgsync` solo puede ejecutar un script que él no puede modificar (root:root, 755).
3. **No se rechaza silenciosamente lo inválido:** antes de instalar, la configuración se valida con `wg-quick strip`; si `wg syncconf` falla, se restaura el respaldo.
4. **Protección contra borrado accidental:** una lista vacía se rechaza salvo `--permitir-vacio` (solo lo usa `revocar` cuando se elimina el último peer).
5. **Validaciones en S1 antes de sincronizar:** formato de clave pública (44 caracteres base64), `AllowedIPs` presente, sin claves ni IP duplicadas.
6. **Respaldo automático** de `wg0.conf` antes de cada cambio (se conservan los 5 últimos).
7. **Bloqueo (`flock`)** para evitar dos ejecuciones simultáneas.
8. La clave privada nunca viaja por la red: `leer` solo devuelve los bloques `[Peer]`.

## 5. Procedimiento de implementación

### 5.1 Preparación
```bash
git pull
chmod +x scripts/*.sh
```

### 5.2 Servidor principal (S1)
```bash
sudo ./scripts/gestionar-peers.sh init <IP_S2>
```
Genera `/root/.ssh/wg_sync`, guarda `/etc/wireguard/peers-sync.env` e imprime el comando que debe ejecutarse en S2 con la clave pública SSH.

### 5.3 Servidor secundario (S2)
```bash
git pull
sudo ./scripts/13-peers-preparar-secundario.sh 'ssh-ed25519 AAAA... wg-peers-sync@vpn-servidor'
```

### 5.4 Comprobar y sincronizar (en S1)
```bash
sudo ./scripts/gestionar-peers.sh estado      # SSH y receptor operativos
sudo ./scripts/gestionar-peers.sh sync        # primera sincronización
sudo ./scripts/gestionar-peers.sh verificar   # debe indicar "Sin divergencias"
```

### 5.5 Integración con `agregar-cliente.sh`
Reemplazar el bloque final del script que imprime «Registrar el peer en el SERVIDOR 2» por:
```bash
"$(dirname "$(readlink -f "$0")")/gestionar-peers.sh" sync \
  || echo "[AVISO] S2 no sincronizado: ejecute 'sudo gestionar-peers.sh sync'"
```
Con esto, cada cliente nuevo queda registrado en ambos servidores sin pasos manuales.

### 5.6 Sincronización automática (opcional, recomendada)
```bash
sudo ./scripts/gestionar-peers.sh instalar-timer
systemctl list-timers wg-peers-sync.timer
journalctl -u wg-peers-sync.service
```
Cada 5 minutos revisa y corrige divergencias. **Si alguien edita peers directamente en S2, el cambio se sobrescribe.**

## 6. Uso diario (siempre en S1)

| Acción | Comando |
|---|---|
| Ver peers y su estado en S2 | `sudo ./scripts/gestionar-peers.sh listar` |
| Detectar divergencias (exit 1 si hay) | `sudo ./scripts/gestionar-peers.sh verificar` |
| Forzar sincronización | `sudo ./scripts/gestionar-peers.sh sync` |
| Alta con clave propia del cliente | `sudo ./scripts/gestionar-peers.sh agregar Kevin <ClavePublica> 10.0.0.50` |
| Revocar en ambos servidores | `sudo ./scripts/gestionar-peers.sh revocar Ana` (o por clave pública) |
| Quitar sincronización automática | `sudo ./scripts/gestionar-peers.sh quitar-timer` |

Estados que muestra `listar`/`verificar`:

| Estado | Significado |
|---|---|
| `OK` | El peer existe en S1 y S2 con la misma IP. |
| `FALTA_EN_S2` | Está en S1 pero no en S2. |
| `IP_DISTINTA` | Misma clave, distinta `AllowedIPs`. |
| `SOLO_EN_S2` | Está en S2 pero no en S1 (se eliminará con `sync`). |

## 7. Pruebas de validación

| # | Prueba | Resultado esperado |
|---|---|---|
| 1 | `verificar` tras el primer `sync` | «Sin divergencias» |
| 2 | Crear un cliente con `agregar-cliente.sh` | Aparece en S2 sin pasos manuales |
| 3 | Añadir un peer solo en S2 (`wg set`) y ejecutar `verificar` | Reporta `SOLO_EN_S2` y termina con error |
| 4 | Ejecutar `sync` tras la prueba 3 | S2 vuelve a coincidir con S1 |
| 5 | `revocar` un cliente; ping desde él a `10.0.0.1` con `wgS1` y con `wgS2` | 100 % de pérdida en ambos servidores |
| 6 | Durante la prueba 5, ping desde otro cliente | 0 % de pérdida (sin cortes) |
| 7 | Apagar S2 y ejecutar `revocar` | Aviso «S2 NO está actualizado» y código de salida 2 |
| 8 | Encender S2 y esperar al timer (o `sync`) | Converge solo |
| 9 | Reiniciar S2 y ejecutar `verificar` | Los peers persisten |
| 10 | Enviar al receptor de S2 una lista con `PostUp` | Rechazada |
| 11 | Intentar `agregar` con clave o IP duplicada | Rechazado con mensaje claro |
| 12 | Failover (HU-16) con un cliente creado vía `gestionar-peers.sh` | El cliente conecta al servidor de relevo |

## 8. Evidencias para `evidencias/ADM008/`

- Salida de `estado`, `listar` y `verificar` (antes y después de `sync`).
- Prueba 3 y 4: divergencia provocada y corregida.
- Prueba 5 y 6: revocación en ambos servidores y continuidad del resto.
- Prueba 7: aviso con S2 apagado.
- Prueba 10: rechazo de directivas no permitidas.
- `systemctl list-timers wg-peers-sync.timer` y `journalctl -u wg-peers-sync.service`.

> ⚠ **No guardar** `wg showconf`, `wg0.conf`, `peers-sync.env` ni la clave `/root/.ssh/wg_sync`: contienen secretos. `wg show` y la clave pública SSH son seguros.

## 9. Solución de problemas

| Síntoma | Causa probable |
|---|---|
| `estado`: no se pudo ejecutar el receptor | Falta ejecutar `13-peers-preparar-secundario.sh` en S2, clave SSH distinta, IP de S2 incorrecta o puerto 22 bloqueado |
| `Permission denied (publickey)` | La clave pública autorizada en S2 no es la de `/root/.ssh/wg_sync.pub` |
| `sudo: a password is required` | Falta o es inválido `/etc/sudoers.d/wg-aplicar-peers` en S2 |
| «Directivas no permitidas» | La lista contiene líneas distintas de `PublicKey`, `AllowedIPs`, `PersistentKeepalive` o `Endpoint` |
| «Claves públicas duplicadas en S1» | Hay dos bloques con la misma clave en `wg0.conf` de S1; eliminar uno |
| «Lista de peers vacía» | S1 no tiene peers; el receptor rechaza para no borrar todo en S2 |
| `verificar` avisa que `wg0` no coincide con el archivo | Se hicieron cambios con `wg set` sin persistir; ejecutar `sync` o reconstruir con `wg syncconf` |
| «Otra instancia está en ejecución» | El timer o un `sync` anterior sigue corriendo; reintentar en unos segundos |

## 10. Limitaciones

- La sincronización es **unidireccional (S1 → S2)**; no es multi-maestro. Si S1 está caído no se pueden agregar ni revocar peers; S2 sigue atendiendo a los peers ya registrados (lo que necesita HU-16).
- Puede existir divergencia **hasta 5 minutos** si un cambio no pasó por `gestionar-peers.sh` y el timer está activo; sin timer, hasta el siguiente `sync`.
- Si S2 no responde durante una revocación, el peer **sigue activo en S2** hasta el siguiente `sync` (el script lo advierte y devuelve código 2).
- SSH usa `StrictHostKeyChecking=accept-new`: la huella de S2 se acepta la primera vez que se conecta.
- La sincronización cubre dos servidores. Para más servidores habría que generalizar `SECUNDARIO_HOST` a una lista.
- Las bases de datos de ambos servidores siguen siendo independientes (limitación de HU-15, fuera del alcance de esta HU).

## 11. Criterio de aceptación (HU-17)

- [ ] Un único punto de administración (S1) para alta y revocación de peers.
- [ ] Los peers se propagan a S2 sin reiniciar `wg0` ni cortar a los clientes conectados.
- [ ] El comando `verificar` detecta divergencias y `sync` las corrige.
- [ ] La revocación elimina al peer en ambos servidores.
- [ ] Acceso SSH a S2 restringido a un único comando.
- [ ] Sincronización automática periódica operativa.
- [ ] Ninguna clave privada, `.conf` real ni `peers-sync.env` en el repositorio.
- [ ] Evidencias en `evidencias/ADM008/`.
- [ ] Pull Request revisado por **otro integrante**.

## 12. Cierre en Git

```bash
git checkout main && git pull
git checkout -b feature/ADM008-gestion-peers
git add scripts/gestionar-peers.sh scripts/wg-aplicar-peers.sh scripts/13-peers-preparar-secundario.sh \
        scripts/agregar-cliente.sh docs/ADM008-gestion-centralizada-peers.md evidencias/ADM008/
git status        # verificar: ningún .key, .conf, .env ni peers-sync.env
git commit -m "feat(ADM008): gestión centralizada de peers entre servidores VPN"
git push -u origin feature/ADM008-gestion-peers
```
Abrir un Pull Request hacia `main` y pedir revisión a otro integrante.
