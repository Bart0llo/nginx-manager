#!/bin/bash
# ==========================================================
# NGINX Manager Pro - AdGuard Home DNS rewrites
# Sourced by nginx-site.sh: defines state and functions only.
#
# Talks to AdGuard Home's web API (<URL>/control/...) with curl. Inactive
# until configured: nothing is sent anywhere until a connection is saved
# and the user opens the DNS screen. Nothing here runs when sites change.
#
# The login password lives in $ADGUARD_SECRET (0600). It reaches curl only
# as an Authorization header inside a config read from stdin (-K -): never
# in arguments, the environment, the log or the screen.
#
# HTTPS certificates are always verified against the system's trusted
# certificates. There is no option to skip that or to name another CA: a
# private CA belongs in the system store (update-ca-certificates).
# ==========================================================

AG_CONNECT_TIMEOUT=5
AG_MAX_TIME=15
AG_MAX_BYTES=1048576

# Filled by adguard_load_config.
AG_URL="" AG_USER="" AG_ANSWER="" AG_CONFIG_ERROR=""
# Filled by adguard_request.
AG_HTTP="" AG_BODY="" AG_ERROR=""

# ==========================================================
# CONFIGURATION
# ==========================================================
# Reads $ADGUARD_CONF as data (plugin_read_kv: strict KEY=VALUE, never
# executed). Keys:
#   URL             AdGuard Home web address, http(s)://host[:port][/path]
#   USERNAME        login; empty when AdGuard Home has no users
#   DEFAULT_ANSWER  IP address offered when adding a rewrite (optional)
# Returns 0 loaded, 1 invalid (AG_CONFIG_ERROR says why; values never
# appear in it), 2 not configured (no file).
adguard_load_config() {
    AG_URL="" AG_USER="" AG_ANSWER="" AG_CONFIG_ERROR=""
    [[ -e "$ADGUARD_CONF" || -L "$ADGUARD_CONF" ]] || return 2

    local key
    local -A conf=()
    if ! plugin_read_kv "$ADGUARD_CONF" conf; then
        AG_CONFIG_ERROR="$PLUGIN_KV_ERROR"
        return 1
    fi
    while IFS= read -r key; do
        case "$key" in
            URL|USERNAME|DEFAULT_ANSWER) ;;
            *) AG_CONFIG_ERROR="unknown setting $key"; return 1 ;;
        esac
    done < <(plugin_sorted_keys conf)

    if [[ -z "${conf[URL]}" ]]; then
        AG_CONFIG_ERROR="URL is missing"
    elif ! validate_http_url "${conf[URL]}"; then
        AG_CONFIG_ERROR="invalid URL"
    elif [[ -n "${conf[USERNAME]}" ]] && ! adguard_valid_user "${conf[USERNAME]}"; then
        AG_CONFIG_ERROR="invalid USERNAME"
    elif [[ -n "${conf[DEFAULT_ANSWER]}" ]] && ! adguard_valid_ip "${conf[DEFAULT_ANSWER]}"; then
        AG_CONFIG_ERROR="invalid DEFAULT_ANSWER"
    fi
    [[ -n "$AG_CONFIG_ERROR" ]] && return 1

    AG_URL="${conf[URL]%/}"
    AG_USER="${conf[USERNAME]}"
    AG_ANSWER="${conf[DEFAULT_ANSWER]}"
}

# A Basic-auth user name cannot contain ':'; the set is kept small so it
# also round-trips through the KEY=VALUE file unchanged.
adguard_valid_user() { [[ "$1" =~ ^[A-Za-z0-9._@+-]{1,64}$ ]]; }
adguard_valid_ip() { validate_ipv4 "$1" || validate_ipv6 "$1"; }

# adguard_save_config <url> <username> <default-answer>
# Validates and writes $ADGUARD_CONF (0600, temp file + rename). A trailing
# "/" or "/control" on the URL is dropped. The password is separate
# (adguard_password_set). Returns 0 saved, 1 failed, 2 invalid input.
adguard_save_config() {
    local url="${1%/}" user="$2" answer="$3" tmp
    url="${url%/control}"
    if ! validate_http_url "$url"; then
        msg_error "Invalid URL (expected http(s)://host[:port][/path], without a login, query or #)"
        return 2
    fi
    if [[ -n "$user" ]] && ! adguard_valid_user "$user"; then
        msg_error "Invalid username (1-64 letters, numbers, . _ @ + -)"
        return 2
    fi
    if [[ -n "$answer" ]] && ! adguard_valid_ip "$answer"; then
        msg_error "Invalid IP address: '$answer'"
        return 2
    fi

    if ! tmp=$(mktemp -p "$MANAGER_DIR") || ! chmod 600 "$tmp" || ! {
        echo "# AdGuard Home connection (NGINX Manager). The password is in $ADGUARD_SECRET."
        printf '%s\n' "URL=$url" "USERNAME=$user" "DEFAULT_ANSWER=$answer"
    } > "$tmp" || ! mv -fT "$tmp" "$ADGUARD_CONF"; then
        [[ -n "$tmp" ]] && rm -f "$tmp"
        msg_error "Failed to write $ADGUARD_CONF"
        log "AdGuard Home settings not saved: could not write $ADGUARD_CONF"
        return 1
    fi
    log "AdGuard Home settings saved: $url"
}

