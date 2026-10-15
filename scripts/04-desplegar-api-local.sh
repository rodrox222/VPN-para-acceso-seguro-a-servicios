#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_DIR="${REPO_DIR}/api"
SERVICE_FILE="/etc/systemd/system/telematica-api.service"
RUN_USER="${SUDO_USER:-$USER}"

echo "=== [HU-05 / DEV001] Despliegue de API REST local sobre WireGuard ==="

# 1. Verificar interfaz wg0
if ! ip -4 addr show wg0 | grep -q "10.0.0.1"; then
    echo "[ERROR] La interfaz wg0 con IP 10.0.0.1 no está activa."
    exit 1
fi
echo "[OK] Interfaz wg0 activa con IP 10.0.0.1"

# 2. Crear entorno virtual e instalar dependencias
echo "[INFO] Configurando entorno virtual en ${API_DIR}/venv..."
sudo -u "${RUN_USER}" python3 -m venv "${API_DIR}/venv"
sudo -u "${RUN_USER}" "${API_DIR}/venv/bin/pip" install --upgrade pip -q
sudo -u "${RUN_USER}" "${API_DIR}/venv/bin/pip" install -r "${API_DIR}/requirements.txt" -q
echo "[OK] Dependencias instaladas (Flask + Gunicorn)"

# 3. Crear servicio systemd atado a wg0 (10.0.0.1:5000)
echo "[INFO] Configurando servicio systemd telematica-api.service..."
cat << SERVICE > "${SERVICE_FILE}"
[Unit]
Description=API REST Telematica (Flask + Gunicorn) protegida por WireGuard
After=network.target wg-quick@wg0.service
Requires=wg-quick@wg0.service

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${API_DIR}
Environment="PATH=${API_DIR}/venv/bin"
ExecStart=${API_DIR}/venv/bin/gunicorn --workers 2 --bind 10.0.0.1:5000 app:app
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

# 4. Recargar systemd y arrancar servicio
systemctl daemon-reload
systemctl enable telematica-api.service
systemctl restart telematica-api.service
sleep 2

# 5. Comprobar estado
if systemctl is-active --quiet telematica-api.service; then
    echo "[OK] Servicio telematica-api activo y escuchando en 10.0.0.1:5000"
else
    echo "[ERROR] El servicio telematica-api no pudo iniciar."
    systemctl status telematica-api.service --no-pager
    exit 1
fi
