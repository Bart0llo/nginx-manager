#!/bin/bash
# ==========================================================
# NGINX Manager Pro - dashboard, backups and logs
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

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

    # Enabled = has a sites-enabled symlink (the db flag may be stale).
    local total enabled=0 n
    total=$(jq 'keys | length' "$SITES_DB" 2>/dev/null)
    while IFS= read -r n; do
        [[ -L "$NGINX_ENABLED/$n.conf" ]] && ((enabled++))
    done < <(jq -r 'keys[]' "$SITES_DB" 2>/dev/null)
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
