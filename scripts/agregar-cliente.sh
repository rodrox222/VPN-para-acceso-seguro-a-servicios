#!/bin/bash
# HU03 - Script Proxy DHCP con Switch Virtual y Mapeo de Subred

if [ -z "$1" ]; then
    echo "Uso: $0 <NombreCliente>"
    echo "Ejemplo: $0 Kevin"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Debe ejecutar este script con sudo."
  exit 1
fi

CLIENT_NAME=$1
SERVER_CONF="/etc/wireguard/wg0.conf"
SERVER_PUB_KEY_FILE="/etc/wireguard/server_public.key"

if [ -f "${CLIENT_NAME}.conf" ] || grep -q "# Cliente: $CLIENT_NAME$" "$SERVER_CONF"; then
    echo "[ERROR] Cliente '$CLIENT_NAME' ya registrado."
    exit 1
fi

# =================================================================
# 2. PROXY DHCP: Switch (Cero Demora) + Namespace + AppArmor Fix
# =================================================================

# A. Asegurar que el Switch Virtual existe, SIN demoras de aprendizaje (forward_delay 0)
if ! ip link show br-wg-dhcp >/dev/null 2>&1; then
    echo "[INFO] Creando switch virtual aislado de respuesta rápida..."
    ip link add name br-wg-dhcp type bridge
    ip link set dev br-wg-dhcp type bridge forward_delay 0 stp_state 0
    ip addr add 10.255.0.254/24 dev br-wg-dhcp
    ip link set br-wg-dhcp up
    systemctl restart dnsmasq
    sleep 1
fi

MAC_ADDR="02:$(echo -n "$CLIENT_NAME" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/\1:\2:\3:\4:\5/')"
VETH_S="vds_${CLIENT_NAME::5}"
VETH_C="vdc_${CLIENT_NAME::5}"
NETNS="ns_${CLIENT_NAME::5}"

echo "[INFO] Configurando namespace y solicitando IP DHCP (MAC: $MAC_ADDR)..."

# B. Crear namespace y encender su loopback (vital para dhclient)
ip netns add "$NETNS"
ip -n "$NETNS" link set lo up

# C. Crear el cable virtual y aislar el extremo del cliente
ip link add "$VETH_S" type veth peer name "$VETH_C"
ip link set "$VETH_C" netns "$NETNS"

# D. Conectar al switch virtual (ahora pasará tráfico inmediatamente)
ip link set "$VETH_S" master br-wg-dhcp
ip link set "$VETH_S" up

# E. Configurar extremo Cliente
ip -n "$NETNS" link set "$VETH_C" address "$MAC_ADDR"
ip -n "$NETNS" link set "$VETH_C" up

sleep 1 # Micro-pausa para asentar las interfaces

# F. Ejecutar DORA usando archivos temporales para evitar bloqueos de AppArmor
ip netns exec "$NETNS" dhclient -1 -v -lf "/tmp/dhclient-${VETH_C}.leases" -pf "/tmp/dhclient-${VETH_C}.pid" "$VETH_C" 2>/dev/null

# G. Extraer la IP otorgada
PROXY_IP=$(ip -n "$NETNS" -4 addr show dev "$VETH_C" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# H. Limpiar recursos de red y archivos temporales
ip link delete "$VETH_S" 2>/dev/null
ip netns delete "$NETNS" 2>/dev/null
rm -f "/tmp/dhclient-${VETH_C}.leases" "/tmp/dhclient-${VETH_C}.pid"

if [ -z "$PROXY_IP" ]; then
    echo "[ERROR] El servidor DHCP no respondió (Posible bloqueo de Firewall residual)."
    exit 1
fi

# I. Mapear la IP proxy (10.255.0.X) a la subred de WireGuard (10.0.0.X)
OCTET=$(echo "$PROXY_IP" | cut -d'.' -f4)
CLIENT_IP="10.0.0.$OCTET"

if grep -q "$CLIENT_IP/32" "$SERVER_CONF"; then
    echo "[ERROR] DHCP asignó .${OCTET}, pero $CLIENT_IP ya existe en wg0.conf"
    exit 1
fi
# =================================================================
# Fin de sección Proxy DHCP
# =================================================================

#

if [ -f "$SERVER_PUB_KEY_FILE" ]; then
    SERVER_PUB_KEY=$(cat "$SERVER_PUB_KEY_FILE")
else
    SERVER_PUB_KEY=$(wg show wg0 public-key)
fi

SERVER_ENDPOINT="192.168.23.137:51820"

echo "[INFO] Concesión DHCP exitosa."
echo "[INFO] Cliente: $CLIENT_NAME | IP asignada: $CLIENT_IP"

wg genkey | tee "${CLIENT_NAME}_private.key" | wg pubkey > "${CLIENT_NAME}_public.key"
CLIENT_PRIV_KEY=$(cat "${CLIENT_NAME}_private.key")
CLIENT_PUB_KEY=$(cat "${CLIENT_NAME}_public.key")

CONF_FILE="${CLIENT_NAME}.conf"
cat <<EOF > "$CONF_FILE"
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = $CLIENT_IP/32

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 "$CONF_FILE" "${CLIENT_NAME}_private.key"

cat <<EOF >> "$SERVER_CONF"

# Cliente: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = $CLIENT_IP/32
EOF

wg syncconf wg0 <(wg-quick strip wg0)

echo "================================================================="
echo "[ÉXITO] Cliente '$CLIENT_NAME' agregado (Protocolo DHCP + WireGuard)"
echo " - Archivo generado: $CONF_FILE"
echo "================================================================="
