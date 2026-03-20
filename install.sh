#!/bin/bash
set -e

source ./lib/utils.sh
source ./lib/network.sh

require_root

CONFIG_FILE="./config.env"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

echo "=== WireGuard Auto Installer ==="

# ===== AUTO MODE =====
if [[ "$AUTO_MODE" == "true" ]]; then
    echo "[→] Running in AUTO mode"

    SERVER_IP="${SERVER_IP:-$(detect_ip)}"
    WG_PORT="${WG_PORT:-51820}"
    VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"
    CLIENT_DNS="${CLIENT_DNS:-1.1.1.1,8.8.8.8}"
    NUM_CLIENTS="${NUM_CLIENTS:-1}"
    CLIENT_PREFIX="${CLIENT_PREFIX:-client}"
    NET_IFACE="${NET_IFACE:-$(detect_iface)}"
    QR_CODES="${QR_CODES:-n}"

else
    echo "[→] Interactive mode"

    read -p "Server IP: " SERVER_IP
    read -p "Port: " WG_PORT
fi

echo "[✔] Using IP: $SERVER_IP"
echo "[✔] Interface: $NET_IFACE"

# ===== INSTALL =====
apt update -y
apt install -y wireguard wireguard-tools iptables curl qrencode

# ===== CONFIG =====
WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
mkdir -p "$CLIENT_DIR"

SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)

VPN_BASE=$(echo "$VPN_SUBNET" | cut -d. -f1-3)

cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = ${VPN_BASE}.1/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV

PostUp = iptables -t nat -A POSTROUTING -o $NET_IFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $NET_IFACE -j MASQUERADE
EOF

# ===== CLIENTS =====
for ((i=1;i<=NUM_CLIENTS;i++)); do
    PRIV=$(wg genkey)
    PUB=$(echo "$PRIV" | wg pubkey)
    PSK=$(wg genpsk)

    CLIENT_IP="${VPN_BASE}.$((i+1))"

    cat >> "$WG_DIR/wg0.conf" <<EOF

[Peer]
PublicKey = $PUB
PresharedKey = $PSK
AllowedIPs = $CLIENT_IP/32
EOF

    cat > "$CLIENT_DIR/${CLIENT_PREFIX}${i}.conf" <<EOF
[Interface]
PrivateKey = $PRIV
Address = $CLIENT_IP/24
DNS = $CLIENT_DNS

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $PSK
Endpoint = $SERVER_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

done

# ===== ENABLE =====
sysctl -w net.ipv4.ip_forward=1

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "[✔] WireGuard installed!"
echo "Client files: $CLIENT_DIR"
