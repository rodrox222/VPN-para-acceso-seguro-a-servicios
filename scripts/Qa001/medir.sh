#!/usr/bin/env bash
# QA001 / HU-11 — Mide latencia y throughput CON y SIN VPN.
#
# Se ejecuta en el CLIENTE (un peer Linux, p. ej. peer2). Requiere que el servidor
# tenga preparado el entorno de medición (ver servidor-preparar.sh).
#
# Uso:
#   ./medir.sh --rapido      # prueba corta para verificar que todo funciona (~2 min)
#   ./medir.sh               # medición completa según config.env
#   ./medir.sh --config otro.env
#
# Qué hace, por cada corrida y por cada escenario (sin_vpn, con_vpn):
#   1. ping            -> RTT, jitter y pérdida
#   2. curl            -> tiempos HTTP (conexión, primer byte, total) sobre /api/status
#   3. iperf3 TCP      -> throughput
#   4. iperf3 UDP      -> throughput, jitter y pérdida
# Alterna el orden de los escenarios entre corridas para que el ruido afecte a ambos por igual.
# Guarda los datos crudos y, al final, llama a analizar.py para generar el resumen.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
CONFIG="$DIR/config.env"
RAPIDO=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rapido) RAPIDO=1; shift ;;
        --config) CONFIG="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Opción desconocida: $1 (use --help)"; exit 2 ;;
    esac
done

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fallo() { echo "ERROR: $*" >&2; exit 1; }

# ----------------------------------------------------------------- configuración
[[ -f "$CONFIG" ]] || fallo "No existe $CONFIG. Copie config.env.example a config.env y ajústelo."
# shellcheck disable=SC1090
source "$CONFIG"

: "${ENTORNO:=local}" "${IP_SIN_VPN:?Falta IP_SIN_VPN en config.env}" "${IP_CON_VPN:=10.0.0.1}"
: "${PUERTO_API_VPN:=5000}" "${PUERTO_API_SIN_VPN:=5001}" "${PUERTO_IPERF:=5201}"
: "${RUNS:=10}" "${PING_COUNT:=100}" "${CURL_REQUESTS:=100}" "${IPERF_TIME:=30}" "${IPERF_OMIT:=3}"
: "${UDP_BW:=100M}" "${UDP_LEN:=1200}" "${VERIFICAR_RUTAS:=1}"

if [[ $RAPIDO -eq 1 ]]; then
    RUNS=2; PING_COUNT=10; CURL_REQUESTS=10; IPERF_TIME=5; IPERF_OMIT=1
    log "Modo rápido: RUNS=$RUNS PING=$PING_COUNT CURL=$CURL_REQUESTS IPERF=${IPERF_TIME}s"
fi

