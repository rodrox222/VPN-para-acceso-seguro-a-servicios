#!/usr/bin/env bash
# HU-17 / ADM008 - Gestión centralizada de peers entre el servidor principal (S1) y el secundario (S2).
#
# S1 es la FUENTE DE VERDAD de la lista de peers. S2 conserva su propio [Interface] (claves propias,
# HU-14) y recibe por SSH solo los bloques [Peer], que se aplican en caliente (wg syncconf).
#
# Se ejecuta en S1, con sudo:
#   init <IP_S2>                    genera la clave SSH de sincronización y guarda la configuración
#   estado                          comprueba SSH y receptor en S2
#   listar                          tabla de peers y su estado en S1 y S2
#   verificar                       detecta divergencias (exit 1 si las hay)
#   sync                            empuja la lista de S1 a S2 (idempotente)
#   agregar <Nombre> <ClavePub> <IP>   registra un peer en S1 y S2   (ej. 10.0.0.50)
#   revocar <Nombre|ClavePub>       elimina un peer en S1 y S2
#   instalar-timer | quitar-timer   sincronización automática cada 5 min (autocorrige divergencias)
#
# Config opcional en /etc/wireguard/peers-sync.env (la crea 'init'): SECUNDARIO_HOST, SECUNDARIO_USER,
# SSH_KEY, SSH_PORT.
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RECEPTOR_LOCAL="$DIR/wg-aplicar-peers.sh"
RECEPTOR_REMOTO="/usr/local/sbin/wg-aplicar-peers"
WG_IF="${WG_IF:-wg0}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
CONF="${WG_DIR}/${WG_IF}.conf"
ENV_FILE="${PEERS_ENV:-${WG_DIR}/peers-sync.env}"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${SECUNDARIO_USER:=wgsync}" "${SSH_KEY:=/root/.ssh/wg_sync}" "${SSH_PORT:=22}"

info()  { echo "[INFO] $*"; }
ok()    { echo "[OK]   $*"; }
aviso() { echo "[AVISO] $*" >&2; }
fallo() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------- análisis de bloques
peers_local() { awk '/^# *(>>>|<<<)/{next} /^(# Cliente:|\[Peer\])/{f=1} f' "$CONF"; }

# stdin: bloques [Peer]  ->  nombre<TAB>clave<TAB>allowedips (una línea por peer)
tsv() {
  awk '
    function flush() { if (inpeer) printf "%s\t%s\t%s\n", (name==""?"-":name), key, allowed; inpeer=0; key=""; allowed=""; name="" }
    /^# *(>>>|<<<)/ { next }
    /^# Cliente:/ { flush(); v=$0; sub(/^# Cliente:[ \t]*/,"",v); gsub(/[ \t\r]+$/,"",v); pend=v; next }
    /^\[Peer\]/   { flush(); inpeer=1; name=pend; pend=""; next }
    inpeer && /^#/ { if (name=="") { v=$0; sub(/^#[ \t]*/,"",v); gsub(/[ \t\r]+$/,"",v); name=v }; next }
    inpeer && /^PublicKey/  { v=$0; sub(/^PublicKey[ \t]*=[ \t]*/,"",v);  gsub(/[ \t\r]+$/,"",v); key=v }
    inpeer && /^AllowedIPs/ { v=$0; sub(/^AllowedIPs[ \t]*=[ \t]*/,"",v); gsub(/[ \t\r]/,"",v);   allowed=v }
    END { flush() }'
}

# stdin: bloques [Peer]; $1 = clave pública a eliminar  ->  bloques sin ese peer
borrar_bloque() {
  awk -v K="$1" '
    function flush() { if (buf != "" && !drop) printf "%s", buf; buf=""; drop=0; haspeer=0 }
    /^# *(>>>|<<<)/ { next }
    /^# Cliente:/   { flush(); buf=$0 "\n"; next }
    /^\[Peer\]/     { if (haspeer) flush(); buf = buf $0 "\n"; haspeer=1; next }
    { buf = buf $0 "\n"
      if ($0 ~ /^PublicKey/) { v=$0; sub(/^PublicKey[ \t]*=[ \t]*/,"",v); gsub(/[ \t\r]+$/,"",v); if (v==K) drop=1 } }
    END { flush() }'
}

