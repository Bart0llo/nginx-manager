#!/bin/bash

set -e

URL="https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/nginx-site.sh"
TARGET="/usr/local/bin/nginx-manager"

# Options (pass them through the pipe with: ... | sudo bash -s -- --with-certbot)
#   --with-certbot     also install certbot and the Cloudflare DNS plugin
#                      (same as NM_WITH_CERTBOT=1); otherwise TLS Manager ->
#                      Install TLS dependencies can add them later
#   NM_SHA256=<hash>   expected SHA-256 of the downloaded script. Take it from
#                      a source you trust, not from the gist: a hash served
#                      next to the file proves nothing about who wrote it.
#                      This check runs inside install.sh, so it only means
#                      something if this install.sh was itself obtained or
#                      reviewed in a trustworthy way.
WITH_CERTBOT="${NM_WITH_CERTBOT:-0}"
EXPECTED_SHA256="${NM_SHA256:-}"

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

for arg in "$@"; do
    case "$arg" in
        --with-certbot) WITH_CERTBOT=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if [[ -n "$EXPECTED_SHA256" && ! "$EXPECTED_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "Error: NM_SHA256 must be 64 hex characters."
    exit 1
fi

echo "[1/3] Installing dependencies..."

export DEBIAN_FRONTEND=noninteractive

PACKAGES=(curl jq nginx openssl)
if [[ "$WITH_CERTBOT" == 1 ]]; then
    PACKAGES+=(certbot python3-certbot-dns-cloudflare)
fi

apt-get update

apt-get install -y "${PACKAGES[@]}"

echo
echo "[2/3] Downloading NGINX Manager Pro..."

# Private temp directory (mode 700, unpredictable name), removed on any exit.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
TMP="$TMP_DIR/nginx-site.sh"

curl -fsSL "$URL" -o "$TMP"

# Nothing downloaded is run: it is only checked, then copied into place.
if [[ -n "$EXPECTED_SHA256" ]]; then
    actual=$(sha256sum "$TMP" | cut -d' ' -f1)
    if [[ "$actual" != "${EXPECTED_SHA256,,}" ]]; then
        echo "Error: checksum mismatch."
        echo "  expected $EXPECTED_SHA256"
        echo "  got      $actual"
        exit 1
    fi
    echo "Checksum verified (SHA-256 matches NM_SHA256)."
else
    echo "Note: the download is not verified against a checksum (set NM_SHA256 to verify it)."
fi

if ! bash -n "$TMP"; then
    echo "Error: downloaded script has invalid Bash syntax."
    exit 1
fi

echo
echo "[3/3] Installing..."

install -m 755 "$TMP" "$TARGET"

echo
echo "======================================"
echo " Installation completed successfully"
echo "======================================"
echo
echo "Run:"
echo "  nginx-manager"
echo
if [[ "$WITH_CERTBOT" != 1 ]]; then
    echo "Certbot was not installed (only needed for HTTPS certificates)."
    echo "Add it later via TLS Manager -> Install TLS dependencies, or rerun"
    echo "the installer with: ... | sudo bash -s -- --with-certbot"
    echo
fi
