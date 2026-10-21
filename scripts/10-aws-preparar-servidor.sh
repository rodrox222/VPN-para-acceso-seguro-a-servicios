#!/usr/bin/env bash
# DEV006 / HU13 - Preparación base del servidor AWS (Ubuntu 22.04 LTS).
# Instala las herramientas que el resto de scripts del repositorio da por supuestas
# (en la .ova ya estaban) y deja listo el entorno para el DHCP proxy de agregar-cliente.sh.
#
# Uso: sudo ./scripts/10-aws-preparar-servidor.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Ejecuta como root: sudo $0" >&2
  exit 1
fi

# Evita las pantallas interactivas de apt / needrestart al trabajar por SSH
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

. /etc/os-release
echo "[INFO] Sistema: ${PRETTY_NAME}  ·  Kernel: $(uname -r)  ·  Arquitectura: $(dpkg --print-architecture)"
if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "22.04" ]]; then
  echo "[AVISO] El proyecto está definido sobre Ubuntu 22.04 LTS (sección 9 del informe); detectado: ${PRETTY_NAME}."
fi

echo "[INFO] Actualizando paquetes..."
apt-get update
apt-get -y upgrade

echo "[INFO] Instalando herramientas base..."
apt-get install -y git curl ca-certificates openssl iproute2 iptables tcpdump iperf3 isc-dhcp-client

# --- dnsmasq para el DHCP proxy de scripts/agregar-cliente.sh (docs/ADM002) -----------------
# Se escribe la configuración ANTES de instalar y se impide que apt arranque el servicio:
# la interfaz br-wg-dhcp todavía no existe (la crea agregar-cliente.sh) y dnsmasq no
# arrancaría; sin esta precaución la instalación puede terminar con un error de dpkg.
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/wireguard-dhcp.conf << 'CONF'
# Escuchar solo en el switch virtual de WireGuard
interface=br-wg-dhcp
bind-interfaces

# Subred paralela para gestionar las concesiones sin colisionar con wg0
dhcp-range=10.255.0.2,10.255.0.253,255.255.255.0,infinite

# SEGURIDAD: No enviar Gateway (3) ni DNS (6) para no alterar las rutas del servidor
dhcp-option=3
dhcp-option=6
port=0
CONF

printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
apt-get install -y dnsmasq
rm -f /usr/sbin/policy-rc.d
echo "[OK] dnsmasq instalado y configurado (arrancará cuando agregar-cliente.sh cree el puente)."

# --- Swap de seguridad si la instancia tiene poca RAM (p. ej. t3.micro con 1 GB) -----------
MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
if [[ "$MEM_MB" -lt 1500 ]] && ! swapon --show | grep -q .; then
  echo "[INFO] RAM = ${MEM_MB} MB y sin swap: creando /swapfile de 2 GB..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "[OK] Swap activo."
else
  echo "[INFO] RAM = ${MEM_MB} MB; swap: $(swapon --show --noheadings | wc -l) dispositivo(s). No se crea swap adicional."
fi

echo
echo "------ Resumen ------"
echo "Interfaces de red (anota el nombre de la interfaz pública, suele ser ens5):"
ip -br link | sed 's/^/   /'
free -h | sed 's/^/   /'
echo "---------------------"
echo "[SIGUIENTE] sudo ./scripts/01-instalar-wireguard.sh  y  sudo ./scripts/02-configurar-servidor.sh"
