#!/bin/bash
# =============================================================================
#  WireGuard Uninstaller
#  Removes WireGuard, all configs, keys, and firewall rules
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root (sudo).${NC}"
    exit 1
fi

WG_INTERFACE="wg0"

echo -e "\n${BOLD}${RED}━━━  WireGuard Uninstaller  ━━━${NC}\n"
echo -e "${YELLOW}This will:${NC}"
echo -e "  • Stop and disable wg-quick@${WG_INTERFACE}"
echo -e "  • Remove wireguard and wireguard-tools packages"
echo -e "  • Delete /etc/wireguard/ (all configs and keys)"
echo -e "  • Remove IP forwarding sysctl config"
echo -e "  • Remove UFW rule for WireGuard port (if applicable)"
echo ""
read -rp "$(echo -e "${RED}${BOLD}Are you sure? This cannot be undone. [yes/N]: ${NC}")" CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${CYAN}Aborted.${NC}"
    exit 0
fi

echo ""

# Stop and disable service
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
    echo -e "${CYAN}[→]${NC} Stopping wg-quick@${WG_INTERFACE}..."
    systemctl stop "wg-quick@${WG_INTERFACE}"
fi

if systemctl is-enabled --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
    echo -e "${CYAN}[→]${NC} Disabling wg-quick@${WG_INTERFACE}..."
    systemctl disable "wg-quick@${WG_INTERFACE}"
fi

# Remove packages
echo -e "${CYAN}[→]${NC} Removing WireGuard packages..."
apt-get remove --purge -y wireguard wireguard-tools 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Remove configs
if [[ -d /etc/wireguard ]]; then
    echo -e "${CYAN}[→]${NC} Removing /etc/wireguard/..."
    rm -rf /etc/wireguard
fi

# Remove sysctl config
SYSCTL_CONF="/etc/sysctl.d/99-wireguard.conf"
if [[ -f "$SYSCTL_CONF" ]]; then
    echo -e "${CYAN}[→]${NC} Removing sysctl config..."
    rm -f "$SYSCTL_CONF"
    sysctl -p 2>/dev/null || true
fi

# Remove UFW rule (best effort)
if command -v ufw &>/dev/null; then
    WG_PORT=$(grep -r "ListenPort" /etc/wireguard/ 2>/dev/null | awk '{print $3}' | head -n1 || echo "51820")
    echo -e "${CYAN}[→]${NC} Removing UFW rule for port ${WG_PORT}/udp..."
    ufw delete allow "${WG_PORT}/udp" 2>/dev/null || true
fi

# Remove install log
rm -f /var/log/wireguard-install.log

echo ""
echo -e "${GREEN}${BOLD}✔  WireGuard has been fully removed.${NC}"
echo -e "${YELLOW}Note: IP forwarding is now disabled. If other services needed it, re-enable manually.${NC}"
echo ""
