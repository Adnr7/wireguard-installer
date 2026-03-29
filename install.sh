#!/bin/bash
# ================================================
# ⚡ WireGuard VPN Installer & Profile Manager
# https://github.com/Adnr7/wireguard-installer
#
# Usage:
#   sudo bash wireguard-install.sh                  # Full install (first time)
#   sudo bash wireguard-install.sh add-client NAME  # Add a new VPN profile
#   sudo bash wireguard-install.sh list-clients      # List all client profiles
#   sudo bash wireguard-install.sh remove-client NAME # Remove a client
#   sudo bash wireguard-install.sh show-client NAME  # Show client config + QR
#   sudo bash wireguard-install.sh uninstall         # Remove WireGuard completely
# ================================================
set -euo pipefail

# ===== COLORS & UI =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
header(){ echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ===== ROOT CHECK =====
[[ $EUID -ne 0 ]] && fail "This script must be run as root (use sudo)"

# ===== CONFIG =====
WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
LOG_FILE="/var/log/wg-install.log"
WG_PORT="${WG_PORT:-51820}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1, 8.8.8.8}"

VPN_BASE=$(echo "$VPN_SUBNET" | cut -d. -f1-3)
SERVER_VPN_IP="${VPN_BASE}.1"

# ===== HELPER FUNCTIONS =====

detect_public_ip() {
    local ip=""
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null) \
        || ip=$(curl -s --max-time 5 https://icanhazip.com 2>/dev/null) \
        || ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}') \
        || ip=""
    echo "$ip"
}

detect_interface() {
    ip route | grep '^default' | awk '{print $5}' | head -n1
}

get_next_client_ip() {
    # Find the highest used IP in the VPN subnet from the server config
    local max_ip=1  # server is .1
    if [[ -f "$WG_CONF" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ AllowedIPs.*${VPN_BASE}\.([0-9]+) ]]; then
                local num="${BASH_REMATCH[1]}"
                if (( num > max_ip )); then max_ip=$num; fi
            fi
        done < "$WG_CONF"
    fi
    echo "${VPN_BASE}.$(( max_ip + 1 ))"
}

get_server_public_key() {
    if [[ -f "$WG_DIR/server_public.key" ]]; then
        cat "$WG_DIR/server_public.key"
    elif [[ -f "$WG_CONF" ]]; then
        # Extract private key from config, derive public key
        local priv
        priv=$(grep -m1 '^PrivateKey' "$WG_CONF" | awk '{print $3}')
        echo "$priv" | wg pubkey
    else
        fail "Cannot find server public key"
    fi
}

get_server_endpoint() {
    if [[ -f "$WG_DIR/server_endpoint.txt" ]]; then
        cat "$WG_DIR/server_endpoint.txt"
    else
        detect_public_ip
    fi
}

