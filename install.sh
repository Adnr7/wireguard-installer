#!/bin/bash
# =============================================================================
#  WireGuard Auto-Installer
#  Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12
#  Run as root or with sudo
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Error collector ───────────────────────────────────────────────────────────
ERRORS=()
WARNINGS=()
LOG_FILE="/var/log/wireguard-install.log"

log()     { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; WARNINGS+=("$*"); }
error()   { echo -e "${RED}[✘]${NC} $*" | tee -a "$LOG_FILE"; ERRORS+=("$*"); }
info()    { echo -e "${CYAN}[→]${NC} $*" | tee -a "$LOG_FILE"; }
heading() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }

# ── Trap unexpected errors ────────────────────────────────────────────────────
trap 'error "Unexpected failure at line ${LINENO}. Command: ${BASH_COMMAND}"; show_summary; exit 1' ERR

# ── Summary at end ────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}              INSTALLATION SUMMARY                   ${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}Warnings (${#WARNINGS[@]}):${NC}"
        for w in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW}⚠${NC}  $w"
        done
    fi

    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo -e "\n${RED}${BOLD}Errors (${#ERRORS[@]}):${NC}"
        for e in "${ERRORS[@]}"; do
            echo -e "  ${RED}✘${NC}  $e"
        done
        echo -e "\n${RED}Installation completed with errors. Check ${LOG_FILE} for details.${NC}"
    else
        echo -e "\n${GREEN}${BOLD}✔  All steps completed successfully!${NC}"
        echo -e "   Full log: ${LOG_FILE}"
    fi
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root (use sudo).${NC}"
    exit 1
fi

# ── TTY fix ───────────────────────────────────────────────────────────────────
# When run via `curl | sudo bash`, stdin is the pipe, not the terminal.
# Fix: point all read commands explicitly at /dev/tty.
TTY=/dev/tty

# ── Init log ──────────────────────────────────────────────────────────────────
mkdir -p /var/log
echo "=== WireGuard Install Log — $(date) ===" > "$LOG_FILE"

# =============================================================================
#  STEP 1 — GATHER CONFIGURATION
# =============================================================================
heading "CONFIGURATION"

# Server public IP
DETECTED_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
              curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
              ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null || echo "")

read -rp "$(echo -e "${CYAN}Server public IP${NC} [detected: ${DETECTED_IP:-not found}]: ")" SERVER_IP < "$TTY"
SERVER_IP="${SERVER_IP:-$DETECTED_IP}"

if [[ -z "$SERVER_IP" ]]; then
    error "Could not determine server IP. Exiting."
    show_summary
    exit 1
fi

# WireGuard port
read -rp "$(echo -e "${CYAN}WireGuard listen port${NC} [default: 51820]: ")" WG_PORT < "$TTY"
WG_PORT="${WG_PORT:-51820}"

# VPN subnet
read -rp "$(echo -e "${CYAN}VPN subnet${NC} [default: 10.8.0.0/24]: ")" VPN_SUBNET < "$TTY"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"
VPN_BASE=$(echo "$VPN_SUBNET" | cut -d. -f1-3)   # e.g. 10.8.0
SERVER_VPN_IP="${VPN_BASE}.1"

# DNS for clients
read -rp "$(echo -e "${CYAN}DNS for clients${NC} [default: 1.1.1.1, 8.8.8.8]: ")" CLIENT_DNS < "$TTY"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1, 8.8.8.8}"

# Number of clients
while true; do
    read -rp "$(echo -e "${CYAN}Number of client configs to generate${NC} [default: 1]: ")" NUM_CLIENTS < "$TTY"
    NUM_CLIENTS="${NUM_CLIENTS:-1}"
    if [[ "$NUM_CLIENTS" =~ ^[1-9][0-9]*$ ]] && [[ "$NUM_CLIENTS" -le 253 ]]; then
        break
    fi
    warn "Enter a number between 1 and 253."
done

# Client name prefix
read -rp "$(echo -e "${CYAN}Client name prefix${NC} [default: client]: ")" CLIENT_PREFIX < "$TTY"
CLIENT_PREFIX="${CLIENT_PREFIX:-client}"

# Network interface (for masquerade / NAT)
DEFAULT_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
read -rp "$(echo -e "${CYAN}Network interface for NAT masquerade${NC} [detected: ${DEFAULT_IFACE:-eth0}]: ")" NET_IFACE < "$TTY"
NET_IFACE="${NET_IFACE:-${DEFAULT_IFACE:-eth0}}"

# QR codes for clients?
QR_CODES="n"
if command -v qrencode &>/dev/null || apt-cache show qrencode &>/dev/null 2>&1; then
    read -rp "$(echo -e "${CYAN}Generate QR codes for mobile clients?${NC} [Y/n]: ")" QR_CODES < "$TTY"
    QR_CODES="${QR_CODES:-y}"
fi

# WireGuard interface name
WG_INTERFACE="wg0"