# adguard_password_set   (value on stdin) -- returns as secret_write.
adguard_password_set() {
    secret_write "$ADGUARD_SECRET" "the AdGuard Home password" || return
    log "AdGuard Home password saved"
}

adguard_password_saved() { [[ -f "$ADGUARD_SECRET" && -s "$ADGUARD_SECRET" ]]; }

# Deletes the saved connection: settings and password.
adguard_remove_config() {
    if ! rm -f "$ADGUARD_CONF" "$ADGUARD_SECRET"; then
        msg_error "Failed to remove the AdGuard Home settings"
        return 1
    fi
    msg_success "AdGuard Home connection removed"
    log "AdGuard Home settings and password removed"
}

# ==========================================================
# API
# ==========================================================
# adguard_request <method> <endpoint> [<json-body>]
# Sends one request to $AG_URL/control/<endpoint> (call adguard_load_config
# first). Sets AG_HTTP (status; empty when no answer arrived) and AG_BODY.
# Returns 0 for a 2xx answer; otherwise 1 with AG_ERROR saying what went
# wrong. Redirects are not followed; there is no retry (AdGuard Home blocks
# an address after repeated failed logins). AG_ERROR is built from the
# status and AdGuard Home's reply, never from what was sent.
adguard_request() {
    local method="$1" endpoint="$2" body="$3" auth="" password out code rc
    AG_HTTP="" AG_BODY="" AG_ERROR=""
    if ! command -v curl >/dev/null 2>&1; then
        AG_ERROR="curl is not installed (apt install curl)"
        return 1
    fi
    if [[ -n "$AG_USER" ]]; then
        if ! adguard_password_saved; then
            AG_ERROR="no password saved for '$AG_USER' - set it under Connection"
            return 1
        fi
        # Built in this shell: base64 only ever sees the value on stdin.
        password=$(<"$ADGUARD_SECRET")
        auth=$(printf '%s:%s' "$AG_USER" "$password" | base64 -w0)
        password=""
    fi
    if ! out=$(mktemp -t nm-adguard.XXXXXX); then
        AG_ERROR="could not create a temporary file"
        return 1
    fi

    # -q first: ~/.curlrc must not add options (e.g. --insecure).
    local args=(-q -s --proto =http,https --connect-timeout "$AG_CONNECT_TIMEOUT"
        --max-time "$AG_MAX_TIME" --max-filesize "$AG_MAX_BYTES" -K - -o "$out"
        -w '%{http_code}' -H 'Accept: application/json')
    [[ "$method" == GET ]] || args+=(-X "$method")
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
    code=$(if [[ -n "$auth" ]]; then printf 'header = "Authorization: Basic %s"\n' "$auth"; fi \
        | curl "${args[@]}" "$AG_URL/control/$endpoint" 2>/dev/null)
    rc=$?
    auth=""
    AG_BODY=$(tr -d '\0' < "$out" 2>/dev/null | head -c "$AG_MAX_BYTES")
    rm -f "$out"

    if ((rc != 0)); then
        case "$rc" in
            6) AG_ERROR="could not resolve the host name in $AG_URL" ;;
            7) AG_ERROR="could not connect to $AG_URL (is AdGuard Home running, and the address and port right?)" ;;
            28) AG_ERROR="no answer from $AG_URL within ${AG_MAX_TIME}s (timed out)" ;;
            51|60)
                AG_ERROR="the certificate of $AG_URL is not trusted or does not match its name (curl exit $rc) - if AdGuard Home uses a private CA, add it to this system's trusted certificates (update-ca-certificates)" ;;
            35|53|54|58|59|64|66|80|83|90|91)
                AG_ERROR="TLS connection to $AG_URL failed (curl exit $rc) - is it really HTTPS on that port?" ;;
            77) AG_ERROR="this system's trusted certificates could not be read (curl exit 77)" ;;
            52|56) AG_ERROR="the connection to $AG_URL broke off without an answer (curl exit $rc)" ;;
            63) AG_ERROR="the answer was larger than $AG_MAX_BYTES bytes - not AdGuard Home?" ;;
            *) AG_ERROR="request to $AG_URL failed (curl exit $rc)" ;;
        esac
        return 1
    fi

    AG_HTTP="$code"
    case "$code" in
        2??) return 0 ;;
        3??) AG_ERROR="redirected (HTTP $code) - enter the final address, e.g. with https://" ;;
        400) AG_ERROR="AdGuard Home rejected the request: $(adguard_clean_text "$AG_BODY")" ;;
        401)
            if [[ -n "$AG_USER" ]]; then
                AG_ERROR="login failed: wrong username or password, or too many failed attempts (AdGuard Home then blocks this address for a while)"
            else
                AG_ERROR="AdGuard Home requires a login - set the username and password under Connection"
            fi
            ;;
        403) AG_ERROR="access denied (HTTP 403) - is this address allowed in AdGuard Home's access settings?" ;;
        404|405) AG_ERROR="not found (HTTP $code): check the URL (AdGuard Home's web address, without /control), or this AdGuard Home version does not support the request" ;;
        429) AG_ERROR="too many failed login attempts - AdGuard Home blocks this address for a while" ;;
        5??) AG_ERROR="AdGuard Home server error (HTTP $code): $(adguard_clean_text "$AG_BODY")" ;;
        *) AG_ERROR="unexpected answer (HTTP ${code:-none})" ;;
    esac
    return 1
}

