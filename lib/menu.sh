#!/bin/bash
# ==========================================================
# NGINX Manager Pro - main menu
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

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
        read_input choice "Select: " || { input_closed "exiting"; exit 1; }
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
