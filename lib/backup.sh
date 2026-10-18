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

    # <file>_<epoch>.bak, or <file>_<epoch>_<n>.bak if that name is taken
    # (several backups within one second). The name is claimed with
    # noclobber (O_EXCL), so an existing backup is never overwritten.
    local base="$BACKUP_DIR/$(basename "$1")_$(date +%s)" dest n=0
    dest="$base.bak"
    until (set -C; : > "$dest") 2>/dev/null; do
        if [[ ! -e "$dest" && ! -L "$dest" ]] || ((++n > 999)); then
            dest=""
            break
        fi
        dest="${base}_$n.bak"
    done

    if [[ -n "$dest" ]] && cp --preserve=mode "$1" "$dest"; then
        LAST_BACKUP="$dest"
        log "Backup created: $1 -> $dest"
        return 0
    else
        [[ -n "$dest" ]] && rm -f "$dest"   # the empty file claimed above
        msg_error "Failed to create backup of $1"
        log "Backup FAILED for: $1"
        return 1
    fi
}

# restore_backup <backup> <dest>
# Puts a backup back in place atomically: copy next to <dest>, then rename.
# Keeps <dest>'s mode and owner if it exists. <dest> is unchanged on failure.
restore_backup() {
    local backup="$1" dest="$2" tmp
    if tmp=$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX"); then
        if [[ -f "$dest" ]]; then
            chmod --reference="$dest" "$tmp"
            chown --reference="$dest" "$tmp" 2>/dev/null
        else
            chmod 644 "$tmp"
        fi
        cat "$backup" > "$tmp" && mv -f "$tmp" "$dest" && return 0
        rm -f "$tmp"
    fi
    msg_error "Failed to restore $dest from $backup"
    log "Restore FAILED: $backup -> $dest"
    return 1
}
