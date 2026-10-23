#!/usr/bin/env bash
# QA001 / HU-11 — Prepara el SERVIDOR (VM local o EC2) para las mediciones.
#
# Uso (en el servidor, desde la raíz del repo o desde esta carpeta):
#   ./servidor-preparar.sh start     # levanta iperf3 y la API temporal de línea base
#   ./servidor-preparar.sh estado    # muestra qué está corriendo
#   ./servidor-preparar.sh stop      # lo apaga y limpia (¡no olvidar!)
#
# Qué levanta:
#   1. iperf3 en modo servidor (puerto $PUERTO_IPERF), para medir throughput.
#   2. Una API TEMPORAL (misma imagen que la real) publicada en BIND_SIN_VPN:PUERTO_API_SIN_VPN
#      (BIND_SIN_VPN vale IP_SIN_VPN salvo que se defina otra, p. ej. la IP privada en EC2).
#      Sirve solo como línea base "sin VPN": la API real solo escucha en 10.0.0.1 (HU-06/07),
#      así que sin túnel no se podría medir con curl.
#
# ⚠ La API temporal queda expuesta en IP_SIN_VPN mientras dure la medición. Ejecute 'stop' al terminar.
#   En AWS, además, hay que abrir temporalmente en el Security Group: TCP/UDP 5201 y TCP 5001,
#   solo desde la IP del cliente, y cerrarlos al terminar.

set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
CONFIG="${CONFIG:-$DIR/config.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

: "${PUERTO_API_SIN_VPN:=5001}" "${PUERTO_IPERF:=5201}"
IP_SIN_VPN="${2:-${IP_SIN_VPN:-}}"
# IP en la que el servidor publica la API temporal. Por defecto, IP_SIN_VPN.
# En EC2 la IP pública no pertenece a la interfaz: defina BIND_SIN_VPN con la IP PRIVADA de la instancia.
BIND_SIN_VPN="${BIND_SIN_VPN:-$IP_SIN_VPN}"
PIDFILE="/tmp/qa001-iperf3.pid"
CONTENEDOR="qa001-api-baseline"
IMAGEN="qa001-api"

log()   { echo "[$(date +%H:%M:%S)] $*"; }
fallo() { echo "ERROR: $*" >&2; exit 1; }
como_root() { if [[ $(id -u) -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

iperf_activo() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

cmd_start() {
    [[ -n "$BIND_SIN_VPN" ]] || fallo "Falta la IP del servidor sin VPN. Defínala en config.env (IP_SIN_VPN) o úsela como argumento: ./servidor-preparar.sh start <IP>"
    command -v docker >/dev/null 2>&1 || fallo "Docker no está instalado en este servidor."
    if [[ "$BIND_SIN_VPN" != "0.0.0.0" ]] && ! ip -o addr show | grep -qw "$BIND_SIN_VPN"; then
        fallo "La IP $BIND_SIN_VPN no pertenece a este equipo. En EC2 defina BIND_SIN_VPN con la IP PRIVADA de la instancia (ej. BIND_SIN_VPN=172.31.x.x ./servidor-preparar.sh start)."
    fi

    if ! command -v iperf3 >/dev/null 2>&1; then
        log "Instalando iperf3..."
        como_root env DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 >/dev/null
    fi

    if iperf_activo; then
        log "iperf3 ya estaba corriendo (PID $(cat "$PIDFILE"))"
    else
        iperf3 -s -D -p "$PUERTO_IPERF" --pidfile "$PIDFILE"
        sleep 1
        iperf_activo || fallo "iperf3 no pudo arrancar (¿puerto $PUERTO_IPERF ocupado?)"
        log "iperf3 servidor escuchando en el puerto $PUERTO_IPERF (PID $(cat "$PIDFILE"))"
    fi

    log "Construyendo la imagen de la API desde $REPO/api ..."
    docker build -q -t "$IMAGEN" "$REPO/api" >/dev/null

    docker rm -f "$CONTENEDOR" >/dev/null 2>&1 || true
    docker run -d --name "$CONTENEDOR" -p "$BIND_SIN_VPN:$PUERTO_API_SIN_VPN:5000" "$IMAGEN" >/dev/null
    log "API temporal publicada en $BIND_SIN_VPN:$PUERTO_API_SIN_VPN"

    for _ in $(seq 1 15); do
        if curl -sf --max-time 2 "http://${BIND_SIN_VPN/0.0.0.0/127.0.0.1}:$PUERTO_API_SIN_VPN/api/status" >/dev/null; then
            log "API temporal responde correctamente."
            echo
            echo "Servidor listo para medir. Cuando termine, ejecute:  ./servidor-preparar.sh stop"
            return 0
        fi
        sleep 1
    done
    docker logs "$CONTENEDOR" 2>&1 | tail -10
    fallo "La API temporal no respondió en 15 s (ver logs arriba)."
}

cmd_stop() {
    if iperf_activo; then
        kill "$(cat "$PIDFILE")" && log "iperf3 detenido"
    else
        log "iperf3 no estaba corriendo"
    fi
    rm -f "$PIDFILE"
    if command -v docker >/dev/null 2>&1 && docker rm -f "$CONTENEDOR" >/dev/null 2>&1; then
        log "API temporal eliminada (la imagen '$IMAGEN' se conserva; borrar con: docker rmi $IMAGEN)"
    else
        log "La API temporal no estaba corriendo"
    fi
    echo "Si abrió puertos en un Security Group o firewall para la medición, ciérrelos ahora."
}

cmd_estado() {
    if iperf_activo; then log "iperf3: ACTIVO (PID $(cat "$PIDFILE"))"; else log "iperf3: detenido"; fi
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx "$CONTENEDOR"; then
        log "API temporal: ACTIVA"; docker ps --filter "name=$CONTENEDOR" --format '   {{.Names}}  {{.Ports}}'
    else
        log "API temporal: detenida"
    fi
    echo "Puertos en escucha relevantes:"
    ss -tulnp 2>/dev/null | grep -E ":($PUERTO_IPERF|$PUERTO_API_SIN_VPN)\b" || echo "   (ninguno)"
}

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    estado) cmd_estado ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
