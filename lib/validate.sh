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
