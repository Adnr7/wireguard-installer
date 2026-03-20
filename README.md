<div align="center">

# ⚡ WireGuard Installer

**Automated WireGuard VPN setup for Ubuntu & Debian — from zero to running in under 2 minutes.**

[![Shell Script](https://img.shields.io/badge/shell-bash-green?style=flat-square&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-blue?style=flat-square&logo=linux)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/license-MIT-orange?style=flat-square)](LICENSE)
[![WireGuard](https://img.shields.io/badge/WireGuard-✔-red?style=flat-square)](https://www.wireguard.com/)

</div>

---

## 🚀 One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/Adnr7/wireguard-installer/main/install.sh | sudo bash
```

> **Requirements:** Ubuntu 20.04 / 22.04 / 24.04 or Debian 11 / 12 — root or sudo access.

---

## 📋 What It Does

The script handles everything from a fresh server to a fully working VPN:

| Step | Action |
|------|--------|
| 1 | System update & upgrade (`apt update && apt upgrade`) |
| 2 | Install WireGuard, wireguard-tools, iptables, qrencode |
| 3 | Enable persistent IPv4/IPv6 forwarding via sysctl |
| 4 | Auto-detect public IP, network interface |
| 5 | Generate server + per-client key pairs + preshared keys |
| 6 | Write `/etc/wireguard/wg0.conf` with NAT/masquerade rules |
| 7 | Write client `.conf` files to `/etc/wireguard/clients/` |
| 8 | Configure UFW (or raw iptables if UFW is absent) |
| 9 | Enable & start `wg-quick@wg0` as a systemd service |
| 10 | Verify interface is UP, port is listening |
| 11 | Show error/warning summary at the end |

---

## 🖥️ Interactive Prompts

The script will ask you:

```
Server public IP        → auto-detected, press Enter to confirm
Listen port             → default: 51820
VPN subnet              → default: 10.8.0.0/24
DNS for clients         → default: 1.1.1.1, 8.8.8.8
Number of clients       → e.g. 3  (generates client1, client2, client3)
Client name prefix      → default: client
NAT interface           → auto-detected from default route
Generate QR codes?      → Y/n  (for mobile clients)
```

---

## 📁 Output Files

After installation:

```
/etc/wireguard/
├── wg0.conf                  ← Server config
└── clients/
    ├── client1.conf          ← Import into WireGuard app
    ├── client1.png           ← QR code (if enabled)
    ├── client2.conf
    ├── client2.png
    └── ...
```

---

## 📱 Connecting a Client

### Desktop (Linux / macOS / Windows)
Import the `.conf` file into the WireGuard app.

### Mobile (iOS / Android)
Scan the `.png` QR code directly from the WireGuard mobile app.

### Linux CLI
```bash
sudo wg-quick up /etc/wireguard/clients/client1.conf
```

---

## 🛠️ Useful Commands

```bash
# Check WireGuard status & connected peers
sudo wg show

# Restart WireGuard
sudo systemctl restart wg-quick@wg0

# Stop WireGuard
sudo systemctl stop wg-quick@wg0

# View live logs
sudo journalctl -fu wg-quick@wg0

# Check install log
cat /var/log/wireguard-install.log
```

---

## 🗑️ Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Adnr7/wireguard-installer/main/uninstall.sh | sudo bash
```

This will stop the service, remove all WireGuard packages, and delete `/etc/wireguard/` (after a confirmation prompt).

---

## ⚠️ OCI / Cloud Firewall Note

If you're on **Oracle Cloud (OCI)**, AWS, GCE, or any provider with an external firewall/security group, you **must also open UDP port 51820** in the cloud console — the script only handles the OS-level firewall.

For OCI specifically:
- Go to **VCN → Security Lists → Add Ingress Rule**
- Protocol: UDP | Port: 51820

---

## 🧩 Compatibility

| OS | Version | Status |
|----|---------|--------|
| Ubuntu | 20.04 LTS | ✅ Tested |
| Ubuntu | 22.04 LTS | ✅ Tested |
| Ubuntu | 24.04 LTS | ✅ Tested |
| Debian | 11 (Bullseye) | ✅ Tested |
| Debian | 12 (Bookworm) | ✅ Tested |

---

## 📄 License

MIT © [Adarsh](https://github.com/Adnr7)