# ============================
# COMMAND: FULL INSTALL
# ============================
do_install() {
    header "⚡ WireGuard Auto Installer"

    # Check if already installed
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        warn "WireGuard is already installed and running!"
        echo ""
        echo "  Use 'sudo bash $0 add-client <name>' to add a new VPN profile."
        echo "  Use 'sudo bash $0 list-clients' to see existing profiles."
        echo ""
        exit 0
    fi

    # Detect settings
    SERVER_IP=$(detect_public_ip)
    NET_IFACE=$(detect_interface)

    [[ -z "$SERVER_IP" ]] && fail "Could not detect public IP. Set it with: SERVER_IP=x.x.x.x sudo bash $0"
    [[ -z "$NET_IFACE" ]] && NET_IFACE="eth0"

    echo ""
    echo "  Server IP  : $SERVER_IP"
    echo "  Port       : $WG_PORT"
    echo "  VPN Subnet : $VPN_SUBNET"
    echo "  DNS        : $CLIENT_DNS"
    echo "  Interface  : $NET_IFACE"
    echo ""

    mkdir -p /var/log
    echo "=== WireGuard Install Log — $(date) ===" > "$LOG_FILE"

    # --- Step 1: System update ---
    header "[1/6] Updating System"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >> "$LOG_FILE" 2>&1 || warn "apt update had issues"
    apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1 || warn "apt upgrade had issues"
    info "System updated."

    # --- Step 2: Install packages ---
    header "[2/6] Installing Dependencies"
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    apt-get install -y wireguard wireguard-tools iptables iptables-persistent \
        netfilter-persistent qrencode curl >> "$LOG_FILE" 2>&1 || fail "Package installation failed"
    info "Dependencies installed."

    # --- Step 3: Enable IP forwarding ---
    header "[3/6] Enabling IP Forwarding"
    cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p /etc/sysctl.d/99-wireguard.conf >> "$LOG_FILE" 2>&1 || warn "sysctl apply failed"
    info "IP forwarding enabled."

    # --- Step 4: Generate server keys ---
    header "[4/6] Generating Server Keys"
    mkdir -p "$CLIENT_DIR"
    chmod 700 "$WG_DIR"

    SERVER_PRIV=$(wg genkey)
    SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
    echo "$SERVER_PUB" > "$WG_DIR/server_public.key"
    echo "$SERVER_PRIV" > "$WG_DIR/server_private.key"
    echo "$SERVER_IP" > "$WG_DIR/server_endpoint.txt"
    chmod 600 "$WG_DIR/server_private.key"
    info "Server keys generated."

    # --- Step 5: Create server config ---
    header "[5/6] Creating Server Config"
    cat > "$WG_CONF" <<EOF
[Interface]
Address = ${SERVER_VPN_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

PostUp = iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${NET_IFACE} -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${NET_IFACE} -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
EOF
    chmod 600 "$WG_CONF"
    info "Server config written."

    # --- Step 6: Start WireGuard ---
    header "[6/6] Starting WireGuard"
    systemctl enable wg-quick@wg0 >> "$LOG_FILE" 2>&1 || fail "Enable failed"
    systemctl start wg-quick@wg0 >> "$LOG_FILE" 2>&1 || fail "Start failed"
    sleep 2

    if wg show wg0 &>/dev/null; then
        info "WireGuard is running!"
        echo ""
        wg show wg0
    else
        fail "WireGuard failed to start — check: journalctl -u wg-quick@wg0"
    fi

    netfilter-persistent save >> "$LOG_FILE" 2>&1 || warn "Could not save iptables rules"

    # Create the first client automatically
    echo ""
    do_add_client "client1"

    header "✅ Installation Complete"
    echo ""
    echo "  Client config:  $CLIENT_DIR/client1.conf"
    echo "  QR code:        $CLIENT_DIR/client1.png"
    echo "  Full log:       $LOG_FILE"
    echo ""
    echo "  Add more clients:  sudo bash $0 add-client <name>"
    echo "  List clients:      sudo bash $0 list-clients"
    echo ""
}

# ============================
# COMMAND: ADD CLIENT
# ============================
do_add_client() {
    local CLIENT_NAME="${1:-}"
    [[ -z "$CLIENT_NAME" ]] && fail "Usage: sudo bash $0 add-client <client-name>"

    # Sanitize name
    CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd 'a-zA-Z0-9_-')
    [[ -z "$CLIENT_NAME" ]] && fail "Invalid client name (use alphanumeric, dash, underscore)"

    # Check if WireGuard is installed
    [[ ! -f "$WG_CONF" ]] && fail "WireGuard is not installed. Run: sudo bash $0"

    # Check for duplicate
    if [[ -f "$CLIENT_DIR/${CLIENT_NAME}.conf" ]]; then
        fail "Client '$CLIENT_NAME' already exists. Use a different name or remove it first."
    fi

    header "🔑 Creating Client: $CLIENT_NAME"

    # Get server info
    SERVER_PUB=$(get_server_public_key)
    SERVER_IP=$(get_server_endpoint)
    [[ -z "$SERVER_IP" ]] && fail "Could not determine server endpoint IP"

    # Get next available IP
    CLIENT_IP=$(get_next_client_ip)
    local client_num
    client_num=$(echo "$CLIENT_IP" | cut -d. -f4)
    if (( client_num > 254 )); then fail "No more IPs available in subnet (max 253 clients)"; fi

    # Generate client keys
    CLIENT_PRIV=$(wg genkey)
    CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
    CLIENT_PSK=$(wg genpsk)

    mkdir -p "$CLIENT_DIR"

    # Add peer to server config
    cat >> "$WG_CONF" <<EOF

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${CLIENT_IP}/32
EOF

    # Write client config
    cat > "$CLIENT_DIR/${CLIENT_NAME}.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/24
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    chmod 600 "$CLIENT_DIR/${CLIENT_NAME}.conf"

    # Generate QR code image
    if command -v qrencode &>/dev/null; then
        qrencode -t PNG -o "$CLIENT_DIR/${CLIENT_NAME}.png" < "$CLIENT_DIR/${CLIENT_NAME}.conf"
    fi

    # Add peer to running WireGuard (live, no restart needed)
    if wg show wg0 &>/dev/null; then
        wg set wg0 peer "$CLIENT_PUB" \
            preshared-key <(echo "$CLIENT_PSK") \
            allowed-ips "${CLIENT_IP}/32"
        info "Peer added to running WireGuard (no restart needed)"
    else
        warn "WireGuard not running — peer added to config, will take effect on start"
    fi

    info "Client '$CLIENT_NAME' created — VPN IP: $CLIENT_IP"
    echo ""
    echo "  Config file:  $CLIENT_DIR/${CLIENT_NAME}.conf"
    [[ -f "$CLIENT_DIR/${CLIENT_NAME}.png" ]] && echo "  QR image:     $CLIENT_DIR/${CLIENT_NAME}.png"
    echo ""

    # Show QR code in terminal if possible
    if command -v qrencode &>/dev/null; then
        echo -e "${CYAN}  Scan this QR code with the WireGuard mobile app:${NC}"
        echo ""
        qrencode -t ansiutf8 < "$CLIENT_DIR/${CLIENT_NAME}.conf"
        echo ""
    fi

    # Also display the config for easy copy-paste
    echo -e "${CYAN}  ─── Client Config (copy & paste into WireGuard app) ───${NC}"
    echo ""
    cat "$CLIENT_DIR/${CLIENT_NAME}.conf"
    echo ""
}

