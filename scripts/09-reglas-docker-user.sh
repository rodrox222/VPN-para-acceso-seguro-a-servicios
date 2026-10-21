#!/usr/bin/env bash
# DEV006 / HU13 - Reglas de firewall compatibles con Docker (sustituyen en AWS a la persistencia
# de scripts/05-configurar-firewall-api.sh, que no es compatible con Docker; ver docs/DEV006 §2).
#
# El tráfico hacia puertos publicados de contenedores NO pasa por INPUT: pasa por FORWARD, y allí
# se filtra con la cadena DOCKER-USER (se procesa antes que las reglas propias de Docker).
#
# Uso: sudo ./scripts/09-reglas-docker-user.sh {aplicar|quitar|estado|instalar-servicio|quitar-servicio}
#
#  R1: solo wg0 puede llegar a la API del contenedor (descarta el resto).
#  R2: los clientes VPN no se alcanzan entre sí (wg0 -> wg0), coherente con CLI001.
#  R3: política por defecto de FORWARD en DROP (es lo que Docker hace por sí mismo si es él quien activa el reenvío).
#
# Las reglas se reaplican tras cada arranque de Docker con docker-user-rules.service.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
leer_env() { grep -E "^$1=" "$REPO/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

WG_IF="${WG_IF:-wg0}"
API_IP="${API_IP:-$(leer_env API_IP)}";     API_IP="${API_IP:-172.18.0.10}"
API_PORT="${API_PORT:-$(leer_env API_PORT)}"; API_PORT="${API_PORT:-5000}"
SERVICIO="docker-user-rules.service"
RUTA_SERVICIO="/etc/systemd/system/${SERVICIO}"

[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo: sudo $0 <accion>"; exit 1; }

R1=(-d "$API_IP" -p tcp --dport "$API_PORT" ! -i "$WG_IF" -j DROP)
R2=(-i "$WG_IF" -o "$WG_IF" -j DROP)

esperar_cadena() {   # DOCKER-USER la crea Docker al arrancar
  for _ in $(seq 1 30); do
    iptables -S DOCKER-USER >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "[ERROR] No existe la cadena DOCKER-USER (¿Docker está en marcha?)." >&2
  exit 1
}

asegurar() {        # añade la regla solo si no existe (idempotente)
  if iptables -C DOCKER-USER "$@" 2>/dev/null; then
    echo "[INFO] Ya existe: $*"
  else
    iptables -I DOCKER-USER "$@"
    echo "[OK]   Añadida:  $*"
  fi
}

retirar() {
  local n=0
  while iptables -C DOCKER-USER "$@" 2>/dev/null; do iptables -D DOCKER-USER "$@"; n=$((n+1)); done
  echo "[OK]   Retiradas ${n} copia(s): $*"
}

estado() {
  echo "--- DOCKER-USER ---";  iptables -S DOCKER-USER 2>/dev/null || echo "(no existe)"
  echo "--- Política FORWARD ---"; iptables -S FORWARD 2>/dev/null | head -1
  echo "--- net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null) ---"
}

case "${1:-}" in
  aplicar)
    esperar_cadena
    asegurar "${R1[@]}"
    asegurar "${R2[@]}"
    iptables -P FORWARD DROP && echo "[OK]   Política FORWARD = DROP"
    ;;
  quitar)
    iptables -S DOCKER-USER >/dev/null 2>&1 || { echo "[INFO] No existe DOCKER-USER; nada que quitar."; exit 0; }
    retirar "${R1[@]}"; retirar "${R2[@]}"
    echo "[INFO] La política FORWARD no se modifica al quitar (queda como estaba)."
    ;;
  estado) estado ;;
  instalar-servicio)
    RUTA_SCRIPT="$(readlink -f "$0")"
    cat > "$RUTA_SERVICIO" << UNIT
[Unit]
Description=Reglas DOCKER-USER del proyecto VPN (DEV006)
After=docker.service wg-quick@wg0.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${RUTA_SCRIPT} aplicar
ExecStop=${RUTA_SCRIPT} quitar

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$SERVICIO"
    echo "[OK] Servicio ${SERVICIO} instalado y activo (usa la ruta ${RUTA_SCRIPT}; si mueves el repositorio, reinstálalo)."
    ;;
  quitar-servicio)
    systemctl disable --now "$SERVICIO" 2>/dev/null || true
    rm -f "$RUTA_SERVICIO"; systemctl daemon-reload
    echo "[OK] Servicio ${SERVICIO} retirado."
    ;;
  *) echo "Uso: sudo $0 {aplicar|quitar|estado|instalar-servicio|quitar-servicio}"; exit 1 ;;
esac
