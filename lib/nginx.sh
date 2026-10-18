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

# Reloads the nginx service. Reports and logs a failure and returns
# systemctl's exit status, so callers never claim a reload that failed.
reload_nginx_service() {
    systemctl reload nginx
    local rc=$?
    if ((rc != 0)); then
        msg_error "Nginx reload failed (systemctl exit $rc)"
        log "nginx reload failed (systemctl exit $rc)"
    fi
    return $rc
}

reload_nginx() {
    msg_step "Testing nginx config..."
    if test_nginx_config; then
        reload_nginx_service || return 1
        msg_success "Nginx reload OK"
        log "nginx reload OK"
        return 0
    else
        msg_error "Nginx config invalid"
        log "nginx config failed"
        return 1
    fi
}

# The sites-enabled symlink is the source of truth for whether a site is
# enabled. Prints "true" (symlink present) or "false" (nothing there).
# Returns 1, printing nothing, when something other than a symlink is in
# the way: that is never created, replaced or removed by the manager.
site_enabled_state() {
    local link="$NGINX_ENABLED/$1.conf"
    if [[ -L "$link" ]]; then
        echo true
    elif [[ -e "$link" ]]; then
        msg_error "$link is not a symlink; leaving it alone" >&2
        log "Refused to manage $link: not a symlink"
        return 1
    else
        echo false
    fi
}

# Brings the database's enabled flag in line with the symlink, logging any
# correction. Never touches the symlink. Returns 1 if the state is unknown.
sync_enabled_state() {
    local name="$1" actual recorded
    actual=$(site_enabled_state "$name") || return 1
    recorded=$(db_get "$name" enabled)
    [[ "$recorded" == "$actual" ]] && return 0
    if db_update_enabled "$name" "$actual"; then
        msg_warning "Database state for '$name' was out of date (enabled: $recorded -> $actual); corrected"
        log "State corrected for $name: db enabled=$recorded, symlink says $actual"
    fi
}

# Transactionally enables a site: symlink -> test -> commit-or-rollback.
# Leaves the previous working state intact if validation fails.
# Returns 2 without changes if the name is not a managed site.
enable_site() {
    local name="$1"
    require_site "$name" || return 2
    local conf="$NGINX_AVAILABLE/$name.conf"
    local link="$NGINX_ENABLED/$name.conf"

    if [[ ! -f "$conf" ]]; then
        msg_error "Cannot enable '$name': configuration file missing"
        log "enable_site failed for $name: missing config file"
        return 1
    fi

    local had_link
    had_link=$(site_enabled_state "$name") || return 1
    if [[ "$had_link" == true ]]; then
        if [[ "$(readlink -f "$link")" != "$(readlink -f "$conf")" ]]; then
            msg_error "Cannot enable '$name': $link points to $(readlink "$link"); leaving it alone"
            log "enable_site refused for $name: $link points elsewhere"
            return 1
        fi
    else
        ln -s "$conf" "$link"
    fi

    msg_step "Testing nginx config..."
    if test_nginx_config; then
        if ! db_update_enabled "$name" true; then
            msg_warning "Nginx enabled but failed to update database state for $name"
            log "enable_site: db update failed for $name after successful enable"
        fi
        if ! reload_nginx_service; then
            msg_warning "Site enabled, but nginx was not reloaded - the change is not live yet"
            log "Site enabled: $name (nginx reload failed)"
            return 1
        fi
        msg_success "Site enabled"
        msg_success "Nginx configuration valid"
        msg_success "Nginx reloaded"
        log "Site enabled: $name"
        plugin_notify site-applied "$name"
        return 0
    else
        # Only remove the symlink if we created it; never destroy a
        # pre-existing link that wasn't ours to begin with.
        if [[ "$had_link" == false ]]; then
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
# Returns 2 without changes if the name is not a managed site.
disable_site() {
    local name="$1"
    require_site "$name" || return 2
    local link="$NGINX_ENABLED/$name.conf"

    site_enabled_state "$name" >/dev/null || return 1
    rm -f "$link"

    if ! db_update_enabled "$name" false; then
        msg_warning "Failed to update database state for $name"
        log "disable_site: db update failed for $name"
    fi

    msg_step "Testing nginx config..."
    if test_nginx_config; then
        if ! reload_nginx_service; then
            msg_warning "Site disabled, but nginx was not reloaded - the change is not live yet"
            log "Site disabled: $name (nginx reload failed)"
            return 1
        fi
        msg_success "Site disabled"
        msg_success "Nginx configuration valid"
        msg_success "Nginx reloaded"
        log "Site disabled: $name"
        plugin_notify site-applied "$name"
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
