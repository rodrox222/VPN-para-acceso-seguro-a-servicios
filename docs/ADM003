# ADM003 — Revocación de accesos de un peer sin interrupción del servicio (HU04)

**Requerimiento:** Documentar y validar la revocación del acceso de un cliente VPN (*peer*) mediante la eliminación de su clave pública en caliente en el servidor WireGuard (`vpn-servidor`), garantizando la continuidad operativa y la cero interrupción del túnel (*zero downtime*) para el resto de los clientes conectados.
**Sprint:** 1 · **Depende de:** HU01 (`wg0` activa en el servidor) y HU02 (Conexión manual de clientes)

---

## 1. Prerrequisitos

* Servidor Ubuntu 22.04 (`vpn-servidor`) con la interfaz `wg0` activa en `10.0.0.1/24` (puerto UDP/51820).
* Mínimo dos clientes (*peers*) autenticados y con intercambio de claves (*handshake*) activo (ej. `peer1` en `10.0.0.2` y `peer2` en `10.0.0.3`).
* Permisos de superusuario (`sudo`) para ejecutar utilidades de WireGuard (`wg`, `wg syncconf`) y modificar `/etc/wireguard/wg0.conf`.
* Repositorio Git configurado con rama de trabajo `feature/HU04-revocacion-peer` o equivalente.

---

## 2. Parámetros del diseño

| Componente / Parámetro | Valor / Comportamiento |
| --- | --- |
| Estrategia de revocación | Revocación en caliente (*hot-removal*) vía espacio de kernel (`wg set`) |
| Peer a revocar (Ejemplo) | `peer2` (`IP: 10.0.0.3/32`, Clave pública: `WcIlHi+ef4zAZrRPCS/xam8fOrnrO/D+RzUB06iOPxU=`) |
| Peer activo de control | `peer1` (`IP: 10.0.0.2/32`) |
| Comando de memoria volatil | `sudo wg set wg0 peer <CLAVE_PUBLICA> remove` |
| Sincronización persistente | `sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'` |
| Comportamiento deseado revocado | 100% pérdida de paquetes (*Stealth mode* / descarte silencioso en el kernel) |
| Comportamiento deseado activo | 0% pérdida de paquetes (Conexión ininterrumpida sin caída de interfaz) |

---

## 3. Procedimiento de Revocación en Caliente

A diferencia de los comandos `systemctl restart wg-quick@wg0` o `wg-quick down/up` que reiniciarían la interfaz virtual desconectando temporalmente a todos los usuarios, el procedimiento en caliente consta de tres comandos principales:

### 3.1 Identificación del Peer
Muestra el estado activo de las conexiones y sus claves públicas correspondientes:
```bash
sudo wg show
```

### 3.2 Expulsión Inmediata en Memoria (Kernel)
Corta el tráfico del cliente de forma instantánea sin reiniciar el socket UDP:
```bash
sudo wg set wg0 peer WcIlHi+ef4zAZrRPCS/xam8fOrnrO/D+RzUB06iOPxU= remove
```

### 3.3 Persistencia en Configuración
Edición del archivo de configuración para eliminar o comentar el bloque `[Peer]`:
```bash
sudo nano /etc/wireguard/wg0.conf
```
Y posterior sincronización limpia en segundo plano:
```bash
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
```

---

## 4. Configuración de Seguridad y Resguardo en Git

Para garantizar que únicamente se suban evidencias visuales y documentación al repositorio oficial de GitHub:

* Verificar que las capturas de pantalla se almacenen dentro del directorio `evidencias/`.
* Confirmar que el archivo `.gitignore` prevenga la subida accidental de llaves privadas o archivos `.conf`:

```text
# Exclusión de credenciales y llaves sensibles
*.key
*.conf
```

---

## 5. Procedimiento de Ejecución Paso a Paso

### 5.1 Verificación de Conexiones Previas
En `vpn-servidor`, ejecutar `sudo wg show` para confirmar que tanto `peer1` (`10.0.0.2`) como `peer2` (`10.0.0.3`) registran un *latest handshake* reciente.

