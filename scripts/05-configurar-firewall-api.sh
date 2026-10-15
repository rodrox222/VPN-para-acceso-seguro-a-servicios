#!/usr/bin/env bash
set -euo pipefail

API_PORT=5000
WG_IF="wg0"
WG_NET="10.0.0.0/24"
WG_PORT=51820

echo "=== [HU-06 / ADM004] Configuracion de Firewall (iptables) para aislar API REST ==="

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Ejecute este script con sudo."
    exit 1
fi

# 1. Habilitar IP Forwarding
echo "[INFO] Habilitando IP forwarding en el kernel..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
cat << 'SYSCTL' > /etc/sysctl.d/99-wireguard-forwarding.conf
net.ipv4.ip_forward=1
SYSCTL

# 2. Limpiar reglas previas del puerto 5000 (idempotencia)
iptables -D INPUT -i "${WG_IF}" -s "${WG_NET}" -p tcp --dport "${API_PORT}" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i lo -p tcp --dport "${API_PORT}" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport "${API_PORT}" -j DROP 2>/dev/null || true

iptables -D FORWARD -i "${WG_IF}" -s "${WG_NET}" -p tcp --dport "${API_PORT}" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD ! -i "${WG_IF}" -p tcp --dport "${API_PORT}" -j DROP 2>/dev/null || true

# 3. Asegurar puerto UDP 51820 de WireGuard abierto en INPUT
if ! iptables -C INPUT -p udp --dport "${WG_PORT}" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p udp --dport "${WG_PORT}" -j ACCEPT
fi

# 4. Reglas en cadena INPUT
iptables -I INPUT 1 -p tcp --dport "${API_PORT}" -j DROP
iptables -I INPUT 1 -i lo -p tcp --dport "${API_PORT}" -j ACCEPT
iptables -I INPUT 1 -i "${WG_IF}" -s "${WG_NET}" -p tcp --dport "${API_PORT}" -j ACCEPT

# 5. Reglas en cadena FORWARD
iptables -I FORWARD 1 ! -i "${WG_IF}" -p tcp --dport "${API_PORT}" -j DROP
iptables -I FORWARD 1 -i "${WG_IF}" -s "${WG_NET}" -p tcp --dport "${API_PORT}" -j ACCEPT

# 6. Guardar reglas y crear servicio systemd
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

cat << 'SERVICE' > /etc/systemd/system/telematica-firewall.service
[Unit]
Description=Reglas iptables de aislamiento para API REST sobre WireGuard (ADM004)
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable telematica-firewall.service > /dev/null 2>&1

echo "[OK] Reglas iptables aplicadas y persistidas en telematica-firewall.service"
echo ""
echo "=== Estado actual de reglas iptables (INPUT y FORWARD) ==="
iptables -L INPUT -v -n --line-numbers
echo ""
iptables -L FORWARD -v -n --line-numbers