# ---------------------------------------------------------------- acceso a S2
requiere_s2() {
  [[ -n "${SECUNDARIO_HOST:-}" ]] || fallo "Falta SECUNDARIO_HOST. Ejecute primero: sudo $0 init <IP_S2>"
  [[ -f "$SSH_KEY" ]] || fallo "No existe la clave SSH $SSH_KEY. Ejecute: sudo $0 init <IP_S2>"
}
ssh_s2() {
  ssh -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "${SECUNDARIO_USER}@${SECUNDARIO_HOST}" sudo -n "$RECEPTOR_REMOTO" "$@"
}

# ---------------------------------------------------------------- validación y comparación
validar_local() {
  local t d n k a
  t="$(peers_local | tsv)"
  [[ -n "$t" ]] || return 0
  while IFS=$'\t' read -r n k a; do
    [[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fallo "Clave pública con formato inválido en '$n': $k"
    [[ -n "$a" ]] || fallo "El peer '$n' no tiene AllowedIPs"
  done <<< "$t"
  d="$(cut -f2 <<< "$t" | sort | uniq -d)"; [[ -z "$d" ]] || fallo "Claves públicas duplicadas en S1: $d"
  d="$(cut -f3 <<< "$t" | sort | uniq -d)"; [[ -z "$d" ]] || fallo "AllowedIPs duplicadas en S1: $d"
}

# Salida: ESTADO<TAB>nombre<TAB>ip<TAB>clave   (OK | FALTA_EN_S2 | IP_DISTINTA | SOLO_EN_S2)
comparar() {
  local rem
  rem="$(ssh_s2 leer)" || fallo "No se pudo consultar a S2 (${SECUNDARIO_HOST}). Ejecute: sudo $0 estado"
  awk -F'\t' '
    FNR==1 { nf++ }
    nf==1 { rk[$2]=$3; rn[$2]=$1; next }
    { seen[$2]=1
      if (!($2 in rk)) st="FALTA_EN_S2"; else if (rk[$2]!=$3) st="IP_DISTINTA"; else st="OK"
      printf "%s\t%s\t%s\t%s\n", st, $1, $3, $2 }
    END { for (k in rk) if (!(k in seen)) printf "SOLO_EN_S2\t%s\t%s\t%s\n", rn[k], rk[k], k }' \
    <(tsv <<< "$rem"; printf '') <(peers_local | tsv) | sort -t$'\t' -k2,2
}

# ---------------------------------------------------------------- comandos
cmd_init() {
  local host="${1:-}" pub
  [[ -n "$host" ]] || fallo "Uso: sudo $0 init <IP_S2>"
  umask 077
  mkdir -p "$(dirname "$SSH_KEY")"; chmod 700 "$(dirname "$SSH_KEY")"
  if [[ -f "$SSH_KEY" ]]; then info "Ya existe $SSH_KEY; se conserva."
  else ssh-keygen -q -t ed25519 -N "" -C "wg-peers-sync@$(hostname)" -f "$SSH_KEY"; ok "Clave SSH generada en $SSH_KEY"; fi
  cat > "$ENV_FILE" << ENVEOF
SECUNDARIO_HOST=${host}
SECUNDARIO_USER=${SECUNDARIO_USER}
SSH_KEY=${SSH_KEY}
SSH_PORT=${SSH_PORT}
ENVEOF
  ok "Configuración guardada en $ENV_FILE"
  pub="$(cat "${SSH_KEY}.pub")"
  cat << MSG

=========== PASO SIGUIENTE: ejecutar en el SERVIDOR SECUNDARIO (S2) ===========
git pull   # (para tener scripts/13-... y scripts/wg-aplicar-peers.sh)
sudo ./scripts/13-peers-preparar-secundario.sh '${pub}'
===============================================================================
Luego, aquí en S1:  sudo $0 estado   y   sudo $0 sync
MSG
}

cmd_estado() {
  requiere_s2
  [[ -f "$CONF" ]] || fallo "No existe $CONF en este servidor."
  info "Peers en S1: $(peers_local | tsv | wc -l)"
  if out="$(ssh_s2 leer 2>&1)"; then ok "SSH y receptor en S2 (${SECUNDARIO_HOST}) funcionan. Peers en S2: $(tsv <<< "$out" | wc -l)"
  else fallo "No se pudo ejecutar el receptor en S2: ${out}"; fi
}

cmd_listar() {
  requiere_s2
  validar_local
  printf '%-16s %-16s %-14s %s\n' NOMBRE IP ESTADO_S2 CLAVE_PUBLICA
  comparar | awk -F'\t' '{ printf "%-16s %-16s %-14s %s\n", $2, $3, $1, substr($4,1,12) "..." }'
}

cmd_verificar() {
  requiere_s2
  validar_local
  local cmp n_ok n_mal
  cmp="$(comparar)"
  n_ok="$(grep -c '^OK' <<< "$cmp" || true)"
  n_mal="$(grep -vc '^OK' <<< "$cmp" || true)"
  [[ -z "$cmp" ]] && { n_ok=0; n_mal=0; }
  # Coherencia interna de S1: lo configurado en el archivo vs lo cargado en el kernel
  if ip link show "$WG_IF" >/dev/null 2>&1; then
    if ! diff -q <(peers_local | tsv | cut -f2 | sort) <(wg show "$WG_IF" peers | sort) >/dev/null; then
      aviso "S1: los peers cargados en ${WG_IF} no coinciden con ${CONF} (¿cambios con 'wg set' sin persistir?)."
      n_mal=$((n_mal+1))
    fi
  fi
  if [[ "$n_mal" -eq 0 ]]; then ok "Sin divergencias: ${n_ok} peer(s) idénticos en S1 y S2."; return 0; fi
  grep -v '^OK' <<< "$cmp" | awk -F'\t' '{ printf "  %-12s %-16s %-16s %s\n", $1, $2, $3, substr($4,1,12) "..." }' >&2 || true
  fallo "Hay divergencias entre S1 y S2. Corrija con: sudo $0 sync"
}

empujar() {   # $1 = texto de peers destino (opcional); por defecto los de S1
  local texto flag=""
  texto="${1-$(peers_local)}"
  grep -q '^\[Peer\]' <<< "$texto" || flag="--permitir-vacio"
  printf '%s\n' "$texto" | ssh_s2 aplicar $flag
}

cmd_sync() {
  local silencioso=0 cmp pend
  [[ "${1:-}" == "--silencioso" ]] && silencioso=1
  requiere_s2
  validar_local
  cmp="$(comparar)"
  pend="$(grep -v '^OK' <<< "$cmp" || true)"
  if [[ -z "$pend" ]]; then [[ $silencioso -eq 1 ]] || ok "S2 ya está sincronizado con S1."; return 0; fi
  info "Cambios que se aplicarán en S2 (S1 es la fuente de verdad):"
  awk -F'\t' '{ printf "  %-12s %-16s %s\n", $1, $2, $3 }' <<< "$pend"
  empujar
  [[ -z "$(comparar | grep -v '^OK' || true)" ]] || fallo "Tras sincronizar sigue habiendo divergencias; revise: sudo $0 verificar"
  ok "S2 sincronizado."
}

cmd_agregar() {
  local nombre="${1:-}" clave="${2:-}" ip="${3:-}" nuevo
  [[ -n "$nombre" && -n "$clave" && -n "$ip" ]] || fallo "Uso: sudo $0 agregar <Nombre> <ClavePublica> <IP 10.0.0.x>"
  [[ "$nombre" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || fallo "Nombre inválido (letras, números, . _ -; máx. 32)."
  [[ "$clave" =~ ^[A-Za-z0-9+/]{43}=$ ]]    || fallo "Clave pública con formato inválido."
  ip="${ip%/32}"
  [[ "$ip" =~ ^10\.0\.0\.([0-9]{1,3})$ && "${BASH_REMATCH[1]}" -ge 2 && "${BASH_REMATCH[1]}" -le 254 ]] || fallo "IP fuera de 10.0.0.2–10.0.0.254."
  requiere_s2
  validar_local
  peers_local | tsv | cut -f2 | grep -qxF "$clave" && fallo "Esa clave pública ya está registrada."
  peers_local | tsv | cut -f3 | grep -qxF "${ip}/32" && fallo "La IP ${ip} ya está asignada a otro peer."
  nuevo="$(peers_local)"
  nuevo+=$'\n\n'"# Cliente: ${nombre}"$'\n'"[Peer]"$'\n'"PublicKey = ${clave}"$'\n'"AllowedIPs = ${ip}/32"
  printf '%s\n' "$nuevo" | "$RECEPTOR_LOCAL" aplicar
  empujar || aviso "S1 actualizado pero S2 NO. Reintente: sudo $0 sync"
  ok "Peer '${nombre}' (${ip}) registrado."
}

cmd_revocar() {
  local id="${1:-}" clave n nuevo
  [[ -n "$id" ]] || fallo "Uso: sudo $0 revocar <Nombre|ClavePublica>"
  requiere_s2
  n="$(peers_local | tsv | awk -F'\t' -v I="$id" '$1==I || $2==I' | wc -l)"
  [[ "$n" -ge 1 ]] || fallo "No existe ningún peer '${id}' en S1."
  [[ "$n" -eq 1 ]] || fallo "'${id}' coincide con ${n} peers; use la clave pública."
  clave="$(peers_local | tsv | awk -F'\t' -v I="$id" '$1==I || $2==I {print $2}')"
  nuevo="$(peers_local | borrar_bloque "$clave")"
  if grep -q '^\[Peer\]' <<< "$nuevo"; then printf '%s\n' "$nuevo" | "$RECEPTOR_LOCAL" aplicar
  else printf '%s\n' "$nuevo" | "$RECEPTOR_LOCAL" aplicar --permitir-vacio; fi
  ok "Peer revocado en S1."
  if empujar; then ok "Peer revocado también en S2."
  else aviso "S2 NO está actualizado: el peer revocado SIGUE ACTIVO en S2. Reintente: sudo $0 sync"; exit 2; fi
}

cmd_instalar_timer() {
  cat > /etc/systemd/system/wg-peers-sync.service << UNIT
[Unit]
Description=Sincroniza la lista de peers WireGuard hacia el servidor secundario (HU-17)
After=network-online.target wg-quick@${WG_IF}.service

[Service]
Type=oneshot
ExecStart=${DIR}/gestionar-peers.sh sync --silencioso
UNIT
  cat > /etc/systemd/system/wg-peers-sync.timer << UNIT
[Unit]
Description=Sincronización periódica de peers (cada 5 min)

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now wg-peers-sync.timer
  ok "Timer activo. Ver: systemctl list-timers wg-peers-sync.timer ; journalctl -u wg-peers-sync.service"
}
cmd_quitar_timer() {
  systemctl disable --now wg-peers-sync.timer 2>/dev/null || true
  rm -f /etc/systemd/system/wg-peers-sync.{service,timer}; systemctl daemon-reload
  ok "Timer retirado."
}

uso() { sed -n '2,19p' "$0"; }

main() {
  [[ $EUID -eq 0 ]] || fallo "Ejecute con sudo: sudo $0 <comando>"
  [[ -f "$CONF" ]] || fallo "No existe $CONF (¿es este el servidor principal?)."
  exec 9> /run/lock/gestionar-peers.lock
  flock -n 9 || fallo "Otra instancia de gestionar-peers.sh está en ejecución."
  case "${1:-}" in
    init)            shift; cmd_init "$@" ;;
    estado)          cmd_estado ;;
    listar)          cmd_listar ;;
    verificar)       cmd_verificar ;;
    sync)            shift; cmd_sync "$@" ;;
    agregar)         shift; cmd_agregar "$@" ;;
    revocar)         shift; cmd_revocar "$@" ;;
    instalar-timer)  cmd_instalar_timer ;;
    quitar-timer)    cmd_quitar_timer ;;
    *) uso; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
