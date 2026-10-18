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

# Atomically rewrites sites.json through a jq program: the result goes to a
# temp file, is checked to be valid JSON, and only then replaces the db.
# The db is left untouched on any failure.
#   db_write <caller> <site> <jq args...>   (caller/site only label errors)
db_write() {
    local caller="$1" name="$2"
    shift 2
    local tmp
    tmp=$(mktemp -p "$MANAGER_DIR") || {
        msg_error "Failed to create temporary database file"
        log "$caller failed: could not create temp file"
        return 1
    }

    if ! jq "$@" "$SITES_DB" > "$tmp"; then
        msg_error "Failed to update database (jq error)"
        log "$caller failed: jq error for site $name"
        rm -f "$tmp"
        return 1
    fi

    if ! jq empty "$tmp" >/dev/null 2>&1; then
        msg_error "Failed to update database (invalid JSON produced)"
        log "$caller failed: invalid JSON produced for site $name"
        rm -f "$tmp"
        return 1
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$SITES_DB"
}

db_save() {
    local name="$1" domain="$2" backend="$3" tls="$4" enabled="$5"
    db_write db_save "$name" \
        --arg name "$name" --arg domain "$domain" --arg backend "$backend" \
        --arg tls "$tls" --arg enabled "$enabled" '
        .[$name]={domain:$domain,backend:$backend,tls:$tls,
        enabled:($enabled=="true"),created:(now|todate)}'
}

db_update_enabled() {
    local name="$1" enabled="$2"
    db_write db_update_enabled "$name" \
        --arg name "$name" --arg enabled "$enabled" \
        '.[$name].enabled=($enabled=="true")'
}

db_remove() {
    local name="$1"
    db_write db_remove "$name" --arg name "$name" 'del(.[$name])'
}
