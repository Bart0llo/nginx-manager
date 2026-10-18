#!/bin/bash
# ==========================================================
# NGINX MANAGER PRO v3
# Debian / Ubuntu
# Nginx + Certbot + Cloudflare DNS
# ==========================================================

# ==========================================================
# PATHS
# ==========================================================
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
MANAGER_DIR="/etc/nginx-manager"
CONFIG_FILE="$MANAGER_DIR/config.conf"
SITES_DB="$MANAGER_DIR/sites.json"
BACKUP_DIR="$MANAGER_DIR/backups"
LOG_FILE="/var/log/nginx-manager/manager.log"
LOCK_FILE="/run/lock/nginx-manager.lock"
SNIPPETS_DIR="/etc/nginx/snippets"
CF_DIR="/etc/nginx-manager/secrets"
CF_FILE="$CF_DIR/cloudflare.ini"

# ==========================================================
# COLORS
# ==========================================================
BLUE=$'\033[1;34m'
GREEN=$'\033[1;32m'
RED=$'\033[1;31m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[1;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'
BOLD=$'\033[1m'

# ==========================================================
# ROOT CHECK
# ==========================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}Run as root${NC}"
    exec sudo "$0" "$@"
fi

# ==========================================================
# CORE DEPENDENCY CHECK
# ==========================================================
# jq and nginx are required for the manager to function at all
# (site database + nginx control). Certbot/OpenSSL are only needed
# for TLS features and are intentionally NOT required to start.
check_core_dependencies() {
    local missing=()
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v nginx >/dev/null 2>&1 || missing+=("nginx")

    if ((${#missing[@]} > 0)); then
        echo -e "${RED}${BOLD}Missing required dependency: ${missing[*]}${NC}"
        echo "NGINX Manager requires 'jq' and 'nginx' to manage sites."
        echo "Install them, for example:"
        echo "  apt update && apt install -y jq nginx"
        echo "(Certbot/OpenSSL are only needed for TLS features and are not required here.)"
        return 1
    fi
    return 0
}

check_core_dependencies || exit 1

require_certbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        echo -e "${RED}Certbot is not installed. Run TLS Manager -> Install TLS dependencies.${NC}"
        return 1
    fi
    return 0
}

require_openssl() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}OpenSSL is not installed. Run TLS Manager -> Install TLS dependencies.${NC}"
        return 1
    fi
    return 0
}

# ==========================================================
# DIRECTORIES
# ==========================================================
mkdir -p "$MANAGER_DIR" "$BACKUP_DIR" "$SNIPPETS_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"

# ==========================================================
# LOCK
# ==========================================================
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo -e "${YELLOW}Manager already running${NC}"
    exit 1
}

# ==========================================================
# LOG
# ==========================================================
log() {
    echo "$(date '+%F %T') $1" >> "$LOG_FILE"
}

# ==========================================================
# UI HELPERS / MESSAGING
# ==========================================================
pause() {
    echo
    read -n1 -s -r -p "$(echo -e "${GRAY}Press any key...${NC}")"
    echo
}

header() {
    clear
    echo -e "${BLUE}${BOLD}NGINX MANAGER PRO${NC}"
    echo "──────────────────────────────────────────────────────"
}

msg_success() { echo -e "${GREEN}✓ $1${NC}"; }
msg_warning() { echo -e "${YELLOW}! $1${NC}"; }
msg_error()   { echo -e "${RED}✗ $1${NC}"; }
msg_step()    { echo -e "${CYAN}→ $1${NC}"; }

