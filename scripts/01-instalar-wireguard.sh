#!/usr/bin/env bash
# HU ADM001 - Paso 1: instalar WireGuard y verificar soporte en el kernel.
# Objetivo: Ubuntu 22.04 LTS (ver sección 9 del informe).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ejecuta este script como root: sudo $0" >&2
  exit 1
fi

echo "[INFO] Sistema:  $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "[INFO] Kernel:   $(uname -r)"

apt-get update
apt-get install -y wireguard tcpdump

# WireGuard está integrado en el kernel Linux desde la versión 5.6
if modprobe wireguard 2>/dev/null; then
  echo "[OK] Módulo de kernel 'wireguard' disponible."
else
  echo "[ERROR] No se pudo cargar el módulo 'wireguard' en este kernel." >&2
  exit 1
fi

command -v wg >/dev/null && echo "[OK] Herramientas instaladas: $(wg --version)"
echo "[SIGUIENTE] Ejecuta: sudo ./scripts/02-configurar-servidor.sh"
