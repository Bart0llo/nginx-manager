#!/bin/bash
# ==========================================================
# NGINX Manager Pro - site operations
# Sourced by nginx-site.sh: defines functions only.
#
# Non-interactive site operations: every value is an argument, nothing is
# read from stdin. Prompts, confirmations and pauses belong to the callers
# in sites.sh. Status messages are printed as the operation runs.
#
# Return codes:
#   0  success
#   1  the operation failed (any rollback has already been attempted)
#   2  input rejected; nothing was changed
# ==========================================================

# ==========================================================
# SITE OPERATIONS
# ==========================================================

# Rejects a name that is not a managed site. Guards every operation that
# builds file paths from the name, so a bad name never reaches rm or ln.
# Imported sites are named after their config file (e.g. example.com), so
# this only checks that "<dir>/<name>.conf" stays inside <dir>; the strict
# validate_name rule applies to new sites in site_create.
require_site() {
    if [[ -z "$1" || "$1" == "." || "$1" == ".." || "$1" == */* ]]; then
        msg_error "Invalid site name: '$1'"
        return 1
    fi
    if ! db_exists "$1"; then
        msg_error "Site '$1' not found"
        return 1
    fi
}

# site_create <name> <domain> <backend> <tls>
# Saves a new, disabled site and generates its configuration. On failure
# the database entry is rolled back. Enabling is a separate step.
site_create() {
    local name="$1" domain="$2" backend="$3" tls="$4"

    if ! validate_name "$name"; then
        msg_error "Invalid name (letters, numbers, - and _ only)"
        return 2
    fi
    if db_exists "$name"; then
        msg_error "A site named '$name' already exists"
        return 2
    fi
    if ! validate_domain "$domain"; then
        msg_error "Invalid domain"
        return 2
    fi
    if ! validate_backend "$backend"; then
        msg_error "Invalid backend (expected host:port, 1-65535)"
        return 2
    fi
    if ! validate_tls "$tls"; then
        msg_error "Invalid TLS mode: $tls"
        return 2
    fi

    # enabled starts false; enable_site is the only thing allowed to flip it,
    # so the DB never claims "enabled" while no symlink actually exists.
    if ! db_save "$name" "$domain" "$backend" "$tls" false; then
        msg_error "Failed to save site to database"
        return 1
    fi

    if ! generate_site "$name"; then
        echo
        msg_error "Could not create site"
        echo
        echo "No changes were committed."
        if ! db_remove "$name"; then
            msg_warning "Failed to roll back database entry for $name - manual cleanup may be required"
        fi
        return 1
    fi
}

# site_update <name> <domain> <backend> <tls>
# Changes an existing site's settings and regenerates its configuration.
# An enabled site is validated with nginx -t and reloaded; if the new
# configuration is invalid the previous one is restored.
site_update() {
    local name="$1" domain="$2" backend="$3" tls="$4"

    require_site "$name" || return 2
    if ! validate_domain "$domain"; then
        msg_error "Invalid domain"
        return 2
    fi
    if ! validate_backend "$backend"; then
        msg_error "Invalid backend (expected host:port, 1-65535)"
        return 2
    fi
    if ! validate_tls "$tls"; then
        msg_error "Invalid TLS mode: $tls"
        return 2
    fi

    local old_domain old_backend old_tls old_enabled
    old_domain=$(db_get "$name" domain)
    old_backend=$(db_get "$name" backend)
    old_tls=$(db_get "$name" tls)
    old_enabled=$(db_get "$name" enabled)

    # Preserve the site's actual current enabled state - editing must never
    # silently flip a disabled site to enabled.
    if ! db_save "$name" "$domain" "$backend" "$tls" "$old_enabled"; then
        msg_error "Failed to update database, aborting edit"
        return 1
    fi

    if ! generate_site "$name"; then
        msg_error "Could not generate configuration, restoring previous settings"
        db_save "$name" "$old_domain" "$old_backend" "$old_tls" "$old_enabled"
        return 1
    fi

    if [[ "$old_enabled" != "true" ]]; then
        echo
        msg_success "Site updated (disabled, not reloaded)"
        return 0
    fi

    echo
    if test_nginx_config; then
        systemctl reload nginx
        msg_success "Site updated"
        msg_success "Nginx configuration valid"
        msg_success "Nginx reloaded"
        log "Site edited: $name"
        return 0
    fi

    echo
    msg_error "New configuration invalid"
    echo
    echo "Restoring previous configuration..."
    if [[ -n "$LAST_BACKUP" ]]; then
        cp "$LAST_BACKUP" "$NGINX_AVAILABLE/$name.conf"
    fi
    db_save "$name" "$old_domain" "$old_backend" "$old_tls" "$old_enabled"

    if test_nginx_config; then
        systemctl reload nginx
        msg_warning "Previous configuration restored and reloaded"
        log "Edit rolled back for $name after failed validation"
    else
        msg_error "Restored configuration still fails validation for $name - manual intervention required"
        log "Rollback FAILED validation for $name after edit"
    fi
    return 1
}

# site_delete <name>
# Removes the site's configuration, symlink and database entry (keeping a
# backup of the configuration) and reloads nginx. Asks no confirmation:
# callers must confirm first. Returns 1 if the site was removed but the
# database update or the nginx reload failed.
site_delete() {
    local name="$1"
    require_site "$name" || return 2

    local rc=0
    backup_file "$NGINX_AVAILABLE/$name.conf"
    rm -f "$NGINX_AVAILABLE/$name.conf" "$NGINX_ENABLED/$name.conf"
    if ! db_remove "$name"; then
        msg_warning "Failed to remove $name from database"
        rc=1
    fi
    reload_nginx || rc=1

    echo
    msg_success "Site '$name' deleted"
    return $rc
}

# site_import <config-file>
# Adds an existing nginx config as a disabled site, named after the file.
# The config file itself is not modified. Returns 2 (silently) when the
# file is skipped: missing, already managed, or without a server_name.
site_import() {
    local file="$1"
    [[ -f "$file" ]] || return 2

    local name domain backend tls
    name=$(basename "$file" .conf)
    db_exists "$name" && return 2
    domain=$(grep server_name "$file" | head -1 | awk '{print $2}' | sed 's/;//')
    backend=$(grep proxy_pass "$file" | head -1 | awk '{print $2}' | sed 's/http:\/\///' | sed 's/;//')
    [[ -z "$domain" ]] && return 2
    [[ -z "$backend" ]] && backend="unknown"
    tls="http"
    grep -q "listen 443" "$file" && tls="https"

    db_save "$name" "$domain" "$backend" "$tls" false || return 1
    msg_success "Imported: $name"
}
