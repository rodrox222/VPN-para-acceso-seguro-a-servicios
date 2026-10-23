#!/usr/bin/env bash
# DEV006 / HU13 - Verificación integral del despliegue en AWS (guardar la salida como evidencia).
# Comprueba WireGuard + Docker + API + base de datos + firewall + persistencia, en la propia instancia.
#
# Uso: sudo ./scripts/11-verificar-despliegue-aws.sh
# Variables opcionales: VPN_IP (10.0.0.1), API_PORT (5000), WG_IF (wg0), WG_PORT (51820)
set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
VPN_IP="${VPN_IP:-10.0.0.1}"
API_PORT="${API_PORT:-5000}"
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
FALLOS=0; AVISOS=0

ok()    { echo "[OK]    $1"; }
fallo() { echo "[FALLO] $1"; FALLOS=$((FALLOS+1)); }
aviso() { echo "[AVISO] $1"; AVISOS=$((AVISOS+1)); }
info()  { echo "[INFO]  $1"; }
titulo(){ echo; echo "=== $1 ==="; }

[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo: sudo $0"; exit 1; }

espera_ok() {   # URL, descripción  -> 200
  local codigo
  codigo="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$1" 2>&1)"
  if [[ "$codigo" == "200" ]]; then ok "$2"; else fallo "$2  ->  HTTP ${codigo:0:100}"; fi
}
espera_fallo() { # URL, descripción  -> no debe responder
  if curl -sS --max-time 3 -o /dev/null "$1" >/dev/null 2>&1; then fallo "$2  ->  ¡RESPONDIÓ! (no debería)"; else ok "$2"; fi
}

