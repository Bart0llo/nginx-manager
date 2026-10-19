#!/bin/bash
# ==========================================================
# NGINX Manager Pro - AdGuard Home DNS rewrites
# Sourced by nginx-site.sh: defines state and functions only.
#
# Talks to AdGuard Home's web API (<URL>/control/...) with curl. Inactive
# until configured: nothing is sent anywhere until a connection is saved
# and the user picks an action on the DNS screen. Nothing here runs when
# sites change. The rewrite views only read (GET); they change nothing.
# The changes each follow a confirmed summary and only touch exact records
# for a site's domain: Add rewrite creates one (POST rewrite/add), Edit
# rewrite changes one record's answer in place (PUT rewrite/update, never
# delete + add), Delete rewrite removes the records with exactly one domain
# and answer (POST rewrite/delete). Records are never switched on or off,
# and a change is reported as done only once the list read back shows it.
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
# Filled by adguard_request. AG_CURL_RC is curl's exit status (empty when
# curl never ran).
AG_HTTP="" AG_BODY="" AG_ERROR="" AG_CURL_RC=""
# Filled by adguard_get_status.
AG_VERSION="" AG_RUNNING="" AG_PROTECTION=""
# Filled by adguard_fetch_rewrites: one entry per usable rewrite, sorted by
# domain. AG_RW_STATE is true, false or unknown (AdGuard Home before
# v0.107.68 does not report it). AG_RW_GLOBAL is the global rewrite switch:
# true, false or unknown (AG_RW_GLOBAL_NOTE says why). AG_RW_RAW is true
# when domain and answer are exactly as stored (nothing removed for
# display), so they can name the record in a change.
AG_RW_DOMAIN=() AG_RW_ANSWER=() AG_RW_STATE=() AG_RW_RAW=() AG_RW_SKIPPED=0
AG_RW_GLOBAL="" AG_RW_GLOBAL_NOTE=""
# Filled by adguard_match: indexes into the AG_RW_* arrays.
AG_EXACT=() AG_WILD=()
# Editing in place (PUT /control/rewrite/update) arrived in this version.
AG_UPDATE_SINCE=0.107.33
# Filled by adguard_manage_start (site and domain) and adguard_pick_rewrite
# (an index into the AG_RW_* arrays).
AG_SITE="" AG_DOMAIN="" AG_PICK=""

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
    AG_HTTP="" AG_BODY="" AG_ERROR="" AG_CURL_RC=""
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
    AG_CURL_RC=$rc
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

# GET /control/status. Sets AG_VERSION, AG_RUNNING and AG_PROTECTION
# (true/false). Returns 0, or 1 with AG_ERROR.
adguard_get_status() {
    AG_VERSION="" AG_RUNNING="" AG_PROTECTION=""
    adguard_request GET status || return 1
    if ! AG_VERSION=$(jq -er 'if type == "object" then .version else empty end | strings' <<< "$AG_BODY" 2>/dev/null); then
        AG_VERSION=""
        AG_ERROR="$AG_URL did not answer like AdGuard Home (no version in /control/status)"
        return 1
    fi
    AG_VERSION=$(adguard_clean_text "$AG_VERSION")
    AG_RUNNING=$(jq -r '.running == true' <<< "$AG_BODY")
    AG_PROTECTION=$(jq -r '.protection_enabled == true' <<< "$AG_BODY")
}

# Usable rewrites as a count of skipped records, then one
# "domain<TAB>answer<TAB>true|false|unknown<TAB>raw" line each, sorted by
# domain. A record is skipped unless domain and answer are non-empty strings
# and "enabled", if present, is a boolean. Control characters are removed,
# so no field can hold a tab or drive the terminal; raw says whether that
# (or the length limit) left domain and answer unchanged.
AG_RW_JQ='
def clean: gsub("[[:cntrl:]]"; "") | .[0:255];
def row:
    if type == "object" and (.domain | type) == "string" and (.answer | type) == "string"
        and (.enabled == null or (.enabled | type) == "boolean")
    then [(.domain | clean), (.answer | clean), (if .enabled == null then "unknown" else (.enabled | tostring) end),
            ((.domain | clean) == .domain and (.answer | clean) == .answer | tostring)]
        | if .[0] != "" and .[1] != "" then . else null end
    else null end;
(. // []) | map(row)
| (map(select(. == null)) | length),
  (map(select(. != null)) | sort_by(.[0] | ascii_downcase)[] | join("\t"))'

# Reads the version, every rewrite (GET /control/rewrite/list) and the
# global rewrite switch (GET /control/rewrite/settings, v0.107.68+) into
# AG_VERSION and AG_RW_*. Only reads. Stops at the first failed request,
# so a rejected login is never sent twice. A missing or unreadable switch
# leaves AG_RW_GLOBAL unknown and is not an error. Returns 0, or 1 with
# AG_ERROR.
adguard_fetch_rewrites() {
    AG_RW_DOMAIN=() AG_RW_ANSWER=() AG_RW_STATE=() AG_RW_SKIPPED=0
    AG_RW_GLOBAL=unknown AG_RW_GLOBAL_NOTE=""
    adguard_get_status || return 1
    adguard_fetch_list || return 1

    if adguard_request GET rewrite/settings; then
        case "$(jq -r 'if type == "object" and (.enabled | type) == "boolean" then .enabled else "bad" end' <<< "$AG_BODY" 2>/dev/null)" in
            true) AG_RW_GLOBAL=true ;;
            false) AG_RW_GLOBAL=false ;;
            *) AG_RW_GLOBAL_NOTE="unexpected answer from /control/rewrite/settings" ;;
        esac
    elif [[ "$AG_HTTP" == 404 || "$AG_HTTP" == 405 ]]; then
        AG_RW_GLOBAL_NOTE="this AdGuard Home version has no global rewrite switch (added in v0.107.68)"
    else
        AG_RW_GLOBAL_NOTE="$AG_ERROR"
    fi
    AG_ERROR=""
}

