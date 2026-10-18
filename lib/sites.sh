#!/bin/bash
# ==========================================================
# NGINX Manager Pro - site screens
# Sourced by nginx-site.sh: defines functions only.
#
# Screens and questions only: every change is made by the operations in
# site_ops.sh, nginx.sh and generate.sh, run through ui_run.
# ==========================================================

# ==========================================================
# SITE STATE (read-only)
# ==========================================================
# Prints one "name<TAB>domain<TAB>backend<TAB>tls<TAB>db-enabled-flag" line
# per site, sorted by name.
sites_tsv() {
    jq -r 'to_entries | sort_by(.key)[]
        | [.key, .value.domain, .value.backend, .value.tls, (.value.enabled | tostring)] | @tsv' "$SITES_DB"
}

# Prints on (enabled symlink), off (nothing) or blocked (something that is
# not a symlink, which the manager leaves alone). Never changes anything.
site_link_state() {
    local link="$NGINX_ENABLED/$1.conf"
    if [[ -L "$link" ]]; then
        echo on
    elif [[ -e "$link" ]]; then
        echo blocked
    else
        echo off
    fi
}

# site_warnings <name> <domain> <tls> <db-enabled-flag>
# Prints one line per problem with the site (nothing if there is none).
# Uses DOMAIN and CERT_NAME from load_config.
site_warnings() {
    local name="$1" domain="$2" tls="$3" flag="$4"
    local conf="$NGINX_AVAILABLE/$name.conf" link="$NGINX_ENABLED/$name.conf"

    [[ -f "$conf" ]] || echo "Configuration file $conf is missing"
    case "$(site_link_state "$name")" in
        on)
            [[ "$(readlink -f "$link")" == "$(readlink -f "$conf")" ]] \
                || echo "$link points to $(readlink "$link"), not to the site's configuration"
            [[ "$flag" == true ]] || echo "Database says disabled, nginx has it enabled (corrected on the next change)"
            ;;
        blocked)
            echo "$link is not a symlink; the manager will not enable, disable or delete it"
            ;;
        off)
            [[ "$flag" == true ]] && echo "Database says enabled, nginx has it disabled (corrected on the next change)"
            ;;
    esac
    if [[ "$tls" == https || "$tls" == both ]]; then
        if [[ -z "$DOMAIN" || -z "$CERT_NAME" ]]; then
            echo "Uses HTTPS, but no certificate is configured"
        elif ! domain_covered_by_wildcard "$domain" "$DOMAIN"; then
            echo "Uses HTTPS, but $domain is not covered by the *.$DOMAIN certificate"
        elif [[ ! -f "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" ]]; then
            echo "Uses HTTPS, but certificate $CERT_NAME has not been issued yet"
        fi
    fi
}

tls_label() {
    case "$1" in
        http) echo "HTTP" ;;
        https) echo "HTTPS (HTTP redirects to HTTPS)" ;;
        both) echo "HTTP and HTTPS" ;;
        *) echo "${1:-$SYM_NONE}" ;;
    esac
}

# tls_coverage_hint <domain>  -- says whether HTTPS can work for the domain.
# Returns 1 when the configured certificate cannot cover it.
tls_coverage_hint() {
    if [[ -z "$DOMAIN" || -z "$CERT_NAME" ]]; then
        ui_hint "No wildcard certificate is configured, so only HTTP will work."
        return 1
    elif ! domain_covered_by_wildcard "$1" "$DOMAIN"; then
        ui_hint "$1 is not covered by the *.$DOMAIN certificate, so only HTTP will work."
        return 1
    elif [[ ! -f "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" ]]; then
        ui_hint "Covered by *.$DOMAIN, but that certificate is not issued yet (TLS & certificates)."
    else
        ui_hint "Covered by the *.$DOMAIN certificate."
    fi
}

