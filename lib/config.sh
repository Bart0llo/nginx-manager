#!/bin/bash
# ==========================================================
# NGINX Manager Pro - manager configuration
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# CONFIG
# ==========================================================
create_default_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        local tmp
        tmp=$(mktemp -p "$MANAGER_DIR") || {
            msg_error "Failed to create temporary config file"
            return 1
        }

        cat > "$tmp" <<EOF
DOMAIN=
CERT_NAME=
CERTBOT_EMAIL=
DEFAULT_TLS=https
EOF

        if [[ $? -ne 0 ]]; then
            rm -f "$tmp"
            msg_error "Failed to write config file"
            return 1
        fi

        mv "$tmp" "$CONFIG_FILE"
    fi
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Missing config: $CONFIG_FILE${NC}"
        return 1
    fi
    source "$CONFIG_FILE"
}

first_run_setup() {

    if [[ -f "$CONFIG_FILE" ]] && grep -q "^SETUP_DONE=true" "$CONFIG_FILE"; then
        return
    fi

    header
    echo -e "${BOLD}FIRST RUN SETUP${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    local domain
    while true; do
        read -p "Base domain (example: lan.example.com): " domain
        validate_domain "$domain" && break
        msg_error "Invalid domain"
    done

    local email
    while true; do
        read -p "Certbot email: " email
        [[ "$email" =~ ^.+@.+\..+$ ]] && break
        msg_error "Invalid email"
    done

    local tmp
    tmp=$(mktemp -p "$MANAGER_DIR") || {
        msg_error "Failed to create temporary config file"
        pause
        return 1
    }

    cat > "$tmp" <<EOF
DOMAIN=$domain
CERT_NAME=$domain
CERTBOT_EMAIL=$email
DEFAULT_TLS=https
SETUP_DONE=true
EOF

    if [[ $? -ne 0 ]]; then
        rm -f "$tmp"
        msg_error "Failed to write config file"
        pause
        return 1
    fi

    mv "$tmp" "$CONFIG_FILE"

    echo
    msg_success "Initial setup completed"
    pause
}
