#!/bin/bash
# ==========================================================
# NGINX Manager Pro - nginx config generator
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# NGINX CONFIG GENERATOR
# ==========================================================
create_snippets() {
    cat > "$SNIPPETS_DIR/proxy-common.conf" <<EOF
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
proxy_set_header X-Forwarded-Port \$server_port;
proxy_http_version 1.1;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection "upgrade";
EOF

    cat > "$SNIPPETS_DIR/tls-common.conf" <<EOF
ssl_protocols TLSv1.2 TLSv1.3;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
add_header Strict-Transport-Security "max-age=31536000" always;
EOF
}

generate_http() {
    cat > "$NGINX_AVAILABLE/$1.conf" <<EOF
# NGINX_MANAGER_TLS=http
server {
    listen 80;
    server_name $2;
    location / {
        proxy_pass http://$3;
        include snippets/proxy-common.conf;
    }
}
EOF
}

generate_https() {

    load_config

    [[ -z "$CERT_NAME" ]] && {
        msg_error "CERT_NAME missing"
        return 1
    }

    if ! domain_covered_by_wildcard "$2" "$DOMAIN"; then
        msg_error "Domain '$2' is not covered by the configured wildcard certificate (*.$DOMAIN / $DOMAIN)"
        return 1
    fi

    cat > "$NGINX_AVAILABLE/$1.conf" <<EOF
# NGINX_MANAGER_TLS=https
server {
    listen 80;
    server_name $2;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $2;
    ssl_certificate /etc/letsencrypt/live/$CERT_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CERT_NAME/privkey.pem;
    include snippets/tls-common.conf;
    location / {
        proxy_pass http://$3;
        include snippets/proxy-common.conf;
    }
}
EOF
}

generate_both() {

    load_config

    [[ -z "$CERT_NAME" ]] && {
        msg_error "CERT_NAME missing"
        return 1
    }

    if ! domain_covered_by_wildcard "$2" "$DOMAIN"; then
        msg_error "Domain '$2' is not covered by the configured wildcard certificate (*.$DOMAIN / $DOMAIN)"
        return 1
    fi

    cat > "$NGINX_AVAILABLE/$1.conf" <<EOF
# NGINX_MANAGER_TLS=both
server {
    listen 80;
    server_name $2;
    location / {
        proxy_pass http://$3;
        include snippets/proxy-common.conf;
    }
}
server {
    listen 443 ssl http2;
    server_name $2;
    ssl_certificate /etc/letsencrypt/live/$CERT_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CERT_NAME/privkey.pem;
    include snippets/tls-common.conf;
    location / {
        proxy_pass http://$3;
        include snippets/proxy-common.conf;
    }
}
EOF
}

generate_site() {
    load_config

    local name="$1"
    local domain backend tls
    domain=$(db_get "$name" domain)
    backend=$(db_get "$name" backend)
    tls=$(db_get "$name" tls)

    # Back up whatever is currently on disk before it gets overwritten, so
    # callers can roll back if the new config turns out to be invalid.
    backup_file "$NGINX_AVAILABLE/$name.conf"

    case "$tls" in
        http) generate_http "$name" "$domain" "$backend" ;;
        https) generate_https "$name" "$domain" "$backend" ;;
        both) generate_both "$name" "$domain" "$backend" ;;
        *)
            msg_error "Unknown TLS mode: $tls"
            return 1
            ;;
    esac
}

# Regenerates a single site's config, validates it if the site is enabled,
# and rolls back to the previous working config if validation fails.
# Returns 0 on success, 1 on failure (previous state is preserved either way).
regenerate_site_safe() {
    local name="$1"
    local was_enabled=0
    [[ -L "$NGINX_ENABLED/$name.conf" ]] && was_enabled=1

    if ! generate_site "$name"; then
        msg_error "[$name] Configuration generation failed"
        log "regenerate failed for $name: generate_site error"
        return 1
    fi

    if [[ "$was_enabled" -eq 0 ]]; then
        # Disabled site: new config written to sites-available only,
        # nothing live to validate or reload.
        return 0
    fi

    if test_nginx_config; then
        systemctl reload nginx
        msg_success "Nginx configuration valid"
        msg_success "Nginx reloaded"
        log "Regenerated and reloaded: $name"
        return 0
    fi

    msg_warning "New configuration invalid, restoring previous version..."
    log "regenerate failed for $name: nginx -t invalid, rolling back"

    if [[ -n "$LAST_BACKUP" ]]; then
        cp "$LAST_BACKUP" "$NGINX_AVAILABLE/$name.conf"
        if test_nginx_config; then
            systemctl reload nginx
            msg_warning "Previous configuration restored"
            log "Rollback restored previous config for $name"
        else
            msg_error "Restored configuration still fails validation for $name"
            log "Rollback FAILED validation for $name"
        fi
    else
        msg_error "No backup available to restore for $name"
        log "No backup available to roll back $name"
    fi

    return 1
}

regenerate_config() {
    local name="$1"
    confirm "Regenerate configuration for '$name'?" n || return
    echo
    if regenerate_site_safe "$name"; then
        msg_success "Configuration regenerated"
    else
        echo
        echo "The new configuration was rejected."
        echo "The previous configuration was restored if possible."
    fi
    pause
}

regenerate_all() {
    header
    echo -e "${BOLD}REGENERATE ALL${NC}"
    echo "──────────────────────────────────────────────────────"
    echo
    confirm "Regenerate configuration for all sites?" n || return
    echo
    msg_step "Regenerating nginx configs..."
    echo

    local ok=() failed=()
    while read -r name; do
        if regenerate_site_safe "$name"; then
            ok+=("$name")
        else
            failed+=("$name")
        fi
    done < <(jq -r 'keys[]' "$SITES_DB")

    echo
    echo -e "${BOLD}Regeneration complete${NC}"
    echo
    if ((${#ok[@]} > 0)); then
        echo -e "${GREEN}Successful:${NC}"
        printf "  %s\n" "${ok[@]}"
    fi
    if ((${#failed[@]} > 0)); then
        echo -e "${RED}Failed:${NC}"
        printf "  %s\n" "${failed[@]}"
    fi
    echo
    echo "${#ok[@]} succeeded, ${#failed[@]} failed"
    pause
}
