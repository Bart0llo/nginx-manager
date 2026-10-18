#!/bin/bash
# ==========================================================
# NGINX Manager Pro - nginx config generator
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# NGINX CONFIG GENERATOR
# ==========================================================
# install_snippet <dest> < content
# Writes one managed snippet. A file that already has the content is left
# alone and a missing one is created. A different (customised) one is backed
# up and then atomically replaced, keeping its mode and owner. Anything
# other than a regular file is never touched. On any failure the existing
# file stays as it was.
# Returns 0 unchanged/created, 1 failed, 3 replaced a customised file.
install_snippet() {
    local dest="$1" content
    content=$(cat)

    if [[ -L "$dest" || ( -e "$dest" && ! -f "$dest" ) ]]; then
        msg_warning "Snippet $dest is not a regular file; left unchanged"
        log "Snippet not updated: $dest is not a regular file"
        return 1
    fi
    if [[ -f "$dest" ]] && printf '%s\n' "$content" | cmp -s - "$dest"; then
        return 0
    fi

    local tmp
    if ! tmp=$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX") \
        || ! printf '%s\n' "$content" > "$tmp"; then
        [[ -n "$tmp" ]] && rm -f "$tmp"
        msg_error "Failed to write snippet $dest"
        log "Snippet not updated: could not write a temp file for $dest"
        return 1
    fi

    local replacing=0
    if [[ -f "$dest" ]]; then
        replacing=1
        if ! backup_file "$dest"; then
            rm -f "$tmp"
            msg_warning "Snippet $dest differs from the managed version but could not be backed up; left unchanged"
            log "Snippet not updated: backup of $dest failed"
            return 1
        fi
        chmod --reference="$dest" "$tmp"
        chown --reference="$dest" "$tmp" 2>/dev/null
    else
        chmod 644 "$tmp"
    fi

    if ! mv -f "$tmp" "$dest"; then
        rm -f "$tmp"
        msg_error "Failed to replace snippet $dest"
        log "Snippet not updated: could not move the new version into place for $dest"
        return 1
    fi

    if ((replacing)); then
        msg_warning "Snippet $dest differed from the managed version and was replaced (backup: $LAST_BACKUP)"
        log "Snippet replaced: $dest (backup: $LAST_BACKUP)"
        return 3
    fi
}

# Returns 1 if any snippet could not be written.
create_snippets() {
    local rc=0 replaced=0 r

    install_snippet "$SNIPPETS_DIR/proxy-common.conf" <<EOF
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
proxy_set_header X-Forwarded-Port \$server_port;
proxy_http_version 1.1;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection "upgrade";
EOF
    r=$?; ((r == 1)) && rc=1; ((r == 3)) && replaced=1

    install_snippet "$SNIPPETS_DIR/tls-common.conf" <<EOF
ssl_protocols TLSv1.2 TLSv1.3;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
add_header Strict-Transport-Security "max-age=31536000" always;
EOF
    r=$?; ((r == 1)) && rc=1; ((r == 3)) && replaced=1

    # Start-up clears the screen next; let an interactive user read this.
    if ((rc || replaced)) && [[ -t 0 ]]; then
        pause
    fi
    return $rc
}

generate_http() {
    cat > "$1" <<EOF
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

    cat > "$1" <<EOF
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

    cat > "$1" <<EOF
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

# ==========================================================
# CONFIGS NOT WRITTEN BY THE MANAGER (imported)
# ==========================================================
# Prints a config's statements one per line: comments dropped, whitespace
# collapsed, split at ";", "{" and "}" ("location / {" -> "location /").
# Enough to read simple proxy configs; this is not an nginx parser.
conf_statements() {
    sed 's/#.*//' "$1" | tr '\n' ' ' | tr ';{}' '\n\n\n' \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | grep -v '^$'
}

# Prints the first argument of the first <directive> statement.
conf_value() { # file directive
    conf_statements "$1" | sed -n "s/^$2 \([^ ]*\).*/\1/p" | head -1
}

# Prints the statements of a config that the templates cannot reproduce,
# i.e. what regenerating it would lose. Nothing printed = safe to regenerate.
conf_unsupported_statements() {
    load_config >/dev/null 2>&1
    local live="/etc/letsencrypt/live/$CERT_NAME" s server_name="" proxy=""
    local servers=0 locations=0 redirects=0
    while IFS= read -r s; do
        case "$s" in
            server) ((servers++)); continue ;;
            "location /") ((locations++)); continue ;;
            'return 301 https://$host$request_uri') ((redirects++)); continue ;;
            "listen 80"|"listen 443 ssl"|"listen 443 ssl http2") continue ;;
            "include snippets/proxy-common.conf"|"include snippets/tls-common.conf") continue ;;
            "ssl_certificate $live/fullchain.pem"|"ssl_certificate_key $live/privkey.pem")
                [[ -n "$CERT_NAME" ]] && continue ;;
            "server_name "*)
                # One plain domain, the same in every server block. Quotes are
                # refused: comment stripping may have cut a quoted value short.
                if validate_domain "${s#server_name }" && [[ -z "$server_name" || "$s" == "$server_name" ]]; then
                    server_name="$s"
                    continue
                fi
                ;;
            "proxy_pass http://"*)
                # One host:port upstream, the same everywhere.
                if validate_backend "${s#proxy_pass http://}" && [[ -z "$proxy" || "$s" == "$proxy" ]]; then
                    proxy="$s"
                    continue
                fi
                ;;
        esac
        echo "$s"
    done < <(conf_statements "$1")

    # Statements are read without their block structure, so also check the
    # layout: in every template each server block is either a "location /"
    # proxy or the HTTPS redirect.
    if ((servers != locations + redirects)); then
        echo "($servers server blocks, but only $((locations + redirects)) with a 'location /' proxy or an HTTPS redirect)"
    fi
}

