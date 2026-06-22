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

This script is purely autonomous and instantly sets up your server to accept secure VPN connections:

| Step | Action |
|------|--------|
| 1 | System update & upgrade (`apt update && apt upgrade`) |
| 2 | Install WireGuard, wireguard-tools, iptables, qrencode |
| 3 | Enable persistent IPv4/IPv6 forwarding via sysctl |
| 4 | Auto-detect public IP, network interface, and optimal IPs |
| 5 | Generate server + client key pairs |
| 6 | Create robust, cloud-ready NAT/masquerade firewall rules |
| 7 | Enable & start `wg-quick@wg0` as a systemd service |
| 8 | Instantly generate your very first `.conf` profile |

---

## 🛠️ Instant Profile Management

The same script used for installation now doubles as your robust VPN profile manager. Once WireGuard is installed, you can effortlessly manage clients: 

```bash
Add a new client: sudo bash ~/wireguard-install.sh add-client <name>
List clients: sudo bash ~/wireguard-install.sh list-clients
Show QR code/Config: sudo bash ~/wireguard-install.sh show-client <name>
Remove a client: sudo bash ~/wireguard-install.sh remove-client <name>
```

---

## 📁 Output Files

After running the script or adding clients, your files will look like this:

```
/etc/wireguard/
├── wg0.conf                  ← Secure Server Config
└── clients/
    ├── client1.conf          ← First profile automatically created
    ├── client1.png           ← QR code for your phone
    ├── my-laptop.conf        ← Added via `add-client`
    └── ...
```

---

## 📱 Connecting a Client

### Desktop (Linux / macOS / Windows)
Download the `.conf` file from `/etc/wireguard/clients/` and import it into the WireGuard app.

### Mobile (iOS / Android)
View the `.png` QR code natively in your terminal using the script, and scan it directly from the WireGuard mobile app:
```bash
sudo bash install.sh show-client client1
```

---

## ⚠️ OCI / Cloud Firewall Note

This script generates highly sophisticated OS-level rules (`iptables -I FORWARD`) capable of cutting through the restrictive default firewalls on platforms like **Oracle Cloud (OCI)**, AWS, and Azure, so your internet routing will work perfectly!

However, **you must still open UDP port 51820 manually in your Cloud Provider's Web Console**, otherwise the VPN connection will never reach the server at all.

For OCI specifically:
- Go to **VCN → Security Lists → Default Security List → Add Ingress Rule**
- Protocol: UDP | Source CIDR: `0.0.0.0/0` | Destination Port: `51820`

---

## 🗑️ Uninstall

Uninstalling WireGuard and scrubbing all traces of configs is now handled natively via the script. You no longer need a separate `uninstall.sh`. 

```bash
sudo bash install.sh uninstall
```

This will stop the service, remove all WireGuard packages, and explicitly delete `/etc/wireguard/` (after a safety confirmation prompt).

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
