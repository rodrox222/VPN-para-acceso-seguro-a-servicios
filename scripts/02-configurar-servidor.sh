#!/usr/bin/env bash
# HU ADM001 - Paso 2: generar claves del servidor, crear wg0.conf y levantar la interfaz.
# Las claves se generan LOCALMENTE en /etc/wireguard (nunca dentro del repositorio).
set -euo pipefail

WG_IF="${WG_IF:-wg0}"
WG_ADDR="${WG_ADDR:-10.0.0.1/24}"
WG_PORT="${WG_PORT:-51820}"
WG_DIR="/etc/wireguard"
CONF="${WG_DIR}/${WG_IF}.conf"

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ejecuta este script como root: sudo $0" >&2
  exit 1
fi
command -v wg >/dev/null || { echo "[ERROR] WireGuard no está instalado. Ejecuta primero 01-instalar-wireguard.sh" >&2; exit 1; }

# Todo archivo creado a partir de aquí será legible solo por root
umask 077
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

# --- Claves del servidor (no se sobrescriben si ya existen) ---
if [[ -f "${WG_DIR}/server_private.key" ]]; then
  echo "[INFO] Ya existen claves del servidor; se conservan."
else
  wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
  echo "[OK] Claves del servidor generadas en ${WG_DIR}"
fi
chmod 600 "${WG_DIR}/server_private.key"
chmod 644 "${WG_DIR}/server_public.key"

# --- Configuración de la interfaz ---
if [[ -f "$CONF" && "${FORCE:-0}" != "1" ]]; then
  echo "[AVISO] ${CONF} ya existe; no se modifica. (Usa FORCE=1 para regenerarlo)"
else
  PRIV="$(cat "${WG_DIR}/server_private.key")"
  cat > "$CONF" << CONFEOF
[Interface]
Address = ${WG_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${PRIV}
CONFEOF
  chmod 600 "$CONF"
  echo "[OK] Creado ${CONF}"
fi

# --- Firewall: abrir solo el puerto UDP de WireGuard si ufw está activo ---
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "${WG_PORT}/udp"
  echo "[OK] ufw: permitido ${WG_PORT}/udp"
else
  echo "[INFO] ufw no está activo; no se modificó el firewall (las reglas iptables se tratan en ADM004)."
fi

# --- Arranque persistente de la interfaz ---
systemctl enable "wg-quick@${WG_IF}" >/dev/null
if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
  echo "[INFO] ${WG_IF} ya estaba activa."
else
  systemctl start "wg-quick@${WG_IF}"
  echo "[OK] Interfaz ${WG_IF} levantada."
fi

echo
echo "================ DATOS PARA CONFIGURAR LOS CLIENTES ================"
echo "Clave pública del servidor: $(cat "${WG_DIR}/server_public.key")"
echo "Puerto UDP:                 ${WG_PORT}"
echo "IP del túnel (servidor):    ${WG_ADDR}"
echo "(La clave pública NO es secreta; la privada nunca se comparte.)"
echo "====================================================================="
echo "[SIGUIENTE] Verifica con: sudo ./scripts/99-verificar-servidor.sh"
