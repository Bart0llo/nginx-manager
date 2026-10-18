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
        echo -e "${RED}Certbot is not installed. Run TLS Manager -> Install TLS dependencies.${NC}"
        return 1
    fi
    return 0
}

require_openssl() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}OpenSSL is not installed. Run TLS Manager -> Install TLS dependencies.${NC}"
        return 1
    fi
    return 0
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
