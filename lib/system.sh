#!/bin/bash
# ==========================================================
# NGINX Manager Pro - status (full system check)
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# SYSTEM
# ==========================================================
# dependency_line <command> <required|optional> <purpose>
dependency_line() {
    if command -v "$1" >/dev/null 2>&1; then
        ui_kv "$1" "$(ui_badge ok "Installed")"
    elif [[ "$2" == required ]]; then
        ui_kv "$1" "$(ui_badge err "Missing (required)")"
    else
        ui_kv "$1" "$(ui_badge off "Not installed ($3)")"
    fi
}

system_check() {
    ui_screen "Status"

    printf '%s\n' "${BOLD}Dependencies${NC}"
    dependency_line jq required
    dependency_line nginx required
    dependency_line certbot optional "needed for certificates"
    dependency_line openssl optional "needed to read certificates"
    dependency_line gum optional "enhanced interface"

    ui_section "NGINX"
    if ! command -v systemctl >/dev/null 2>&1; then
        ui_kv "Service" "$(ui_badge unknown "Unknown (systemctl not available)")"
    elif ui_shield systemctl is-active --quiet nginx 2>/dev/null; then
        ui_kv "Service" "$(ui_badge ok "Running")"
    else
        ui_kv "Service" "$(ui_badge err "Not running")"
    fi
    if ui_shield test_nginx_config >/dev/null 2>&1; then
        ui_kv "Configuration" "$(ui_badge ok "Valid")"
    else
        ui_kv "Configuration" "$(ui_badge err "Invalid (Logs & diagnostics -> Test nginx configuration)")"
    fi

    ui_section "TLS"
    local config_error=""
    if ! load_config >/dev/null 2>&1; then
        config_error=$(load_config 2>&1)
        ui_kv "Certificate" "$(ui_badge unknown "Unknown (manager configuration invalid)")"
    else
        cert_status
        ui_kv "Certificate" "$(cert_badge)"
        [[ -n "$CERT_END" ]] && ui_kv "Expires" "$CERT_END"
    fi

    ui_section "Manager"
    if [[ -z "$config_error" ]]; then
        ui_kv "Config file" "$(ui_badge ok "Valid")"
    else
        ui_kv "Config file" "$(ui_badge err "Invalid")"
        printf '%s\n' "$config_error" | sed 's/^/    /'
    fi
    if jq empty "$SITES_DB" >/dev/null 2>&1; then
        ui_kv "Database" "$(ui_badge ok "Valid")"
    else
        ui_kv "Database" "$(ui_badge err "Broken (not valid JSON)")"
    fi
    local db_perm
    db_perm=$(stat -c "%a" "$SITES_DB" 2>/dev/null)
    if [[ "$db_perm" == "600" ]]; then
        ui_kv "Permissions" "$(ui_badge ok "600")"
    else
        ui_kv "Permissions" "$(ui_badge warn "${db_perm:-unknown} (expected 600)")"
    fi

    ui_section "Plugins"
    plugins_load
    if ! plugins_read_enabled; then
        ui_kv "Enabled list" "$(ui_badge err "Invalid: $PLUGINS_ENABLED_ERROR")"
    else
        local id active=0 broken=0
        for id in "${PLUGINS_ON[@]}"; do
            if plugin_is_active "$id"; then ((active++)); else ((broken++)); fi
        done
        ui_kv "Installed" "${#PLUGIN_IDS[@]}"
        ui_kv "Enabled" "$active"
        if ((broken)); then
            ui_kv "Broken" "$(ui_badge err "$broken (Plugins shows why)")"
        fi
    fi

    DASH_TIME=0
    pause
}
