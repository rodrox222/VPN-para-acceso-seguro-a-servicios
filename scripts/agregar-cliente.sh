#!/bin/bash
# HU03 - Script con asignación automática de IP e incorporación en vivo

if [ -z "$1" ]; then
    echo "Uso: $0 <NombreCliente> [IP_Opcional]"
    echo "Ejemplo (Auto IP): $0 Kevin"
    echo "Ejemplo (Fijar IP): $0 Kevin 10.0.0.5"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Debe ejecutar este script con sudo."
  exit 1
fi

CLIENT_NAME=$1
SERVER_CONF="/etc/wireguard/wg0.conf"
SERVER_PUB_KEY_FILE="/etc/wireguard/server_public.key"


# Validar que el nombre de cliente no esté repetido
if [ -f "${CLIENT_NAME}.conf" ] || grep -q "# Cliente: $CLIENT_NAME" "$SERVER_CONF"; then
    echo "[ERROR] Ya existe un cliente registrado con el nombre '$CLIENT_NAME'."
    echo "Elige un nombre diferente o elimina el cliente anterior antes de continuar."
    exit 1
fi


# 1. Asignar IP automáticamente si no se especifica como parámetro
if [ -n "$2" ]; then
    CLIENT_IP=$2
else
    # Buscar octetos ocupados en wg0.conf y agregar el 1 del servidor
    USED_OCTETS=$(grep -oE '10\.0\.0\.[0-9]+' "$SERVER_CONF" 2>/dev/null | cut -d'.' -f4)
    USED_OCTETS="1 $USED_OCTETS"

    NEXT_OCTET=""
    for i in {2..254}; do
        if ! echo "$USED_OCTETS" | grep -qw "$i"; then
            NEXT_OCTET=$i
            break
        fi
    done

    if [ -z "$NEXT_OCTET" ]; then
        echo "[ERROR] No hay direcciones IP disponibles en la subred 10.0.0.0/24"
        exit 1
    fi
    CLIENT_IP="10.0.0.$NEXT_OCTET"
fi


# Validar que la IP elegida no esté duplicada
if grep -q "$CLIENT_IP/32" "$SERVER_CONF"; then
    echo "[ERROR] La IP $CLIENT_IP ya se encuentra registrada en $SERVER_CONF"
    exit 1
fi

# 2. Leer la clave pública del servidor
if [ -f "$SERVER_PUB_KEY_FILE" ]; then
    SERVER_PUB_KEY=$(cat "$SERVER_PUB_KEY_FILE")
else
    SERVER_PUB_KEY=$(wg show wg0 public-key)
fi

SERVER_ENDPOINT="192.168.23.137:51820"

echo "[INFO] Nombre de cliente: $CLIENT_NAME"
echo "[INFO] IP asignada automáticamente: $CLIENT_IP"



# 3. Generar claves del cliente
wg genkey | tee "${CLIENT_NAME}_private.key" | wg pubkey > "${CLIENT_NAME}_public.key"
CLIENT_PRIV_KEY=$(cat "${CLIENT_NAME}_private.key")
CLIENT_PUB_KEY=$(cat "${CLIENT_NAME}_public.key")

# 4. Crear archivo .conf del cliente
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

# 5. Agregar automáticamente la sección Peer a wg0.conf
cat <<EOF >> "$SERVER_CONF"

# Cliente: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# 6. Sincronizar en vivo la interfaz wg0 sin interrumpir conexiones existentes
wg syncconf wg0 <(wg-quick strip wg0)

echo "================================================================="
echo "[ÉXITO] Cliente '$CLIENT_NAME' agregado con la IP $CLIENT_IP"
echo " - Archivo generado: $CONF_FILE"
echo " - Servidor actualizado y sincronizado correctamente."
echo "================================================================="
