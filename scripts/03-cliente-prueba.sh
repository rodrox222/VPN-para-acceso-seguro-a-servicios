#!/usr/bin/env bash
# HU ADM001 - Cliente de prueba (Linux): genera claves del cliente y su configuración.
# Se ejecuta en la máquina CLIENTE (p. ej. el anfitrión Linux), NO en el servidor.
#
# Uso:  sudo ./scripts/03-cliente-prueba.sh <CLAVE_PUBLICA_SERVIDOR> <IP_DEL_SERVIDOR>
# Opcionales (variables de entorno): WG_IF (def. wgtest), CLIENT_TUN_IP (def. 10.0.0.2), WG_PORT (def. 51820)
set -euo pipefail

WG_IF="${WG_IF:-wgtest}"
CLIENT_TUN_IP="${CLIENT_TUN_IP:-10.0.0.2}"
WG_PORT="${WG_PORT:-51820}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
CONF="${WG_DIR}/${WG_IF}.conf"

if [[ $# -ne 2 ]]; then
  echo "Uso: sudo $0 <CLAVE_PUBLICA_SERVIDOR> <IP_DEL_SERVIDOR>" >&2
  exit 1
fi
SERVER_PUB="$1"
SERVER_IP="$2"

[[ $EUID -eq 0 ]] || { echo "[ERROR] Ejecuta como root: sudo $0 ..." >&2; exit 1; }
command -v wg >/dev/null || { echo "[ERROR] Falta 'wg'. Instala wireguard-tools (Arch/CachyOS: sudo pacman -S wireguard-tools)." >&2; exit 1; }

# Una clave pública de WireGuard son 44 caracteres en base64 terminados en '='
if [[ ! "$SERVER_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "[ERROR] La clave pública del servidor no tiene formato válido (revisa que la copiaste completa)." >&2
  exit 1
fi

umask 077
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

PRIV_FILE="${WG_DIR}/${WG_IF}_private.key"
PUB_FILE="${WG_DIR}/${WG_IF}_public.key"
if [[ -f "$PRIV_FILE" ]]; then
  echo "[INFO] Ya existen claves del cliente (${WG_IF}); se conservan."
else
  wg genkey | tee "$PRIV_FILE" | wg pubkey > "$PUB_FILE"
  echo "[OK] Claves del cliente generadas en ${WG_DIR}"
fi
chmod 600 "$PRIV_FILE"

if [[ -f "$CONF" && "${FORCE:-0}" != "1" ]]; then
  echo "[AVISO] ${CONF} ya existe; no se modifica. (FORCE=1 para regenerarlo)"
else
  cat > "$CONF" << CONFEOF
[Interface]
Address = ${CLIENT_TUN_IP}/24
PrivateKey = $(cat "$PRIV_FILE")

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
CONFEOF
  chmod 600 "$CONF"
  echo "[OK] Creado ${CONF}"
fi

CLIENT_PUB="$(cat "$PUB_FILE")"
cat << MSG

============ PASO SIGUIENTE: REGISTRAR ESTE CLIENTE EN EL SERVIDOR ============
Clave pública de este cliente: ${CLIENT_PUB}

En el SERVIDOR ejecuta:

sudo tee -a /etc/wireguard/wg0.conf > /dev/null << 'PEER'

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_TUN_IP}/32
PEER
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'

Luego, en este CLIENTE:
sudo wg-quick up ${WG_IF}
ping -c 4 10.0.0.1
sudo wg show
(Para bajar el túnel: sudo wg-quick down ${WG_IF})
================================================================================
MSG
