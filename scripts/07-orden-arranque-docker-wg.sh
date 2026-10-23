#!/usr/bin/env bash
# DEV002 / HU07 - Paso 2: que Docker arranque DESPUÉS de WireGuard.
# El contenedor publica su puerto en 10.0.0.1 (IP de wg0). Si Docker arrancara antes que
# wg0, esa IP no existiría todavía y el contenedor no podría enlazar el puerto.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ejecuta como root: sudo $0" >&2
  exit 1
fi

DROPIN_DIR="/etc/systemd/system/docker.service.d"
DROPIN="${DROPIN_DIR}/10-esperar-wireguard.conf"

mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" << 'UNIT'
[Unit]
After=wg-quick@wg0.service
Wants=wg-quick@wg0.service
UNIT

systemctl daemon-reload
echo "[OK] Creado ${DROPIN}"
echo "--- Orden efectivo (docker.service) ---"
systemctl show docker.service -p After -p Wants | tr ' ' '\n' | grep -E "wg-quick" || echo "(no aparece wg-quick: revisa el drop-in)"
echo "---------------------------------------"
echo "[SIGUIENTE] ./scripts/08-desplegar-api.sh  y luego valida el reinicio (docs/DEV002, prueba 8)."
