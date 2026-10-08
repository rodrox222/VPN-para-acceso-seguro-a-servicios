#!/usr/bin/env bash
# HU ADM001 - Verificación del servidor WireGuard (útil como evidencia para el informe).
set -uo pipefail

WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_DIR="/etc/wireguard"
fallos=0
ok()   { echo "[OK]    $1"; }
fail() { echo "[FALLO] $1"; fallos=$((fallos+1)); }

[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo: sudo $0"; exit 1; }

command -v wg >/dev/null && ok "WireGuard instalado" || fail "WireGuard no instalado"
lsmod | grep -q '^wireguard' && ok "Módulo de kernel cargado" || fail "Módulo de kernel no cargado"
ip link show "$WG_IF" >/dev/null 2>&1 && ok "Interfaz ${WG_IF} existe" || fail "Interfaz ${WG_IF} no existe"
ip -4 addr show "$WG_IF" 2>/dev/null | grep -q '10.0.0.1/24' && ok "IP 10.0.0.1/24 asignada a ${WG_IF}" || fail "IP 10.0.0.1/24 no asignada"
systemctl is-enabled --quiet "wg-quick@${WG_IF}" && ok "Servicio habilitado en el arranque" || fail "Servicio no habilitado"
systemctl is-active --quiet "wg-quick@${WG_IF}" && ok "Servicio activo" || fail "Servicio inactivo"
[[ "$(wg show "$WG_IF" listen-port 2>/dev/null)" == "$WG_PORT" ]] && ok "WireGuard escuchando en UDP/${WG_PORT}" || fail "WireGuard no escucha en UDP/${WG_PORT}"
[[ "$(stat -c %a ${WG_DIR}/server_private.key 2>/dev/null)" == "600" ]] && ok "Clave privada con permisos 600" || fail "Permisos de clave privada incorrectos"

echo
echo "------ wg show ------"
wg show "$WG_IF" 2>/dev/null || true
echo "---------------------"
if [[ $fallos -eq 0 ]]; then echo "RESULTADO: todo correcto."; else echo "RESULTADO: ${fallos} verificación(es) fallida(s)."; exit 1; fi