# Reads every rewrite (GET /control/rewrite/list) into AG_RW_DOMAIN,
# AG_RW_ANSWER, AG_RW_STATE, AG_RW_RAW and AG_RW_SKIPPED. Returns 0, or 1
# with AG_ERROR and no records.
adguard_fetch_list() {
    AG_RW_DOMAIN=() AG_RW_ANSWER=() AG_RW_STATE=() AG_RW_RAW=() AG_RW_SKIPPED=0
    adguard_request GET rewrite/list || return 1

    local type rows domain answer state raw
    type=$(jq -r type <<< "$AG_BODY" 2>/dev/null)
    case "$type" in
        array|null) ;;
        "") AG_ERROR="the rewrite list from $AG_URL is not valid JSON"; return 1 ;;
        *) AG_ERROR="the rewrite list from $AG_URL has an unexpected form (expected a JSON list)"; return 1 ;;
    esac
    if ! rows=$(jq -r "$AG_RW_JQ" <<< "$AG_BODY" 2>/dev/null); then
        AG_ERROR="the rewrite list from $AG_URL could not be read"
        return 1
    fi
    {
        read -r AG_RW_SKIPPED
        while IFS=$'\t' read -r domain answer state raw; do
            AG_RW_DOMAIN+=("$domain") AG_RW_ANSWER+=("$answer") AG_RW_STATE+=("$state") AG_RW_RAW+=("$raw")
        done
    } <<< "$rows"
}

# adguard_match <domain>  -- which fetched rewrites apply to a domain, as
# AdGuard Home matches them (letter case and a final "." ignored):
# AG_EXACT the records for exactly that name, AG_WILD the "*.<suffix>"
# records covering it (any depth, never <suffix> itself).
adguard_match() {
    local host="${1,,}" i d
    host="${host%.}"
    AG_EXACT=() AG_WILD=()
    for i in "${!AG_RW_DOMAIN[@]}"; do
        d="${AG_RW_DOMAIN[i],,}"
        d="${d%.}"
        if [[ "$d" == "$host" ]]; then
            AG_EXACT+=("$i")
        elif [[ "$d" == "*."?* && "$host" == *"${d:1}" ]]; then
            AG_WILD+=("$i")
        fi
    done
}

# adguard_ip_key <answer>  -- one spelling per address, for comparing
# answers: IPv6 written out in full, in lowercase (FD00:0::01 is fd00::1).
# Anything else comes back lowercased.
adguard_ip_key() {
    local ip="${1,,}" head tail h=() t=() g out="" n
    if ! validate_ipv6 "$ip"; then
        printf '%s' "$ip"
        return
    fi
    if [[ "$ip" == *.* ]]; then
        local a b c d
        IFS=. read -r a b c d <<< "${ip##*:}"
        ip="${ip%:*}:$(printf '%x:%x' $((a * 256 + b)) $((c * 256 + d)))"
    fi
    head="$ip" tail=""
    [[ "$ip" == *::* ]] && head="${ip%%::*}" tail="${ip#*::}"
    IFS=: read -ra h <<< "$head"
    IFS=: read -ra t <<< "$tail"
    for g in "${h[@]}"; do out+=$(printf '%04x:' "0x$g"); done
    for ((n = 8 - ${#h[@]} - ${#t[@]}; n > 0; n--)); do out+="0000:"; done
    for g in "${t[@]}"; do out+=$(printf '%04x:' "0x$g"); done
    printf '%s' "${out%:}"
}

adguard_same_answer() { [[ "$(adguard_ip_key "$1")" == "$(adguard_ip_key "$2")" ]]; }

# adguard_has_rewrite <domain> <answer>  -- whether the fetched list holds
# the rewrite as AdGuard Home stores an added one (domain in lowercase,
# answer as sent) and it is not disabled.
adguard_has_rewrite() {
    local domain="${1,,}" i
    for i in "${!AG_RW_DOMAIN[@]}"; do
        [[ "${AG_RW_DOMAIN[i]}" == "$domain" && "${AG_RW_STATE[i]}" != false ]] \
            && adguard_same_answer "${AG_RW_ANSWER[i]}" "$2" && return 0
    done
    return 1
}

# After a failed request: whether it may still have been carried out. Not
# when nothing was sent (no connection, TLS refused) or AdGuard Home
# refused it (3xx/4xx); yes when the answer was cut off or timed out, or
# the server failed (5xx) while handling it.
adguard_maybe_applied() {
    case "$AG_HTTP" in
        5??) return 0 ;;
        "") ;;
        *) return 1 ;;
    esac
    case "$AG_CURL_RC" in
        ""|6|7|35|51|53|54|58|59|60|64|66|77|80|83|90|91) return 1 ;;
    esac
    return 0
}

