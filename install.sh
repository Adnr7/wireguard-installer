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

log()   { echo "[✔] $*" | tee -a "$LOG_FILE"; }
warn()  { echo "[!] $*" | tee -a "$LOG_FILE"; WARNINGS+=("$*"); }
error() { echo "[✘] $*" | tee -a "$LOG_FILE"; ERRORS+=("$*"); }

trap 'error "Failed at line $LINENO: $BASH_COMMAND"; show_summary; exit 1' ERR

show_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "INSTALLATION SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ ${#WARNINGS[@]} -gt 0 ]] && echo "Warnings:" && printf '  [!] %s\n' "${WARNINGS[@]}"
    [[ ${#ERRORS[@]} -gt 0 ]]   && echo "Errors:"   && printf '  [✘] %s\n' "${ERRORS[@]}"
    [[ ${#ERRORS[@]} -eq 0 ]]   && echo "[✔] All steps completed successfully!"
    echo ""
    echo "Client configs: /etc/wireguard/clients/"
    echo "Full log:       $LOG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ===== ROOT CHECK =====
[[ $EUID -ne 0 ]] && { echo "Run with sudo"; exit 1; }

echo ""
echo "  ⚡ WireGuard Auto Installer"
echo "  Log: $LOG_FILE"
echo ""

mkdir -p /var/log
echo "=== WireGuard Install Log — $(date) ===" > "$LOG_FILE"

# ===== STEP 1: CONFIG =====
step "Collecting Configuration"

DETECTED_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null \
    || echo "")

read -rp "Server IP [${DETECTED_IP:-not detected}]: " SERVER_IP < /dev/tty
SERVER_IP=${SERVER_IP:-$DETECTED_IP}

[[ -z "$SERVER_IP" ]] && { error "Could not determine server IP."; show_summary; exit 1; }

read -rp "Port [51820]: " WG_PORT < /dev/tty
WG_PORT=${WG_PORT:-51820}

read -rp "VPN subnet [10.8.0.0/24]: " VPN_SUBNET < /dev/tty
VPN_SUBNET=${VPN_SUBNET:-10.8.0.0/24}

VPN_BASE=$(echo "$VPN_SUBNET" | cut -d. -f1-3)
SERVER_VPN_IP="$VPN_BASE.1"

read -rp "DNS [1.1.1.1, 8.8.8.8]: " CLIENT_DNS < /dev/tty
CLIENT_DNS=${CLIENT_DNS:-"1.1.1.1, 8.8.8.8"}

while true; do
    read -rp "Number of clients [1]: " NUM_CLIENTS < /dev/tty
    NUM_CLIENTS=${NUM_CLIENTS:-1}
    [[ "$NUM_CLIENTS" =~ ^[1-9][0-9]*$ ]] && [[ "$NUM_CLIENTS" -le 253 ]] && break
    echo "Enter a number between 1 and 253."
done

read -rp "Client prefix [client]: " CLIENT_PREFIX < /dev/tty
CLIENT_PREFIX=${CLIENT_PREFIX:-client}

DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
read -rp "Interface [${DEFAULT_IFACE:-eth0}]: " NET_IFACE < /dev/tty
NET_IFACE=${NET_IFACE:-${DEFAULT_IFACE:-eth0}}

read -rp "Generate QR codes? [y/N]: " QR < /dev/tty
QR=${QR:-n}

echo ""
echo "  Server IP  : $SERVER_IP"
echo "  Port       : $WG_PORT"
echo "  VPN Subnet : $VPN_SUBNET"
echo "  DNS        : $CLIENT_DNS"
echo "  Clients    : $NUM_CLIENTS (prefix: $CLIENT_PREFIX)"
echo "  Interface  : $NET_IFACE"
echo "  QR Codes   : $QR"
echo ""

read -rp "Proceed? [Y/n]: " CONFIRM < /dev/tty
CONFIRM=${CONFIRM:-y}
[[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }

# ===== STEP 2: SYSTEM UPDATE =====
step "Updating System"

export DEBIAN_FRONTEND=noninteractive

echo "[→] Running apt update..."
apt-get update -y >> "$LOG_FILE" 2>&1 || warn "apt update had issues"

echo "[→] Running apt upgrade..."
apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1 || warn "apt upgrade had issues"

log "System updated."

# ===== STEP 3: INSTALL PACKAGES =====
step "Installing Dependencies"

PKGS=(wireguard wireguard-tools iptables iptables-persistent netfilter-persistent curl)
[[ "${QR,,}" =~ ^y ]] && PKGS+=(qrencode)

# Pre-answer iptables-persistent prompt
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

apt-get install -y "${PKGS[@]}" >> "$LOG_FILE" 2>&1 || error "Package installation failed"
log "Dependencies installed."

# ===== STEP 4: ENABLE IP FORWARDING =====
step "Enabling IP Forwarding"

cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

sysctl -p /etc/sysctl.d/99-wireguard.conf >> "$LOG_FILE" 2>&1 || warn "sysctl apply failed"
log "IP forwarding enabled."

# ===== STEP 5: KEY GENERATION =====
step "Generating Keys"

WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
mkdir -p "$CLIENT_DIR"
chmod 700 "$WG_DIR"

SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
log "Server keys generated."

# ===== STEP 6: SERVER CONFIG =====
step "Creating Server Config"

# PostUp/PostDown:
#   1. NAT/masquerade for outbound traffic
#   2. FORWARD rules so traffic can flow through wg0
#   3. INPUT rule so OCI's default REJECT rule doesn't block WireGuard UDP
POST_UP="iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT; \
iptables -t nat -A POSTROUTING -o ${NET_IFACE} -j MASQUERADE; \
iptables -A FORWARD -i wg0 -j ACCEPT; \
iptables -A FORWARD -o wg0 -j ACCEPT"

POST_DOWN="iptables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT; \
iptables -t nat -D POSTROUTING -o ${NET_IFACE} -j MASQUERADE; \
iptables -D FORWARD -i wg0 -j ACCEPT; \
iptables -D FORWARD -o wg0 -j ACCEPT"

cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = ${SERVER_VPN_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

PostUp   = ${POST_UP}
PostDown = ${POST_DOWN}
EOF

chmod 600 "$WG_DIR/wg0.conf"
log "Server config written."

# ===== STEP 7: CLIENT CONFIGS =====
step "Generating Client Configs"

for ((i=1; i<=NUM_CLIENTS; i++)); do
    PRIV=$(wg genkey)
    PUB=$(echo "$PRIV" | wg pubkey)
    PSK=$(wg genpsk)
    CLIENT_IP="${VPN_BASE}.$((i+1))"
    CONF="$CLIENT_DIR/${CLIENT_PREFIX}${i}.conf"

    # Add peer to server config
    cat >> "$WG_DIR/wg0.conf" <<EOF

[Peer]
# ${CLIENT_PREFIX}${i}
PublicKey = ${PUB}
PresharedKey = ${PSK}
AllowedIPs = ${CLIENT_IP}/32
EOF

    # Write client config
    cat > "$CONF" <<EOF
[Interface]
PrivateKey = ${PRIV}
Address = ${CLIENT_IP}/24
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    chmod 600 "$CONF"

    [[ "${QR,,}" =~ ^y ]] && command -v qrencode &>/dev/null && \
        qrencode -t PNG -o "$CLIENT_DIR/${CLIENT_PREFIX}${i}.png" < "$CONF"

    log "Created ${CLIENT_PREFIX}${i} — VPN IP: ${CLIENT_IP}"
done

# ===== STEP 8: START SERVICE =====
step "Starting WireGuard"

systemctl enable wg-quick@wg0 >> "$LOG_FILE" 2>&1 || error "Enable failed"
systemctl start wg-quick@wg0  >> "$LOG_FILE" 2>&1 || error "Start failed"

sleep 2

if sudo wg show wg0 >> "$LOG_FILE" 2>&1; then
    log "WireGuard is running"
    echo ""
    sudo wg show wg0
else
    error "WireGuard failed to start — check: journalctl -u wg-quick@wg0"
fi

# Save iptables rules persistently
netfilter-persistent save >> "$LOG_FILE" 2>&1 || warn "Could not save iptables rules persistently"

show_summary