# Config dirs
WG_DIR="/etc/wireguard"
CLIENT_DIR="${WG_DIR}/clients"

echo ""
info "Configuration summary:"
echo -e "  Server IP      : ${SERVER_IP}"
echo -e "  WG Port        : ${WG_PORT}"
echo -e "  VPN Subnet     : ${VPN_SUBNET}"
echo -e "  Server VPN IP  : ${SERVER_VPN_IP}/24"
echo -e "  Client DNS     : ${CLIENT_DNS}"
echo -e "  Clients        : ${NUM_CLIENTS} (prefix: ${CLIENT_PREFIX})"
echo -e "  NAT Interface  : ${NET_IFACE}"
echo -e "  QR Codes       : ${QR_CODES}"
echo ""
read -rp "$(echo -e "${YELLOW}Proceed with installation? [Y/n]: ")" CONFIRM < "$TTY"
CONFIRM="${CONFIRM:-y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# =============================================================================
#  STEP 2 — SYSTEM UPDATE
# =============================================================================
heading "SYSTEM UPDATE"

export DEBIAN_FRONTEND=noninteractive

info "Updating package lists..."
if ! apt-get update -y >> "$LOG_FILE" 2>&1; then
    error "apt-get update failed. Check network or mirror settings."
fi

info "Upgrading installed packages..."
if ! apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1; then
    warn "apt-get upgrade had issues. Continuing..."
fi
log "System update complete."

# =============================================================================
#  STEP 3 — INSTALL DEPENDENCIES
# =============================================================================
heading "INSTALLING DEPENDENCIES"

PACKAGES=(wireguard wireguard-tools iptables curl)
[[ "${QR_CODES,,}" =~ ^y ]] && PACKAGES+=(qrencode)

for pkg in "${PACKAGES[@]}"; do
    info "Installing ${pkg}..."
    if ! apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
        error "Failed to install ${pkg}."
    else
        log "${pkg} installed."
    fi
done

# =============================================================================
#  STEP 4 — IP FORWARDING
# =============================================================================
heading "IP FORWARDING"

SYSCTL_CONF="/etc/sysctl.d/99-wireguard.conf"
cat > "$SYSCTL_CONF" <<EOF
# WireGuard — enable IP forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

if ! sysctl -p "$SYSCTL_CONF" >> "$LOG_FILE" 2>&1; then
    error "Failed to apply sysctl settings."
else
    log "IP forwarding enabled (persistent via ${SYSCTL_CONF})."
fi

# =============================================================================
#  STEP 5 — KEY GENERATION
# =============================================================================
heading "KEY GENERATION"

mkdir -p "$WG_DIR" "$CLIENT_DIR"
chmod 700 "$WG_DIR"

# Server keys
info "Generating server key pair..."
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
log "Server keys generated."

# Client keys
declare -a CLIENT_PRIVATE_KEYS
declare -a CLIENT_PUBLIC_KEYS
declare -a CLIENT_PRESHARED_KEYS

for (( i=1; i<=NUM_CLIENTS; i++ )); do
    priv=$(wg genkey)
    pub=$(echo "$priv" | wg pubkey)
    psk=$(wg genpsk)
    CLIENT_PRIVATE_KEYS+=("$priv")
    CLIENT_PUBLIC_KEYS+=("$pub")
    CLIENT_PRESHARED_KEYS+=("$psk")
    log "Keys generated for ${CLIENT_PREFIX}${i}."
done

# =============================================================================
#  STEP 6 — SERVER CONFIG
# =============================================================================
heading "SERVER CONFIG"

SERVER_CONF="${WG_DIR}/${WG_INTERFACE}.conf"

cat > "$SERVER_CONF" <<EOF
# WireGuard Server Config — generated $(date)
[Interface]
Address = ${SERVER_VPN_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

# NAT / masquerade
PostUp   = iptables -t nat -A POSTROUTING -o ${NET_IFACE} -j MASQUERADE; iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${NET_IFACE} -j MASQUERADE; iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT

EOF

for (( i=1; i<=NUM_CLIENTS; i++ )); do
    CLIENT_IP="${VPN_BASE}.$((i+1))"
    cat >> "$SERVER_CONF" <<EOF
# ${CLIENT_PREFIX}${i}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEYS[$((i-1))]}
PresharedKey = ${CLIENT_PRESHARED_KEYS[$((i-1))]}
AllowedIPs = ${CLIENT_IP}/32

EOF
done

chmod 600 "$SERVER_CONF"
log "Server config written to ${SERVER_CONF}."

# =============================================================================
#  STEP 7 — CLIENT CONFIGS
# =============================================================================
heading "CLIENT CONFIGS"

for (( i=1; i<=NUM_CLIENTS; i++ )); do
    CLIENT_NAME="${CLIENT_PREFIX}${i}"
    CLIENT_IP="${VPN_BASE}.$((i+1))"
    CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}.conf"

    cat > "$CLIENT_CONF" <<EOF