# adguard_create_rewrite <domain> <answer>
# Adds one rewrite (POST /control/rewrite/add) and reads the list back to
# confirm it. Right before sending, the list is read again: if an exact
# rewrite for the domain is there by now, nothing is sent. Never edits or
# removes a record, and never sends the POST twice (AdGuard Home does not
# refuse duplicates). Returns 0 added and confirmed, 1 not added, 2 not sent
# (an exact rewrite exists), 3 sent but not confirmed.
adguard_create_rewrite() {
    local domain="$1" answer="$2" body err
    if ! adguard_fetch_list; then
        msg_error "AdGuard Home: $AG_ERROR"
        msg_warning "Nothing was sent: the rewrites could not be checked"
        log "AdGuard Home rewrite $domain -> $answer not added: $AG_ERROR"
        return 1
    fi
    adguard_match "$domain"
    if ((${#AG_EXACT[@]})); then
        msg_error "An exact rewrite for $domain exists by now - nothing was sent"
        log "AdGuard Home rewrite $domain -> $answer not added: an exact rewrite appeared"
        return 2
    fi

    body=$(jq -nc --arg d "$domain" --arg a "$answer" '{domain: $d, answer: $a}')
    if ! adguard_request POST rewrite/add "$body"; then
        err="$AG_ERROR"
        msg_error "AdGuard Home: $err"
        if adguard_maybe_applied; then
            msg_warning "The rewrite may or may not have been added"
            ui_hint "Check Your sites' DNS before trying again: AdGuard Home does not refuse duplicates."
            log "AdGuard Home rewrite $domain -> $answer: result unknown ($err)"
            return 3
        fi
        msg_warning "The rewrite was not added"
        log "AdGuard Home rewrite $domain -> $answer not added: $err"
        return 1
    fi
    log "AdGuard Home rewrite $domain -> $answer sent (HTTP $AG_HTTP)"

    if ! adguard_fetch_list; then
        msg_warning "AdGuard Home accepted the rewrite, but it could not be confirmed: $AG_ERROR"
    elif ! adguard_has_rewrite "$domain" "$answer"; then
        msg_warning "AdGuard Home accepted the rewrite, but $domain $SYM_ARROW $answer is not in its list"
    else
        msg_success "Rewrite added: $domain $SYM_ARROW $answer"
        log "AdGuard Home rewrite $domain -> $answer added and confirmed"
        return 0
    fi
    ui_hint "Check Your sites' DNS before adding it again: AdGuard Home does not refuse duplicates."
    log "AdGuard Home rewrite $domain -> $answer not confirmed"
    return 3
}

# adguard_count_exact <domain> <answer> [<state>]  -- how many fetched
# records AdGuard Home takes for this one when editing or deleting: it
# compares domain and answer letter for letter (not the enabled state, and
# not as addresses). A record shown with characters removed never counts:
# what is stored differs. With <state>, only records in that state count.
adguard_count_exact() {
    local i n=0
    for i in "${!AG_RW_DOMAIN[@]}"; do
        [[ "${AG_RW_RAW[i]}" == true && "${AG_RW_DOMAIN[i]}" == "$1" && "${AG_RW_ANSWER[i]}" == "$2" ]] \
            && [[ -z "$3" || "${AG_RW_STATE[i]}" == "$3" ]] && n=$((n + 1))
    done
    echo "$n"
}

# Whether the fetched list is complete enough to aim a change at records by
# domain and answer: a record that could not be read might match as well.
adguard_list_complete() {
    ((AG_RW_SKIPPED == 0)) && return 0
    msg_error "$AG_RW_SKIPPED record(s) in AdGuard Home could not be read, so which records a change would hit cannot be checked - nothing was sent"
    ui_hint "Review the rewrites in AdGuard Home (Filters › DNS rewrites)."
    return 1
}

# adguard_version_at_least <version> <x.y.z>  -- 0 yes, 1 older, 2 cannot
# tell (not vX.Y.Z, e.g. a development build, or a pre-release of x.y.z).
adguard_version_at_least() {
    [[ "$1" =~ ^v?([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})(-[0-9A-Za-z.-]+)?$ ]] || return 2
    local have=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}") pre="${BASH_REMATCH[4]}" want i
    IFS=. read -ra want <<< "$2"
    for i in 0 1 2; do
        ((10#${have[i]} > want[i])) && return 0
        ((10#${have[i]} < want[i])) && return 1
    done
    [[ -z "$pre" ]] || return 2
}

# Whether the AdGuard Home in AG_VERSION can edit a rewrite in place; says
# why not. Editing is never done as delete + add instead.
adguard_edit_supported() {
    adguard_version_at_least "$AG_VERSION" "$AG_UPDATE_SINCE"
    case $? in
        0) return 0 ;;
        1) msg_error "AdGuard Home $AG_VERSION cannot edit rewrites - that needs v$AG_UPDATE_SINCE or later" ;;
        *) msg_error "Whether AdGuard Home $AG_VERSION can edit rewrites cannot be determined (it needs v$AG_UPDATE_SINCE or later)" ;;
    esac
    ui_hint "Nothing was sent. A rewrite is never changed here by deleting and re-adding it:"
    ui_hint "update AdGuard Home, or change the record in AdGuard Home (Filters › DNS rewrites)."
    return 1
}

# adguard_update_rewrite <domain> <answer> <new-answer> [<state>]
# Changes the answer of one rewrite in place (PUT /control/rewrite/update),
# keeping its domain and enabled state, and reads the list back to confirm.
# <domain> and <answer> are as AdGuard Home lists them; <state> is the
# record's (adguard_fetch_list). AdGuard Home changes the first record that
# matches exactly, so right before sending the list is read again: nothing
# is sent unless exactly one record matches (still in <state>, if given) and
# no other exact rewrite for the domain has the new answer. Never deletes
# and re-adds, never sends the PUT twice. Returns 0 changed and confirmed,
# 1 not changed, 2 not sent (the record is gone, ambiguous, switched on or
# off, or would be duplicated, or the version cannot edit), 3 sent but not
# confirmed.
adguard_update_rewrite() {
    local domain="$1" old="$2" new="$3" state="$4" body err n i
    if adguard_same_answer "$old" "$new"; then
        msg_success "$domain already points to $old - nothing to change"
        return 2
    fi
    if [[ -z "$AG_VERSION" ]] && ! adguard_get_status; then
        msg_error "AdGuard Home: $AG_ERROR"
        msg_warning "Nothing was sent: the AdGuard Home version could not be checked"
        log "AdGuard Home rewrite $domain -> $old not changed: $AG_ERROR"
        return 1
    fi
    adguard_edit_supported || return 2
    if ! adguard_fetch_list; then
        msg_error "AdGuard Home: $AG_ERROR"
        msg_warning "Nothing was sent: the rewrites could not be checked"
        log "AdGuard Home rewrite $domain -> $old not changed: $AG_ERROR"
        return 1
    fi
    adguard_list_complete || return 2
    n=$(adguard_count_exact "$domain" "$old")
    if ((n != 1)); then
        if ((n == 0)); then
            msg_error "$domain $SYM_ARROW $old is no longer in AdGuard Home - nothing was sent"
        else
            msg_error "$domain $SYM_ARROW $old is in AdGuard Home $n times by now - which one would change is ambiguous; nothing was sent"
        fi
        ui_hint "Open Your sites' DNS to review the current records before trying again."
        log "AdGuard Home rewrite $domain -> $old not changed: $n matching records"
        return 2
    fi
    if [[ -n "$state" ]] && (($(adguard_count_exact "$domain" "$old" "$state") != 1)); then
        msg_error "$domain $SYM_ARROW $old was switched on or off in AdGuard Home since it was shown - nothing was sent"
        ui_hint "Open Your sites' DNS to review the current records before trying again."
        log "AdGuard Home rewrite $domain -> $old not changed: its enabled state changed"
        return 2
    fi
    adguard_match "$domain"
    for i in "${AG_EXACT[@]}"; do
        if [[ "${AG_RW_ANSWER[i]}" != "$old" ]] && adguard_same_answer "${AG_RW_ANSWER[i]}" "$new"; then
            msg_error "$domain has a rewrite to $new by now - nothing was sent"
            log "AdGuard Home rewrite $domain -> $old not changed: $new exists"
            return 2
        fi
    done

    # No "enabled" in the update: AdGuard Home keeps the record's own.
    body=$(jq -nc --arg d "$domain" --arg o "$old" --arg n "$new" \
        '{target: {domain: $d, answer: $o}, update: {domain: $d, answer: $n}}')
    if ! adguard_request PUT rewrite/update "$body"; then
        err="$AG_ERROR"
        msg_error "AdGuard Home: $err"
        if adguard_maybe_applied; then
            msg_warning "The rewrite may or may not have been changed"
            ui_hint "Check Your sites' DNS before trying again."
            log "AdGuard Home rewrite $domain -> $old to $new: result unknown ($err)"
            return 3
        fi
        msg_warning "The rewrite was not changed"
        log "AdGuard Home rewrite $domain -> $old not changed: $err"
        return 1
    fi
    log "AdGuard Home rewrite $domain -> $old change to $new sent (HTTP $AG_HTTP)"

    # AdGuard Home stores the updated domain in lowercase.
    if ! adguard_fetch_list; then
        msg_warning "AdGuard Home accepted the change, but it could not be confirmed: $AG_ERROR"
    elif (($(adguard_count_exact "$domain" "$old"))) \
        || (($(adguard_count_exact "${domain,,}" "$new" "$state") != 1)); then
        msg_warning "AdGuard Home accepted the change, but its list does not show $domain $SYM_ARROW $new in place of $old"
    else
        msg_success "Rewrite changed: $domain $SYM_ARROW $new (was $old)"
        log "AdGuard Home rewrite $domain -> $old changed to $new and confirmed"
        return 0
    fi
    ui_hint "Check Your sites' DNS before trying again."
    log "AdGuard Home rewrite $domain -> $old change to $new not confirmed"
    return 3
}

# adguard_delete_rewrite <domain> <answer> <count>
# Removes the rewrites with exactly this domain and answer (POST
# /control/rewrite/delete) and reads the list back to confirm. AdGuard Home
# removes every record that matches, so right before sending the list is
# read again: nothing is sent unless exactly <count> records match (as many
# as the user agreed to remove). It answers 200 whether or not anything
# matched; only the list read back counts. Never sends the request twice.
# Returns as adguard_update_rewrite (2: the records changed meanwhile).
adguard_delete_rewrite() {
    local domain="$1" answer="$2" count="$3" body err n
    if ! adguard_fetch_list; then
        msg_error "AdGuard Home: $AG_ERROR"
        msg_warning "Nothing was sent: the rewrites could not be checked"
        log "AdGuard Home rewrite $domain -> $answer not deleted: $AG_ERROR"
        return 1
    fi
    adguard_list_complete || return 2
    n=$(adguard_count_exact "$domain" "$answer")
    if ((n != count)); then
        if ((n == 0)); then
            msg_error "$domain $SYM_ARROW $answer is no longer in AdGuard Home - nothing was sent"
        else
            msg_error "$domain $SYM_ARROW $answer is now in AdGuard Home $n time(s), not $count - nothing was sent"
        fi
        ui_hint "Open Your sites' DNS to review the current records before trying again."
        log "AdGuard Home rewrite $domain -> $answer not deleted: $n matching records, $count expected"
        return 2
    fi

    body=$(jq -nc --arg d "$domain" --arg a "$answer" '{domain: $d, answer: $a}')
    if ! adguard_request POST rewrite/delete "$body"; then
        err="$AG_ERROR"
        msg_error "AdGuard Home: $err"
        if adguard_maybe_applied; then
            msg_warning "The rewrite may or may not have been deleted"
            ui_hint "Check Your sites' DNS before trying again."
            log "AdGuard Home rewrite $domain -> $answer: deletion result unknown ($err)"
            return 3
        fi
        msg_warning "The rewrite was not deleted"
        log "AdGuard Home rewrite $domain -> $answer not deleted: $err"
        return 1
    fi
    log "AdGuard Home rewrite $domain -> $answer deletion sent (HTTP $AG_HTTP)"

    if ! adguard_fetch_list; then
        msg_warning "AdGuard Home answered, but the deletion could not be confirmed: $AG_ERROR"
    elif (($(adguard_count_exact "$domain" "$answer"))); then
        msg_warning "AdGuard Home answered, but $domain $SYM_ARROW $answer is still in its list - not deleted"
    else
        if ((count > 1)); then
            msg_success "Rewrite deleted: $domain $SYM_ARROW $answer ($count identical records)"
        else
            msg_success "Rewrite deleted: $domain $SYM_ARROW $answer"
        fi
        log "AdGuard Home rewrite $domain -> $answer deleted ($count record(s)) and confirmed"
        return 0
    fi
    ui_hint "Check Your sites' DNS before trying again."
    log "AdGuard Home rewrite $domain -> $answer deletion not confirmed"
    return 3
}

# adguard_test -- GET /control/status and shows the version and DNS state.
# Returns 0 connected, 1 failed, 2 not configured.
adguard_test() {
    adguard_require_config || return 2
    if ! adguard_get_status; then
        msg_error "AdGuard Home: $AG_ERROR"
        log "AdGuard Home connection test failed: $AG_ERROR"
        return 1
    fi

    msg_success "Connected to AdGuard Home $AG_VERSION"
    if [[ "$AG_RUNNING" == true ]]; then
        ui_kv "DNS server" "$(ui_badge ok "Running")"
    else
        ui_kv "DNS server" "$(ui_badge warn "Not running")"
    fi
    if [[ "$AG_PROTECTION" == true ]]; then
        ui_kv "Protection" "$(ui_badge on "Enabled")"
    else
        ui_kv "Protection" "$(ui_badge off "Disabled")"
    fi
    log "AdGuard Home connection test passed ($AG_VERSION)"
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
        items=()
        if ((configured == 0)); then
            items+=("s|Your sites' DNS|rewrites for your sites' domains (read-only)"
                "a|All rewrites|every rewrite in AdGuard Home (read-only)"
                "n|Add rewrite|point a site's domain to an IP address"
                "e|Edit rewrite|change the IP address of a site's rewrite"
                "d|Delete rewrite|remove a rewrite for a site's domain")
        fi
        items+=("c|Connection|AdGuard Home address, login and default IP")
        if ((configured == 0)); then
            items+=("t|Test connection|check the address and login"
                "r|Remove connection|delete the saved address and password")
        fi
        items+=("q|Back|")
        ui_menu "Actions" q "${items[@]}" || return
        case "$UI_REPLY" in
            s) adguard_sites_screen ;;
            a) adguard_rewrites_screen ;;
            n) adguard_add_screen ;;
            e) adguard_edit_screen ;;
            d) adguard_delete_screen ;;
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

