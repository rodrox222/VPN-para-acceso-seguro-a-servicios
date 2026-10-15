#!/usr/bin/env bash
# DEV002 / HU07 - Paso 3: construir y levantar la API en su contenedor aislado.
# Puede ejecutarse desde cualquier carpeta; usa la raíz del repositorio.
set -euo pipefail

cd "$(dirname "$0")/.."

[[ -f docker-compose.yml ]] || { echo "[ERROR] No encuentro docker-compose.yml en $(pwd)" >&2; exit 1; }
command -v docker >/dev/null || { echo "[ERROR] Docker no está instalado (scripts/04-instalar-docker.sh)." >&2; exit 1; }

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "[INFO] Creado .env a partir de .env.example (no se sube a GitHub)."
fi
set -a; . ./.env; set +a
VPN_BIND_IP="${VPN_BIND_IP:-10.0.0.1}"

# Precondición dura de la HU07: la IP del túnel debe existir en este host.
if [[ "${VPN_BIND_IP}" != "0.0.0.0" ]] && ! ip -4 -o addr show | grep -q "inet ${VPN_BIND_IP}/"; then
  echo "[ERROR] ${VPN_BIND_IP} no está asignada a ninguna interfaz. ¿wg0 está activa?" >&2
  echo "        Revisa: sudo systemctl status wg-quick@wg0   (HU01)" >&2
  exit 1
fi
echo "[OK] ${VPN_BIND_IP} presente en el host."

if [[ "${VPN_BIND_IP}" == "0.0.0.0" ]]; then
  echo "[AVISO] VPN_BIND_IP=0.0.0.0: la API quedaría PUBLICADA EN TODAS LAS INTERFACES."
  echo "        Úsalo solo para la prueba de regresión del firewall (HU06) y luego revierte."
fi

# --- INICIO MODIFICACIÓN COMPATIBILIDAD HU05 ---
echo "[INFO] Verificando conflicto con el servicio local de la HU05..."
if systemctl is-active --quiet telematica-api.service 2>/dev/null; then
  echo "[INFO] Deteniendo y deshabilitando telematica-api.service para liberar 10.0.0.1:5000..."
  sudo systemctl disable --now telematica-api.service
  echo "[OK] Servicio anterior de la API detenido."
fi
# --- FIN MODIFICACIÓN ---

docker compose config -q && echo "[OK] docker-compose.yml válido."
docker compose up -d --build

echo "[INFO] Esperando a que el contenedor esté saludable..."
estado="no-existe"
for _ in $(seq 1 30); do
  estado="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' api-rest 2>/dev/null || echo "no-existe")"
  [[ "$estado" == "healthy" ]] && break
  sleep 2
done
echo "[INFO] Estado del contenedor: ${estado}"
if [[ "$estado" != "healthy" ]]; then
  echo "[ERROR] No llegó a 'healthy'. Revisa: docker logs api-rest" >&2
  exit 1
fi

echo
echo "------ Publicación del puerto ------"
docker port api-rest
echo "------------------------------------"
echo "[OK] API desplegada. Siguiente: sudo ./scripts/98-probar-aislamiento-api.sh servidor"