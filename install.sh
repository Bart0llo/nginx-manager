#!/bin/bash

set -e

URL="https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/nginx-site.sh"
TARGET="/usr/local/bin/nginx-manager"
TMP="/tmp/nginx-manager.sh"

echo "======================================"
echo " NGINX Manager Pro - Installer"
echo "======================================"
echo

if [[ $EUID -ne 0 ]]; then
    echo "Please run this installer with sudo."
    echo
    echo "Example:"
    echo "  curl -fsSL https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/install.sh | sudo bash"
    exit 1
fi

echo "[1/3] Installing dependencies..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    curl \
    jq \
    nginx \
    certbot \
    python3-certbot-dns-cloudflare \
    openssl

echo
echo "[2/3] Downloading NGINX Manager Pro..."

curl -fsSL "$URL" -o "$TMP"

if ! bash -n "$TMP"; then
    echo "Error: downloaded script has invalid Bash syntax."
    rm -f "$TMP"
    exit 1
fi

echo
echo "[3/3] Installing..."

install -m 755 "$TMP" "$TARGET"
rm -f "$TMP"

echo
echo "======================================"
echo " Installation completed successfully"
echo "======================================"
echo
echo "Run:"
echo "  nginx-manager"
echo