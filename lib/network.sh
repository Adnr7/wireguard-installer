#!/bin/bash

detect_ip() {
    curl -s https://api.ipify.org || hostname -I | awk '{print $1}'
}

detect_iface() {
    ip route | grep '^default' | awk '{print $5}' | head -n1
}