# ============================
# COMMAND: LIST CLIENTS
# ============================
do_list_clients() {
    [[ ! -d "$CLIENT_DIR" ]] && fail "No clients directory found. Is WireGuard installed?"

    header "📋 WireGuard Clients"

    local count=0
    for conf in "$CLIENT_DIR"/*.conf; do
        [[ ! -f "$conf" ]] && continue
        local name
        name=$(basename "$conf" .conf)
        local ip
        ip=$(grep -m1 '^Address' "$conf" | awk '{print $3}' | cut -d/ -f1)
        echo "  • $name  →  $ip"
        count=$((count + 1))
    done

    if (( count == 0 )); then
        echo "  No clients found."
    else
        echo ""
        echo "  Total: $count client(s)"
    fi
    echo ""
}

# ============================
# COMMAND: SHOW CLIENT
# ============================
do_show_client() {
    local CLIENT_NAME="${1:-}"
    [[ -z "$CLIENT_NAME" ]] && fail "Usage: sudo bash $0 show-client <client-name>"

    local conf="$CLIENT_DIR/${CLIENT_NAME}.conf"
    [[ ! -f "$conf" ]] && fail "Client '$CLIENT_NAME' not found"

    header "📱 Client: $CLIENT_NAME"

    cat "$conf"
    echo ""

    if command -v qrencode &>/dev/null; then
        echo -e "${CYAN}  QR Code:${NC}"
        echo ""
        qrencode -t ansiutf8 < "$conf"
        echo ""
    fi
}

# ============================
# COMMAND: REMOVE CLIENT
# ============================
do_remove_client() {
    local CLIENT_NAME="${1:-}"
    [[ -z "$CLIENT_NAME" ]] && fail "Usage: sudo bash $0 remove-client <client-name>"

    local conf="$CLIENT_DIR/${CLIENT_NAME}.conf"
    [[ ! -f "$conf" ]] && fail "Client '$CLIENT_NAME' not found"

    header "🗑️  Removing Client: $CLIENT_NAME"

    # Get the client's public key from the server config (find the peer block with the comment)
    # We need to find and remove the [Peer] block that has "# CLIENT_NAME"
    local pub_key=""
    local in_block=false
    local temp_conf
    temp_conf=$(mktemp)

    while IFS= read -r line; do
        if [[ "$line" == "[Peer]" ]]; then
            in_block=true
            local block="$line"
            continue
        fi

        if $in_block; then
            block+=$'\n'"$line"
            # Check if this block belongs to our client
            if [[ "$line" == "# ${CLIENT_NAME}" ]]; then
                # Read the rest of this peer block
                while IFS= read -r line; do
                    [[ -z "$line" || "$line" == "[Peer]" || "$line" == "[Interface]" ]] && break
                    block+=$'\n'"$line"
                    if [[ "$line" =~ ^PublicKey ]]; then
                        pub_key=$(echo "$line" | awk '{print $3}')
                    fi
                done
                # Skip this entire block (don't write to temp)
                if [[ "$line" == "[Peer]" || "$line" == "[Interface]" ]]; then
                    echo "$line" >> "$temp_conf"
                fi
                in_block=false
                continue
            fi

            # Not our client — check if block is complete
            if [[ -z "$line" ]]; then
                echo "$block" >> "$temp_conf"
                echo "" >> "$temp_conf"
                in_block=false
                continue
            fi
            continue
        fi

        echo "$line" >> "$temp_conf"
    done < "$WG_CONF"

    # If still in a block at EOF, write it (it wasn't our target)
    if $in_block && [[ -n "${block:-}" ]]; then
        echo "$block" >> "$temp_conf"
    fi

    # Remove trailing blank lines
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$temp_conf"

    mv "$temp_conf" "$WG_CONF"
    chmod 600 "$WG_CONF"

    # Remove peer from running WireGuard
    if [[ -n "$pub_key" ]] && wg show wg0 &>/dev/null; then
        wg set wg0 peer "$pub_key" remove
        info "Peer removed from running WireGuard"
    fi

    # Remove config and QR files
    rm -f "$CLIENT_DIR/${CLIENT_NAME}.conf"
    rm -f "$CLIENT_DIR/${CLIENT_NAME}.png"

    info "Client '$CLIENT_NAME' removed."
    echo ""
}

# ============================
# COMMAND: UNINSTALL
# ============================
do_uninstall() {
    header "🗑️  Uninstalling WireGuard"

    echo -e "${YELLOW}This will remove WireGuard and all configs including client profiles.${NC}"
    read -rp "Are you sure? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { echo "Aborted."; exit 0; }

    systemctl stop wg-quick@wg0 2>/dev/null || true
    systemctl disable wg-quick@wg0 2>/dev/null || true
    apt-get remove --purge -y wireguard wireguard-tools 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /etc/wireguard
    rm -f /etc/sysctl.d/99-wireguard.conf
    sysctl -p 2>/dev/null || true

    info "WireGuard has been completely removed."
    echo ""
}

# ============================
# MAIN — COMMAND ROUTER
# ============================
COMMAND="${1:-}"

case "$COMMAND" in
    add-client)
        do_add_client "${2:-}"
        ;;
    list-clients)
        do_list_clients
        ;;
    show-client)
        do_show_client "${2:-}"
        ;;
    remove-client)
        do_remove_client "${2:-}"
        ;;
    uninstall)
        do_uninstall
        ;;
    ""|install)
        do_install
        ;;
    *)
        echo ""
        echo "⚡ WireGuard VPN Installer & Manager"
        echo ""
        echo "Usage:"
        echo "  sudo bash $0                      # Full install (first time)"
        echo "  sudo bash $0 add-client <name>     # Instant VPN profile creation"
        echo "  sudo bash $0 list-clients           # List all client profiles"
        echo "  sudo bash $0 show-client <name>     # Show config + QR code"
        echo "  sudo bash $0 remove-client <name>   # Remove a client"
        echo "  sudo bash $0 uninstall              # Remove WireGuard completely"
        echo ""
        exit 1
        ;;
esac