# ui_choose_tls <default>  -- puts http, https or both in UI_REPLY.
ui_choose_tls() {
    local default_key=""
    case "$1" in
        http) default_key=1 ;;
        https) default_key=2 ;;
        both) default_key=3 ;;
    esac
    ui_menu "TLS mode" "$default_key" \
        "1|HTTP|port 80 only" \
        "2|HTTPS|port 443; port 80 redirects to HTTPS" \
        "3|Both|ports 80 and 443, no redirect" || return
    case "$UI_REPLY" in
        1) UI_REPLY=http ;;
        2) UI_REPLY=https ;;
        3) UI_REPLY=both ;;
    esac
}

# ==========================================================
# SITE LIST
# ==========================================================
# Picks a site; the name goes to UI_REPLY. Returns 2 if there is none or
# the user goes back.
select_site() {
    local prompt="${1:-Select site}" names=() labels=() name domain backend tls flag
    while IFS=$'\t' read -r name domain backend tls flag; do
        names+=("$name")
        labels+=("$(printf '%-20s %s' "$name" "$domain")")
    done < <(sites_tsv 2>/dev/null)

    if ((${#names[@]} == 0)); then
        msg_warning "No sites configured yet"
        return 2
    fi
    echo
    UI_PICK_LABELS=("${labels[@]}")
    ui_pick "$prompt" "${names[@]}"
}

# site_row <index> <name> <domain> <backend> <tls>  -- one table row.
# Wide terminals get a BACKEND column; narrow ones drop it.
site_row() {
    local state badge text
    state=$(site_link_state "$2")
    case "$state" in
        on) badge=on text=ENABLED ;;
        off) badge=off text=DISABLED ;;
        *) badge=unknown text=UNKNOWN ;;
    esac
    printf "  %-3s %-16s " "$1" "$(truncate_field "$2" 16)"
    ui_badge_cell 11 "$badge" "$text"
    if ((UI_COLS >= 80)); then
        printf " %-6s %-28s %s\n" "${5^^}" "$(truncate_field "$3" 28)" "$(truncate_field "$4" 22)"
    else
        printf " %-6s %s\n" "${5^^}" "$(truncate_field "$3" $((UI_COLS > 52 ? UI_COLS - 43 : 9)))"
    fi
}

site_table_header() {
    if ((UI_COLS >= 80)); then
        printf "  %-3s %-16s %-11s %-6s %-28s %s\n" "#" "NAME" "STATUS" "TLS" "DOMAIN" "BACKEND"
    else
        printf "  %-3s %-16s %-11s %-6s %s\n" "#" "NAME" "STATUS" "TLS" "DOMAIN"
    fi
}

