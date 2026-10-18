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
#   2  input rejected (also by a plugin's validate-site); nothing was changed
# Plugin informational hooks (site-applied, site-deleted) run after a
# success; their failures are reported but do not change the result.
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
    if ! plugin_run_hook validate-site "$name" "$(plugin_site_entry "$name" "$domain" "$backend" "$tls")"; then
        msg_error "Site rejected by a plugin; nothing was changed"
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
    plugin_notify site-applied "$name"
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
    if ! plugin_run_hook validate-site "$name" "$(plugin_site_entry "$name" "$domain" "$backend" "$tls")"; then
        msg_error "Change rejected by a plugin; nothing was changed"
        return 2
    fi

    local old_domain old_backend old_tls old_enabled
    old_domain=$(db_get "$name" domain)
    old_backend=$(db_get "$name" backend)
    old_tls=$(db_get "$name" tls)
    # The symlink, not the db flag, says whether the site is live (and so
    # whether the new config must pass nginx -t); the db is corrected to it.
    old_enabled=$(site_enabled_state "$name") || return 1
    sync_enabled_state "$name"

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
        plugin_notify site-applied "$name"
        return 0
    fi

    echo
    if test_nginx_config; then
        if ! reload_nginx_service; then
            msg_warning "Site updated, but nginx was not reloaded - the change is not live yet"
            log "Site edited: $name (nginx reload failed)"
            return 1
        fi
        msg_success "Site updated"
        msg_success "Nginx configuration valid"
        msg_success "Nginx reloaded"
        log "Site edited: $name"
        plugin_notify site-applied "$name"
        return 0
    fi

    echo
    msg_error "New configuration invalid"
    echo
    echo "Restoring previous configuration..."
    db_save "$name" "$old_domain" "$old_backend" "$old_tls" "$old_enabled"
    if [[ -n "$LAST_BACKUP" ]] && ! restore_backup "$LAST_BACKUP" "$NGINX_AVAILABLE/$name.conf"; then
        msg_error "The invalid new configuration is still in $NGINX_AVAILABLE/$name.conf; nginx was not reloaded - fix it manually (backup: $LAST_BACKUP)"
        log "Rollback FAILED for $name after edit: backup could not be restored"
        return 1
    fi

    if test_nginx_config; then
        if reload_nginx_service; then
            msg_warning "Previous configuration restored and reloaded"
            log "Edit rolled back for $name after failed validation"
        else
            msg_warning "Previous configuration restored, but nginx was not reloaded"
            log "Edit rolled back for $name after failed validation (nginx reload failed)"
        fi
    else
        msg_error "Restored configuration still fails validation for $name - manual intervention required"
        log "Rollback FAILED validation for $name after edit"
    fi
    return 1
}

# site_delete <name>
# Removes the site's configuration, symlink and database entry (keeping a
# backup of the configuration) and reloads nginx. Asks no confirmation:
# callers must confirm first. Nothing is removed unless the backup succeeds.
# Returns 1 if the delete was aborted, or if a later step failed (reported
# as a partial delete).
site_delete() {
    local name="$1"
    require_site "$name" || return 2
    local conf="$NGINX_AVAILABLE/$name.conf" link="$NGINX_ENABLED/$name.conf"

    # Only a symlink is removed from sites-enabled; anything else stops here.
    site_enabled_state "$name" >/dev/null || return 1
    # site-deleted gets the entry as it was, plugin data included.
    local entry
    entry=$(plugin_site_entry "$name")

    if ! backup_file "$conf"; then
        echo
        msg_error "Site '$name' was NOT deleted: its configuration could not be backed up"
        log "site_delete aborted for $name: backup failed"
        return 1
    fi

    # Disable first: a symlink left pointing at a removed config would
    # break nginx -t for every site.
    if ! rm -f "$link"; then
        echo
        msg_error "Site '$name' was NOT deleted: could not remove $link"
        log "site_delete aborted for $name: could not remove $link"
        return 1
    fi

    local rc=0 removed=0
    if ! rm -f "$conf"; then
        msg_warning "Failed to remove $conf"
        rc=1
    elif ! db_remove "$name"; then
        msg_warning "Failed to remove $name from database"
        rc=1
    else
        removed=1
    fi
    reload_nginx || rc=1

    echo
    if ((rc == 0)); then
        msg_success "Site '$name' deleted"
        log "Site deleted: $name"
    else
        msg_warning "Site '$name' was only partly deleted - see the messages above"
        log "Site partly deleted: $name"
    fi
    # Once the entry is gone, plugins clean up after it (even if the reload
    # failed).
    ((removed)) && plugin_notify site-deleted "$name" "$entry"
    return $rc
}

# site_import <config-file>
# Adds an existing nginx config as a site, named after the file, recording
# whether it is currently enabled. The config file itself is not modified.
# Returns 2 when the file is skipped: silently if it is missing, already
# managed or has no server_name; with a reason if its server_name or
# proxy_pass cannot be expressed as a managed site (domain + host:port).
site_import() {
    local file="$1"
    [[ -f "$file" ]] || return 2

    local name domain proxy backend tls statements
    name=$(basename "$file" .conf)
    db_exists "$name" && return 2
    statements=$(conf_statements "$file")
    domain=$(conf_value "$file" server_name)
    [[ -z "$domain" ]] && return 2

    if ! validate_domain "$domain"; then
        msg_warning "Skipped $name: server_name '$domain' is not a single domain"
        return 2
    fi
    proxy=$(conf_value "$file" proxy_pass)
    if [[ -z "$proxy" ]]; then
        msg_warning "Skipped $name: no proxy_pass backend found"
        return 2
    fi
    backend="${proxy#http://}"
    if [[ "$backend" == "$proxy" ]] || ! validate_backend "$backend"; then
        msg_warning "Skipped $name: backend '$proxy' is not http://host:port"
        return 2
    fi

    # HTTPS plus a plain-HTTP server that does not just redirect = BOTH.
    tls="http"
    if grep -qE '^listen ([^ ]*:)?443( |$)' <<< "$statements"; then
        tls="https"
        if grep -qE '^listen ([^ ]*:)?80( |$)' <<< "$statements" \
            && ! grep -qE '^return 30[18] https://' <<< "$statements"; then
            tls="both"
        fi
    fi

    # Record whether the site is live; importing never enables or disables.
    local enabled
    enabled=$(site_enabled_state "$name") || return 1

    db_save "$name" "$domain" "$backend" "$tls" "$enabled" || return 1
    msg_success "Imported: $name"

    local lost
    lost=$(conf_unsupported_statements "$file")
    if [[ -n "$lost" ]]; then
        msg_warning "$name has directives NGINX Manager cannot reproduce; edit and regenerate will refuse to replace its config:"
        sed 's/^/    /' <<< "$lost"
    fi
}