# WireGuard Client Config — ${CLIENT_NAME} — generated $(date)
[Interface]
Address = ${CLIENT_IP}/24
PrivateKey = ${CLIENT_PRIVATE_KEYS[$((i-1))]}
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEYS[$((i-1))]}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    chmod 600 "$CLIENT_CONF"
    log "Client config: ${CLIENT_CONF}"

    if [[ "${QR_CODES,,}" =~ ^y ]] && command -v qrencode &>/dev/null; then
        QR_FILE="${CLIENT_DIR}/${CLIENT_NAME}.png"
        qrencode -t PNG -o "$QR_FILE" < "$CLIENT_CONF"
        log "QR code saved: ${QR_FILE}"
    fi
done

# =============================================================================
#  STEP 8 — FIREWALL (UFW or iptables)
# =============================================================================
heading "FIREWALL"

if command -v ufw &>/dev/null; then
    info "UFW detected. Adding WireGuard rule..."
    if ! ufw allow "${WG_PORT}/udp" >> "$LOG_FILE" 2>&1; then
        warn "UFW rule for port ${WG_PORT}/udp may not have been added. Check manually."
    else
        log "UFW: allowed ${WG_PORT}/udp."
    fi

    # Ensure UFW default forward policy is ACCEPT
    UFW_DEFAULTS="/etc/default/ufw"
    if grep -q "DEFAULT_FORWARD_POLICY=\"DROP\"" "$UFW_DEFAULTS" 2>/dev/null; then
        sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$UFW_DEFAULTS"
        warn "UFW DEFAULT_FORWARD_POLICY changed from DROP to ACCEPT. Review if unexpected."
    fi

    ufw --force reload >> "$LOG_FILE" 2>&1 || warn "UFW reload failed."
else
    info "UFW not found. Applying iptables rules directly..."
    iptables -A INPUT -p udp --dport "${WG_PORT}" -j ACCEPT >> "$LOG_FILE" 2>&1 || \
        warn "iptables INPUT rule may have failed."
    iptables -A FORWARD -i "${WG_INTERFACE}" -j ACCEPT >> "$LOG_FILE" 2>&1 || \
        warn "iptables FORWARD rule may have failed."
    log "iptables rules applied (not persistent across reboots — install iptables-persistent manually)."
fi

# =============================================================================
#  STEP 9 — ENABLE & START SERVICE
# =============================================================================
heading "WIREGUARD SERVICE"

info "Enabling wg-quick@${WG_INTERFACE}..."
if ! systemctl enable "wg-quick@${WG_INTERFACE}" >> "$LOG_FILE" 2>&1; then
    error "Failed to enable WireGuard service."
fi

info "Starting wg-quick@${WG_INTERFACE}..."
if ! systemctl start "wg-quick@${WG_INTERFACE}" >> "$LOG_FILE" 2>&1; then
    error "Failed to start WireGuard service. Check: journalctl -xe -u wg-quick@${WG_INTERFACE}"
else
    log "WireGuard service started and enabled on boot."
fi

# =============================================================================
#  STEP 10 — VERIFY
# =============================================================================
heading "VERIFICATION"

sleep 2  # give the interface a moment

if wg show "${WG_INTERFACE}" >> "$LOG_FILE" 2>&1; then
    log "WireGuard interface ${WG_INTERFACE} is UP."
    echo ""
    wg show "${WG_INTERFACE}"
    echo ""
else
    error "wg show failed. Interface may not be running."
fi

# Check port is listening
if ss -ulnp | grep -q ":${WG_PORT}"; then
    log "Server is listening on UDP port ${WG_PORT}."
else
    warn "Port ${WG_PORT}/udp does not appear to be open. Firewall or bind issue?"
fi

# =============================================================================
#  DONE — PRINT CLIENT LOCATIONS & SUMMARY
# =============================================================================
heading "CLIENT FILES"

echo -e "${BOLD}Client configs saved to: ${CLIENT_DIR}/${NC}"
echo ""
for (( i=1; i<=NUM_CLIENTS; i++ )); do
    CLIENT_NAME="${CLIENT_PREFIX}${i}"
    CLIENT_IP="${VPN_BASE}.$((i+1))"
    echo -e "  ${GREEN}${CLIENT_NAME}${NC}  →  VPN IP: ${CLIENT_IP}  |  Config: ${CLIENT_DIR}/${CLIENT_NAME}.conf"
    [[ "${QR_CODES,,}" =~ ^y ]] && [[ -f "${CLIENT_DIR}/${CLIENT_NAME}.png" ]] && \
        echo -e "              QR Code: ${CLIENT_DIR}/${CLIENT_NAME}.png"
done

echo ""
echo -e "${CYAN}To add more clients later, re-run this script or manually add [Peer] blocks.${NC}"
echo -e "${CYAN}To show live WireGuard status: ${BOLD}wg show${NC}"
echo -e "${CYAN}To restart: ${BOLD}systemctl restart wg-quick@${WG_INTERFACE}${NC}"

show_summary