### 5.2 Remoción del Cliente Objetivo
Ejecutar el comando de remoción con la clave pública de `peer2`:
```bash
sudo wg set wg0 peer WcIlHi+ef4zAZrRPCS/xam8fOrnrO/D+RzUB06iOPxU= remove
```

### 5.3 Modificación del Archivo Persistente
Eliminar el bloque correspondiente en `/etc/wireguard/wg0.conf` y aplicar `wg syncconf`:
```bash
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
```

### 5.4 Prueba de Conectividad Simultánea
* **En el peer revocado (`peer2`):** Lanzar `ping -c 4 10.0.0.1`. Debe fallar con 100% de pérdida de paquetes.
* **En el peer activo (`peer1`):** Lanzar `ping -c 4 10.0.0.1`. Debe responder exitosamente con 0% de pérdida de paquetes.

---

## 6. Pruebas de Validación y Casos de Borde

| # | Prueba | Comando / Procedimiento | Resultado Esperado |
| --- | --- | --- | --- |
| 1 | Revocación en memoria | `sudo wg set wg0 peer <KEY> remove` | El peer desaparece de inmediato de la lista generada por `sudo wg show`. |
| 2 | Bloqueo de cliente revocado | `ping -c 4 10.0.0.1` desde `peer2` | **100% packet loss**. El servidor descarta los paquetes silenciosamente. |
| 3 | Continuidad del servicio | `ping -c 4 10.0.0.1` desde `peer1` | **0% packet loss**. La comunicación no experimenta micro-cortes ni reinicios. |
| 4 | Persistencia tras sincronización | `sudo wg syncconf wg0 <(wg-quick strip wg0)` | La regla de eliminación se mantiene sin restaurar al peer revocado. |
| 5 | Inspección de seguridad en Git | `git status` en la raíz | No se identifican archivos `.key` ni `.conf` rastreados para el commit. |

---

## 7. Solución de Problemas

| Síntoma | Causa Probable | Solución |
| --- | --- | --- |
| El peer revocado aún puede hacer ping | No se ejecutó `wg set remove` o la clave pública indicada no coincidía exactamente | Verificar la clave pública exacta en `sudo wg show` antes de la eliminación. |
| Todos los peers se desconectaron temporalmente | Se utilizó `systemctl restart wg-quick@wg0` o `wg-quick down/up` | Usar exclusivamente `wg set` y `wg syncconf` para evitar reiniciar la interfaz. |
| El peer revocado vuelve a conectarse tras reiniciar | No se eliminó la sección `[Peer]` del archivo `/etc/wireguard/wg0.conf` | Editar `/etc/wireguard/wg0.conf`, borrar el bloque `[Peer]` y guardar los cambios. |
| Git muestra archivos de llaves en `git status` | El archivo `.gitignore` no está en la raíz del repositorio | Mover `.gitignore` a la raíz y ejecutar `git rm -r --cached .` si ya estaban agregados. |

---

## 8. Criterios de Aceptación (HU04)

* [x] Identificación de la clave pública del peer objetivo en `vpn-servidor`.
* [x] Eliminación en caliente de la clave pública mediante `wg set wg0 peer <KEY> remove`.
* [x] Edición del archivo persistente `/etc/wireguard/wg0.conf` y sincronización con `wg syncconf`.
* [x] Confirmación de denegación de servicio (100% packet loss) en el cliente revocado.
* [x] Confirmación de continuidad del servicio (0% packet loss) en los demás clientes activos.
* [x] Registro de capturas de evidencia en la carpeta `evidencias/`.
* [x] Publicación de los cambios en la rama correspondiente del repositorio en GitHub.

---

## 9. Cierre de la HU en Git

```bash
git checkout -b feature/HU04-revocacion-peer
git add evidencias/ docs/ADM003-revocacion-peer.md
git commit -m "feat(HU04): documentacion y evidencias de revocacion de peer sin interrupcion"
git push -u origin feature/HU04-revocacion-peer
```
