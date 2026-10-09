
# CLI002 — Automatización de la generación y registro de clientes WireGuard (HU03)

**Requerimiento:** Automatizar mediante un script Bash (`agregar-cliente.sh`) la creación de claves, asignación dinámica de IP libres en la subred `10.0.0.0/24`, generación del archivo de configuración `.conf` del cliente, registro automático del bloque `[Peer]` en el servidor y sincronización en vivo mediante `wg syncconf` sin interrumpir el servicio ni permitir registros duplicados.
**Sprint:** 1 · **Depende de:** HU01 (`wg0` activa en el servidor) y HU02 (Conexión manual de clientes)

---

## 1. Prerrequisitos

* Servidor Ubuntu 22.04 (`vpn-servidor`) con la interfaz `wg0` activa (`10.0.0.1/24`, UDP/51820).
* Permisos de superusuario (`sudo`) para interactuar con `/etc/wireguard/wg0.conf` y comandos `wg`.
* Paquete `wireguard-tools` instalado en el servidor.
* Repositorio Git configurado con `.gitignore` para evitar la filtración accidental de llaves privadas o archivos de configuración de clientes.

---

## 2. Parámetros del diseño

| Componente / Parámetro | Valor / Comportamiento |
| --- | --- |
| Script de automatización | `scripts/agregar-cliente.sh` |
| Rango de subred VPN | `10.0.0.0/24` (IPs asignadas dinámicamente entre `10.0.0.2` y `10.0.0.254`) |
| Estrategia de IP | Autodetección del primer octeto disponible en `/etc/wireguard/wg0.conf` u opción de IP fija |
| Endpoint del servidor | `192.168.23.137:51820` |
| Permisos de credenciales | `chmod 600` aplicado a archivos `.key` y `.conf` generados |
| Sincronización del servidor | `wg syncconf wg0 <(wg-quick strip wg0)` (en caliente, sin reinicio) |

---

## 3. Lógica y código del script `agregar-cliente.sh`

Ubicación dentro del repositorio: `scripts/agregar-cliente.sh`

```bash
#!/bin/bash
# HU03 - Script con validación de nombre, IP automática e incorporación en vivo

if [ -z "$1" ]; then
    echo "Uso: $0 <NombreCliente> [IP_Opcional]"
    echo "Ejemplo (Auto IP): $0 Kevin"
    echo "Ejemplo (Fijar IP): $0 Kevin 10.0.0.5"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Debe ejecutar este script con sudo."
  exit 1
fi

CLIENT_NAME=$1
SERVER_CONF="/etc/wireguard/wg0.conf"
SERVER_PUB_KEY_FILE="/etc/wireguard/server_public.key"

# 1. Validar que el nombre del cliente no esté repetido
if [ -f "${CLIENT_NAME}.conf" ] || grep -q "# Cliente: $CLIENT_NAME$" "$SERVER_CONF"; then
    echo "[ERROR] Ya existe un cliente registrado con el nombre '$CLIENT_NAME'."
    echo "Elige un nombre diferente para evitar sobrescribir claves."
    exit 1
fi

# 2. Asignar IP automáticamente si no se especifica como parámetro
if [ -n "$2" ]; then
    CLIENT_IP=$2
else
    USED_OCTETS=$(grep -oE '10\.0\.0\.[0-9]+' "$SERVER_CONF" 2>/dev/null | cut -d'.' -f4)
    USED_OCTETS="1 $USED_OCTETS"

    NEXT_OCTET=""
    for i in {2..254}; do
        if ! echo "$USED_OCTETS" | grep -qw "$i"; then
            NEXT_OCTET=$i
            break
        fi
    done

    if [ -z "$NEXT_OCTET" ]; then
        echo "[ERROR] No hay direcciones IP disponibles en la subred 10.0.0.0/24"
        exit 1
    fi
    CLIENT_IP="10.0.0.$NEXT_OCTET"
fi

# Validar que la IP elegida no esté duplicada
if grep -q "$CLIENT_IP/32" "$SERVER_CONF"; then
    echo "[ERROR] La IP $CLIENT_IP ya se encuentra registrada en $SERVER_CONF"
    exit 1
fi

# 3. Leer la clave pública del servidor
if [ -f "$SERVER_PUB_KEY_FILE" ]; then
    SERVER_PUB_KEY=$(cat "$SERVER_PUB_KEY_FILE")
else
    SERVER_PUB_KEY=$(wg show wg0 public-key)
fi

SERVER_ENDPOINT="192.168.23.137:51820"

echo "[INFO] Nombre de cliente: $CLIENT_NAME"
echo "[INFO] IP asignada: $CLIENT_IP"

# 4. Generar claves del cliente
wg genkey | tee "${CLIENT_NAME}_private.key" | wg pubkey > "${CLIENT_NAME}_public.key"
CLIENT_PRIV_KEY=$(cat "${CLIENT_NAME}_private.key")
CLIENT_PUB_KEY=$(cat "${CLIENT_NAME}_public.key")

# 5. Crear archivo .conf del cliente
CONF_FILE="${CLIENT_NAME}.conf"
cat <<EOF > "$CONF_FILE"
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = $CLIENT_IP/32

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 "$CONF_FILE" "${CLIENT_NAME}_private.key"

# 6. Agregar automáticamente la sección Peer a wg0.conf
cat <<EOF >> "$SERVER_CONF"

# Cliente: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# 7. Sincronizar en vivo la interfaz wg0 sin interrumpir conexiones existentes
wg syncconf wg0 <(wg-quick strip wg0)

echo "================================================================="
echo "[ÉXITO] Cliente '$CLIENT_NAME' agregado con la IP $CLIENT_IP"
echo " - Archivo generado: $CONF_FILE"
echo " - Servidor actualizado y sincronizado correctamente."
echo "================================================================="

```

