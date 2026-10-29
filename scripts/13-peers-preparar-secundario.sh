#!/usr/bin/env bash
# HU-17 / ADM008 - Prepara el SERVIDOR SECUNDARIO para recibir la lista de peers del principal.
#
# Uso (en el secundario, desde la raíz del repo):
#   sudo ./scripts/13-peers-preparar-secundario.sh "ssh-ed25519 AAAA... wg-peers-sync@vpn-servidor"
#   (la clave pública la imprime 'gestionar-peers.sh init <IP_S2>' en el principal)
#
# Crea el usuario 'wgsync' (sin contraseña, solo clave SSH, con 'restrict') que únicamente puede
# ejecutar con sudo /usr/local/sbin/wg-aplicar-peers (root:root, no modificable por wgsync).
set -euo pipefail

USUARIO="wgsync"
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "[ERROR] Ejecuta como root: sudo $0 \"<clave ssh>\"" >&2; exit 1; }
[[ $# -eq 1 ]] || { echo "Uso: sudo $0 \"ssh-ed25519 AAAA... comentario\"" >&2; exit 1; }
CLAVE="$1"
[[ "$CLAVE" =~ ^ssh-ed25519\ AAAA[0-9A-Za-z+/=]+(\ .*)?$ ]] || { echo "[ERROR] Formato de clave pública SSH no válido." >&2; exit 1; }
[[ -f /etc/wireguard/wg0.conf ]] || { echo "[ERROR] No existe /etc/wireguard/wg0.conf: configure primero este servidor (HU-14)." >&2; exit 1; }

install -m 755 -o root -g root "$DIR/wg-aplicar-peers.sh" /usr/local/sbin/wg-aplicar-peers
echo "[OK] Receptor instalado en /usr/local/sbin/wg-aplicar-peers"

if ! id "$USUARIO" >/dev/null 2>&1; then
  useradd --system --create-home --shell /bin/bash "$USUARIO"
  echo "[OK] Usuario $USUARIO creado"
fi
usermod -p '*' "$USUARIO"     # sin contraseña válida; solo entra con clave SSH

HOME_U="$(getent passwd "$USUARIO" | cut -d: -f6)"
install -d -m 700 -o "$USUARIO" -g "$USUARIO" "$HOME_U/.ssh"
echo "restrict ${CLAVE}" > "$HOME_U/.ssh/authorized_keys"
chown "$USUARIO:$USUARIO" "$HOME_U/.ssh/authorized_keys"; chmod 600 "$HOME_U/.ssh/authorized_keys"
echo "[OK] Clave SSH autorizada (restrict: sin reenvío de puertos ni agente)"

SUDOERS="/etc/sudoers.d/wg-aplicar-peers"
echo "${USUARIO} ALL=(root) NOPASSWD: /usr/local/sbin/wg-aplicar-peers" > "${SUDOERS}.tmp"
chmod 440 "${SUDOERS}.tmp"
visudo -cf "${SUDOERS}.tmp" >/dev/null || { rm -f "${SUDOERS}.tmp"; echo "[ERROR] sudoers inválido" >&2; exit 1; }
mv "${SUDOERS}.tmp" "$SUDOERS"
echo "[OK] sudoers: ${USUARIO} solo puede ejecutar wg-aplicar-peers"
echo
echo "[SIGUIENTE] En el servidor principal: sudo ./scripts/gestionar-peers.sh estado"