# confirm "question" [default]  -- default is "y" or "n" (default: "n")
# Returns 0 for yes, 1 for no. Empty input accepts the default.
confirm() {
    local question="$1" default="${2:-n}"
    local hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"

    echo -e -n "${YELLOW}${question} [${hint}]: ${NC}"
    local answer
    read answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

# Prints "$colored" then pads with spaces so the VISIBLE width matches
# $width, based on the visible length of "$plain" (avoids ANSI escape
# codes throwing off column alignment in tables).
pad_colored() {
    local colored="$1" plain="$2" width="$3"
    local pad=$((width - ${#plain}))
    ((pad < 0)) && pad=0
    printf "%s%*s" "$colored" "$pad" ""
}

# Truncates $1 to $2 visible characters, appending "..." when it was cut,
# so a long value shortens instead of dragging the rest of a table row
# out of alignment.
truncate_field() {
    local text="$1" width="$2"
    if ((${#text} > width)); then
        printf "%s..." "${text:0:$((width - 3))}"
    else
        printf "%s" "$text"
    fi
}

# ==========================================================
# CONFIG
# ==========================================================
create_default_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        local tmp
        tmp=$(mktemp -p "$MANAGER_DIR") || {
            msg_error "Failed to create temporary config file"
            return 1
        }

        cat > "$tmp" <<EOF
DOMAIN=
CERT_NAME=
CERTBOT_EMAIL=
DEFAULT_TLS=https
EOF

        if [[ $? -ne 0 ]]; then
            rm -f "$tmp"
            msg_error "Failed to write config file"
            return 1
        fi

        mv "$tmp" "$CONFIG_FILE"
    fi
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Missing config: $CONFIG_FILE${NC}"
        return 1
    fi
    source "$CONFIG_FILE"
}

first_run_setup() {

    if [[ -f "$CONFIG_FILE" ]] && grep -q "^SETUP_DONE=true" "$CONFIG_FILE"; then
        return
    fi

    header
    echo -e "${BOLD}FIRST RUN SETUP${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    local domain
    while true; do
        read -p "Base domain (example: lan.example.com): " domain
        validate_domain "$domain" && break
        msg_error "Invalid domain"
    done

    local email
    while true; do
        read -p "Certbot email: " email
        [[ "$email" =~ ^.+@.+\..+$ ]] && break
        msg_error "Invalid email"
    done

    local tmp
    tmp=$(mktemp -p "$MANAGER_DIR") || {
        msg_error "Failed to create temporary config file"
        pause
        return 1
    }

    cat > "$tmp" <<EOF
DOMAIN=$domain
CERT_NAME=$domain
CERTBOT_EMAIL=$email
DEFAULT_TLS=https
SETUP_DONE=true
EOF

    if [[ $? -ne 0 ]]; then
        rm -f "$tmp"
        msg_error "Failed to write config file"
        pause
        return 1
    fi

    mv "$tmp" "$CONFIG_FILE"

    echo
    msg_success "Initial setup completed"
    pause
}

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

# ==========================================================
# VALIDATION
# ==========================================================
validate_name() { [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }
validate_domain() { [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; }

validate_backend() {
    [[ "$1" =~ ^([a-zA-Z0-9.-]+):([0-9]+)$ ]] || return 1
    local port="${BASH_REMATCH[2]}"

    # Reject leading-zero ports (e.g. "080", "065535") instead of letting
    # bash arithmetic reinterpret them as octal (or silently misjudging them).
    if [[ "$port" =~ ^0[0-9]+$ ]]; then
        return 1
    fi

    ((port >= 1 && port <= 65535))
}

# A site domain is covered by the managed wildcard certificate only if it
# is exactly $DOMAIN or exactly one label below it (matching *.DOMAIN).
domain_covered_by_wildcard() {
    local site_domain="$1" base_domain="$2"
    local escaped_base="${base_domain//./\\.}"

    [[ "$site_domain" == "$base_domain" ]] && return 0
    [[ "$site_domain" =~ ^[a-zA-Z0-9-]+\.${escaped_base}$ ]]
}

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

# ==========================================================
# INIT
# ==========================================================
create_default_config
first_run_setup
create_database

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

create_snippets

# ==========================================================
# SITE MANAGER
# ==========================================================

# Prints a numbered list of sites and lets the user pick one.
# Echoes the chosen site name to stdout and returns 0, or returns 1
# if the user cancels (Q/empty) or the selection is invalid.
# All interactive/informational output goes to stderr so this is safe
# to use as: name=$(select_site "prompt") || <cancelled>
select_site() {
    local prompt="${1:-Select site}"
    local names=()
    while IFS= read -r n; do names+=("$n"); done < <(jq -r 'keys[]' "$SITES_DB")

    if ((${#names[@]} == 0)); then
        msg_warning "No sites configured yet" >&2
        return 1
    fi

    echo >&2
    echo "$prompt:" >&2
    echo >&2
    local i=1
    for n in "${names[@]}"; do
        printf " %2d) %s\n" "$i" "$n" >&2
        ((i++))
    done
    echo >&2
    echo " [Q] Back" >&2
    echo >&2

    local choice
    read -p "Select: " choice
    if [[ -z "$choice" || "$choice" =~ ^[Qq]$ ]]; then
        return 1
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#names[@]})); then
        msg_error "Invalid selection" >&2
        return 1
    fi

    echo "${names[$((choice-1))]}"
}

sites_menu() {
    while true; do
        header
        echo -e "${BOLD}SITES${NC}"
        echo "──────────────────────────────────────────────────────"
        echo

        local names=()
        while IFS= read -r n; do names+=("$n"); done < <(jq -r 'keys[]' "$SITES_DB")

        if ((${#names[@]} == 0)); then
            echo "  No sites configured yet"
        else
            printf "  %-3s %-16s %-11s %-6s %-28s %s\n" "#" "NAME" "STATUS" "TLS" "DOMAIN" "BACKEND"
            local i=1 n domain backend tls status_plain status_colored domain_display backend_display
            for n in "${names[@]}"; do
                domain=$(db_get "$n" domain)
                backend=$(db_get "$n" backend)
                tls=$(db_get "$n" tls)
                domain_display=$(truncate_field "$domain" 28)
                backend_display=$(truncate_field "$backend" 22)
                if [[ -L "$NGINX_ENABLED/$n.conf" ]]; then
                    status_plain="● ENABLED"
                    status_colored="${GREEN}${status_plain}${NC}"
                else
                    status_plain="○ DISABLED"
                    status_colored="${GRAY}${status_plain}${NC}"
                fi
                printf "  %-3s %-16s " "$i" "$n"
                pad_colored "$status_colored" "$status_plain" 11
                printf " %-6s %-28s %s\n" "${tls^^}" "$domain_display" "$backend_display"
                ((i++))
            done
        fi

        echo
        echo "──────────────────────────────────────────────────────"
        echo
        echo "  [A] Add       [E] Edit      [T] Toggle    [R] Regenerate"
        echo "  [V] View      [D] Delete    [I] Import    [G] Regen all"
        echo "  [Q] Back"
        echo

        local choice
        read -p "Select # or action: " choice
        choice="${choice,,}"

        if [[ -z "$choice" || "$choice" == "q" ]]; then
            return
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if ((choice >= 1 && choice <= ${#names[@]})); then
                site_details "${names[$((choice-1))]}"
            else
                msg_error "Invalid selection"
                pause
            fi
            continue
        fi

        local target
        case "$choice" in
            a) add_site ;;
            i) import_sites ;;
            g) regenerate_all ;;
            e)
                target=$(select_site "Select site to edit") && edit_site "$target"
                ;;
            t)
                target=$(select_site "Select site to toggle") && site_toggle "$target"
                ;;
            r)
                target=$(select_site "Select site to regenerate") && regenerate_config "$target"
                ;;
            v)
                target=$(select_site "Select site to view") && site_details "$target"
                ;;
            d)
                target=$(select_site "Select site to delete") && delete_site "$target"
                ;;
            *)
                msg_error "Invalid option"
                pause
                ;;
        esac
    done
}

site_details() {
    local name="$1"

    while true; do
        header
        echo -e "${BOLD}SITE: ${name}${NC}"
        echo "──────────────────────────────────────────────────────"
        echo

        local domain backend tls created conf link
        domain=$(db_get "$name" domain)
        backend=$(db_get "$name" backend)
        tls=$(db_get "$name" tls)
        created=$(db_get "$name" created)
        conf="$NGINX_AVAILABLE/$name.conf"
        link="$NGINX_ENABLED/$name.conf"

        local status_line toggle_label
        if [[ -L "$link" ]]; then
            status_line="${GREEN}✓ Enabled${NC}"
            toggle_label="Disable"
        else
            status_line="${GRAY}○ Disabled${NC}"
            toggle_label="Enable"
        fi

        local config_line="${GRAY}— (site disabled)${NC}"
        if [[ -L "$link" ]]; then
            if test_nginx_config >/dev/null 2>&1; then
                config_line="${GREEN}✓ Valid${NC}"
            else
                config_line="${RED}✗ Invalid${NC}"
            fi
        fi

        local cert_line="—"
        if [[ "$tls" == "https" || "$tls" == "both" ]]; then
            if load_config >/dev/null 2>&1 && [[ -n "$CERT_NAME" ]]; then
                cert_line="*.${DOMAIN} (${CERT_NAME})"
            else
                cert_line="${YELLOW}not configured${NC}"
            fi
        fi

        echo -e "  Domain       $domain"
        echo -e "  Backend      http://$backend"
        echo -e "  TLS          ${tls^^}"
        echo -e "  Status       $status_line"
        echo -e "  Config       $config_line"
        echo -e "  Certificate  $cert_line"
        echo -e "  Created      $created"
        echo
        echo "  Config file  $conf"
        [[ -L "$link" ]] && echo "  Symlink      $link"
        echo
        echo "──────────────────────────────────────────────────────"
        echo
        echo "  [E] Edit         [T] $toggle_label      [R] Regenerate"
        echo "  [C] View config  [D] Delete       [Q] Back"
        echo

        local choice
        read -p "Select: " choice
        choice="${choice,,}"

        case "$choice" in
            e) edit_site "$name" ;;
            t) site_toggle "$name" ;;
            r) regenerate_config "$name" ;;
            c) view_site_config "$name" ;;
            d) delete_site "$name" && return ;;
            q|"") return ;;
            *) msg_error "Invalid option"; pause ;;
        esac
    done
}

view_site_config() {
    local name="$1"
    header
    echo -e "${BOLD}CONFIG: ${name}${NC}"
    echo "──────────────────────────────────────────────────────"
    echo
    if [[ -f "$NGINX_AVAILABLE/$name.conf" ]]; then
        cat "$NGINX_AVAILABLE/$name.conf"
    else
        msg_error "Configuration file not found"
    fi
    pause
}

add_site() {
    header
    echo -e "${BOLD}ADD SITE${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    local name
    while true; do
        read -p "Site name: " name
        if ! validate_name "$name"; then
            msg_error "Invalid name (letters, numbers, - and _ only)"
            continue
        fi
        if db_exists "$name"; then
            msg_error "A site named '$name' already exists"
            continue
        fi
        break
    done

    local domain
    while true; do
        read -p "Domain: " domain
        validate_domain "$domain" && break
        msg_error "Invalid domain"
    done

    local backend
    while true; do
        read -p "Backend (ip:port): " backend
        validate_backend "$backend" && break
        msg_error "Invalid backend (expected host:port, 1-65535)"
    done

    echo
    echo "TLS mode:"
    echo "  1) HTTP"
    echo "  2) HTTPS"
    echo "  3) BOTH"
    echo

    local tls mode
    while true; do
        read -p "Select [1-3]: " mode
        case "$mode" in
            1) tls="http"; break ;;
            2) tls="https"; break ;;
            3) tls="both"; break ;;
            *) msg_error "Invalid selection" ;;
        esac
    done

    # enabled starts false; enable_site is the only thing allowed to flip it,
    # so the DB never claims "enabled" while no symlink actually exists.
    if ! db_save "$name" "$domain" "$backend" "$tls" false; then
        msg_error "Failed to save site to database"
        pause
        return
    fi

    if ! generate_site "$name"; then
        echo
        msg_error "Could not create site"
        echo
        echo "No changes were committed."
        if ! db_remove "$name"; then
            msg_warning "Failed to roll back database entry for $name - manual cleanup may be required"
        fi
        pause
        return
    fi

    echo
    msg_success "Configuration generated"
    echo

    if confirm "Enable site now?" y; then
        enable_site "$name"
    else
        msg_success "Site created (disabled)"
    fi

    pause
}

