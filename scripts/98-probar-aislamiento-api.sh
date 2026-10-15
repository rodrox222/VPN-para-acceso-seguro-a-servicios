#!/usr/bin/env bash
# DEV002 / HU07 - Pruebas de aislamiento de la API en contenedor.
#
# Uso:
#   sudo ./scripts/98-probar-aislamiento-api.sh servidor              (en la VM)
#   ./scripts/98-probar-aislamiento-api.sh cliente <IP_FISICA_VM>     (en un cliente con el túnel ACTIVO)
#   sudo ./scripts/98-probar-aislamiento-api.sh hu06                  (en la VM, cuando exista el firewall de la HU06)
#
# Variables opcionales: VPN_IP (10.0.0.1), API_PORT (5000), CONTAINER (api-rest), API_IP (172.18.0.10)
set -uo pipefail

VPN_IP="${VPN_IP:-10.0.0.1}"
API_PORT="${API_PORT:-5000}"
CONTAINER="${CONTAINER:-api-rest}"
API_IP="${API_IP:-172.18.0.10}"
MODO="${1:-}"
FALLOS=0

ok()    { echo "[OK]    $1"; }
fallo() { echo "[FALLO] $1"; FALLOS=$((FALLOS+1)); }
aviso() { echo "[AVISO] $1"; }
info()  { echo "[INFO]  $1"; }

# Debe responder 200 con status ok
espera_ok() {  # $1 = URL, $2 = descripción
  local salida
  salida="$(curl -sS --max-time 5 -w ' HTTP=%{http_code}' "$1" 2>&1)"
  if [[ "$salida" == *"HTTP=200"* ]] && echo "$salida" | grep -Eq '"status" *: *"ok"'; then ok "$2"; else fallo "$2  ->  ${salida:0:140}"; fi
}

# NO debe responder (rechazo o timeout)
espera_fallo() {  # $1 = URL, $2 = descripción
  if curl -sS --max-time 3 -o /dev/null "$1" >/dev/null 2>&1; then
    fallo "$2  ->  ¡RESPONDIÓ! (no debería)"
  else
    ok "$2"
  fi
}