# ------------------------------------------------------------------ 1. Instancia
titulo "1. Instancia AWS"
TOKEN="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
meta() { curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
ID_INSTANCIA=""
[[ -n "$TOKEN" && "$TOKEN" != *" "* ]] && ID_INSTANCIA="$(meta instance-id)"
if [[ "$ID_INSTANCIA" =~ ^i-[0-9a-f]+$ ]]; then
  info "Instancia: ${ID_INSTANCIA} · tipo: $(meta instance-type) · zona: $(meta placement/availability-zone)"
  info "IP pública: $(meta public-ipv4) · IP privada: $(meta local-ipv4)"
else
  aviso "No se pudo consultar los metadatos de EC2 (¿no es una instancia AWS?)"
fi
. /etc/os-release
[[ "${VERSION_ID}" == "22.04" ]] && ok "Ubuntu 22.04 LTS" || aviso "Sistema distinto de Ubuntu 22.04: ${PRETTY_NAME}"
info "Kernel: $(uname -r) · RAM: $(awk '/MemTotal/ {printf "%d MB", $2/1024}' /proc/meminfo) · swap: $(swapon --show --noheadings 2>/dev/null | wc -l) dispositivo(s)"

# ------------------------------------------------------------------ 2. WireGuard
titulo "2. WireGuard"
command -v wg >/dev/null && ok "WireGuard instalado" || fallo "WireGuard no instalado"
lsmod | grep -q '^wireguard' && ok "Módulo de kernel cargado" || fallo "Módulo de kernel no cargado"
ip -4 addr show "$WG_IF" 2>/dev/null | grep -q "${VPN_IP}/24" && ok "${WG_IF} con ${VPN_IP}/24" || fallo "${WG_IF} sin ${VPN_IP}/24"
[[ "$(wg show "$WG_IF" listen-port 2>/dev/null)" == "$WG_PORT" ]] && ok "Escuchando en UDP/${WG_PORT}" || fallo "No escucha en UDP/${WG_PORT}"
systemctl is-enabled --quiet "wg-quick@${WG_IF}" && ok "wg-quick@${WG_IF} habilitado en el arranque" || fallo "wg-quick@${WG_IF} no habilitado"
[[ "$(stat -c %a /etc/wireguard/server_private.key 2>/dev/null)" == "600" ]] && ok "Clave privada del servidor con permisos 600" || fallo "Permisos de la clave privada incorrectos"
NPEERS="$(wg show "$WG_IF" peers 2>/dev/null | wc -l)"
info "Peers registrados: ${NPEERS}"
[[ "$NPEERS" -ge 1 ]] || aviso "No hay peers registrados todavía (agregar-cliente.sh)"
AHORA="$(date +%s)"
while read -r clave ts; do
  [[ -n "${ts:-}" && "$ts" -gt 0 ]] && info "peer ${clave:0:8}... último handshake hace $((AHORA - ts)) s"
done < <(wg show "$WG_IF" latest-handshakes 2>/dev/null)

# ------------------------------------------------------------------ 3. Docker y orden de arranque
titulo "3. Docker"
command -v docker >/dev/null && ok "Docker instalado" || { fallo "Docker no instalado"; }
systemctl is-enabled --quiet docker && ok "docker.service habilitado" || fallo "docker.service no habilitado"
systemctl show docker.service -p After 2>/dev/null | grep -q "wg-quick@${WG_IF}" && ok "Docker arranca después de wg-quick@${WG_IF}" || fallo "Falta el drop-in de orden de arranque (07-orden-arranque-docker-wg.sh)"
info "ip_forward = $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
if systemctl is-active --quiet telematica-api.service 2>/dev/null; then
  fallo "El servicio telematica-api.service (HU05) sigue activo: choca con el contenedor"
fi

# ------------------------------------------------------------------ 4. Contenedores
titulo "4. Contenedores"
for c in api-db api-rest; do
  estado="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo no-existe)"
  salud="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' "$c" 2>/dev/null || echo -)"
  if [[ "$estado" == "running" && "$salud" == "healthy" ]]; then ok "Contenedor ${c}: running y healthy"; else fallo "Contenedor ${c}: estado=${estado}, salud=${salud}"; fi
done
publicado="$(docker port api-rest "${API_PORT}/tcp" 2>/dev/null || true)"
malos="$(echo "$publicado" | grep -v "^${VPN_IP}:${API_PORT}$" | grep -v '^$' || true)"
if [[ -n "$publicado" && -z "$malos" ]]; then ok "api-rest publicado únicamente en ${VPN_IP}:${API_PORT}"; else fallo "Publicación inesperada de api-rest: ${publicado:-<ninguna>}"; fi
if [[ -z "$(docker port api-db 2>/dev/null || true)" ]]; then ok "api-db no publica ningún puerto"; else fallo "api-db publica puertos: $(docker port api-db)"; fi
docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q 'pgdata' && ok "Volumen de datos pgdata presente" || fallo "No existe el volumen pgdata"
uid="$(docker exec api-rest id -u 2>/dev/null || echo '?')"
[[ "$uid" != "0" && "$uid" != "?" ]] && ok "api-rest corre sin privilegios (uid=${uid})" || fallo "api-rest corre como root o no se pudo comprobar"

# ------------------------------------------------------------------ 5. API y aislamiento
titulo "5. API y aislamiento"
espera_ok "http://${VPN_IP}:${API_PORT}/api/status" "GET /api/status por ${VPN_IP}"
espera_ok "http://${VPN_IP}:${API_PORT}/api/usuarios" "GET /api/usuarios (CRUD + base de datos) por ${VPN_IP}"
espera_fallo "http://127.0.0.1:${API_PORT}/api/status" "127.0.0.1:${API_PORT} no responde"
while read -r ipl; do
  [[ -z "$ipl" || "$ipl" == 127.* || "$ipl" == "$VPN_IP" ]] && continue
  espera_fallo "http://${ipl}:${API_PORT}/api/status" "${ipl}:${API_PORT} no responde"
done < <(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

# ------------------------------------------------------------------ 6. Firewall
titulo "6. Firewall"
if reglas="$(iptables -S DOCKER-USER 2>&1)"; then
  ok "La cadena DOCKER-USER existe"
  echo "$reglas" | grep -E -- '-j (DROP|REJECT)' | grep -Eq -- "--dport ${API_PORT}" \
    && ok "R1: hay una regla DROP hacia la API fuera de ${WG_IF}" || fallo "R1: falta la regla DROP hacia la API en DOCKER-USER"
  echo "$reglas" | grep -E -- "-i ${WG_IF} -o ${WG_IF}" | grep -Eq -- '-j (DROP|REJECT)' \
    && ok "R2: los clientes no se alcanzan entre sí (${WG_IF} -> ${WG_IF})" || fallo "R2: falta la regla ${WG_IF} -> ${WG_IF}"
else
  fallo "No existe la cadena DOCKER-USER"
fi
politica="$(iptables -S FORWARD 2>/dev/null | head -1)"
[[ "$politica" == "-P FORWARD DROP" ]] && ok "Política FORWARD = DROP" || aviso "Política FORWARD distinta de DROP (${politica})"
systemctl is-enabled --quiet docker-user-rules.service 2>/dev/null && ok "docker-user-rules.service habilitado (reglas persistentes)" || fallo "Reglas no persistentes: falta 09-reglas-docker-user.sh instalar-servicio"
if systemctl is-enabled --quiet telematica-firewall.service 2>/dev/null; then
  aviso "telematica-firewall.service (HU06) está habilitado: su iptables-restore puede borrar las reglas de Docker al arrancar (docs/DEV006 §2)"
fi

# ------------------------------------------------------------------ 7. Secretos
titulo "7. Configuración y secretos"
if [[ -f "$REPO/.env" ]]; then
  ok ".env presente"
  grep -q 'POSTGRES_PASSWORD=cambiar-esta-clave' "$REPO/.env" && fallo ".env conserva la contraseña de ejemplo" || ok "La contraseña de la base de datos no es la de ejemplo"
  [[ "$(stat -c %a "$REPO/.env")" == "600" ]] && ok ".env con permisos 600" || aviso ".env sin permisos 600 (chmod 600 .env)"
else
  fallo "No existe .env en ${REPO}"
fi
if git -C "$REPO" ls-files 2>/dev/null | grep -Eq '(\.pem$|\.key$|(^|/)\.env$)'; then fallo "Hay claves o .env versionados en Git"; else ok "Git no versiona claves ni .env"; fi

echo
echo "------ wg show ------"; wg show "$WG_IF" 2>/dev/null | sed -E 's/(private key: ).*/\1(oculta)/' || true
echo "---------------------"
if [[ $FALLOS -eq 0 ]]; then echo "RESULTADO: todo correcto (${AVISOS} aviso(s))."; else echo "RESULTADO: ${FALLOS} verificación(es) fallida(s), ${AVISOS} aviso(s)."; exit 1; fi
