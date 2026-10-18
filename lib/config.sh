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

# Reads config.conf as data - it is never executed. Format, one per line:
#   KEY=VALUE        KEY is DOMAIN, CERT_NAME, CERTBOT_EMAIL, DEFAULT_TLS
#                    or SETUP_DONE; VALUE may be empty, or wrapped in one
#                    pair of '...' or "..." (taken literally, no escapes);
#                    whitespace around the line is ignored
#   # comment        blank lines and lines starting with # are skipped
# Anything else (unknown keys, "export", spaces around "=", shell syntax,
# invalid values) rejects the whole file: the variables are cleared and
# load_config returns 1 with the offending line number.
load_config() {
    DOMAIN="" CERT_NAME="" CERTBOT_EMAIL="" DEFAULT_TLS="" SETUP_DONE=""
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Missing config: $CONFIG_FILE${NC}"
        return 1
    fi

    local line key value error n=0
    local -A conf=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue

        if [[ ! "$line" =~ ^[[:space:]]*([A-Z_]+)=(.*[^[:space:]])?[[:space:]]*$ ]]; then
            error="expected KEY=VALUE"
            break
        fi
        key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ ^\"([^\"]*)\"$ || "$value" =~ ^\'([^\']*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi

        case "$key" in
            DOMAIN) [[ -z "$value" ]] || validate_domain "$value" || error="invalid DOMAIN" ;;
            CERT_NAME) [[ -z "$value" || "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || error="invalid CERT_NAME" ;;
            CERTBOT_EMAIL) [[ -z "$value" ]] || validate_email "$value" || error="invalid CERTBOT_EMAIL" ;;
            DEFAULT_TLS) [[ -z "$value" ]] || validate_tls "$value" || error="invalid DEFAULT_TLS" ;;
            SETUP_DONE) [[ -z "$value" || "$value" == true || "$value" == false ]] || error="invalid SETUP_DONE" ;;
            *) error="unknown setting $key" ;;
        esac
        [[ -n "$error" ]] && break
        conf[$key]="$value"
    done < "$CONFIG_FILE"

    if [[ -n "$error" ]]; then
        msg_error "Invalid config $CONFIG_FILE line $n: $error"
        log "Config rejected: $CONFIG_FILE line $n: $error"
        return 1
    fi

    DOMAIN="${conf[DOMAIN]}"
    CERT_NAME="${conf[CERT_NAME]}"
    CERTBOT_EMAIL="${conf[CERTBOT_EMAIL]}"
    DEFAULT_TLS="${conf[DEFAULT_TLS]}"
    SETUP_DONE="${conf[SETUP_DONE]}"
}

first_run_setup() {

    if [[ -f "$CONFIG_FILE" ]] && grep -q "^SETUP_DONE=true" "$CONFIG_FILE"; then
        return
    fi

    ui_screen "First-run setup"
    echo "Two questions before the first start. They are saved in $CONFIG_FILE."
    ui_hint "The base domain names the wildcard certificate (*.domain) HTTPS sites use."
    ui_cancel_hint
    echo

    local domain
    while true; do
        ui_input "Base domain" "" "e.g. lan.example.com" || { ui_aborted $? "setup not completed"; return 1; }
        domain="$UI_REPLY"
        validate_domain "$domain" && break
        msg_error "Invalid domain - expected a name like lan.example.com"
    done

    local email
    while true; do
        ui_input "Certbot email" "" "Let's Encrypt sends expiry notices here" || { ui_aborted $? "setup not completed"; return 1; }
        email="$UI_REPLY"
        validate_email "$email" && break
        msg_error "Invalid email - expected name@example.com"
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
