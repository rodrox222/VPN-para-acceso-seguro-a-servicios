#!/usr/bin/env bash
# DEV002 / HU07 - Paso 1: instalar Docker Engine + Compose en Ubuntu 22.04
# Método oficial: repositorio apt de Docker (https://docs.docker.com/engine/install/ubuntu/).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ejecuta como root: sudo $0" >&2
  exit 1
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "[INFO] Docker y Compose ya están instalados:"
  docker --version; docker compose version
  exit 0
fi

. /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
  echo "[ERROR] Este script es solo para Ubuntu (detectado: ${ID})." >&2
  exit 1
fi
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
echo "[INFO] Ubuntu ${VERSION_ID} (${CODENAME})"

# Paquetes no oficiales que chocan con Docker Engine
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "[INFO] Desinstalando paquete en conflicto: $pkg"
    apt-get remove -y "$pkg"
  fi
done

apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources << SRC
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
SRC

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Permitir usar docker sin sudo (requiere cerrar sesión y volver a entrar)
if [[ -n "${SUDO_USER:-}" ]] && ! id -nG "$SUDO_USER" | grep -qw docker; then
  usermod -aG docker "$SUDO_USER"
  echo "[INFO] Usuario ${SUDO_USER} añadido al grupo 'docker' (cierra sesión y vuelve a entrar)."
fi

echo "[OK] $(docker --version)"
echo "[OK] $(docker compose version)"
echo
echo "[AVISO] Docker activa el reenvío de paquetes (IP forwarding) y puede cambiar la política"
echo "        de la cadena FORWARD de iptables. Revísalo con:"
echo "          sysctl net.ipv4.ip_forward ; sudo iptables -S FORWARD | head -3"
echo "[SIGUIENTE] sudo ./scripts/07-orden-arranque-docker-wg.sh"