edit_site() {
    local name="$1"
    local old_domain old_backend old_tls old_enabled
    old_domain=$(db_get "$name" domain)
    old_backend=$(db_get "$name" backend)
    old_tls=$(db_get "$name" tls)
    old_enabled=$(db_get "$name" enabled)

    local domain="$old_domain" backend="$old_backend" tls="$old_tls"

    header
    echo -e "${BOLD}EDIT SITE: ${name}${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    local input
    while true; do
        read -p "Domain [$domain]: " input
        input="${input:-$domain}"
        if validate_domain "$input"; then
            domain="$input"
            break
        fi
        msg_error "Invalid domain"
    done

    while true; do
        read -p "Backend [$backend]: " input
        input="${input:-$backend}"
        if validate_backend "$input"; then
            backend="$input"
            break
        fi
        msg_error "Invalid backend (expected host:port, 1-65535)"
    done

    echo
    echo "TLS mode:"
    echo "  1) HTTP"
    echo "  2) HTTPS"
    echo "  3) BOTH"
    echo
    local default_mode
    case "$tls" in
        http) default_mode=1 ;;
        https) default_mode=2 ;;
        both) default_mode=3 ;;
        *) default_mode="" ;;
    esac

    local mode
    while true; do
        read -p "Select [$default_mode]: " mode
        mode="${mode:-$default_mode}"
        case "$mode" in
            1) tls="http"; break ;;
            2) tls="https"; break ;;
            3) tls="both"; break ;;
            *) msg_error "Invalid selection" ;;
        esac
    done

    # Preserve the site's actual current enabled state - editing must never
    # silently flip a disabled site to enabled.
    if ! db_save "$name" "$domain" "$backend" "$tls" "$old_enabled"; then
        msg_error "Failed to update database, aborting edit"
        pause
        return
    fi

    if ! generate_site "$name"; then
        msg_error "Could not generate configuration, restoring previous settings"
        db_save "$name" "$old_domain" "$old_backend" "$old_tls" "$old_enabled"
        pause
        return
    fi

    if [[ "$old_enabled" != "true" ]]; then
        echo
        msg_success "Site updated (disabled, not reloaded)"
        pause
        return
    fi

    echo
    if test_nginx_config; then
        systemctl reload nginx
        msg_success "Site updated"
        msg_success "Nginx configuration valid"
        msg_success "Nginx reloaded"
        log "Site edited: $name"
    else
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
    fi

    pause
}