# ==========================================================
# REWRITE VIEWS (read-only)
# ==========================================================
# Fetches the rewrites for a view and shows the server, the count and the
# global switch, or what failed. Returns 0, or 1 when there is nothing to
# show.
adguard_fetch_view() {
    adguard_require_config || return 1
    msg_step "Contacting $AG_URL..."
    if ! ui_shield adguard_fetch_rewrites; then
        msg_error "AdGuard Home: $AG_ERROR"
        log "AdGuard Home rewrites not read: $AG_ERROR"
        return 1
    fi
    echo
    ui_kv "Server" "$AG_URL (AdGuard Home $AG_VERSION)"
    ui_kv "Rewrites" "${#AG_RW_DOMAIN[@]} in AdGuard Home"
    case "$AG_RW_GLOBAL" in
        true) ui_kv "Rewriting" "$(ui_badge on "Enabled")" ;;
        false)
            ui_kv "Rewriting" "$(ui_badge warn "Disabled")"
            msg_warning "Rewrites are turned off in AdGuard Home: the records below are not applied now"
            ;;
        *)
            ui_kv "Rewriting" "$(ui_badge unknown "Unknown")"
            ui_hint "Whether rewrites are on cannot be determined: $AG_RW_GLOBAL_NOTE"
            ;;
    esac
    ((AG_RW_SKIPPED)) && msg_warning "$AG_RW_SKIPPED record(s) skipped: not a domain and answer as expected"
    return 0
}