# First line of a server message, without control characters, at most 200
# characters - safe to show and log.
adguard_clean_text() {
    local text="${1%%$'\n'*}"
    text="${text//[[:cntrl:]]/}"
    ((${#text} > 200)) && text="${text:0:197}..."
    printf '%s' "${text:-no details}"
}

# ==========================================================
# OPERATIONS
# ==========================================================
# Loads the settings for an operation. Returns 0, or 2 with a message when
# they are missing or invalid.
adguard_require_config() {
    adguard_load_config
    case $? in
        0) return 0 ;;
        1) msg_error "Invalid $ADGUARD_CONF ($AG_CONFIG_ERROR) - set the connection again" ;;
        *) msg_error "AdGuard Home is not configured - set the connection first" ;;
    esac
    return 2
}

# adguard_test -- GET /control/status and shows the version and DNS state.
# Returns 0 connected, 1 failed, 2 not configured.
adguard_test() {
    adguard_require_config || return 2
    if ! adguard_request GET status; then
        msg_error "AdGuard Home: $AG_ERROR"
        log "AdGuard Home connection test failed: $AG_ERROR"
        return 1
    fi
    local version running protection
    if ! version=$(jq -er 'if type == "object" then .version else empty end | strings' <<< "$AG_BODY" 2>/dev/null); then
        msg_error "$AG_URL did not answer like AdGuard Home (no version in /control/status)"
        log "AdGuard Home connection test failed: not an AdGuard Home API response"
        return 1
    fi
    version=$(adguard_clean_text "$version")
    running=$(jq -r '.running == true' <<< "$AG_BODY")
    protection=$(jq -r '.protection_enabled == true' <<< "$AG_BODY")

    msg_success "Connected to AdGuard Home $version"
    if [[ "$running" == true ]]; then
        ui_kv "DNS server" "$(ui_badge ok "Running")"
    else
        ui_kv "DNS server" "$(ui_badge warn "Not running")"
    fi
    if [[ "$protection" == true ]]; then
        ui_kv "Protection" "$(ui_badge on "Enabled")"
    else
        ui_kv "Protection" "$(ui_badge off "Disabled")"
    fi
    log "AdGuard Home connection test passed ($version)"
}

# ==========================================================
# DNS MENU
# ==========================================================
# Shows the saved connection. Never contacts AdGuard Home. Returns as
# adguard_load_config.
adguard_show_connection() {
    adguard_load_config
    local rc=$?
    case $rc in
        2)
            ui_kv "Connection" "$(ui_badge none "Not configured")"
            ui_hint "Set the connection to manage DNS rewrites for your sites' domains."
            ui_hint "Nothing is sent to AdGuard Home until then."
            ;;
        1)
            ui_kv "Connection" "$(ui_badge err "Invalid $ADGUARD_CONF")"
            ui_hint "$AG_CONFIG_ERROR - set the connection again to replace it."
            ;;
        0)
            ui_kv "Server" "$AG_URL"
            if [[ -z "$AG_USER" ]]; then
                ui_kv "Login" "$(ui_badge none "none")"
            elif adguard_password_saved; then
                ui_kv "Login" "$AG_USER (password saved)"
            else
                ui_kv "Login" "$(ui_badge warn "$AG_USER (no password saved)")"
            fi
            ui_kv "Default IP" "${AG_ANSWER:-$SYM_NONE}"
            [[ "$AG_URL" == http://* ]] && adguard_http_warning
            ;;
    esac
    return $rc
}

adguard_http_warning() {
    msg_warning "HTTP: the login and DNS changes travel unencrypted - prefer https://"
}

adguard_menu() {
    local configured items
    while true; do
        ui_screen "DNS (AdGuard Home)"
        adguard_show_connection
        configured=$?
        echo
        items=("c|Connection|AdGuard Home address, login and default IP")
        if ((configured == 0)); then
            items+=("t|Test connection|check the address and login"
                "r|Remove connection|delete the saved address and password")
        fi
        items+=("q|Back|")
        ui_menu "Actions" q "${items[@]}" || return
        case "$UI_REPLY" in
            c) adguard_connection_prompt ;;
            t) adguard_test_screen ;;
            r) adguard_remove_prompt ;;
            q) return ;;
        esac
    done
}