modo_servidor() {
  [[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo: sudo $0 servidor"; exit 1; }
  command -v docker >/dev/null || { echo "Docker no instalado"; exit 1; }

  echo "=== Pruebas en el servidor (VPN_IP=${VPN_IP}, puerto ${API_PORT}) ==="

  # 1. Contenedor en marcha y saludable
  local estado salud
  estado="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "no-existe")"
  salud="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' "$CONTAINER" 2>/dev/null || echo "-")"
  if [[ "$estado" == "running" && "$salud" == "healthy" ]]; then ok "1. Contenedor '${CONTAINER}' en ejecución y healthy"; else fallo "1. Contenedor: estado=${estado}, salud=${salud}"; fi

  # 2. Puerto publicado SOLO en la IP del túnel
  local publicado malos
  publicado="$(docker port "$CONTAINER" "${API_PORT}/tcp" 2>/dev/null || true)"
  malos="$(echo "$publicado" | grep -v "^${VPN_IP}:${API_PORT}$" | grep -v '^$' || true)"
  if [[ -n "$publicado" && -z "$malos" ]]; then ok "2. Puerto publicado únicamente en ${VPN_IP}:${API_PORT}"; else fallo "2. Publicación inesperada: ${publicado:-<ninguna>}"; fi

  # 3. Ningún socket escuchando el puerto en todas las interfaces
  local comodin
  if command -v ss >/dev/null; then
    comodin="$(ss -tlnH "sport = :${API_PORT}" 2>/dev/null | awk '{print $4}' | grep -E "^(0\.0\.0\.0|\*|\[::\]|::):${API_PORT}$" || true)"
    if [[ -z "$comodin" ]]; then ok "3. Ningún socket escucha ${API_PORT} en todas las interfaces"; else fallo "3. Escucha en todas las interfaces: ${comodin}"; fi
  else
    fallo "3. No se pudo comprobar: falta el comando 'ss' (paquete iproute2)"
  fi

  # 4. Responde por la IP del túnel
  espera_ok "http://${VPN_IP}:${API_PORT}/api/status" "4. GET /api/status por ${VPN_IP} responde 200 y status ok"

  # 5. NO responde por localhost
  espera_fallo "http://127.0.0.1:${API_PORT}/api/status" "5. 127.0.0.1:${API_PORT} no responde"

  # 6. NO responde por ninguna otra IP del servidor (física, puentes de Docker, etc.)
  local ip algunas=0
  command -v ip >/dev/null || fallo "6. No se pudo comprobar: falta el comando 'ip' (paquete iproute2)"
  while read -r ip; do
    [[ -z "$ip" || "$ip" == 127.* || "$ip" == "$VPN_IP" ]] && continue
    algunas=1
    espera_fallo "http://${ip}:${API_PORT}/api/status" "6. ${ip}:${API_PORT} no responde"
  done < <(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  command -v ip >/dev/null && { [[ $algunas -eq 1 ]] || aviso "6. No se encontraron otras IP del servidor para probar"; }

  # 7. El contenedor no corre como root
  local uid
  uid="$(docker exec "$CONTAINER" id -u 2>/dev/null || echo "?")"
  if [[ "$uid" != "0" && "$uid" != "?" ]]; then ok "7. El contenedor corre sin privilegios (uid=${uid})"; else fallo "7. El contenedor corre como root o no se pudo comprobar (uid=${uid})"; fi

  # 8. IP interna estable (la usará la HU06 en sus reglas)
  local ipc
  ipc="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
  if [[ "$ipc" == "$API_IP" ]]; then ok "8. IP interna del contenedor = ${API_IP}"; else fallo "8. IP interna = '${ipc}' (esperada ${API_IP})"; fi

  echo "--- Información para la HU06 y para el informe ---"
  info "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  info "Política FORWARD: $(iptables -S FORWARD 2>/dev/null | head -1)"
}

modo_cliente() {
  local ip_fisica="${2:-}"
  [[ -n "$ip_fisica" ]] || { echo "Uso: $0 cliente <IP_FISICA_DE_LA_VM>"; exit 1; }
  echo "=== Pruebas desde un cliente (túnel activo) ==="

  espera_ok "http://${VPN_IP}:${API_PORT}/api/status" "C1. GET /api/status por el túnel (${VPN_IP}) responde 200 y status ok"

  local eco
  eco="$(curl -sS --max-time 5 -X POST -H 'Content-Type: application/json' -d '{"prueba":"hu07"}' "http://${VPN_IP}:${API_PORT}/api/echo" 2>&1)"
  if echo "$eco" | grep -Eq '"prueba" *: *"hu07"'; then ok "C2. POST /api/echo por el túnel devuelve el eco"; else fallo "C2. POST /api/echo  ->  ${eco:0:140}"; fi

  espera_fallo "http://${ip_fisica}:${API_PORT}/api/status" "C3. ${ip_fisica}:${API_PORT} (IP física de la VM) NO responde"

  info "Prueba manual pendiente (C4): baja el túnel (sudo wg-quick down wgtest) y comprueba que ${VPN_IP}:${API_PORT} deja de responder."
}

modo_hu06() {
  [[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo: sudo $0 hu06"; exit 1; }
  echo "=== Pruebas de la capa de firewall (HU06) sobre el contenedor ==="

  local reglas
  if ! reglas="$(iptables -S DOCKER-USER 2>&1)"; then fallo "H1. No existe la cadena DOCKER-USER (¿Docker instalado y en marcha?)"; return; fi
  ok "H1. La cadena DOCKER-USER existe"
  echo "$reglas" | sed 's/^/        /'

  if echo "$reglas" | grep -E -- '-j (DROP|REJECT)' | grep -Eq -- "(${API_IP}|--dport ${API_PORT}|--ctorigdstport ${API_PORT})"; then
    ok "H2. Hay una regla DROP/REJECT en DOCKER-USER que apunta a la API (${API_IP} / puerto ${API_PORT})"
  else
    fallo "H2. No hay una regla DROP/REJECT en DOCKER-USER que apunte a la API"
  fi

  aviso "H3. Persistencia: las reglas de iptables se pierden al reiniciar si no se guardan. Compruébalo con la prueba 8 de docs/DEV002."
  info "Vuelve a ejecutar ahora:  servidor  (en la VM)  y  cliente <IP_FISICA>  (en un cliente) para confirmar que el firewall NO rompió el acceso por el túnel."
}

case "$MODO" in
  servidor) modo_servidor ;;
  cliente)  modo_cliente "$@" ;;
  hu06)     modo_hu06 ;;
  *) echo "Uso: $0 {servidor|cliente <IP_FISICA_VM>|hu06}"; exit 1 ;;
esac

echo
if [[ $FALLOS -eq 0 ]]; then echo "RESULTADO: todas las verificaciones pasaron."; else echo "RESULTADO: ${FALLOS} verificación(es) fallida(s)."; exit 1; fi
