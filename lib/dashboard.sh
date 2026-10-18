#!/bin/bash
# ==========================================================
# NGINX Manager Pro - dashboard, logs and diagnostics
# Sourced by nginx-site.sh: defines state and functions only.
# ==========================================================

# ==========================================================
# DASHBOARD
# ==========================================================
# The main screen's status is checked once and reused for DASH_TTL
# seconds, or until an operation changes something (ui_run resets
# DASH_TIME), so redrawing the menu does not rerun nginx -t every time.
DASH_TIME=0
DASH_TTL=60
DASH_LINES=()
DASH_WARNINGS=()

dashboard_refresh() {
    DASH_LINES=() DASH_WARNINGS=()
    local value

    if ! command -v systemctl >/dev/null 2>&1; then
        value=$(ui_badge unknown "Unknown (systemctl not available)")
    elif systemctl is-active --quiet nginx 2>/dev/null; then
        value=$(ui_badge ok "Running")
    else
        value=$(ui_badge err "Not running")
        DASH_WARNINGS+=("nginx is not running")
    fi
    DASH_LINES+=("NGINX service|$value")

    if test_nginx_config >/dev/null 2>&1; then
        value=$(ui_badge ok "Valid")
    else
        value=$(ui_badge err "Invalid")
        DASH_WARNINGS+=("nginx -t fails: Logs & diagnostics -> Test nginx configuration shows why")
    fi
    DASH_LINES+=("NGINX config|$value")

    local config_ok=0
    if load_config >/dev/null 2>&1; then
        config_ok=1
    else
        DASH_WARNINGS+=("$CONFIG_FILE is invalid: Status shows the line")
    fi

    # Enabled = has a sites-enabled symlink (the db flag may be stale).
    if ! jq empty "$SITES_DB" >/dev/null 2>&1; then
        value=$(ui_badge err "Database unreadable")
        DASH_WARNINGS+=("$SITES_DB is not valid JSON")
    else
        local total=0 enabled=0 attention=0 name domain backend tls flag
        while IFS=$'\t' read -r name domain backend tls flag; do
            ((total++))
            [[ -L "$NGINX_ENABLED/$name.conf" ]] && ((enabled++))
            [[ -n "$(site_warnings "$name" "$domain" "$tls" "$flag")" ]] && ((attention++))
        done < <(sites_tsv)
        if ((total == 0)); then
            value=$(ui_badge none "No sites yet")
        else
            value="$enabled enabled, $((total - enabled)) disabled ($total total)"
        fi
        ((attention)) && DASH_WARNINGS+=("$attention site(s) need attention: see Sites")
    fi
    DASH_LINES+=("Sites|$value")

    if ((config_ok)); then
        cert_status
        value=$(cert_badge)
        case "$CERT_STATE" in
            expired) DASH_WARNINGS+=("The certificate expired on $CERT_END: TLS & certificates") ;;
            expiring) DASH_WARNINGS+=("The certificate expires in $CERT_DAYS days: TLS & certificates -> Renew") ;;
        esac
    else
        value=$(ui_badge unknown "Unknown (config.conf invalid)")
    fi
    DASH_LINES+=("Certificate|$value")

    plugins_load
    if ! plugins_read_enabled; then
        value=$(ui_badge err "plugins.enabled is invalid")
        DASH_WARNINGS+=("No plugin can run: $PLUGINS_ENABLED $PLUGINS_ENABLED_ERROR (see Plugins)")
    else
        local id active=0 broken=0
        for id in "${PLUGINS_ON[@]}"; do
            if plugin_is_active "$id"; then ((active++)); else ((broken++)); fi
        done
        if ((broken)); then
            value=$(ui_badge err "$broken enabled plugin(s) cannot run")
            DASH_WARNINGS+=("$broken enabled plugin(s) cannot run; sites cannot be created or changed: see Plugins")
        elif ((active)); then
            value=$(ui_badge ok "$active enabled")
        else
            value=$(ui_badge none "None enabled (${#PLUGIN_IDS[@]} installed)")
        fi
    fi
    DASH_LINES+=("Plugins|$value")

    printf -v DASH_TIME '%(%s)T' -1
}

render_dashboard_status() {
    local now line
    printf -v now '%(%s)T' -1
    ((DASH_TIME && now - DASH_TIME < DASH_TTL)) || ui_shield dashboard_refresh

    for line in "${DASH_LINES[@]}"; do
        ui_kv "${line%%|*}" "${line#*|}"
    done
    if ((${#DASH_WARNINGS[@]})); then
        echo
        for line in "${DASH_WARNINGS[@]}"; do
            msg_warning "$line"
        done
    fi
    echo
    ui_hint "Checked at $(printf '%(%H:%M:%S)T' "$DASH_TIME"). Status runs a full check."
}

# ==========================================================
# LOGS AND DIAGNOSTICS
# ==========================================================
diagnostics_menu() {
    while true; do
        ui_screen "Logs & diagnostics"
        ui_menu "" q \
            "1|Manager log|the last 100 lines of $LOG_FILE" \
            "2|Backups|configuration backups, newest first" \
            "3|Test nginx configuration|runs nginx -t and shows its output (read-only)" \
            "q|Back|" || return
        case "$UI_REPLY" in
            1) show_logs ;;
            2) show_backups ;;
            3) nginx_test_screen ;;
            q) return ;;
        esac
    done
}

show_backups() {
    ui_screen "Logs & diagnostics" "Backups"
    if [[ -d "$BACKUP_DIR" ]] && [[ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
        echo "Newest first, in $BACKUP_DIR:"
        echo
        find "$BACKUP_DIR" -type f -printf "%T@ %TY-%Tm-%Td %TH:%TM  %f\n" \
            | sort -nr \
            | cut -d' ' -f2- \
            | head -50 \
            | sed 's/^/  /'
        echo
        ui_hint "Each file is <config>_<time>.bak. To restore one by hand: copy it over"
        ui_hint "$NGINX_AVAILABLE/<config>, then run nginx -t before reloading nginx."
    else
        echo "No backups yet"
    fi
    pause
}

show_logs() {
    ui_screen "Logs & diagnostics" "Manager log"
    if [[ -f "$LOG_FILE" ]]; then
        tail -100 "$LOG_FILE" | ui_pager
    else
        echo "No logs yet"
        pause
    fi
}

nginx_test_screen() {
    ui_screen "Logs & diagnostics" "Test nginx configuration"
    local out rc
    out=$(ui_shield test_nginx_config 2>&1)
    rc=$?
    printf '%s\n' "$out"
    echo
    if ((rc == 0)); then
        msg_success "nginx configuration is valid"
    else
        msg_error "nginx configuration test failed (nginx -t exit $rc)"
    fi
    DASH_TIME=0
    pause
}
