#!/bin/bash

log() { echo -e "[✔] $*"; }
warn() { echo -e "[!] $*"; }
error() { echo -e "[✘] $*"; exit 1; }

require_root() {
    [[ $EUID -ne 0 ]] && error "Run as root (sudo)."
}
