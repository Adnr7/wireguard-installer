#!/bin/bash
set -e

echo "Removing WireGuard..."

systemctl stop wg-quick@wg0 || true
systemctl disable wg-quick@wg0 || true

apt remove --purge -y wireguard wireguard-tools
apt autoremove -y

rm -rf /etc/wireguard

echo "Done."