# Text after an answer for a record's own switch: AdGuard Home before
# v0.107.68 does not report it, which is not the same as disabled.
adguard_state_suffix() {
    case "$1" in
        false) printf ' %s' "$(ui_badge off "disabled")" ;;
        unknown) printf ' %s' "${GRAY}(enabled state not reported)${NC}" ;;
    esac
}

# adguard_answers <index>...  -- how the answers of a domain's active exact
# records relate: single, duplicate (same answer more than once), dual (one
# IPv4 and one IPv6 address) or conflict (different answers of a kind, or a
# name next to anything). "A"/"AAAA" (keep the upstream records of that
# type) count as an IPv4/IPv6 answer.
adguard_answers() {
    local i a kind n4=0 n6=0 nname=0
    local -A seen=()
    for i in "$@"; do
        a="${AG_RW_ANSWER[i],,}"
        [[ -n "${seen[$a]}" ]] && continue
        seen[$a]=1
        if validate_ipv4 "$a" || [[ "$a" == a ]]; then
            ((n4++))
        elif validate_ipv6 "$a" || [[ "$a" == aaaa ]]; then
            ((n6++))
        else
            ((nname++))
        fi
    done
    if ((${#seen[@]} == 1)); then
        kind=single
        (($# > 1)) && kind=duplicate
    elif ((nname || n4 > 1 || n6 > 1)); then
        kind=conflict
    elif (($# > ${#seen[@]})); then
        kind=duplicate
    else
        kind=dual
    fi
    echo "$kind"
}

# adguard_site_dns <site> <domain>  -- the fetched rewrites for one site.
adguard_site_dns() {
    local name="$1" domain="$2" i on=() off=()
    printf '  %s  %s\n' "${BOLD}$domain${NC}" "${GRAY}(site $name)${NC}"
    if ! validate_domain "$domain"; then
        printf '      %s\n' "$(ui_badge err "Not a valid domain name - not looked up")"
        return
    fi
    adguard_match "$domain"
    for i in "${AG_EXACT[@]}"; do
        if [[ "${AG_RW_STATE[i]}" == false ]]; then off+=("$i"); else on+=("$i"); fi
    done

    if ((${#on[@]})); then
        case "$(adguard_answers "${on[@]}")" in
            single) printf '      %s\n' "$(ui_badge ok "Exact rewrite")" ;;
            dual) printf '      %s\n' "$(ui_badge ok "Exact rewrites (IPv4 and IPv6)")" ;;
            duplicate) printf '      %s\n' "$(ui_badge warn "${#on[@]} exact rewrites, some repeated (duplicates)")" ;;
            conflict) printf '      %s\n' "$(ui_badge warn "${#on[@]} exact rewrites with conflicting answers - clients may get any of them")" ;;
        esac
    elif ((${#off[@]})); then
        printf '      %s\n' "$(ui_badge off "Exact rewrite, disabled in AdGuard Home")"
    elif ((${#AG_WILD[@]})); then
        printf '      %s\n' "$(ui_badge unknown "No exact rewrite - a wildcard rewrite may match")"
    else
        printf '      %s\n' "$(ui_badge none "No rewrite found")"
        return
    fi
    for i in "${on[@]}" "${off[@]}"; do
        printf '        %s %s%s\n' "$SYM_ARROW" "${AG_RW_ANSWER[i]}" "$(adguard_state_suffix "${AG_RW_STATE[i]}")"
    done
    if ((${#AG_WILD[@]})); then
        if ((${#on[@]})); then
            ui_hint "    Also covered by a wildcard rewrite (the exact rewrite takes precedence):"
        elif ((${#off[@]})); then
            ui_hint "    Wildcard rewrites that may match instead:"
        fi
        for i in "${AG_WILD[@]}"; do
            printf '        %s %s %s%s\n' "${AG_RW_DOMAIN[i]}" "$SYM_ARROW" "${AG_RW_ANSWER[i]}" \
                "$(adguard_state_suffix "${AG_RW_STATE[i]}")"
        done
    fi
}

# What AdGuard Home has for each site's domain. Contacts it only when there
# is a site to look up.
adguard_sites_screen() {
    ui_screen "DNS (AdGuard Home)" "Your sites' DNS"
    if ! jq empty "$SITES_DB" >/dev/null 2>&1; then
        msg_error "The site database $SITES_DB cannot be read (invalid JSON)"
        pause
        return
    fi
    local names=() domains=() name domain backend tls flag i
    while IFS=$'\t' read -r name domain backend tls flag; do
        names+=("$name") domains+=("$domain")
    done < <(sites_tsv)
    if ((${#names[@]} == 0)); then
        echo "  No sites configured yet - no domain to look up."
        ui_hint "All rewrites lists every rewrite in AdGuard Home."
        pause
        return
    fi

    if adguard_fetch_view; then
        echo
        for i in "${!names[@]}"; do
            adguard_site_dns "${names[i]}" "${domains[i]}"
        done
        echo
        ui_hint "Read only: nothing was changed in AdGuard Home or nginx."
        ui_hint "Exact rewrites are for the domain itself; a wildcard (*.example.com) covers its subdomains."
    fi
    pause
}

# Every rewrite AdGuard Home reports, the sites' domains or not.
adguard_rewrites_screen() {
    ui_screen "DNS (AdGuard Home)" "All rewrites"
    if adguard_fetch_view; then
        echo
        if ((${#AG_RW_DOMAIN[@]} == 0)); then
            echo "  No rewrites in AdGuard Home"
        else
            local i badge text dw=34 aw=24
            ((UI_COLS < 80)) && dw=$((UI_COLS > 56 ? UI_COLS - 46 : 10))
            printf "  %-${dw}s %-${aw}s %s\n" "DOMAIN" "ANSWER" "STATE"
            for i in "${!AG_RW_DOMAIN[@]}"; do
                case "${AG_RW_STATE[i]}" in
                    true) badge=on text=ENABLED ;;
                    false) badge=off text=DISABLED ;;
                    *) badge=unknown text="NOT REPORTED" ;;
                esac
                printf "  %-${dw}s %-${aw}s %s\n" "$(truncate_field "${AG_RW_DOMAIN[i]}" "$dw")" \
                    "$(truncate_field "${AG_RW_ANSWER[i]}" "$aw")" "$(ui_badge "$badge" "$text")"
            done
            [[ " ${AG_RW_STATE[*]} " == *" unknown "* ]] \
                && ui_hint "NOT REPORTED: this AdGuard Home version does not say whether a rewrite is enabled."
        fi
        echo
        ui_hint "Everything AdGuard Home reports, also for domains that are not your sites;"
        ui_hint "a record being listed does not mean NGINX Manager created it. Read only: nothing was changed."
    fi
    pause
}

# ==========================================================
# ADD REWRITE
# ==========================================================
# Asks for a site and an IP address, shows what AdGuard Home already has
# for the site's domain and, after a confirmed summary, adds one exact
# rewrite. Any exact rewrite for the domain stops it: existing records are
# never changed here. AdGuard Home is contacted only once the IP is given.
adguard_add_screen() {
    ui_screen "DNS (AdGuard Home)" "Add rewrite"
    adguard_require_config || { pause; return 1; }
    if ! jq empty "$SITES_DB" >/dev/null 2>&1; then
        msg_error "The site database $SITES_DB cannot be read (invalid JSON)"
        pause
        return 1
    fi
    if [[ -z "$(sites_tsv)" ]]; then
        echo "  No sites configured yet - no domain to add a rewrite for."
        pause
        return 1
    fi
    echo "Points one of your sites' domains to an IP address, normally this server's."
    echo "Nothing is changed until you confirm the summary."
    ui_cancel_hint

    local site domain answer i
    select_site "Site" || { ui_aborted $?; pause; return 1; }
    site="$UI_REPLY"
    domain=$(db_get "$site" domain)
    if ! validate_domain "$domain"; then
        msg_error "Site $site has no valid domain name - no rewrite can be added for it"
        pause
        return 1
    fi

    echo
    ui_kv "Domain" "$domain"
    while true; do
        ui_input "IP address" "$AG_ANSWER" "IPv4 or IPv6 address $domain should resolve to" || { ui_aborted $?; pause; return 1; }
        answer="$UI_REPLY"
        adguard_valid_ip "$answer" && break
        msg_error "Invalid IP address - enter an IPv4 or IPv6 address"
    done

    echo
    adguard_fetch_view || { pause; return 1; }
    adguard_match "$domain"
    if ((${#AG_EXACT[@]})); then
        adguard_add_blocked "$domain" "$answer"
        pause
        return 1
    fi
    if ((${#AG_WILD[@]})); then
        echo
        msg_warning "No exact rewrite for $domain, but a wildcard rewrite may already answer for it:"
        for i in "${AG_WILD[@]}"; do
            printf '        %s %s %s%s\n' "${AG_RW_DOMAIN[i]}" "$SYM_ARROW" "${AG_RW_ANSWER[i]}" \
                "$(adguard_state_suffix "${AG_RW_STATE[i]}")"
        done
        ui_hint "An exact rewrite takes precedence over the wildcard, for $domain only."
        echo
        if ! confirm "Add an exact rewrite anyway?" n; then
            msg_warning "Cancelled - nothing was changed"
            pause
            return 1
        fi
    fi

    ui_section "Summary"
    ui_kv "Site" "$site"
    ui_kv "Domain" "$domain"
    ui_kv "IP address" "$answer"
    [[ "$domain" != "${domain,,}" ]] && ui_hint "AdGuard Home stores the domain in lowercase: ${domain,,}"
    [[ -n "$AG_ANSWER" ]] && ! adguard_same_answer "$answer" "$AG_ANSWER" \
        && ui_hint "For this rewrite only: the default IP stays $AG_ANSWER."
    [[ "$AG_RW_GLOBAL" == false ]] \
        && ui_hint "Rewrites are turned off in AdGuard Home: this one applies once they are turned on."
    ui_hint "Adds one rewrite to AdGuard Home; nothing else there or in nginx is changed."
    echo
    if ! confirm "Add this rewrite?" y; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return 1
    fi
    echo
    ui_run adguard_create_rewrite "$domain" "$answer"
    pause
}

# adguard_add_blocked <domain> <answer>  -- why AG_EXACT stops Add rewrite.
adguard_add_blocked() {
    local domain="$1" answer="$2" first="${AG_EXACT[0]}" i
    echo
    if ((${#AG_EXACT[@]} > 1)); then
        msg_warning "$domain already has ${#AG_EXACT[@]} exact rewrites - they need a manual review:"
    elif ! adguard_same_answer "${AG_RW_ANSWER[first]}" "$answer"; then
        msg_warning "$domain already has a rewrite with another answer - it was not changed:"
    elif [[ "${AG_RW_STATE[first]}" == false ]]; then
        msg_warning "The rewrite already exists, but is disabled in AdGuard Home:"
    else
        msg_success "The rewrite already exists - nothing to add:"
    fi
    for i in "${AG_EXACT[@]}"; do
        printf '        %s %s %s%s\n' "${AG_RW_DOMAIN[i]}" "$SYM_ARROW" "${AG_RW_ANSWER[i]}" \
            "$(adguard_state_suffix "${AG_RW_STATE[i]}")"
    done
    echo
    if ((${#AG_EXACT[@]} > 1)); then
        ui_hint "Which of them should stay cannot be decided here, and a listed record was not"
        ui_hint "necessarily created by NGINX Manager. Review them in AdGuard Home (Filters › DNS rewrites)."
    elif ! adguard_same_answer "${AG_RW_ANSWER[first]}" "$answer"; then
        ui_hint "To change its IP address, use Edit rewrite (or edit it in AdGuard Home,"
        ui_hint "Filters › DNS rewrites)."
    elif [[ "${AG_RW_STATE[first]}" == false ]]; then
        ui_hint "Turning a rewrite on is not available here yet; until then, enable it in"
        ui_hint "AdGuard Home (Filters › DNS rewrites)."
    fi
    ui_hint "Nothing was sent: Add rewrite never changes existing records."
}

# ==========================================================
# EDIT AND DELETE REWRITE
# ==========================================================
# Asks for a site and reads AdGuard Home's rewrites, for Edit/Delete
# rewrite. Sets AG_SITE and AG_DOMAIN. AdGuard Home is contacted only once
# a site with a valid domain is picked. Returns 1 (explained) when there is
# nothing to work on.
adguard_manage_start() {
    AG_SITE="" AG_DOMAIN=""
    adguard_require_config || return 1
    if ! jq empty "$SITES_DB" >/dev/null 2>&1; then
        msg_error "The site database $SITES_DB cannot be read (invalid JSON)"
        return 1
    fi
    if [[ -z "$(sites_tsv)" ]]; then
        echo "  No sites configured yet - only rewrites for your sites' domains are managed here."
        return 1
    fi
    select_site "Site" || { ui_aborted $?; return 1; }
    AG_SITE="$UI_REPLY"
    AG_DOMAIN=$(db_get "$AG_SITE" domain)
    if ! validate_domain "$AG_DOMAIN"; then
        msg_error "Site $AG_SITE has no valid domain name - its rewrites cannot be managed"
        return 1
    fi
    echo
    adguard_fetch_view && adguard_list_complete
}

# adguard_pick_rewrite <domain> <verb>  -- picks one of the domain's exact
# rewrites (as fetched) into AG_PICK; a single one is taken as it is.
# Wildcard records and records shown with characters removed are not
# offered. Returns 0, 3 when there is none (explained), else as ui_pick.
adguard_pick_rewrite() {
    local domain="$1" verb="$2" i ids=() labels=() values=() hidden=0
    AG_PICK=""
    adguard_match "$domain"
    for i in "${AG_EXACT[@]}"; do
        if [[ "${AG_RW_RAW[i]}" == true ]]; then ids+=("$i"); else hidden=$((hidden + 1)); fi
    done
    echo
    ((hidden)) && msg_warning "$hidden rewrite(s) for $domain hold characters that cannot be shown - not offered; review them in AdGuard Home"
    if ((${#ids[@]} == 0)); then
        if ((hidden)); then
            msg_warning "Nothing to $verb here"
        else
            msg_warning "No exact rewrite for $domain - nothing to $verb"
            ((${#AG_WILD[@]})) && ui_hint "A wildcard rewrite (*.example.com) covers it; wildcard records are not changed here."
            ui_hint "Add rewrite creates one; All rewrites lists every record in AdGuard Home."
        fi
        return 3
    fi
    if ((${#ids[@]} == 1)); then
        AG_PICK="${ids[0]}"
        return 0
    fi
    for i in "${!ids[@]}"; do
        values+=("$((i + 1))")
        labels+=("${AG_RW_DOMAIN[ids[i]]} $SYM_ARROW ${AG_RW_ANSWER[ids[i]]}$(adguard_state_note "${AG_RW_STATE[ids[i]]}")")
    done
    echo "$domain has ${#ids[@]} exact rewrites; pick one."
    UI_PICK_LABELS=("${labels[@]}")
    ui_pick "Rewrite" "${values[@]}" || return
    AG_PICK="${ids[UI_REPLY - 1]}"
}

# adguard_state_suffix without colours, for list labels.
adguard_state_note() {
    case "$1" in
        false) printf ' (disabled)' ;;
        unknown) printf ' (enabled state not reported)' ;;
    esac
}

# Shows the picked rewrite (AG_PICK) for AG_SITE.
adguard_show_rewrite() {
    local i="$AG_PICK" state
    case "${AG_RW_STATE[i]}" in
        true) state=$(ui_badge on "Enabled") ;;
        false) state=$(ui_badge off "Disabled in AdGuard Home") ;;
        *) state=$(ui_badge unknown "Not reported by this AdGuard Home version") ;;
    esac
    ui_section "Rewrite"
    ui_kv "Site" "$AG_SITE"
    ui_kv "Domain" "${AG_RW_DOMAIN[i]}"
    ui_kv "IP address" "${AG_RW_ANSWER[i]}"
    ui_kv "State" "$state"
}

# Changes the IP address of one exact rewrite for a site's domain, in place
# and after a confirmed summary. Its domain and enabled state stay. Blocked
# when the AdGuard Home version cannot edit, the record is listed more than
# once (AdGuard Home would change the first, whichever that is) or another
# record for the domain already has the new address.
adguard_edit_screen() {
    ui_screen "DNS (AdGuard Home)" "Edit rewrite"
    echo "Changes the IP address of one rewrite for a site's domain; the domain stays."
    echo "Nothing is changed until you confirm the summary."
    ui_cancel_hint
    adguard_manage_start || { pause; return 1; }
    adguard_edit_supported || { pause; return 1; }
    adguard_pick_rewrite "$AG_DOMAIN" edit
    local rc=$?
    if ((rc)); then
        ((rc == 3)) || ui_aborted "$rc"
        pause
        return 1
    fi

    local i="$AG_PICK" domain answer state n new default="" j
    domain="${AG_RW_DOMAIN[i]}" answer="${AG_RW_ANSWER[i]}" state="${AG_RW_STATE[i]}"
    adguard_show_rewrite
    n=$(adguard_count_exact "$domain" "$answer")
    if ((n > 1)); then
        echo
        msg_warning "$domain $SYM_ARROW $answer is in AdGuard Home $n times - which one would change is ambiguous"
        ui_hint "AdGuard Home changes the first identical record, and which one that is cannot be chosen."
        ui_hint "Review the duplicates in AdGuard Home (Filters › DNS rewrites). Nothing was sent."
        pause
        return 1
    fi

    echo
    [[ -n "$AG_ANSWER" ]] && ! adguard_same_answer "$AG_ANSWER" "$answer" && default="$AG_ANSWER"
    while true; do
        ui_input "New IP address" "$default" "IPv4 or IPv6 address $domain should resolve to instead of $answer" \
            || { ui_aborted $?; pause; return 1; }
        new="$UI_REPLY"
        adguard_valid_ip "$new" && break
        msg_error "Invalid IP address - enter an IPv4 or IPv6 address"
    done
    if adguard_same_answer "$new" "$answer"; then
        echo
        msg_success "$domain already points to $answer - nothing to change"
        ui_hint "Nothing was sent."
        pause
        return 0
    fi
    adguard_match "$domain"
    for j in "${AG_EXACT[@]}"; do
        if ((j != i)) && adguard_same_answer "${AG_RW_ANSWER[j]}" "$new"; then
            echo
            msg_warning "$domain already has a rewrite to $new - changing this one would duplicate it:"
            printf '        %s %s %s%s\n' "${AG_RW_DOMAIN[j]}" "$SYM_ARROW" "${AG_RW_ANSWER[j]}" \
                "$(adguard_state_suffix "${AG_RW_STATE[j]}")"
            ui_hint "Delete rewrite removes the one you do not need. Nothing was sent."
            pause
            return 1
        fi
    done

    ui_section "Summary"
    ui_kv "Site" "$AG_SITE"
    ui_kv "Domain" "$domain"
    ui_kv "IP address" "$answer $SYM_ARROW $new"
    [[ "$domain" != "${domain,,}" ]] && ui_hint "AdGuard Home stores the domain in lowercase: ${domain,,}"
    [[ "$state" == false ]] && ui_hint "The rewrite is disabled in AdGuard Home and stays disabled."
    [[ "$AG_RW_GLOBAL" == false ]] \
        && ui_hint "Rewrites are turned off in AdGuard Home: the change applies once they are turned on."
    ui_hint "A listed record was not necessarily created by NGINX Manager."
    ui_hint "Changes this one record in AdGuard Home; nothing else there or in nginx is changed."
    echo
    if ! confirm "Change this rewrite?" y; then
        msg_warning "Cancelled - nothing was changed"
        pause
        return 1
    fi
    echo
    ui_run adguard_update_rewrite "$domain" "$answer" "$new" "$state"
    pause
}

# Deletes the rewrites with exactly one domain and answer for a site's
# domain, after the domain is typed. AdGuard Home removes every identical
# record at once: when there are several, that is said with their number
# and confirmed separately.
adguard_delete_screen() {
    ui_screen "DNS (AdGuard Home)" "Delete rewrite"
    echo "Removes a rewrite for one of your sites' domains from AdGuard Home."
    echo "Nothing is removed until you type the domain to confirm."
    ui_cancel_hint
    adguard_manage_start || { pause; return 1; }
    adguard_pick_rewrite "$AG_DOMAIN" delete
    local rc=$?
    if ((rc)); then
        ((rc == 3)) || ui_aborted "$rc"
        pause
        return 1
    fi

    local i="$AG_PICK" domain answer n
    domain="${AG_RW_DOMAIN[i]}" answer="${AG_RW_ANSWER[i]}"
    adguard_show_rewrite
    n=$(adguard_count_exact "$domain" "$answer")
    echo
    if ((n > 1)); then
        msg_warning "$domain $SYM_ARROW $answer is in AdGuard Home $n times: AdGuard Home removes all $n identical records, not just one"
        if ! confirm "Delete all $n identical records?" n; then
            msg_warning "Cancelled - nothing was changed"
            pause
            return 1
        fi
    fi
    ui_hint "Only records with exactly this domain and IP address are removed; other"
    ui_hint "addresses for $domain and other domains stay. A listed record was not"
    ui_hint "necessarily created by NGINX Manager. nginx is not changed."
    echo
    ui_confirm_typed "$domain" "Type the domain to confirm deletion"
    rc=$?
    if ((rc == 3)); then
        echo
        msg_warning "Cancelled (domain did not match) - nothing was changed"
        pause
        return 1
    elif ((rc != 0)); then
        ui_aborted "$rc"
        pause
        return 1
    fi
    echo
    ui_run adguard_delete_rewrite "$domain" "$answer" "$n"
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
