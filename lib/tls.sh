#!/bin/bash
# ==========================================================
# NGINX Manager Pro - TLS manager
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# TLS MANAGER
# ==========================================================
cloudflare_credentials_ok() {
    [[ -f "$CF_FILE" ]] || return 1
    [[ -s "$CF_FILE" ]] || return 1
    grep -q "dns_cloudflare_api_token" "$CF_FILE" || return 1
    return 0
}

install_tls() {
    header
    echo -e "${BOLD}INSTALL TLS DEPENDENCIES${NC}"
    echo "──────────────────────────────────────────────────────"
    echo
    msg_step "Installing certbot, python3-certbot-dns-cloudflare, jq, curl..."
    echo

    if ! apt update; then
        msg_error "apt update failed"
        log "install_tls: apt update failed"
        pause
        return 1
    fi

    if ! apt install -y certbot python3-certbot-dns-cloudflare jq curl; then
        msg_error "Package installation failed"
        log "install_tls: apt install failed"
        pause
        return 1
    fi

    echo
    msg_success "TLS dependencies installed"
    log "TLS packages installed"
    pause
}

create_cloudflare_token() {
    header
    echo -e "${BOLD}CLOUDFLARE CREDENTIALS${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    mkdir -p "$CF_DIR"
    chmod 700 "$CF_DIR"

    echo "An API token with Zone -> DNS -> Edit permission is required."
    echo

    if [[ -f "$CF_FILE" ]]; then
        msg_warning "Existing Cloudflare credentials found: $CF_FILE"
        echo
        confirm "Overwrite existing token?" n || { echo "Cancelled"; pause; return; }
        echo
    fi

    local token
    while true; do
        read -rsp "Token: " token
        echo

        if [[ -z "$token" ]]; then
            msg_error "Token cannot be empty"
            confirm "Try again?" y || return
            continue
        fi

        break
    done

    local tmp
    tmp=$(mktemp -p "$CF_DIR") || {
        msg_error "Failed to create temporary credentials file"
        pause
        return
    }
    chmod 600 "$tmp"

    cat > "$tmp" <<EOF
dns_cloudflare_api_token = $token
EOF

    if [[ $? -ne 0 ]]; then
        rm -f "$tmp"
        msg_error "Failed to write Cloudflare credentials"
        pause
        return
    fi

    mv "$tmp" "$CF_FILE"

    echo
    msg_success "Cloudflare credentials saved"
    log "Cloudflare credentials updated"
    pause
}

create_certificate() {
    header
    echo -e "${BOLD}CREATE CERTIFICATE${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    if ! load_config; then
        pause
        return
    fi

    if [[ -z "$DOMAIN" ]]; then
        msg_error "DOMAIN is not set in configuration"
        pause
        return
    fi

    if [[ -z "$CERT_NAME" ]]; then
        msg_error "CERT_NAME is not set in configuration"
        pause
        return
    fi

    if ! require_certbot; then
        pause
        return
    fi

    if ! cloudflare_credentials_ok; then
        msg_error "Cloudflare credentials not configured"
        echo
        echo "Set them up first via TLS Manager -> Cloudflare credentials."
        pause
        return
    fi

    [[ -z "$CERTBOT_EMAIL" ]] && read -p "Email: " CERTBOT_EMAIL

    echo
    msg_step "Requesting certificate for *.$DOMAIN and $DOMAIN..."
    echo

    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_FILE" \
        --dns-cloudflare-propagation-seconds 30 \
        --cert-name "$CERT_NAME" \
        -d "*.$DOMAIN" -d "$DOMAIN" --agree-tos --non-interactive -m "$CERTBOT_EMAIL"

    echo
    if [[ $? -eq 0 ]]; then
        msg_success "Certificate created"
        log "Certificate created for $DOMAIN (cert-name: $CERT_NAME)"
    else
        msg_error "Certificate request failed"
        log "Certificate creation failed for $DOMAIN"
    fi
    pause
}

renew_certificate() {
    header
    echo -e "${BOLD}RENEW CERTIFICATE${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    if ! load_config; then
        pause
        return
    fi

    if ! require_certbot; then
        pause
        return
    fi

    certbot renew --deploy-hook "systemctl reload nginx"
    pause
}

certificate_info() {
    header
    echo -e "${BOLD}CERTIFICATE INFO${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    if ! load_config; then
        pause
        return
    fi

    if ! require_openssl; then
        pause
        return
    fi

    local cert="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
    if [[ ! -f "$cert" ]]; then
        msg_warning "Certificate not found"
        pause
        return
    fi

    openssl x509 -in "$cert" -noout -subject -ext subjectAltName -dates
    pause
}

# Prints the cert expiry epoch (seconds) for the configured CERT_NAME,
# or nothing if it cannot be determined. Used by status screens only.
_cert_days_left() {
    local cert="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
    [[ -f "$cert" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 1

    local end_date end_epoch now_epoch
    end_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -n "$end_date" ]] || return 1
    end_epoch=$(date -d "$end_date" +%s 2>/dev/null)
    [[ -n "$end_epoch" ]] || return 1
    now_epoch=$(date +%s)
    echo $(( (end_epoch - now_epoch) / 86400 ))
}

tls_menu() {
    while true; do
        header
        echo -e "${BOLD}TLS MANAGER${NC}"
        echo "──────────────────────────────────────────────────────"
        echo

        echo "  Certificate"
        if load_config >/dev/null 2>&1 && [[ -n "$DOMAIN" ]]; then
            echo "    Name         ${CERT_NAME:-—}"
            echo "    Domain       ${DOMAIN:-—}"

            local cert_path="/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem"
            if [[ -n "$CERT_NAME" ]] && [[ -f "$cert_path" ]]; then
                local days_left
                days_left=$(_cert_days_left)
                if [[ -n "$days_left" ]]; then
                    if ((days_left < 0)); then
                        echo -e "    Status       ${RED}✗ Expired${NC}"
                    elif ((days_left < 14)); then
                        echo -e "    Status       ${YELLOW}! Expires soon${NC}"
                    else
                        echo -e "    Status       ${GREEN}✓ Valid${NC}"
                    fi
                    echo "    Days left    $days_left"
                else
                    echo -e "    Status       ${GREEN}✓ Present${NC}"
                fi
            else
                echo -e "    Status       ${YELLOW}○ Not issued${NC}"
            fi
        else
            echo -e "    ${YELLOW}Configuration not loaded (DOMAIN not set)${NC}"
        fi

        echo
        echo "  Cloudflare"
        if cloudflare_credentials_ok; then
            echo -e "    Credentials  ${GREEN}✓ Configured${NC}"
        else
            echo -e "    Credentials  ${RED}✗ Not configured${NC}"
        fi

        echo
        echo "──────────────────────────────────────────────────────"
        echo
        echo "  [1] Certificate info"
        echo "  [2] Create / issue certificate"
        echo "  [3] Renew certificate"
        echo "  [4] Cloudflare credentials"
        echo "  [5] Install TLS dependencies"
        echo "  [Q] Back"
        echo

        local choice
        read -p "Select: " choice
        case "${choice,,}" in
            1) certificate_info ;;
            2) create_certificate ;;
            3) renew_certificate ;;
            4) create_cloudflare_token ;;
            5) install_tls ;;
            q|"") return ;;
            *) msg_error "Invalid option"; pause ;;
        esac
    done
}