sites_menu() {
    local filter=""
    while true; do
        ui_screen "Sites"
        load_config >/dev/null 2>&1
        if ! jq empty "$SITES_DB" >/dev/null 2>&1; then
            msg_error "The site database $SITES_DB cannot be read (invalid JSON)"
            pause
            return
        fi

        local names=() domains=() backends=() tlss=() flags=() name domain backend tls flag
        while IFS=$'\t' read -r name domain backend tls flag; do
            names+=("$name") domains+=("$domain") backends+=("$backend") tlss+=("$tls") flags+=("$flag")
        done < <(sites_tsv)

        local enabled=0 i
        for name in "${names[@]}"; do
            [[ -L "$NGINX_ENABLED/$name.conf" ]] && ((enabled++))
        done

        if ((UI_GUM)); then
            sites_menu_gum && continue
            (($? == 2)) && return
            continue
        fi

        if ((${#names[@]} == 0)); then
            echo "  No sites configured yet"
            ui_hint "Create one with [N], or take over existing nginx configs with [I]."
        else
            echo "  ${#names[@]} site(s): $enabled enabled, $((${#names[@]} - enabled)) disabled"
            [[ -n "$filter" ]] && ui_hint "Filter: '$filter'  (/ alone clears it)"
            echo
            site_table_header
            local shown=() warnings
            for i in "${!names[@]}"; do
                if [[ -n "$filter" && "${names[i],,}" != *"${filter,,}"* && "${domains[i],,}" != *"${filter,,}"* ]]; then
                    continue
                fi
                shown+=("${names[i]}")
                site_row "${#shown[@]}" "${names[i]}" "${domains[i]}" "${backends[i]}" "${tlss[i]}"
                warnings=$(site_warnings "${names[i]}" "${domains[i]}" "${tlss[i]}" "${flags[i]}")
                [[ -n "$warnings" ]] && printf '%s\n' "      ${YELLOW}${SYM_WARN} ${warnings%%$'\n'*}${NC}"
            done
            ((${#shown[@]})) || echo "  (no site matches '$filter')"
        fi

        echo
        ui_rule
        ((${#names[@]})) && ui_hint "Open a site: enter its number or name. Filter: /text"
        echo "  [N] New site   [I] Import existing   [G] Regenerate all   [Q] Back"
        echo

        local choice redraw=0
        while ((!redraw)); do
            ui_read "Select: " || return
            choice="$UI_REPLY"
            redraw=1
            case "${choice,,}" in
                ""|q) return ;;
                n) add_site ;;
                i) import_sites ;;
                g) regenerate_all ;;
                /*) filter="${choice#/}" ;;
                *)
                    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#shown[@]})); then
                        site_details "${shown[choice - 1]}"
                    elif db_exists "$choice" 2>/dev/null; then
                        site_details "$choice"
                    else
                        msg_error "Invalid option '$choice' - enter a site number, a name, or a key in brackets"
                        redraw=0
                    fi
                    ;;
            esac
        done
    done
}

# The site list as one searchable gum list, sites first, then actions.
# Uses the arrays filled by sites_menu. Returns 0 to redraw, 2 to go back.
sites_menu_gum() {
    local rows=() i row warnings
    for i in "${!names[@]}"; do
        # Without the "  #   " index column the table header has too.
        row=$(NC="" GREEN="" YELLOW="" RED="" GRAY="" site_row "" "${names[i]}" "${domains[i]}" "${backends[i]}" "${tlss[i]}")
        row="${row:6}"
        warnings=$(site_warnings "${names[i]}" "${domains[i]}" "${tlss[i]}" "${flags[i]}" | grep -c .)
        ((warnings)) && row+="  $SYM_WARN $warnings warning(s)"
        rows+=("$row")
    done
    local actions=("+ New site" "Import existing nginx configs" "Regenerate all configurations" "Back")

    echo "  ${#names[@]} site(s): $enabled enabled, $((${#names[@]} - enabled)) disabled"
    ((${#names[@]})) || ui_hint "No sites yet: choose '+ New site', or import existing nginx configs."
    ui_hint "Enter opens a site. Type to search. Esc goes back."
    echo

    local header
    header=$(site_table_header)
    ui_gum filter "--header=${header:6}" "--placeholder=Search sites..." --height=20 -- "${rows[@]}" "${actions[@]}"
    case $? in
        0) ;;
        2) return 2 ;;
        *) return 0 ;;
    esac
    for i in "${!rows[@]}"; do
        [[ "${rows[i]}" == "$UI_REPLY" ]] && { site_details "${names[i]}"; return 0; }
    done
    case "$UI_REPLY" in
        "${actions[0]}") add_site ;;
        "${actions[1]}") import_sites ;;
        "${actions[2]}") regenerate_all ;;
        *) return 2 ;;
    esac
}

# ==========================================================
# ONE SITE
# ==========================================================
site_details() {
    local name="$1"

    while db_exists "$name" 2>/dev/null; do
        ui_screen "Sites" "$name"
        load_config >/dev/null 2>&1

        local domain backend tls created flag conf link state
        domain=$(db_get "$name" domain)
        backend=$(db_get "$name" backend)
        tls=$(db_get "$name" tls)
        created=$(db_get "$name" created)
        flag=$(db_get "$name" enabled)
        conf="$NGINX_AVAILABLE/$name.conf"
        link="$NGINX_ENABLED/$name.conf"
        state=$(site_link_state "$name")

        ui_kv "Domain" "$domain"
        ui_kv "Backend" "http://$backend"
        ui_kv "TLS mode" "$(tls_label "$tls")"
        case "$state" in
            on) ui_kv "Status" "$(ui_badge on "Enabled")" ;;
            off) ui_kv "Status" "$(ui_badge off "Disabled")" ;;
            *) ui_kv "Status" "$(ui_badge unknown "Unknown")" ;;
        esac
        if [[ "$state" == on ]]; then
            if ui_shield test_nginx_config >/dev/null 2>&1; then
                ui_kv "NGINX config" "$(ui_badge ok "Valid")"
            else
                ui_kv "NGINX config" "$(ui_badge err "Invalid (Logs & diagnostics shows why)")"
            fi
        fi
        if [[ "$tls" == "https" || "$tls" == "both" ]]; then
            if [[ -n "$CERT_NAME" && -n "$DOMAIN" ]]; then
                ui_kv "Certificate" "*.${DOMAIN} (${CERT_NAME})"
            else
                ui_kv "Certificate" "$(ui_badge warn "Not configured")"
            fi
        fi
        ui_kv "Created" "$created"
        ui_kv "Config file" "$conf"
        [[ "$state" == on ]] && ui_kv "Enabled link" "$link"
        local plugin_data
        plugin_data=$(jq -r --arg n "$name" '.[$n].plugins // {} | keys | join(", ")' "$SITES_DB" 2>/dev/null)
        [[ -n "$plugin_data" ]] && ui_kv "Plugin data" "$plugin_data"

        local warnings line
        warnings=$(site_warnings "$name" "$domain" "$tls" "$flag")
        if [[ -n "$warnings" ]]; then
            ui_section "Warnings"
            while IFS= read -r line; do msg_warning "$line"; done <<< "$warnings"
        fi
        echo

        local items=("e|Edit|change domain, backend or TLS mode")
        case "$state" in
            on) items+=("t|Disable|take the site offline: remove the link, reload nginx") ;;
            off) items+=("t|Enable|put the site online: link, nginx -t, reload") ;;
        esac
        items+=("l|TLS mode|switch between HTTP, HTTPS and both"
            "r|Regenerate|rewrite the config from the saved settings"
            "c|View config|show the nginx configuration file"
            "d|Delete|remove the site (its config is backed up first)"
            "q|Back|")
        ui_menu "Actions" q "${items[@]}" || return
        case "$UI_REPLY" in
            e) edit_site "$name" ;;
            t) site_toggle "$name" ;;
            l) site_tls_mode "$name" ;;
            r) regenerate_config "$name" ;;
            c) view_site_config "$name" ;;
            d) delete_site "$name" && return ;;
            q) return ;;
        esac
    done
}

view_site_config() {
    local name="$1"
    ui_screen "Sites" "$name" "Configuration"
    if [[ -f "$NGINX_AVAILABLE/$name.conf" ]]; then
        echo "$NGINX_AVAILABLE/$name.conf"
        echo
        ui_pager < "$NGINX_AVAILABLE/$name.conf"
    else
        msg_error "Configuration file not found"
        pause
    fi
}

add_site() {
    load_config >/dev/null 2>&1
    ui_screen "Sites" "New site"
    echo "Three steps; nothing is written until you confirm the summary."
    ui_cancel_hint

    ui_section "1. Name"
    local name
    while true; do
        ui_input "Site name" "" "letters, numbers, - and _ (also the config file name)" || { ui_aborted $?; return 1; }
        name="$UI_REPLY"
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

    ui_section "2. Address"
    local default_domain=""
    [[ -n "$DOMAIN" ]] && validate_domain "$name.$DOMAIN" && default_domain="$name.$DOMAIN"
    local domain
    while true; do
        ui_input "Domain" "$default_domain" "the name clients use, e.g. app.lan.example.com" || { ui_aborted $?; return 1; }
        domain="$UI_REPLY"
        validate_domain "$domain" && break
        msg_error "Invalid domain - expected a name like app.example.com"
    done

    local backend
    while true; do
        ui_input "Backend" "" "host:port of the service to proxy to, e.g. 127.0.0.1:8080" || { ui_aborted $?; return 1; }
        backend="$UI_REPLY"
        validate_backend "$backend" && break
        msg_error "Invalid backend (expected host:port, 1-65535)"
    done

    ui_section "3. TLS"
    local default_tls="${DEFAULT_TLS:-https}"
    tls_coverage_hint "$domain" || default_tls=http
    local tls
    ui_choose_tls "$default_tls" || { ui_aborted $?; return 1; }
    tls="$UI_REPLY"

    ui_section "Summary"
    ui_kv "Name" "$name"
    ui_kv "Domain" "$domain"
    ui_kv "Backend" "http://$backend"
    ui_kv "TLS mode" "$(tls_label "$tls")"
    ui_kv "Config file" "$NGINX_AVAILABLE/$name.conf"
    ui_hint "The site is created disabled; you can enable it right after."
    echo
    if ! confirm "Create site '$name'?" y; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return 1
    fi
    echo

    if ! ui_run site_create "$name" "$domain" "$backend" "$tls"; then
        pause
        return 1
    fi

    echo
    msg_success "Configuration generated"
    echo
    ui_hint "Enabling links the site into $NGINX_ENABLED, runs nginx -t and reloads nginx."
    if confirm "Enable site now?" y; then
        echo
        ui_run enable_site "$name"
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
    load_config >/dev/null 2>&1

    ui_screen "Sites" "$name" "Edit"
    echo "Press Enter to keep a current value. Nothing changes until you confirm."
    ui_cancel_hint
    echo

    local new_domain new_backend new_tls
    while true; do
        ui_input "Domain" "$domain" "" || { ui_aborted $?; return 1; }
        new_domain="$UI_REPLY"
        validate_domain "$new_domain" && break
        msg_error "Invalid domain - expected a name like app.example.com"
    done

    while true; do
        ui_input "Backend" "$backend" "" || { ui_aborted $?; return 1; }
        new_backend="$UI_REPLY"
        validate_backend "$new_backend" && break
        msg_error "Invalid backend (expected host:port, 1-65535)"
    done

    echo
    tls_coverage_hint "$new_domain"
    ui_choose_tls "$tls" || { ui_aborted $?; return 1; }
    new_tls="$UI_REPLY"

    if [[ "$new_domain" == "$domain" && "$new_backend" == "$backend" && "$new_tls" == "$tls" ]]; then
        echo
        msg_warning "No changes - nothing to apply"
        ui_hint "To rewrite the configuration anyway, use Regenerate."
        pause
        return 0
    fi

    ui_section "Changes"
    [[ "$new_domain" != "$domain" ]] && ui_kv "Domain" "$domain $SYM_ARROW $new_domain"
    [[ "$new_backend" != "$backend" ]] && ui_kv "Backend" "$backend $SYM_ARROW $new_backend"
    [[ "$new_tls" != "$tls" ]] && ui_kv "TLS mode" "${tls^^} $SYM_ARROW ${new_tls^^}"
    site_apply_hint "$name"
    echo
    if ! confirm "Apply these changes?" y; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return 1
    fi
    echo

    ui_run site_update "$name" "$new_domain" "$new_backend" "$new_tls"
    pause
}

# Says what applying a change to the site will do.
site_apply_hint() {
    if [[ -L "$NGINX_ENABLED/$1.conf" ]]; then
        ui_hint "The site is enabled: the new configuration is tested with nginx -t and nginx is"
        ui_hint "reloaded. If the test fails, the previous configuration is restored."
    else
        ui_hint "The site is disabled: only its configuration file is rewritten (after a backup)."
    fi
}

site_tls_mode() {
    local name="$1"
    local domain backend tls
    domain=$(db_get "$name" domain)
    backend=$(db_get "$name" backend)
    tls=$(db_get "$name" tls)
    load_config >/dev/null 2>&1

    ui_screen "Sites" "$name" "TLS mode"
    ui_kv "Domain" "$domain"
    ui_kv "TLS mode" "$(tls_label "$tls")"
    echo
    tls_coverage_hint "$domain"
    ui_cancel_hint
    echo
    ui_choose_tls "$tls" || { ui_aborted $?; return 1; }
    local new_tls="$UI_REPLY"
    if [[ "$new_tls" == "$tls" ]]; then
        msg_warning "No changes - nothing to apply"
        pause
        return 0
    fi

    echo
    site_apply_hint "$name"
    if ! confirm "Switch '$name' from ${tls^^} to ${new_tls^^}?" y; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return 1
    fi
    echo
    ui_run site_update "$name" "$domain" "$backend" "$new_tls"
    pause
}

delete_site() {
    local name="$1"
    local domain backend status_txt
    domain=$(db_get "$name" domain)
    backend=$(db_get "$name" backend)
    case "$(site_link_state "$name")" in
        on) status_txt="$(ui_badge on "Enabled")" ;;
        off) status_txt="$(ui_badge off "Disabled")" ;;
        *) status_txt="$(ui_badge unknown "Unknown")" ;;
    esac

    ui_screen "Sites" "$name" "Delete"
    ui_kv "Domain" "$domain"
    ui_kv "Backend" "$backend"
    ui_kv "Status" "$status_txt"
    echo
    echo "This removes the site's nginx configuration, its enabled link and its"
    echo "database entry, then reloads nginx. The configuration is backed up to"
    echo "$BACKUP_DIR first; if the backup fails, nothing is deleted."
    echo

    ui_confirm_typed "$name" "Type the site name to confirm deletion"
    local rc=$?
    if ((rc == 3)); then
        echo
        msg_warning "Cancelled (name did not match)"
        pause
        return 1
    elif ((rc != 0)); then
        ui_aborted "$rc"
        return 1
    fi

    echo
    ui_run site_delete "$name"
    pause
    # Returns 0 (leave the site's screens) only if the site is really gone.
    ! db_exists "$name"
}

site_toggle() {
    local name="$1"
    local result

    # Act on what nginx actually has, not on a possibly stale db flag.
    if ! ui_run sync_enabled_state "$name"; then
        pause
        return 1
    fi

    if [[ -L "$NGINX_ENABLED/$name.conf" ]]; then
        confirm "Disable site '$name'?" y || return 1
        echo
        ui_run disable_site "$name"
        result=$?
    else
        confirm "Enable site '$name'?" y || return 1
        echo
        ui_run enable_site "$name"
        result=$?
    fi

    pause
    return $result
}

regenerate_config() {
    local name="$1"
    echo
    site_apply_hint "$name"
    confirm "Regenerate configuration for '$name'?" n || return
    echo
    ui_run regenerate_site_safe "$name"
    local rc=$?
    if ((rc == 0)); then
        msg_success "Configuration regenerated"
    elif ((rc == 3)); then
        echo
        echo "The configuration was regenerated, but nginx was not reloaded."
        echo "The change is not live yet."
    else
        echo
        echo "The new configuration was rejected."
        echo "The previous configuration was restored if possible."
    fi
    pause
}

regenerate_all() {
    ui_screen "Sites" "Regenerate all"
    echo "Rewrites every site's configuration from its saved settings. Enabled"
    echo "sites are tested with nginx -t one by one; a site whose new"
    echo "configuration fails keeps its previous one."
    echo
    confirm "Regenerate configuration for all sites?" n || return
    echo
    msg_step "Regenerating nginx configs..."
    echo

    local ok=() failed=() unloaded=() name
    while read -r name; do
        ui_run regenerate_site_safe "$name"
        case $? in
            0) ok+=("$name") ;;
            3) unloaded+=("$name"); failed+=("$name") ;;
            *) failed+=("$name") ;;
        esac
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
    if ((${#unloaded[@]} > 0)); then
        echo "Regenerated, but nginx was not reloaded (not live yet): ${unloaded[*]}"
    fi
    echo
    echo "${#ok[@]} succeeded, ${#failed[@]} failed"
    pause
}

import_sites() {
    ui_screen "Sites" "Import existing"
    echo "Adds configs in $NGINX_AVAILABLE that are not managed yet. The files"
    echo "themselves are not modified, and nothing is enabled or disabled."
    echo
    msg_step "Searching nginx configs..."
    echo

    local imported=0 file
    for file in "$NGINX_AVAILABLE"/*.conf; do
        ui_run site_import "$file" && ((imported++))
    done

    echo
    if ((imported == 0)); then
        echo "No new sites found to import."
    else
        msg_success "$imported site(s) imported"
    fi
    pause
}
