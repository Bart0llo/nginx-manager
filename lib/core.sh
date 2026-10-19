#!/bin/bash
# ==========================================================
# NGINX Manager Pro - paths, colours, dependencies, directories, log
# Sourced by nginx-site.sh: defines constants and functions only.
# ==========================================================

# ==========================================================
# PATHS
# ==========================================================
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
MANAGER_DIR="/etc/nginx-manager"
CONFIG_FILE="$MANAGER_DIR/config.conf"
SITES_DB="$MANAGER_DIR/sites.json"
BACKUP_DIR="$MANAGER_DIR/backups"
LOG_FILE="/var/log/nginx-manager/manager.log"
LOCK_FILE="/run/lock/nginx-manager.lock"
SNIPPETS_DIR="/etc/nginx/snippets"
CF_DIR="/etc/nginx-manager/secrets"
CF_FILE="$CF_DIR/cloudflare.ini"
# Plugin code (nginx-site.sh points this at plugins/ when run from a
# checkout), the enabled list, settings (<id>.conf) and secrets (<id>/).
PLUGIN_DIR="/usr/local/lib/nginx-manager/plugins"
PLUGINS_ENABLED="$MANAGER_DIR/plugins.enabled"
PLUGIN_CONF_DIR="$MANAGER_DIR/plugins"
PLUGIN_SECRETS_DIR="$CF_DIR"
# AdGuard Home connection (lib/adguard.sh): settings and login password.
ADGUARD_CONF="$MANAGER_DIR/adguard.conf"
ADGUARD_SECRET="$CF_DIR/adguard.password"

# ==========================================================
# COLORS
# ==========================================================
BLUE=$'\033[1;34m'
GREEN=$'\033[1;32m'
RED=$'\033[1;31m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[1;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'
BOLD=$'\033[1m'

# ==========================================================
# CORE DEPENDENCY CHECK
# ==========================================================
# jq and nginx are required for the manager to function at all
# (site database + nginx control). Certbot/OpenSSL are only needed
# for TLS features and are intentionally NOT required to start.
check_core_dependencies() {
    local missing=()
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v nginx >/dev/null 2>&1 || missing+=("nginx")

    if ((${#missing[@]} > 0)); then
        echo -e "${RED}${BOLD}Missing required dependency: ${missing[*]}${NC}"
        echo "NGINX Manager requires 'jq' and 'nginx' to manage sites."
        echo "Install them, for example:"
        echo "  apt update && apt install -y jq nginx"
        echo "(Certbot/OpenSSL are only needed for TLS features and are not required here.)"
        return 1
    fi
    return 0
}

require_certbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        echo -e "${RED}Certbot is not installed. Install it from TLS & certificates -> Install TLS packages.${NC}"
        return 1
    fi
    return 0
}

require_openssl() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}OpenSSL is not installed. Install it from TLS & certificates -> Install TLS packages.${NC}"
        return 1
    fi
    return 0
}

require_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}curl is not installed. Install it with: apt install curl${NC}"
        return 1
    fi
    return 0
}

# ==========================================================
# SECRETS
# ==========================================================
# secret_write <file> <label>   (value on stdin)
# Stores one secret under $CF_DIR. The directories are 0700 and the file is
# 0600 before the value is written, then atomically moved into place. The
# value is never printed or logged; <label> names it in messages.
# Returns 0 saved, 1 failed, 2 empty value.
secret_write() {
    local file="$1" label="$2" dir tmp
    dir=$(dirname "$file")
    if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) ]]; then
        msg_error "$dir is not a directory; secret not saved"
        return 1
    fi
    if ! mkdir -p -m 700 "$CF_DIR" "$dir" || ! chmod 700 "$CF_DIR" "$dir"; then
        msg_error "Failed to create $dir"
        return 1
    fi

    if ! tmp=$(mktemp -p "$dir") || ! chmod 600 "$tmp" || ! cat > "$tmp"; then
        [[ -n "$tmp" ]] && rm -f "$tmp"
        msg_error "Failed to write $label"
        log "Secret not saved: $label (write failed)"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        msg_error "Secret value cannot be empty"
        return 2
    fi
    if ! mv -fT "$tmp" "$file"; then
        rm -f "$tmp"
        msg_error "Failed to write $label"
        log "Secret not saved: $label (move failed)"
        return 1
    fi
}

# ==========================================================
# DIRECTORIES
# ==========================================================
init_directories() {
    mkdir -p "$MANAGER_DIR" "$BACKUP_DIR" "$SNIPPETS_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"
}

# ==========================================================
# LOG
# ==========================================================
log() {
    echo "$(date '+%F %T') $1" >> "$LOG_FILE"
}
