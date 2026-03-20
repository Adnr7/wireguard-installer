#!/bin/bash
set -e

ERRORS=()
WARNINGS=()
LOG_FILE="/var/log/wg-install.log"

log() { echo "[✔] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[!] $*" | tee -a "$LOG_FILE"; WARNINGS+=("$*"); }
error() { echo "[✘] $*" | tee -a "$LOG_FILE"; ERRORS+=("$*"); }

trap 'error "Failed at line $LINENO"; exit 1' ERR

# ===== ROOT CHECK =====
[[ $EUID -ne 0 ]] && { echo "Run with sudo"; exit 1; }

echo "=== WireGuard Installer ==="
echo "Log: $LOG_FILE"
echo "==================================="

# ===== DETECT IP =====
DETECTED_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

read -p "Server IP [$DETECTED_IP]: " SERVER_IP
SERVER_IP=${SERVER_IP:-$DETECTED_IP}

# ===== INPUTS =====
read -p "Port [51820]: " WG_PORT
WG_PORT=${WG_PORT:-51820}

read -p "VPN subnet [10.8.0.0/24]: " VPN_SUBNET
VPN_SUBNET=${VPN_SUBNET:-10.8.0.0/24}

VPN_BASE=$(echo "$VPN_SUBNET" | cut -d. -f1-3)
SERVER_VPN_IP="$VPN_BASE.1"

read -p "DNS [1.1.1.1, 8.8.8.8]: " CLIENT_DNS
CLIENT_DNS=${CLIENT_DNS:-"1.1.1.1, 8.8.8.8"}

read -p "Number of clients [1]: " NUM_CLIENTS
NUM_CLIENTS=${NUM_CLIENTS:-1}

read -p "Client prefix [client]: " CLIENT_PREFIX
CLIENT_PREFIX=${CLIENT_PREFIX:-client}

DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
read -p "Interface [$DEFAULT_IFACE]: " NET_IFACE
NET_IFACE=${NET_IFACE:-$DEFAULT_IFACE}

read -p "Generate QR codes? [y/N]: " QR
QR=${QR:-n}

echo "==================================="
echo "IP: $SERVER_IP"
echo "Port: $WG_PORT"
echo "Clients: $NUM_CLIENTS"
echo "==================================="

read -p "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-y}" != "y" ]] && exit 0

# ===== UPDATE SYSTEM =====
echo "[→] Updating system..."
apt update -y >> "$LOG_FILE" 2>&1 || warn "apt update failed"
apt upgrade -y >> "$LOG_FILE" 2>&1 || warn "apt upgrade failed"

# ===== INSTALL =====
echo "[→] Installing packages..."
apt install -y wireguard wireguard-tools iptables curl qrencode >> "$LOG_FILE" 2>&1 \
    || error "Package install failed"

# ===== ENABLE FORWARDING =====
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/wg.conf
sysctl -p /etc/sysctl.d/wg.conf >> "$LOG_FILE" 2>&1 || warn "sysctl failed"

# ===== KEYS =====
WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
mkdir -p "$CLIENT_DIR"

SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)

# ===== SERVER CONFIG =====
cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = ${SERVER_VPN_IP}/24
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

    CONF="$CLIENT_DIR/${CLIENT_PREFIX}${i}.conf"

    cat > "$CONF" <<EOF
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

    if [[ "$QR" =~ ^[Yy]$ ]]; then
        qrencode -t PNG -o "$CLIENT_DIR/${CLIENT_PREFIX}${i}.png" < "$CONF"
    fi

    log "Created client ${CLIENT_PREFIX}${i}"
done

# ===== START =====
systemctl enable wg-quick@wg0 >> "$LOG_FILE" 2>&1 || error "Enable failed"
systemctl start wg-quick@wg0 >> "$LOG_FILE" 2>&1 || error "Start failed"

# ===== VERIFY =====
if wg show wg0 >> "$LOG_FILE" 2>&1; then
    log "WireGuard running"
else
    error "WireGuard not running"
fi

# ===== SUMMARY =====
echo "==================================="
echo "INSTALL SUMMARY"
echo "==================================="

[[ ${#WARNINGS[@]} -gt 0 ]] && echo "Warnings:" && printf '%s\n' "${WARNINGS[@]}"
[[ ${#ERRORS[@]} -gt 0 ]] && echo "Errors:" && printf '%s\n' "${ERRORS[@]}"

echo "Client configs: $CLIENT_DIR"
echo "==================================="
