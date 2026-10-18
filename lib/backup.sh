#!/bin/bash
# ==========================================================
# NGINX Manager Pro - backups
# Sourced by nginx-site.sh: defines state and functions only.
# ==========================================================

# ==========================================================
# BACKUP
# ==========================================================
LAST_BACKUP=""

backup_file() {
    LAST_BACKUP=""
    [[ -f "$1" ]] || return 0

    local dest="$BACKUP_DIR/$(basename "$1")_$(date +%s).bak"
    if cp "$1" "$dest"; then
        LAST_BACKUP="$dest"
        log "Backup created: $1 -> $dest"
        return 0
    else
        msg_error "Failed to create backup of $1"
        log "Backup FAILED for: $1"
        return 1
    fi
}
