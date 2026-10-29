#!/usr/bin/env bash
# HU-17 / ADM008 - Receptor de peers: aplica la lista de peers sobre ESTE servidor.
# Conserva el bloque [Interface] local (clave privada propia) y reemplaza solo los [Peer].
#
# Subcomandos (siempre como root):
#   aplicar [--permitir-vacio]   lee los bloques [Peer] por stdin y los aplica en caliente
#   leer                         imprime los bloques [Peer] actuales (nunca la clave privada)
#
# En el servidor secundario se instala en /usr/local/sbin/wg-aplicar-peers
# (13-peers-preparar-secundario.sh). En el principal lo usa gestionar-peers.sh desde el repo.
set -euo pipefail

WG_IF="${WG_IF:-wg0}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
CONF="${WG_DIR}/${WG_IF}.conf"
MARCA_INI="# >>> PEERS-GESTIONADOS (generado por gestionar-peers.sh; no editar a mano)"
MARCA_FIN="# <<< FIN PEERS-GESTIONADOS"

fallo() { echo "[ERROR] $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fallo "Ejecutar como root."

# Parte [Interface]: todo lo anterior al primer peer o marcador
interfaz_de() { awk '/^# *>>>/{exit} /^(# Cliente:|\[Peer\])/{exit} {print}' "$1"; }
# Parte de peers: desde el primer peer hasta el final (sin marcadores)
peers_de()    { awk '/^# *(>>>|<<<)/{next} /^(# Cliente:|\[Peer\])/{f=1} f' "$1"; }

validar_peers() {   # $1 = archivo con el texto recibido
  local f="$1" bad np nk
  # Lista blanca de directivas: impide inyectar PostUp/PreUp, otro [Interface], PrivateKey, etc.
  if bad="$(grep -nvE '^[[:space:]]*($|#|\[Peer\][[:space:]]*$|(PublicKey|AllowedIPs|PersistentKeepalive|Endpoint)[[:space:]]*=)' "$f")"; then
    fallo "Directivas no permitidas en la lista de peers:
$bad"
  fi
  np="$(grep -c '^\[Peer\]' "$f" || true)"
  nk="$(grep -c '^PublicKey' "$f" || true)"
  [[ "$np" == "$nk" ]] || fallo "Cada [Peer] debe tener exactamente un PublicKey ($np bloques, $nk claves)."
}

cmd_aplicar() {
  local vacio=0 tmp respaldo n
  [[ "${1:-}" == "--permitir-vacio" ]] && vacio=1
  [[ -f "$CONF" ]] || fallo "No existe $CONF"
  grep -q '^PrivateKey' "$CONF" || fallo "$CONF no tiene PrivateKey en [Interface]; no se toca."

  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  tr -d '\r' | sed -e '$a\' > "$tmp/peers.txt"
  validar_peers "$tmp/peers.txt"
  n="$(grep -c '^\[Peer\]' "$tmp/peers.txt" || true)"
  [[ "$n" -gt 0 || $vacio -eq 1 ]] || fallo "Lista de peers vacía: se rechaza para no borrar todos los clientes (use --permitir-vacio)."

  umask 077
  { interfaz_de "$CONF" | cat -s; echo; echo "$MARCA_INI"; cat "$tmp/peers.txt"; echo "$MARCA_FIN"; } > "$tmp/$WG_IF.conf"
  grep -q '^PrivateKey' "$tmp/$WG_IF.conf" || fallo "Se perdió la PrivateKey al componer la configuración."
  wg-quick strip "$tmp/$WG_IF.conf" >/dev/null 2>&1 || fallo "La configuración resultante no es válida (wg-quick strip falló). No se aplicó nada."

  respaldo="${CONF}.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$CONF" "$respaldo"
  ls -1t "${CONF}".bak-* 2>/dev/null | tail -n +6 | xargs -r rm -f
  install -m 600 -o root -g root "$tmp/$WG_IF.conf" "$CONF"

  if ip link show "$WG_IF" >/dev/null 2>&1; then
    if ! wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF"); then
      install -m 600 -o root -g root "$respaldo" "$CONF"
      fallo "wg syncconf falló; se restauró la configuración anterior."
    fi
    echo "[OK] ${n} peer(s) aplicados en caliente en ${WG_IF} (sin reiniciar la interfaz)."
  else
    echo "[OK] ${n} peer(s) escritos en $CONF (la interfaz ${WG_IF} no está activa)."
  fi
}

cmd_leer() { [[ -f "$CONF" ]] || fallo "No existe $CONF"; peers_de "$CONF"; }

case "${1:-}" in
  aplicar) shift; cmd_aplicar "$@" ;;
  leer)    cmd_leer ;;
  *) echo "Uso: $0 {aplicar [--permitir-vacio] | leer}" >&2; exit 2 ;;
esac