delete_site() {
    local name="$1"
    local domain backend status_txt
    domain=$(db_get "$name" domain)
    backend=$(db_get "$name" backend)
    if [[ -L "$NGINX_ENABLED/$name.conf" ]]; then
        status_txt="ENABLED"
    else
        status_txt="DISABLED"
    fi

    header
    echo -e "${BOLD}DELETE SITE: ${name}${NC}"
    echo "──────────────────────────────────────────────────────"
    echo
    echo "  Domain   $domain"
    echo "  Backend  $backend"
    echo "  Status   $status_txt"
    echo
    echo "This will remove the nginx configuration and database entry."
    echo "A backup of the current configuration will be kept."
    echo

    local confirm_name
    read -p "Type the site name to confirm deletion: " confirm_name

    if [[ "$confirm_name" != "$name" ]]; then
        echo
        msg_warning "Cancelled (name did not match)"
        pause
        return 1
    fi

    echo
    backup_file "$NGINX_AVAILABLE/$name.conf"
    rm -f "$NGINX_AVAILABLE/$name.conf" "$NGINX_ENABLED/$name.conf"
    if ! db_remove "$name"; then
        msg_warning "Failed to remove $name from database"
    fi
    reload_nginx

    echo
    msg_success "Site '$name' deleted"
    pause
    return 0
}

