#!/bin/bash
# ==========================================================
# NGINX Manager Pro - site database
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# DATABASE
# ==========================================================
create_database() {
    [[ ! -f "$SITES_DB" ]] && echo "{}" > "$SITES_DB" && chmod 600 "$SITES_DB"
}

db_get() {
    jq -r --arg name "$1" --arg field "$2" '.[$name][$field]' "$SITES_DB"
}

db_exists() {
    jq -e --arg name "$1" '.[$name]' "$SITES_DB" >/dev/null
}

db_save() {
    local name="$1" domain="$2" backend="$3" tls="$4" enabled="$5"
    local tmp
    tmp=$(mktemp -p "$MANAGER_DIR") || {
        msg_error "Failed to create temporary database file"
        log "db_save failed: could not create temp file"
        return 1
    }

    if ! jq --arg name "$name" --arg domain "$domain" --arg backend "$backend" \
            --arg tls "$tls" --arg enabled "$enabled" '
            .[$name]={domain:$domain,backend:$backend,tls:$tls,
            enabled:($enabled=="true"),created:(now|todate)}' \
            "$SITES_DB" > "$tmp"; then
        msg_error "Failed to update database (jq error)"
        log "db_save failed: jq error for site $name"
        rm -f "$tmp"
        return 1
    fi

    if ! jq empty "$tmp" >/dev/null 2>&1; then
        msg_error "Failed to update database (invalid JSON produced)"
        log "db_save failed: invalid JSON produced for site $name"
        rm -f "$tmp"
        return 1
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$SITES_DB"
}

db_update_enabled() {
    local name="$1" enabled="$2"
    local tmp
    tmp=$(mktemp -p "$MANAGER_DIR") || {
        msg_error "Failed to create temporary database file"
        log "db_update_enabled failed: could not create temp file"
        return 1
    }

    if ! jq --arg name "$name" --arg enabled "$enabled" \
            '.[$name].enabled=($enabled=="true")' \
            "$SITES_DB" > "$tmp"; then
        msg_error "Failed to update database (jq error)"
        log "db_update_enabled failed: jq error for site $name"
        rm -f "$tmp"
        return 1
    fi

    if ! jq empty "$tmp" >/dev/null 2>&1; then
        msg_error "Failed to update database (invalid JSON produced)"
        log "db_update_enabled failed: invalid JSON produced for site $name"
        rm -f "$tmp"
        return 1
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$SITES_DB"
}

db_remove() {
    local name="$1"
    local tmp
    tmp=$(mktemp -p "$MANAGER_DIR") || {
        msg_error "Failed to create temporary database file"
        log "db_remove failed: could not create temp file"
        return 1
    }

    if ! jq --arg name "$name" 'del(.[$name])' "$SITES_DB" > "$tmp"; then
        msg_error "Failed to update database (jq error)"
        log "db_remove failed: jq error for site $name"
        rm -f "$tmp"
        return 1
    fi

    if ! jq empty "$tmp" >/dev/null 2>&1; then
        msg_error "Failed to update database (invalid JSON produced)"
        log "db_remove failed: invalid JSON produced for site $name"
        rm -f "$tmp"
        return 1
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$SITES_DB"
}
