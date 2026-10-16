# Guía de Implementación: Proxy DHCP para WireGuard (HU03)

Dado que WireGuard opera estrictamente en Capa 3 y no soporta *broadcasts* MAC para negociaciones DHCP, esta implementación utiliza un modelo de **Proxy DHCP aislado**. Se crea un switch virtual local (`br-wg-dhcp`) en una subred paralela (`10.255.0.0/24`) y se utilizan *Namespaces* de red para engañar al kernel, obtener la concesión DHCP real y mapearla a la red de WireGuard (`10.0.0.0/24`).

## 1. Prerrequisitos e Instalación del Motor DHCP

El servidor requiere tener instalado `dnsmasq` para actuar como el motor DHCP aislado de WireGuard.

```bash
sudo apt update
sudo apt install -y dnsmasq
```

## 2. Configuración de dnsmasq

Debemos aislar `dnsmasq` para que únicamente escuche en nuestro switch virtual y no interfiera con la salida a internet del servidor.

Ejecuta el siguiente bloque para crear el archivo de configuración exclusivo:

```bash
sudo tee /etc/dnsmasq.d/wireguard-dhcp.conf > /dev/null << 'EOF'
# Escuchar solo en el switch virtual de WireGuard
interface=br-wg-dhcp
bind-interfaces

# Subred paralela para gestionar las concesiones sin colisionar con wg0
dhcp-range=10.255.0.2,10.255.0.253,255.255.255.0,infinite

# SEGURIDAD: No enviar Gateway (3) ni DNS (6) para no alterar las rutas del servidor
dhcp-option=3
dhcp-option=6
port=0
EOF
```

Aplica los cambios reiniciando el servicio (es normal si da error la primera vez si el switch aún no existe, el script lo levantará):

```bash
sudo systemctl restart dnsmasq
```

## 3. Código del Script Automatizado

Reemplaza el contenido completo de `scripts/agregar-cliente.sh` con la siguiente versión definitiva. Este script se encarga de todo el ciclo de vida: crea la infraestructura virtual si no existe, ejecuta la negociación DORA en un entorno aislado, genera las claves y sincroniza WireGuard en caliente.

```bash
#!/bin/bash
# HU03 - Script Proxy DHCP con Switch Virtual y Mapeo de Subred para WireGuard

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
# LÓGICA PROXY DHCP (Namespace + Veth)
# =================================================================

# 1. Asegurar que el Switch Virtual existe, sin demoras de aprendizaje (STP)
if ! ip link show br-wg-dhcp >/dev/null 2>&1; then
    echo "[INFO] Inicializando switch virtual aislado (br-wg-dhcp)..."
    ip link add name br-wg-dhcp type bridge
    ip link set dev br-wg-dhcp type bridge forward_delay 0 stp_state 0
    ip addr add 10.255.0.254/24 dev br-wg-dhcp
    ip link set br-wg-dhcp up
    systemctl restart dnsmasq
    sleep 1
fi

# Generar MAC determinista basada en el nombre
MAC_ADDR="02:$(echo -n "$CLIENT_NAME" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/\1:\2:\3:\4:\5/')"
VETH_S="vds_${CLIENT_NAME::5}"
VETH_C="vdc_${CLIENT_NAME::5}"
NETNS="ns_${CLIENT_NAME::5}"

echo "[INFO] Solicitando concesión DHCP real aislada (MAC: $MAC_ADDR)..."

# 2. Aislamiento con Namespace
ip netns add "$NETNS"
ip -n "$NETNS" link set lo up

# 3. Conexión del cable virtual (veth)
ip link add "$VETH_S" type veth peer name "$VETH_C"
ip link set "$VETH_C" netns "$NETNS"
ip link set "$VETH_S" master br-wg-dhcp
ip link set "$VETH_S" up

ip -n "$NETNS" link set "$VETH_C" address "$MAC_ADDR"
ip -n "$NETNS" link set "$VETH_C" up

sleep 1

# 4. Negociación DORA evadiendo bloqueos de AppArmor mediante /tmp
ip netns exec "$NETNS" dhclient -1 -v -lf "/tmp/dhclient-${VETH_C}.leases" -pf "/tmp/dhclient-${VETH_C}.pid" "$VETH_C" 2>/dev/null

PROXY_IP=$(ip -n "$NETNS" -4 addr show dev "$VETH_C" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# 5. Limpieza de entorno virtual
ip link delete "$VETH_S" 2>/dev/null
ip netns delete "$NETNS" 2>/dev/null
rm -f "/tmp/dhclient-${VETH_C}.leases" "/tmp/dhclient-${VETH_C}.pid"

if [ -z "$PROXY_IP" ]; then
    echo "[ERROR] El servidor DHCP local no otorgó una dirección IP."
    exit 1
fi

# 6. Mapeo transparente a la red de WireGuard
OCTET=$(echo "$PROXY_IP" | cut -d'.' -f4)
CLIENT_IP="10.0.0.$OCTET"

if grep -q "$CLIENT_IP/32" "$SERVER_CONF"; then
    echo "[ERROR] DHCP asignó .${OCTET}, pero la IP $CLIENT_IP ya existe en wg0.conf"
    exit 1
fi

# =================================================================
# FIN PROXY DHCP -> INICIO WIREGUARD
# =================================================================

if [ -f "$SERVER_PUB_KEY_FILE" ]; then
    SERVER_PUB_KEY=$(cat "$SERVER_PUB_KEY_FILE")
else
    SERVER_PUB_KEY=$(wg show wg0 public-key)
fi

# Contrato estipulado en ADM001
SERVER_ENDPOINT="192.168.23.137:51820"

echo "[INFO] Concesión DHCP exitosa. Mapeo Proxy finalizado."
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

# Sincronización en caliente (hot reload)
wg syncconf wg0 <(wg-quick strip wg0)

echo "================================================================="
echo "[ÉXITO] Cliente '$CLIENT_NAME' agregado vía DHCP Dinámico"
echo " - Archivo generado: $CONF_FILE"
echo "================================================================="
```

## 4. Ejecución

Basta con otorgar permisos de ejecución al script y correrlo pasando el nombre del usuario final:

```bash
chmod +x scripts/agregar-cliente.sh
sudo ./scripts/agregar-cliente.sh NuevoUsuario
```