#!/bin/bash
# ==========================================================
# NGINX Manager Pro - main menu, settings and help
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# MAIN MENU
# ==========================================================
main_menu() {
    while true; do
        ui_screen
        render_dashboard_status
        ui_gum_note
        echo

        ui_menu "Main menu" "" \
            "1|Status|full health check of nginx, TLS, manager and plugins" \
            "2|Sites|browse, enable, edit and delete sites" \
            "3|New site|create a site step by step" \
            "4|TLS & certificates|certificate status, issue, renew, credentials" \
            "5|Plugins|enable, disable and configure plugins" \
            "6|Settings|manager configuration and interface" \
            "7|Logs & diagnostics|manager log, backups, nginx -t" \
            "h|Help|keys, options and where things are" \
            "q|Quit|"
        case $? in
            1) ui_aborted 1 "exiting"; exit 1 ;;
            2) exit 0 ;;
        esac

        case "$UI_REPLY" in
            1) system_check ;;
            2) sites_menu ;;
            3) add_site ;;
            4) tls_menu ;;
            5) plugins_menu ;;
            6) settings_screen ;;
            7) diagnostics_menu ;;
            h) help_screen ;;
            q) exit 0 ;;
        esac
    done
}

settings_screen() {
    ui_screen "Settings"

    printf '%s\n' "${BOLD}Manager configuration${NC}"
    if load_config >/dev/null 2>&1; then
        ui_kv "Base domain" "${DOMAIN:-$SYM_NONE}"
        ui_kv "Certificate" "${CERT_NAME:-$SYM_NONE}"
        ui_kv "Certbot email" "${CERTBOT_EMAIL:-$SYM_NONE}"
        ui_kv "Default TLS" "${DEFAULT_TLS:-$SYM_NONE}"
    else
        ui_kv "Status" "$(ui_badge err "Invalid - Status shows the line")"
    fi
    ui_hint "Edit $CONFIG_FILE by hand to change these (format: README, Configuration)."

    ui_section "Files"
    ui_kv "Configuration" "$CONFIG_FILE"
    ui_kv "Site database" "$SITES_DB"
    ui_kv "Backups" "$BACKUP_DIR"
    ui_kv "Log" "$LOG_FILE"
    ui_kv "Plugins" "$PLUGIN_DIR"
    ui_kv "Sites" "$NGINX_AVAILABLE"

    ui_section "Interface"
    if ((UI_GUM)); then
        ui_kv "Prompts" "$(ui_badge ok "gum $UI_GUM_VERSION (enhanced)")"
    else
        ui_kv "Prompts" "$(ui_badge off "Basic ($UI_GUM_NOTE)")"
        ui_hint "For arrow-key menus and search, install gum $UI_GUM_MIN or newer (see Help)."
    fi
    if [[ -n "$NC" ]]; then
        ui_kv "Colours" "on (NO_COLOR=1 turns them off)"
    else
        ui_kv "Colours" "off"
    fi
    pause
}

help_screen() {
    ui_screen "Help"
    printf '%s\n' "${BOLD}Moving around${NC}"
    if ((UI_GUM)); then
        echo "  Arrow keys or j/k move, Enter selects, / or typing searches lists,"
        echo "  Esc goes back or cancels. Cancelling a form changes nothing."
    else
        echo "  Type the key in brackets and press Enter. In lists, type a number"
        echo "  or a name. Enter on its own goes back. Ctrl-C cancels a form"
        echo "  without changing anything."
    fi

    ui_section "Safety"
    echo "  Every change is backed up first. Changes to enabled sites are tested"
    echo "  with nginx -t and rolled back if the test fails; nginx is only reloaded"
    echo "  after a passing test. Deleting a site asks you to type its name."

    ui_section "Enhanced interface (optional)"
    echo "  With gum $UI_GUM_MIN or newer installed, menus use arrow keys and lists"
    echo "  are searchable. Install it from your distribution or from Charm's"
    echo "  apt repository: https://github.com/charmbracelet/gum#installation"
    echo "  The manager never installs it and works the same without it."
    ui_kv "Now" "$( ((UI_GUM)) && echo "gum $UI_GUM_VERSION" || echo "basic interface: $UI_GUM_NOTE")"

    ui_section "Command line"
    echo "  nginx-manager --plain            basic interface even with gum"
    echo "  nginx-manager --non-interactive  never wait for input (exit 1 instead)"
    echo "  nginx-manager --version          installed version"
    echo "  NO_COLOR=1                       no colours"

    ui_section "Documentation"
    echo "  README.md (configuration, TLS, updating) and docs/PLUGINS.md (plugins)"
    ui_kv "Version" "$NM_VERSION"
    pause
}