generate_site() {
    load_config

    local name="$1"
    local domain backend tls
    domain=$(db_get "$name" domain)
    backend=$(db_get "$name" backend)
    tls=$(db_get "$name" tls)

    local conf="$NGINX_AVAILABLE/$name.conf"
    LAST_BACKUP=""

    if [[ -L "$conf" || ( -e "$conf" && ! -f "$conf" ) ]]; then
        msg_error "$conf is not a regular file; not replaced"
        log "generate_site refused for $name: $conf is not a regular file"
        return 1
    fi

    # A config without the manager's header was written by hand (imported).
    # Replacing it with the template must not throw away what it adds.
    if [[ -f "$conf" ]] && ! head -1 "$conf" | grep -q '^# NGINX_MANAGER_TLS='; then
        local lost
        lost=$(conf_unsupported_statements "$conf")
        if [[ -n "$lost" ]]; then
            msg_error "$conf was not generated by NGINX Manager and has directives regeneration would discard:"
            sed 's/^/    /' <<< "$lost"
            echo "Not regenerated. Edit the file by hand, or delete the site and add it again."
            log "generate_site refused for $name: hand-written directives would be lost"
            return 1
        fi
    fi

    # Generate next to the target (same filesystem), so the final mv is an
    # atomic rename. The dot-name keeps it out of the *.conf import glob.
    local tmp
    tmp=$(mktemp "$NGINX_AVAILABLE/.$name.conf.XXXXXX") || {
        msg_error "Failed to write configuration $conf"
        log "generate_site failed for $name: could not create temp file"
        return 1
    }

    local rc=0
    case "$tls" in
        http) generate_http "$tmp" "$domain" "$backend" || rc=1 ;;
        https) generate_https "$tmp" "$domain" "$backend" || rc=1 ;;
        both) generate_both "$tmp" "$domain" "$backend" || rc=1 ;;
        *)
            msg_error "Unknown TLS mode: $tls"
            rc=1
            ;;
    esac
    if ((rc)); then
        rm -f "$tmp"
        return 1
    fi

    # Back up whatever is currently on disk before it gets replaced, so
    # callers can roll back if the new config turns out to be invalid.
    if ! backup_file "$conf"; then
        rm -f "$tmp"
        msg_error "Configuration for $name not replaced"
        return 1
    fi

    if [[ -f "$conf" ]]; then
        chmod --reference="$conf" "$tmp"
        chown --reference="$conf" "$tmp" 2>/dev/null
    else
        chmod 644 "$tmp"
    fi
    if ! mv -f "$tmp" "$conf"; then
        rm -f "$tmp"
        msg_error "Failed to write configuration $conf"
        log "generate_site failed for $name: could not move the new config into place"
        return 1
    fi
}

# Regenerates a single site's config, validates it if the site is enabled,
# and rolls back to the previous working config if validation fails.
# Returns 0 on success, 1 on failure (previous state is preserved either way),
# 3 if the new config is valid and in place but the nginx reload failed.
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
        msg_success "Nginx configuration valid"
        if ! reload_nginx_service; then
            log "Regenerated $name, but nginx reload failed"
            return 3
        fi
        msg_success "Nginx reloaded"
        log "Regenerated and reloaded: $name"
        return 0
    fi

    msg_warning "New configuration invalid, restoring previous version..."
    log "regenerate failed for $name: nginx -t invalid, rolling back"

    if [[ -z "$LAST_BACKUP" ]]; then
        msg_error "No backup available to restore for $name"
        log "No backup available to roll back $name"
    elif restore_backup "$LAST_BACKUP" "$NGINX_AVAILABLE/$name.conf"; then
        if test_nginx_config; then
            reload_nginx_service
            msg_warning "Previous configuration restored"
            log "Rollback restored previous config for $name"
        else
            msg_error "Restored configuration still fails validation for $name"
            log "Rollback FAILED validation for $name"
        fi
    else
        msg_error "The invalid new configuration is still in $NGINX_AVAILABLE/$name.conf; nginx was not reloaded - fix it manually (backup: $LAST_BACKUP)"
    fi

    return 1
}

regenerate_config() {
    local name="$1"
    confirm "Regenerate configuration for '$name'?" n || return
    echo
    regenerate_site_safe "$name"
    local rc=$?
    if ((rc == 0)); then
        msg_success "Configuration regenerated"
    elif ((rc == 3)); then
        echo
        echo "The configuration was regenerated, but nginx was not reloaded."
        echo "The change is not live yet."
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