adguard_test_screen() {
    ui_screen "DNS (AdGuard Home)" "Test connection"
    adguard_load_config
    msg_step "Contacting ${AG_URL:-AdGuard Home}..."
    ui_shield adguard_test
    pause
}

adguard_remove_prompt() {
    echo
    if ! confirm "Delete the saved AdGuard Home address and password?" n; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return
    fi
    echo
    ui_run adguard_remove_config
    ui_hint "AdGuard Home itself and its DNS rewrites are unchanged."
    pause
}

adguard_connection_prompt() {
    ui_screen "DNS (AdGuard Home)" "Connection"
    echo "Nothing is saved until you confirm the summary."
    ui_cancel_hint
    adguard_load_config
    local old_user="$AG_USER" url user answer password="" keep=0

    echo
    while true; do
        ui_input "AdGuard Home URL" "$AG_URL" "web address, e.g. https://dns.lan.example.com or http://192.168.1.2:3000" || { ui_aborted $?; pause; return 1; }
        url="${UI_REPLY%/}"
        url="${url%/control}"
        if ! validate_http_url "$url"; then
            msg_error "Invalid URL - expected http(s)://host[:port][/path], without a login, query or #"
            continue
        fi
        if [[ "$url" == http://* ]]; then
            adguard_http_warning
            confirm "Use HTTP anyway?" n || continue
        fi
        break
    done

    while true; do
        ui_input "Username" "$AG_USER" "empty if AdGuard Home has no login" || { ui_aborted $?; pause; return 1; }
        user="$UI_REPLY"
        [[ -z "$user" ]] || adguard_valid_user "$user" && break
        msg_error "Invalid username (1-64 letters, numbers, . _ @ + -)"
    done

    if [[ -n "$user" ]]; then
        if [[ "$user" == "$old_user" ]] && adguard_password_saved && confirm "Keep the saved password?" y; then
            keep=1
        else
            while true; do
                ui_input "Password (not shown)" "" "" secret || { ui_aborted $?; pause; return 1; }
                password="$UI_REPLY"
                [[ -n "$password" ]] && break
                msg_error "Password cannot be empty"
            done
        fi
    fi

    while true; do
        ui_input "Default IP" "$AG_ANSWER" "IPv4 or IPv6 address your sites' domains should point to (optional)" || { ui_aborted $?; pause; return 1; }
        answer="$UI_REPLY"
        [[ -z "$answer" ]] || adguard_valid_ip "$answer" && break
        msg_error "Invalid IP address"
    done

    ui_section "Summary"
    ui_kv "Server" "$url"
    if [[ -z "$user" ]]; then
        ui_kv "Login" "none"
    elif ((keep)); then
        ui_kv "Login" "$user (saved password kept)"
    else
        ui_kv "Login" "$user (new password)"
    fi
    ui_kv "Default IP" "${answer:-$SYM_NONE}"
    [[ "$url" == https://* ]] && ui_hint "The certificate must be trusted by this system (a private CA: update-ca-certificates)."
    [[ -z "$user" ]] && adguard_password_saved && ui_hint "The saved password will be deleted."
    ui_hint "Saved in $ADGUARD_CONF; the password in $ADGUARD_SECRET (mode 600)."
    echo
    if ! confirm "Save these settings?" y; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return 1
    fi
    echo

    if [[ -n "$password" ]]; then
        # printf is a builtin: the value never appears in a process list.
        printf '%s' "$password" | ui_run adguard_password_set || { pause; return 1; }
        password=""
    fi
    ui_run adguard_save_config "$url" "$user" "$answer" || { pause; return 1; }
    if [[ -z "$user" ]] && [[ -e "$ADGUARD_SECRET" ]]; then
        rm -f "$ADGUARD_SECRET" && log "AdGuard Home password removed (no login)"
    fi
    msg_success "AdGuard Home connection saved"

    echo
    if confirm "Test the connection now?" y; then
        echo
        msg_step "Contacting $url..."
        ui_shield adguard_test
    fi
    pause
}