---

## 4. Configuración de seguridad en `.gitignore`

Para garantizar que ninguna llave privada ni configuración de usuario se suba al repositorio público de GitHub, el archivo `.gitignore` del proyecto se configuró combinando las reglas estándar de Python y la protección explícita de WireGuard:

```text
# Byte-compiled / optimized / DLL files (Python)
__pycache__/
*.py[cod]
*$py.class

# Exclusión de credenciales y llaves sensibles de WireGuard
*.key
*.conf

```

---

## 5. Procedimiento de ejecución

### 5.1 Modo Asignación Automática de IP

Para dar de alta a un usuario permitiendo que el script identifique y asignes la primera IP libre dentro del segmento `10.0.0.0/24`:

```bash
sudo ./scripts/agregar-cliente.sh Harol

```

### 5.2 Modo IP Fija (Opcional)

Si se desea asignar una IP específica de forma explícita (el script validará antes que no esté ocupada):

```bash
sudo ./scripts/agregar-cliente.sh Sara 10.0.0.4

```

---

## 6. Pruebas de Validación y Casos de Borde

| # | Prueba | Comando / Procedimiento | Resultado esperado |
| --- | --- | --- | --- |
| 1 | Alta y asignación automática | `sudo ./scripts/agregar-cliente.sh ClienteAuto` | Detecta el octeto libre más bajo (ej. `10.0.0.5`), genera archivos `.key` y `.conf` con permisos `600`. |
| 2 | Control de nombre duplicado | Re-ejecutar `sudo ./scripts/agregar-cliente.sh Harol` | Muestra error: `[ERROR] Ya existe un cliente registrado con el nombre 'Harol'` y detiene la ejecución. |
| 3 | Control de IP duplicada | Ejecutar `sudo ./scripts/agregar-cliente.sh Test 10.0.0.3` con la `.3` ocupada | Muestra error: `[ERROR] La IP 10.0.0.3 ya se encuentra registrada` y detiene la ejecución. |
| 4 | Sincronización en caliente | Consultar `sudo wg show` tras ejecutar el script | El nuevo `[Peer]` aparece registrado de inmediato en la tabla del servidor sin caídas de conexión de otros peers. |
| 5 | Inspección de estado en Git | Ejecutar `git status` en la raíz | Los archivos `Harol.conf`, `Harol_private.key` y `Harol_public.key` son ignorados por Git. |

---

## 7. Solución de problemas

| Síntoma | Causa probable | Solución |
| --- | --- | --- |
| `[ERROR] Debe ejecutar este script con sudo.` | El script se lanzó sin privilegios de superusuario | Anteponer `sudo` a la ejecución (`sudo ./scripts/agregar-cliente.sh <Nombre>`). |
| `[ERROR] No hay direcciones IP disponibles` | Se agotaron las IPs disponibles en el rango `10.0.0.2` a `10.0.0.254` | Liberar entradas inactivas en `wg0.conf` o ampliar la máscara de subred. |
| Error de permisos al escribir en `wg0.conf` | Permisos incorrectos en la ruta `/etc/wireguard/` | Verificar que el archivo pertenezca a `root` y ejecutar el script con privileges de `sudo`. |
| Git muestra archivos `.key` en `git status` | `.gitignore` no fue creado en la raíz o los archivos ya estaban rastreados | Ejecutar `git rm -r --cached .` y re-sincronizar el repositorio con `git add .`. |

---

## 8. Criterio de aceptación (HU03)

* [x] Script ejecutable `agregar-cliente.sh` alojado dentro de `scripts/`.
* [x] Generación automatizada de llaves privada/pública y archivo de cliente `.conf` con permisos de seguridad `600`.
* [x] Detección automática del octeto libre más bajo en el rango `10.0.0.0/24`.
* [x] Prevención de colisiones por nombre de cliente o IP repetida.
* [x] Inserción automatizada del bloque `[Peer]` dentro de `/etc/wireguard/wg0.conf`.
* [x] Aplicación de la configuración sin reinicio del servicio usando `wg syncconf`.
* [x] Configuración de `.gitignore` para bloquear la subida de claves y credenciales privadas a GitHub.
* [x] Cambios confirmados y publicados en el repositorio remoto de GitHub mediante la cuenta del autor.

---

## 9. Cierre de la HU en Git

```bash
cd ~/VPN-para-acceso-seguro-a-servicios
git add scripts/agregar-cliente.sh .gitignore
git commit -m "feat(HU03): agregar script automatizado para agregar clientes"
git push origin main

```
