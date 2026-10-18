#!/bin/bash
# ==========================================================
# NGINX MANAGER PRO v3
# Debian / Ubuntu
# Nginx + Certbot + Cloudflare DNS
# ==========================================================

# ==========================================================
# MODULES
# ==========================================================
# Sourcing the modules only defines constants and functions; nothing
# runs until main. tools/bundle.sh inlines this block to build the
# single-file script used by install.sh.
# @bundle-begin
NM_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib"
if [[ ! -f "$NM_LIB_DIR/core.sh" ]]; then
    echo "NGINX Manager: modules not found in $NM_LIB_DIR" >&2
    return 1 2>/dev/null || exit 1
fi
source "$NM_LIB_DIR/core.sh"
source "$NM_LIB_DIR/ui.sh"
source "$NM_LIB_DIR/config.sh"
source "$NM_LIB_DIR/db.sh"
source "$NM_LIB_DIR/validate.sh"
source "$NM_LIB_DIR/backup.sh"
source "$NM_LIB_DIR/generate.sh"
source "$NM_LIB_DIR/nginx.sh"
source "$NM_LIB_DIR/site_ops.sh"
source "$NM_LIB_DIR/sites.sh"
source "$NM_LIB_DIR/tls.sh"
source "$NM_LIB_DIR/system.sh"
source "$NM_LIB_DIR/dashboard.sh"
source "$NM_LIB_DIR/menu.sh"
# @bundle-end

# ==========================================================
# START
# ==========================================================
main() {
    # Root check
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}${BOLD}Run as root${NC}"
        exec sudo "$0" "$@"
    fi

    check_core_dependencies || exit 1

    init_directories

    # Lock
    exec 200>"$LOCK_FILE"
    flock -n 200 || {
        echo -e "${YELLOW}Manager already running${NC}"
        exit 1
    }

    # Init
    create_default_config
    first_run_setup || exit 1
    create_database
    create_snippets

    main_menu
}

# NM_NO_MAIN=1 loads the functions without starting (used by the tests).
[[ "${NM_NO_MAIN:-}" == 1 ]] || main "$@"
