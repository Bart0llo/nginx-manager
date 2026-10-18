#!/bin/bash
# ==========================================================
# NGINX MANAGER PRO v3
# Debian / Ubuntu
# Nginx + Certbot + Cloudflare DNS
# ==========================================================

# "dev" in a checkout; tools/bundle.sh --version stamps release builds.
# install.sh reads this line from a bundle without running it.
NM_VERSION="dev"

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
# A checkout uses its own plugins/ directory; the bundle keeps core.sh's.
PLUGIN_DIR="$(dirname "$NM_LIB_DIR")/plugins"
source "$NM_LIB_DIR/ui.sh"
source "$NM_LIB_DIR/config.sh"
source "$NM_LIB_DIR/db.sh"
source "$NM_LIB_DIR/validate.sh"
source "$NM_LIB_DIR/backup.sh"
source "$NM_LIB_DIR/generate.sh"
source "$NM_LIB_DIR/nginx.sh"
source "$NM_LIB_DIR/plugins.sh"
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
usage() {
    cat <<EOF
Usage: nginx-manager [--plain] [--non-interactive] [--help] [--version]

Interactive manager for NGINX reverse proxy sites (runs as root).

  --plain            use the basic text interface even if gum is installed
  --non-interactive  never wait for input: stop with exit status 1 where
                     an answer is needed
  -h, --help         show this help
  --version          show the installed version

Environment:
  NM_UI=auto|gum|plain   interface (default auto: gum $UI_GUM_MIN+ in a terminal)
  NM_NONINTERACTIVE=1    same as --non-interactive
  NO_COLOR=1             no colours

sudo usually drops environment variables; prefer the options, or run
e.g. "sudo NO_COLOR=1 nginx-manager".
EOF
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
            --version) echo "nginx-manager $NM_VERSION"; exit 0 ;;
            --plain) NM_UI=plain ;;
            --non-interactive) NM_NONINTERACTIVE=1 ;;
            *)
                echo "nginx-manager: unknown option '$arg'" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
    ui_init

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

    # Ctrl-C now cancels the current prompt rather than killing the manager.
    ui_trap_interrupts

    # Init
    create_default_config
    first_run_setup || exit 1
    create_database
    create_snippets

    main_menu
}

# NM_NO_MAIN=1 loads the functions without starting (used by the tests).
[[ "${NM_NO_MAIN:-}" == 1 ]] || main "$@"
