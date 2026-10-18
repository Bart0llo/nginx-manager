#!/bin/bash
# ==========================================================
# NGINX Manager Pro - site manager
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

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
        read_input choice "Select # or action: " || return
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
        read_input name "Site name: " || { input_closed; return 1; }
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
        read_input domain "Domain: " || { input_closed; return 1; }
        validate_domain "$domain" && break
        msg_error "Invalid domain"
    done

    local backend
    while true; do
        read_input backend "Backend (ip:port): " || { input_closed; return 1; }
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
        read_input mode "Select [1-3]: " || { input_closed; return 1; }
        case "$mode" in
            1) tls="http"; break ;;
            2) tls="https"; break ;;
            3) tls="both"; break ;;
            *) msg_error "Invalid selection" ;;
        esac
    done

    if ! site_create "$name" "$domain" "$backend" "$tls"; then
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
    local domain backend tls
    domain=$(db_get "$name" domain)
    backend=$(db_get "$name" backend)
    tls=$(db_get "$name" tls)

    header
    echo -e "${BOLD}EDIT SITE: ${name}${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    local input
    while true; do
        read_input input "Domain [$domain]: " || { input_closed; return 1; }
        input="${input:-$domain}"
        if validate_domain "$input"; then
            domain="$input"
            break
        fi
        msg_error "Invalid domain"
    done

    while true; do
        read_input input "Backend [$backend]: " || { input_closed; return 1; }
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
        read_input mode "Select [$default_mode]: " || { input_closed; return 1; }
        mode="${mode:-$default_mode}"
        case "$mode" in
            1) tls="http"; break ;;
            2) tls="https"; break ;;
            3) tls="both"; break ;;
            *) msg_error "Invalid selection" ;;
        esac
    done

    site_update "$name" "$domain" "$backend" "$tls"
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
    site_delete "$name"
    pause
    # Returns 0 (leave the site's screens) only if the site is really gone.
    ! db_exists "$name"
}

site_toggle() {
    local name="$1"
    local result

    # Act on what nginx actually has, not on a possibly stale db flag.
    if ! sync_enabled_state "$name"; then
        pause
        return 1
    fi

    if [[ -L "$NGINX_ENABLED/$name.conf" ]]; then
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

    local imported=0 file
    for file in "$NGINX_AVAILABLE"/*.conf; do
        site_import "$file" && ((imported++))
    done

    echo
    ((imported == 0)) && echo "No new sites found to import."
    pause
}
