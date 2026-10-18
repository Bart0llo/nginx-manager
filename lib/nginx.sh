#!/bin/bash
# ==========================================================
# NGINX Manager Pro - nginx control
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# NGINX CONTROL
# ==========================================================
test_nginx_config() {
    nginx -t
}

reload_nginx() {
    msg_step "Testing nginx config..."
    if test_nginx_config; then
        systemctl reload nginx
        msg_success "Nginx reload OK"
        log "nginx reload OK"
        return 0
    else
        msg_error "Nginx config invalid"
        log "nginx config failed"
        return 1
    fi
}

# Transactionally enables a site: symlink -> test -> commit-or-rollback.
# Leaves the previous working state intact if validation fails.
enable_site() {
    local name="$1"
    local conf="$NGINX_AVAILABLE/$name.conf"
    local link="$NGINX_ENABLED/$name.conf"

    if [[ ! -f "$conf" ]]; then
        msg_error "Cannot enable '$name': configuration file missing"
        log "enable_site failed for $name: missing config file"
        return 1
    fi

    local had_link=0
    [[ -L "$link" ]] && had_link=1

    ln -sf "$conf" "$link"

    msg_step "Testing nginx config..."
    if test_nginx_config; then
        if ! db_update_enabled "$name" true; then
            msg_warning "Nginx enabled but failed to update database state for $name"
            log "enable_site: db update failed for $name after successful enable"
        fi
        systemctl reload nginx
        msg_success "Site enabled"
        msg_success "Nginx configuration valid"
        msg_success "Nginx reloaded"
        log "Site enabled: $name"
        return 0
    else
        # Only remove the symlink if we created it; never destroy a
        # pre-existing link that wasn't ours to begin with.
        if [[ "$had_link" -eq 0 ]]; then
            rm -f "$link"
        fi
        echo
        msg_error "Failed to enable site"
        echo
        echo "Nginx configuration test failed."
        echo "The site was NOT enabled."
        echo "No changes were committed."
        log "enable_site failed for $name: nginx -t invalid, rolled back"
        return 1
    fi
}

# Disabling can only move nginx toward a valid state, so it always proceeds;
# it still reports (but does not hide) unrelated pre-existing config errors.
disable_site() {
    local name="$1"
    local link="$NGINX_ENABLED/$name.conf"

    rm -f "$link"

    if ! db_update_enabled "$name" false; then
        msg_warning "Failed to update database state for $name"
        log "disable_site: db update failed for $name"
    fi

    msg_step "Testing nginx config..."
    if test_nginx_config; then
        systemctl reload nginx
        msg_success "Site disabled"
        msg_success "Nginx configuration valid"
        msg_success "Nginx reloaded"
        log "Site disabled: $name"
        return 0
    else
        echo
        msg_warning "Site disabled, but nginx configuration is still invalid"
        echo
        echo "This is likely unrelated to '$name' - check other sites."
        log "disable_site: nginx -t invalid after disabling $name (possibly unrelated)"
        return 1
    fi
}
