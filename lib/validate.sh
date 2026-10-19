#!/bin/bash
# ==========================================================
# NGINX Manager Pro - input validation
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# VALIDATION
# ==========================================================
validate_name() { [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; }
validate_domain() { [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; }
# Plugin IDs are also directory and file names, so no dots or slashes.
validate_plugin_id() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }
validate_tls() { [[ "$1" == "http" || "$1" == "https" || "$1" == "both" ]]; }
# Plain local@domain.tld: no quotes, spaces or shell metacharacters.
validate_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; }

# Dotted quad, 0-255 each, no leading zeros (010 could be read as octal).
validate_ipv4() {
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    [[ "$1" =~ ^$octet\.$octet\.$octet\.$octet$ ]]
}

# IPv6 text form: eight groups of 1-4 hex digits, one "::" for a run of
# zero groups, optionally ending in a dotted quad. No zone (%eth0).
validate_ipv6() {
    local addr="$1" group groups=()
    [[ "$addr" =~ ^[0-9A-Fa-f:.]{2,45}$ && "$addr" == *:* ]] || return 1
    # A trailing dotted quad stands for the last two groups.
    if [[ "$addr" == *.* ]]; then
        validate_ipv4 "${addr##*:}" || return 1
        addr="${addr%:*}:0:0"
    fi
    # One ':' at either end only as part of "::"; at most one "::".
    [[ "$addr" == :[!:]* || "$addr" == *[!:]: || "$addr" == *:::* || "$addr" == *::*::* ]] && return 1
    IFS=: read -ra groups <<< "${addr/::/:}"
    local n=0
    for group in "${groups[@]}"; do
        [[ -z "$group" ]] && continue
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        ((n++))
    done
    if [[ "$addr" == *::* ]]; then ((n <= 7)); else ((n == 8)); fi
}

# http(s)://host[:port][/path] - no login, query or fragment. The host is
# a name, an IPv4 address or a bracketed IPv6 address.
validate_http_url() {
    [[ "$1" =~ ^https?://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|\[([0-9A-Fa-f:.]+)\])(:([0-9]+))?(/[A-Za-z0-9._~/-]*)?$ ]] || return 1
    local v6="${BASH_REMATCH[3]}" port="${BASH_REMATCH[5]}"
    [[ -z "$v6" ]] || validate_ipv6 "$v6" || return 1
    [[ -z "$port" ]] && return 0
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535))
}

validate_backend() {
    [[ "$1" =~ ^([a-zA-Z0-9.-]+):([0-9]+)$ ]] || return 1
    local port="${BASH_REMATCH[2]}"

    # Reject leading-zero ports (e.g. "080", "065535") instead of letting
    # bash arithmetic reinterpret them as octal (or silently misjudging them).
    if [[ "$port" =~ ^0[0-9]+$ ]]; then
        return 1
    fi

    ((port >= 1 && port <= 65535))
}

# A site domain is covered by the managed wildcard certificate only if it
# is exactly $DOMAIN or exactly one label below it (matching *.DOMAIN).
domain_covered_by_wildcard() {
    local site_domain="$1" base_domain="$2"
    local escaped_base="${base_domain//./\\.}"

    [[ "$site_domain" == "$base_domain" ]] && return 0
    [[ "$site_domain" =~ ^[a-zA-Z0-9-]+\.${escaped_base}$ ]]
}