site_toggle() {
    local name="$1"
    local result state

    state=$(db_get "$name" enabled)

    if [[ "$state" == "true" ]]; then
        confirm "Disable site '$name'?" y || return 1
        echo
        disable_site "$name"
        result=$?
    else
        confirm "Enable site '$name'?" y || return 1
        echo
        enable_site "$name"
        result=$?
    fi

    pause
    return $result
}

import_sites() {
    header
    echo -e "${BOLD}IMPORT EXISTING SITES${NC}"
    echo "──────────────────────────────────────────────────────"
    echo
    echo "Searching nginx configs..."
    echo

    local imported=0
    for file in "$NGINX_AVAILABLE"/*.conf; do
        [[ ! -f "$file" ]] && continue
        name=$(basename "$file" .conf)
        db_exists "$name" && continue
        domain=$(grep server_name "$file" | head -1 | awk '{print $2}' | sed 's/;//')
        backend=$(grep proxy_pass "$file" | head -1 | awk '{print $2}' | sed 's/http:\/\///' | sed 's/;//')
        [[ -z "$domain" ]] && continue
        [[ -z "$backend" ]] && backend="unknown"
        tls="http"
        grep -q "listen 443" "$file" && tls="https"
        db_save "$name" "$domain" "$backend" "$tls" false
        msg_success "Imported: $name"
        ((imported++))
    done

    echo
    ((imported == 0)) && echo "No new sites found to import."
    pause
}

# ==========================================================
# TLS MANAGER
# ==========================================================
cloudflare_credentials_ok() {
    [[ -f "$CF_FILE" ]] || return 1
    [[ -s "$CF_FILE" ]] || return 1
    grep -q "dns_cloudflare_api_token" "$CF_FILE" || return 1
    return 0
}

install_tls() {
    header
    echo -e "${BOLD}INSTALL TLS DEPENDENCIES${NC}"
    echo "──────────────────────────────────────────────────────"
    echo
    msg_step "Installing certbot, python3-certbot-dns-cloudflare, jq, curl..."
    echo

    if ! apt update; then
        msg_error "apt update failed"
        log "install_tls: apt update failed"
        pause
        return 1
    fi

    if ! apt install -y certbot python3-certbot-dns-cloudflare jq curl; then
        msg_error "Package installation failed"
        log "install_tls: apt install failed"
        pause
        return 1
    fi

    echo
    msg_success "TLS dependencies installed"
    log "TLS packages installed"
    pause
}

create_cloudflare_token() {
    header
    echo -e "${BOLD}CLOUDFLARE CREDENTIALS${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    mkdir -p "$CF_DIR"
    chmod 700 "$CF_DIR"

    echo "An API token with Zone -> DNS -> Edit permission is required."
    echo

    if [[ -f "$CF_FILE" ]]; then
        msg_warning "Existing Cloudflare credentials found: $CF_FILE"
        echo
        confirm "Overwrite existing token?" n || { echo "Cancelled"; pause; return; }
        echo
    fi

    local token
    while true; do
        read -rsp "Token: " token
        echo

        if [[ -z "$token" ]]; then
            msg_error "Token cannot be empty"
            confirm "Try again?" y || return
            continue
        fi

        break
    done

    local tmp
    tmp=$(mktemp -p "$CF_DIR") || {
        msg_error "Failed to create temporary credentials file"
        pause
        return
    }
    chmod 600 "$tmp"

    cat > "$tmp" <<EOF
dns_cloudflare_api_token = $token
EOF

    if [[ $? -ne 0 ]]; then
        rm -f "$tmp"
        msg_error "Failed to write Cloudflare credentials"
        pause
        return
    fi

    mv "$tmp" "$CF_FILE"

    echo
    msg_success "Cloudflare credentials saved"
    log "Cloudflare credentials updated"
    pause
}

create_certificate() {
    header
    echo -e "${BOLD}CREATE CERTIFICATE${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    if ! load_config; then
        pause
        return
    fi

    if [[ -z "$DOMAIN" ]]; then
        msg_error "DOMAIN is not set in configuration"
        pause
        return
    fi

    if [[ -z "$CERT_NAME" ]]; then
        msg_error "CERT_NAME is not set in configuration"
        pause
        return
    fi

    if ! require_certbot; then
        pause
        return
    fi

    if ! cloudflare_credentials_ok; then
        msg_error "Cloudflare credentials not configured"
        echo
        echo "Set them up first via TLS Manager -> Cloudflare credentials."
        pause
        return
    fi

    [[ -z "$CERTBOT_EMAIL" ]] && read -p "Email: " CERTBOT_EMAIL

    echo
    msg_step "Requesting certificate for *.$DOMAIN and $DOMAIN..."
    echo

    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_FILE" \
        --dns-cloudflare-propagation-seconds 30 \
        --cert-name "$CERT_NAME" \
        -d "*.$DOMAIN" -d "$DOMAIN" --agree-tos --non-interactive -m "$CERTBOT_EMAIL"

    echo
    if [[ $? -eq 0 ]]; then
        msg_success "Certificate created"
        log "Certificate created for $DOMAIN (cert-name: $CERT_NAME)"
    else
        msg_error "Certificate request failed"
        log "Certificate creation failed for $DOMAIN"
    fi
    pause
}

renew_certificate() {
    header
    echo -e "${BOLD}RENEW CERTIFICATE${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    if ! load_config; then
        pause
        return
    fi

    if ! require_certbot; then
        pause
        return
    fi

    certbot renew --deploy-hook "systemctl reload nginx"
    pause
}

certificate_info() {
    header
    echo -e "${BOLD}CERTIFICATE INFO${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    if ! load_config; then
        pause
        return
    fi

    if ! require_openssl; then
        pause
        return
    fi

    local cert="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
    if [[ ! -f "$cert" ]]; then
        msg_warning "Certificate not found"
        pause
        return
    fi

    openssl x509 -in "$cert" -noout -subject -ext subjectAltName -dates
    pause
}

# Prints the cert expiry epoch (seconds) for the configured CERT_NAME,
# or nothing if it cannot be determined. Used by status screens only.
_cert_days_left() {
    local cert="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
    [[ -f "$cert" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 1

    local end_date end_epoch now_epoch
    end_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -n "$end_date" ]] || return 1
    end_epoch=$(date -d "$end_date" +%s 2>/dev/null)
    [[ -n "$end_epoch" ]] || return 1
    now_epoch=$(date +%s)
    echo $(( (end_epoch - now_epoch) / 86400 ))
}

tls_menu() {
    while true; do
        header
        echo -e "${BOLD}TLS MANAGER${NC}"
        echo "──────────────────────────────────────────────────────"
        echo

        echo "  Certificate"
        if load_config >/dev/null 2>&1 && [[ -n "$DOMAIN" ]]; then
            echo "    Name         ${CERT_NAME:-—}"
            echo "    Domain       ${DOMAIN:-—}"

            local cert_path="/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem"
            if [[ -n "$CERT_NAME" ]] && [[ -f "$cert_path" ]]; then
                local days_left
                days_left=$(_cert_days_left)
                if [[ -n "$days_left" ]]; then
                    if ((days_left < 0)); then
                        echo -e "    Status       ${RED}✗ Expired${NC}"
                    elif ((days_left < 14)); then
                        echo -e "    Status       ${YELLOW}! Expires soon${NC}"
                    else
                        echo -e "    Status       ${GREEN}✓ Valid${NC}"
                    fi
                    echo "    Days left    $days_left"
                else
                    echo -e "    Status       ${GREEN}✓ Present${NC}"
                fi
            else
                echo -e "    Status       ${YELLOW}○ Not issued${NC}"
            fi
        else
            echo -e "    ${YELLOW}Configuration not loaded (DOMAIN not set)${NC}"
        fi

        echo
        echo "  Cloudflare"
        if cloudflare_credentials_ok; then
            echo -e "    Credentials  ${GREEN}✓ Configured${NC}"
        else
            echo -e "    Credentials  ${RED}✗ Not configured${NC}"
        fi

        echo
        echo "──────────────────────────────────────────────────────"
        echo
        echo "  [1] Certificate info"
        echo "  [2] Create / issue certificate"
        echo "  [3] Renew certificate"
        echo "  [4] Cloudflare credentials"
        echo "  [5] Install TLS dependencies"
        echo "  [Q] Back"
        echo

        local choice
        read -p "Select: " choice
        case "${choice,,}" in
            1) certificate_info ;;
            2) create_certificate ;;
            3) renew_certificate ;;
            4) create_cloudflare_token ;;
            5) install_tls ;;
            q|"") return ;;
            *) msg_error "Invalid option"; pause ;;
        esac
    done
}

# ==========================================================
# SYSTEM
# ==========================================================
system_check() {
    header
    echo -e "${BOLD}SYSTEM CHECK${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    echo "  Dependencies"
    if command -v jq >/dev/null 2>&1; then echo -e "    jq        ${GREEN}✓${NC}"; else echo -e "    jq        ${RED}✗${NC}"; fi
    if command -v nginx >/dev/null 2>&1; then echo -e "    nginx     ${GREEN}✓${NC}"; else echo -e "    nginx     ${RED}✗${NC}"; fi
    if command -v certbot >/dev/null 2>&1; then echo -e "    certbot   ${GREEN}✓${NC}"; else echo -e "    certbot   ${YELLOW}○ optional${NC}"; fi
    if command -v openssl >/dev/null 2>&1; then echo -e "    openssl   ${GREEN}✓${NC}"; else echo -e "    openssl   ${YELLOW}○ optional${NC}"; fi
    echo

    echo "  Nginx"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "    Service     ${GREEN}✓ Running${NC}"
    else
        echo -e "    Service     ${RED}✗ Not running${NC}"
    fi
    if test_nginx_config >/dev/null 2>&1; then
        echo -e "    Config      ${GREEN}✓ Valid${NC}"
    else
        echo -e "    Config      ${RED}✗ Invalid${NC}"
    fi
    echo

    echo "  TLS"
    if load_config >/dev/null 2>&1 && [[ -n "$CERT_NAME" ]]; then
        local cert="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
        if [[ -f "$cert" ]]; then
            echo -e "    Certificate ${GREEN}✓ Present${NC}"
            local days_left
            days_left=$(_cert_days_left)
            if [[ -n "$days_left" ]]; then
                if ((days_left < 14)); then
                    echo -e "    Expiration  ${YELLOW}! ${days_left} days${NC}"
                else
                    echo -e "    Expiration  ${GREEN}✓ ${days_left} days${NC}"
                fi
            fi
        else
            echo -e "    Certificate ${YELLOW}○ Not issued${NC}"
        fi
    else
        echo -e "    Certificate ${GRAY}— Not configured${NC}"
    fi
    echo

    echo "  Manager"
    if load_config >/dev/null 2>&1; then
        echo -e "    Config      ${GREEN}✓${NC}"
    else
        echo -e "    Config      ${RED}✗${NC}"
    fi
    if jq empty "$SITES_DB" >/dev/null 2>&1; then
        echo -e "    Database    ${GREEN}✓${NC}"
    else
        echo -e "    Database    ${RED}✗ Broken${NC}"
    fi
    local db_perm
    db_perm=$(stat -c "%a" "$SITES_DB" 2>/dev/null)
    if [[ "$db_perm" == "600" ]]; then
        echo -e "    Permissions ${GREEN}✓${NC}"
    else
        echo -e "    Permissions ${YELLOW}! ${db_perm:-unknown}${NC}"
    fi

    pause
}

# ==========================================================
# DASHBOARD
# ==========================================================
render_dashboard_status() {
    local nginx_line config_line sites_line cert_line

    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_line="${GREEN}✓ Running${NC}"
    else
        nginx_line="${RED}✗ Not running${NC}"
    fi

    if test_nginx_config >/dev/null 2>&1; then
        config_line="${GREEN}✓ Valid${NC}"
    else
        config_line="${RED}✗ Invalid${NC}"
    fi

    local total enabled
    total=$(jq 'keys | length' "$SITES_DB" 2>/dev/null)
    enabled=$(jq '[.[] | select(.enabled==true)] | length' "$SITES_DB" 2>/dev/null)
    sites_line="${enabled:-0} enabled / ${total:-0} total"

    cert_line="${GRAY}— Not configured${NC}"
    if load_config >/dev/null 2>&1 && [[ -n "$CERT_NAME" ]]; then
        local cert_path="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
        if [[ -f "$cert_path" ]]; then
            local days_left
            days_left=$(_cert_days_left)
            if [[ -n "$days_left" ]]; then
                if ((days_left < 0)); then
                    cert_line="${RED}✗ Expired${NC}"
                elif ((days_left < 14)); then
                    cert_line="${YELLOW}! Expires in ${days_left}d${NC}"
                else
                    cert_line="${GREEN}✓ Valid (${days_left}d left)${NC}"
                fi
            else
                cert_line="${GREEN}✓ Present${NC}"
            fi
        else
            cert_line="${YELLOW}○ Not issued${NC}"
        fi
    fi

    echo -e "  Nginx          $nginx_line"
    echo -e "  Configuration  $config_line"
    echo -e "  Sites          $sites_line"
    echo -e "  Certificate    $cert_line"
}

show_backups() {
    header
    echo -e "${BOLD}BACKUPS${NC}"
    echo "──────────────────────────────────────────────────────"
    echo
    if [[ -d "$BACKUP_DIR" ]] && [[ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        find "$BACKUP_DIR" -type f -printf "%T@ %p\n" \
            | sort -nr \
            | cut -d' ' -f2- \
            | head -50
    else
        echo "No backups yet"
    fi
    pause
}

show_logs() {
    header
    echo -e "${BOLD}LOGS${NC}"
    echo "──────────────────────────────────────────────────────"
    echo
    tail -100 "$LOG_FILE" 2>/dev/null || echo "No logs yet"
    pause
}

# ==========================================================
# MAIN MENU
# ==========================================================
main_menu() {
    while true; do
        header
        echo
        render_dashboard_status
        echo
        echo "──────────────────────────────────────────────────────"
        echo
        echo "  [1] Sites"
        echo "  [2] TLS Manager"
        echo "  [3] System Check"
        echo "  [4] Backups"
        echo "  [5] Logs"
        echo
        echo "  [Q] Quit"
        echo

        local choice
        read -p "Select: " choice
        choice="${choice,,}"

        case "$choice" in
            1) sites_menu ;;
            2) tls_menu ;;
            3) system_check ;;
            4) show_backups ;;
            5) show_logs ;;
            q) clear; exit 0 ;;
            "") ;;
            *) msg_error "Invalid option"; pause ;;
        esac
    done
}

# ==========================================================
# START
# ==========================================================
main_menu