# ------------------------------------------------------------------ requisitos
faltan=()
for c in ping curl iperf3 python3 ip; do command -v "$c" >/dev/null 2>&1 || faltan+=("$c"); done
if [[ ${#faltan[@]} -gt 0 ]]; then
    fallo "Faltan herramientas: ${faltan[*]}
  Instalar con: sudo apt install -y iperf3 iputils-ping curl python3 iproute2"
fi

# --------------------------------------------------------- verificación de rutas
es_wireguard() { ip -d link show "$1" 2>/dev/null | grep -qw wireguard; }
iface_ruta()   { ip route get "$1" 2>/dev/null | grep -o 'dev [^ ]*' | head -1 | cut -d' ' -f2; }

IFACE_CON="$(iface_ruta "$IP_CON_VPN")"
IFACE_SIN="$(iface_ruta "$IP_SIN_VPN")"
log "Ruta con_vpn -> $IP_CON_VPN por interfaz '${IFACE_CON:-?}'"
log "Ruta sin_vpn -> $IP_SIN_VPN por interfaz '${IFACE_SIN:-?}'"

if [[ "$VERIFICAR_RUTAS" == "1" ]]; then
    es_wireguard "${IFACE_CON:-none}" || fallo "El tráfico a $IP_CON_VPN no sale por una interfaz WireGuard. ¿Está el túnel activo? (sudo wg-quick up <nombre>)"
    if es_wireguard "${IFACE_SIN:-none}"; then
        fallo "El tráfico a $IP_SIN_VPN sale por WireGuard: no sería una medición 'sin VPN'. Revise AllowedIPs del cliente (debe ser 10.0.0.0/24, no 0.0.0.0/0)."
    fi
fi

# ------------------------------------------------------------ conectividad previa
comprobar() {  # nombre ip puerto_api
    local ok=0 intento
    curl -sf --max-time 5 "http://$2:$3/api/status" >/dev/null \
        || fallo "No responde la API de '$1' en http://$2:$3/api/status
  (con_vpn: ¿túnel activo y 'docker compose up' corriendo?  sin_vpn: ¿ejecutó servidor-preparar.sh start?)"
    # iperf3 atiende un solo cliente a la vez: si está ocupado, se espera y se reintenta
    for intento in 1 2 3 4 5; do
        if iperf3 -c "$2" -p "$PUERTO_IPERF" -t 1 >/dev/null 2>&1; then ok=1; break; fi
        log "  iperf3 de '$1' no disponible (¿servidor ocupado?), reintento $intento/5 en 3 s..."
        sleep 3
    done
    [[ $ok -eq 1 ]] || fallo "No responde iperf3 de '$1' en $2:$PUERTO_IPERF tras 5 intentos
  (¿servidor-preparar.sh start? Compruebe a mano: iperf3 -c $2 -p $PUERTO_IPERF -t 1)"
    sleep 3   # dejar que el servidor iperf3 termine de cerrar esta prueba
}
comprobar con_vpn "$IP_CON_VPN" "$PUERTO_API_VPN"
comprobar sin_vpn "$IP_SIN_VPN" "$PUERTO_API_SIN_VPN"
log "Conectividad previa OK en ambos escenarios"

# ---------------------------------------------------------------------- salida
OUT_BASE="${OUT_BASE:-$REPO/evidencias/QA001}"
OUT="$OUT_BASE/${ENTORNO}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT/raw/sin_vpn" "$OUT/raw/con_vpn"

{
    echo "entorno=$ENTORNO"
    echo "fecha=$(date -Is)"
    echo "cliente=$(hostname)"
    echo "kernel=$(uname -r)"
    echo "cpus=$(nproc)"
    echo "ip_sin_vpn=$IP_SIN_VPN  (interfaz: ${IFACE_SIN:-?})"
    echo "ip_con_vpn=$IP_CON_VPN  (interfaz: ${IFACE_CON:-?})"
    echo "mtu_interfaz_vpn=$(ip -o link show "${IFACE_CON:-lo}" 2>/dev/null | grep -o 'mtu [0-9]*' | cut -d' ' -f2)"
    echo "iperf3=$(iperf3 --version 2>&1 | head -1)"
    echo "curl=$(curl --version | head -1)"
    echo "wireguard_tools=$(wg --version 2>/dev/null | head -1)"
    echo "runs=$RUNS ping_count=$PING_COUNT curl_requests=$CURL_REQUESTS iperf_time=$IPERF_TIME iperf_omit=$IPERF_OMIT udp_bw=$UDP_BW udp_len=$UDP_LEN"
} > "$OUT/entorno.txt"

# ---------------------------------------------------------------- una corrida
# Ejecuta iperf3 y, si el servidor está ocupado con la prueba anterior, espera y reintenta.
correr_iperf() {  # archivo_json archivo_err args_de_iperf3...
    local json="$1" err="$2" intento
    shift 2
    for intento in 1 2 3 4 5; do
        iperf3 "$@" -J > "$json" 2> "$err" && return 0
        if grep -qs "server is busy" "$json" "$err"; then
            log "  iperf3 ocupado, reintento $intento/5 en 3 s..."
            sleep 3
        else
            return 1
        fi
    done
    return 1
}

medir_escenario() {  # escenario ip puerto_api n_corrida
    local esc="$1" ip="$2" puerto="$3" n d f out i
    n="$(printf '%02d' "$4")"
    d="$OUT/raw/$esc"

    log "  [$esc] ping ($PING_COUNT paquetes)"
    ping -c "$PING_COUNT" -i 0.2 "$ip" > "$d/run${n}_ping.txt" 2>&1 || log "  AVISO: ping terminó con error (pérdida alta o sin respuesta)"

    log "  [$esc] curl ($CURL_REQUESTS peticiones)"
    f="$d/run${n}_curl.csv"
    echo "connect_s,ttfb_s,total_s,http_code" > "$f"
    for ((i = 0; i < CURL_REQUESTS; i++)); do
        out="$(curl -s -o /dev/null --max-time 10 \
            -w '%{time_connect},%{time_starttransfer},%{time_total},%{http_code}' \
            "http://$ip:$puerto/api/status" 2>/dev/null)" || out="0,0,0,000"
        echo "$out" >> "$f"
    done

    log "  [$esc] iperf3 TCP (${IPERF_TIME}s)"
    correr_iperf "$d/run${n}_tcp.json" "$d/run${n}_tcp.err" \
        -c "$ip" -p "$PUERTO_IPERF" -t "$IPERF_TIME" -O "$IPERF_OMIT" \
        || log "  AVISO: iperf3 TCP falló (ver run${n}_tcp.json / .err)"
    sleep 3

    log "  [$esc] iperf3 UDP (${IPERF_TIME}s, $UDP_BW, datagrama $UDP_LEN B)"
    correr_iperf "$d/run${n}_udp.json" "$d/run${n}_udp.err" \
        -c "$ip" -p "$PUERTO_IPERF" -u -b "$UDP_BW" -l "$UDP_LEN" -t "$IPERF_TIME" -O "$IPERF_OMIT" \
        || log "  AVISO: iperf3 UDP falló (ver run${n}_udp.json / .err)"
    sleep 3
}

# --------------------------------------------------------------------- bucle
por_escenario=$(( PING_COUNT / 5 + CURL_REQUESTS / 20 + 2 * (IPERF_TIME + IPERF_OMIT + 4) ))
total=$(( por_escenario * 2 * RUNS ))
log "Resultados en: $OUT"
log "Duración estimada: ~$(( total / 60 )) min ($RUNS corridas x 2 escenarios)"

trap 'echo; log "Interrumpido. Datos parciales en $OUT (puede analizarlos con: python3 $DIR/analizar.py $OUT)"; exit 130' INT TERM

for ((r = 1; r <= RUNS; r++)); do
    if (( r % 2 == 1 )); then orden=(sin_vpn con_vpn); else orden=(con_vpn sin_vpn); fi
    log "=== Corrida $r de $RUNS (orden: ${orden[*]}) ==="
    for esc in "${orden[@]}"; do
        if [[ $esc == sin_vpn ]]; then
            medir_escenario sin_vpn "$IP_SIN_VPN" "$PUERTO_API_SIN_VPN" "$r"
        else
            medir_escenario con_vpn "$IP_CON_VPN" "$PUERTO_API_VPN" "$r"
        fi
    done
done

log "Mediciones terminadas. Procesando datos..."
python3 "$DIR/analizar.py" "$OUT" || fallo "analizar.py falló; los datos crudos están en $OUT/raw"
log "Listo. Resumen: $OUT/resumen.md"
