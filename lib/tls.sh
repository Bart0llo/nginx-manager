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
    ui_screen "TLS & certificates" "Install TLS packages"
    echo "Installs certbot, python3-certbot-dns-cloudflare, jq and curl with apt."
    ui_hint "Needs network access to the Debian/Ubuntu package mirrors."
    echo
    if ! confirm "Install the packages now?" y; then
        msg_warning "Cancelled - nothing was installed"
        pause
        return 1
    fi
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
    ui_screen "TLS & certificates" "Cloudflare credentials"
    echo "certbot proves that you own the domain by creating a DNS record"
    echo "through the Cloudflare API."
    ui_hint "Create an API token with Zone -> DNS -> Edit permission in the Cloudflare dashboard."
    ui_hint "It is stored in $CF_FILE (mode 600) and never shown."
    echo

    if [[ -f "$CF_FILE" ]]; then
        msg_warning "Existing Cloudflare credentials found: $CF_FILE"
        echo
        confirm "Overwrite existing token?" n || { msg_warning "Cancelled - the existing token is kept"; pause; return; }
        echo
    fi

    local token
    while true; do
        ui_input "API token" "" "" secret || { ui_aborted $?; return; }
        token="$UI_REPLY"

        if [[ -z "$token" ]]; then
            msg_error "Token cannot be empty"
            confirm "Try again?" y || return
            continue
        fi

        break
    done

    mkdir -p "$CF_DIR"
    chmod 700 "$CF_DIR"

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
    ui_screen "TLS & certificates" "Issue certificate"

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
        echo "Set them up first via TLS & certificates -> Cloudflare credentials."
        pause
        return
    fi

    # load_config has already rejected an invalid CERTBOT_EMAIL.
    local email="$CERTBOT_EMAIL"
    while [[ -z "$email" ]]; do
        ui_input "Email for Let's Encrypt" "" "expiry notices are sent here" || { ui_aborted $?; return 1; }
        validate_email "$UI_REPLY" && email="$UI_REPLY" && break
        msg_error "Invalid email - expected name@example.com"
    done

    ui_kv "Certificate" "$CERT_NAME"
    ui_kv "Domains" "*.$DOMAIN, $DOMAIN"
    ui_kv "Email" "$email"
    ui_kv "Challenge" "Cloudflare DNS (waits 30 s for propagation)"
    echo
    ui_hint "certbot asks Let's Encrypt for the certificate and creates or replaces its files."
    if ! confirm "Request the certificate now?" y; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return 1
    fi

    echo
    msg_step "Requesting certificate for *.$DOMAIN and $DOMAIN (certbot output follows)..."
    echo

    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_FILE" \
        --dns-cloudflare-propagation-seconds 30 \
        --cert-name "$CERT_NAME" \
        -d "*.$DOMAIN" -d "$DOMAIN" --agree-tos --non-interactive -m "$email"
    local rc=$?

    echo
    if [[ $rc -eq 0 ]]; then
        msg_success "Certificate created"
        log "Certificate created for $DOMAIN (cert-name: $CERT_NAME)"
    else
        msg_error "Certificate request failed (certbot exit $rc)"
        log "Certificate creation failed for $DOMAIN (certbot exit $rc)"
        pause
        return 1
    fi
    pause
}

renew_certificate() {
    ui_screen "TLS & certificates" "Renew certificates"

    if ! load_config; then
        pause
        return
    fi

    if ! require_certbot; then
        pause
        return
    fi

    echo "certbot renews every certificate that expires within 30 days and"
    echo "skips the others. nginx is reloaded after a renewal."
    echo
    if ! confirm "Run certbot renew now?" y; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return 1
    fi
    echo

    certbot renew --deploy-hook "systemctl reload nginx"
    local rc=$?
    echo
    if ((rc == 0)); then
        msg_success "certbot renew finished - its output above lists what was renewed"
        log "certbot renew finished"
    else
        msg_error "certbot renew failed (exit $rc) - see its output above"
        log "certbot renew failed (exit $rc)"
    fi
    pause
    return $rc
}

certificate_info() {
    ui_screen "TLS & certificates" "Certificate details"

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

    echo "$cert"
    echo
    openssl x509 -in "$cert" -noout -subject -ext subjectAltName -dates
    pause
}

# Prints the days until the configured CERT_NAME expires, or nothing if
# that cannot be determined.
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

