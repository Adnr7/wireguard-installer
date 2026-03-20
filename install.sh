#!/bin/bash
set -e

# ===== UI =====
STEP=1
TOTAL_STEPS=8

step() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[STEP $STEP/$TOTAL_STEPS] $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ((STEP++))
}

# ===== LOGGING =====
ERRORS=()
WARNINGS=()
LOG_FILE="/var/log/wg-install.log"

log() { echo "[✔] $*" | tee -a "$LOG_FILE"; }
warn() { echo "[!] $*" | tee -a "$LOG_FILE"; WARNINGS+=("$*"); }
error() { echo "[✘] $*" | tee -a "$LOG_FILE"; ERRORS+=("$*"); }

trap 'error "Failed at line $LINENO"; exit 1' ERR

# ===== ROOT CHECK =====
[[ $EUID -ne 0 ]] && { echo "Run with sudo"; exit 1; }

echo "⚡ WireGuard Auto Installer"
echo "Log: $LOG_FILE"

# ===== STEP 1: CONFIG =====
step "Collecting Configuration"

DETECTED_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')

read -p "Server IP [$DETECTED_IP]: " SERVER_IP
SERVER_IP=${SERVER_IP:-$DETECTED_IP}

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

echo ""
echo "IP: $SERVER_IP"
echo "Port: $WG_PORT"
echo "Clients: $NUM_CLIENTS"

read -p "Proceed? [Y/n]: " CONFIRM
[[ "${CONFIRM:-y}" != "y" ]] && exit 0

# ===== STEP 2: SYSTEM UPDATE =====
step "Updating System"

export DEBIAN_FRONTEND=noninteractive

echo "[→] Fixing mirror (OCI optimized)..."
sed -i 's|http://.*archive.ubuntu.com|http://in.archive.ubuntu.com|g' /etc/apt/sources.list

echo "[→] Running apt update..."
apt update -y | tee -a "$LOG_FILE" || warn "apt update failed"

echo "[→] Running apt upgrade..."
apt upgrade -y | tee -a "$LOG_FILE" || warn "apt upgrade had issues"

# ===== STEP 3: INSTALL PACKAGES =====
step "Installing Dependencies"

apt install -y wireguard wireguard-tools iptables curl qrencode | tee -a "$LOG_FILE" \
    || error "Package installation failed"

# ===== STEP 4: ENABLE IP FORWARDING =====
step "Enabling IP Forwarding"

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/wg.conf
sysctl -p /etc/sysctl.d/wg.conf | tee -a "$LOG_FILE" || warn "sysctl failed"

# ===== STEP 5: KEY GENERATION =====
step "Generating Keys"

WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
mkdir -p "$CLIENT_DIR"

SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)

# ===== STEP 6: SERVER CONFIG =====
step "Creating Server Config"

cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = ${SERVER_VPN_IP}/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV

PostUp = iptables -t nat -A POSTROUTING -o $NET_IFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $NET_IFACE -j MASQUERADE
EOF

# ===== STEP 7: CLIENT CONFIGS =====
step "Generating Client Configs"

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

    log "Created ${CLIENT_PREFIX}${i}"
done

# ===== STEP 8: START SERVICE =====
step "Starting WireGuard"

systemctl enable wg-quick@wg0 | tee -a "$LOG_FILE" || error "Enable failed"
systemctl start wg-quick@wg0 | tee -a "$LOG_FILE" || error "Start failed"

# ===== VERIFY =====
if wg show wg0 | tee -a "$LOG_FILE"; then
    log "WireGuard is running"
else
    error "WireGuard failed to start"
fi

# ===== SUMMARY =====
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "INSTALLATION SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ ${#WARNINGS[@]} -gt 0 ]] && echo "Warnings:" && printf '%s\n' "${WARNINGS[@]}"
[[ ${#ERRORS[@]} -gt 0 ]] && echo "Errors:" && printf '%s\n' "${ERRORS[@]}"

echo ""
echo "Client configs:"
echo "/etc/wireguard/clients/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