# Reads the configured certificate (call load_config first) into:
#   CERT_STATE  none (no CERT_NAME), missing (not issued), unknown (no
#               openssl, or unreadable), expired, expiring (< 14 days), valid
#   CERT_DAYS   whole days left;  CERT_END  expiry date (YYYY-MM-DD)
#   CERT_SANS   the names it covers, space-separated
cert_status() {
    CERT_STATE=none CERT_DAYS="" CERT_END="" CERT_SANS=""
    [[ -n "$CERT_NAME" ]] || return 0
    local cert="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
    if [[ ! -f "$cert" ]]; then
        CERT_STATE=missing
        return 0
    fi
    CERT_STATE=unknown
    command -v openssl >/dev/null 2>&1 || return 0

    local out end_epoch now_epoch
    out=$(openssl x509 -in "$cert" -noout -enddate -ext subjectAltName 2>/dev/null) || return 0
    end_epoch=$(date -d "$(sed -n 's/^notAfter=//p' <<< "$out")" +%s 2>/dev/null) || return 0
    now_epoch=$(date +%s)
    CERT_END=$(date -d "@$end_epoch" +%F)
    CERT_DAYS=$(( (end_epoch - now_epoch) / 86400 ))
    CERT_SANS=$(grep -o 'DNS:[^,]*' <<< "$out" | sed 's/^DNS://' | paste -sd ' ')
    if ((end_epoch <= now_epoch)); then
        CERT_STATE=expired
    elif ((CERT_DAYS < 14)); then
        CERT_STATE=expiring
    else
        CERT_STATE=valid
    fi
}

# The CERT_STATE from cert_status as a badge.
cert_badge() {
    case "$CERT_STATE" in
        none)     ui_badge none "Not configured" ;;
        missing)  ui_badge warn "Not issued" ;;
        expired)  ui_badge err "Expired on $CERT_END" ;;
        expiring) ui_badge warn "Expires soon ($CERT_DAYS days left)" ;;
        valid)    ui_badge ok "Valid ($CERT_DAYS days left)" ;;
        *)        ui_badge unknown "Present, expiry unknown" ;;
    esac
}

tls_menu() {
    while true; do
        ui_screen "TLS & certificates"

        printf '%s\n' "${BOLD}Certificate${NC}"
        if ! load_config >/dev/null 2>&1; then
            ui_kv "Status" "$(ui_badge err "config.conf is invalid - see Status")"
        elif [[ -z "$DOMAIN" ]]; then
            ui_kv "Status" "$(ui_badge none "Not configured (DOMAIN is not set)")"
        else
            cert_status
            ui_kv "Name" "${CERT_NAME:-$SYM_NONE}"
            ui_kv "Domain" "*.$DOMAIN, $DOMAIN"
            ui_kv "Status" "$(cert_badge)"
            [[ -n "$CERT_SANS" ]] && ui_kv "Covers" "${CERT_SANS// /, }"
            [[ -n "$CERT_END" ]] && ui_kv "Expires" "$CERT_END"
            [[ -n "$CERT_DAYS" ]] && ui_kv "Days left" "$CERT_DAYS"
        fi

        ui_section "Cloudflare"
        if cloudflare_credentials_ok; then
            ui_kv "Credentials" "$(ui_badge ok "Configured")"
        else
            ui_kv "Credentials" "$(ui_badge err "Not configured")"
        fi

        ui_section "Tools"
        if command -v certbot >/dev/null 2>&1; then
            ui_kv "certbot" "$(ui_badge ok "Installed")"
        else
            ui_kv "certbot" "$(ui_badge off "Not installed (needed to issue and renew)")"
        fi
        echo

        ui_menu "Actions" q \
            "1|Certificate details|read-only: subject, names and dates" \
            "2|Issue certificate|asks Let's Encrypt for *.domain (changes certificates)" \
            "3|Renew certificates|certbot renew, then nginx reload (changes certificates)" \
            "4|Cloudflare credentials|saves the DNS API token (changes credentials)" \
            "5|Install TLS packages|apt install certbot and its Cloudflare plugin" \
            "q|Back|" || return
        # certbot and the credentials run outside ui_run (certbot stays
        # interruptible), so the dashboard is refreshed here instead.
        [[ "$UI_REPLY" == [2-5] ]] && DASH_TIME=0
        case "$UI_REPLY" in
            1) certificate_info ;;
            2) create_certificate ;;
            3) renew_certificate ;;
            4) create_cloudflare_token ;;
            5) install_tls ;;
            q) return ;;
        esac
    done
}
