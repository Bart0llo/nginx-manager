#!/bin/bash
# ==========================================================
# NGINX Manager Pro - system check
# Sourced by nginx-site.sh: defines functions only.
# ==========================================================

# ==========================================================
# SYSTEM
# ==========================================================
system_check() {
    header
    echo -e "${BOLD}SYSTEM CHECK${NC}"
    echo "──────────────────────────────────────────────────────"
    echo

    echo "  Dependencies"
    if command -v jq >/dev/null 2>&1; then echo -e "    jq        ${GREEN}✓${NC}"; else echo -e "    jq        ${RED}✗${NC}"; fi
    if command -v nginx >/dev/null 2>&1; then echo -e "    nginx     ${GREEN}✓${NC}"; else echo -e "    nginx     ${RED}✗${NC}"; fi
    if command -v certbot >/dev/null 2>&1; then echo -e "    certbot   ${GREEN}✓${NC}"; else echo -e "    certbot   ${YELLOW}○ optional${NC}"; fi
    if command -v openssl >/dev/null 2>&1; then echo -e "    openssl   ${GREEN}✓${NC}"; else echo -e "    openssl   ${YELLOW}○ optional${NC}"; fi
    echo

    echo "  Nginx"
    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "    Service     ${GREEN}✓ Running${NC}"
    else
        echo -e "    Service     ${RED}✗ Not running${NC}"
    fi
    if test_nginx_config >/dev/null 2>&1; then
        echo -e "    Config      ${GREEN}✓ Valid${NC}"
    else
        echo -e "    Config      ${RED}✗ Invalid${NC}"
    fi
    echo

    echo "  TLS"
    if load_config >/dev/null 2>&1 && [[ -n "$CERT_NAME" ]]; then
        local cert="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
        if [[ -f "$cert" ]]; then
            echo -e "    Certificate ${GREEN}✓ Present${NC}"
            local days_left
            days_left=$(_cert_days_left)
            if [[ -n "$days_left" ]]; then
                if ((days_left < 14)); then
                    echo -e "    Expiration  ${YELLOW}! ${days_left} days${NC}"
                else
                    echo -e "    Expiration  ${GREEN}✓ ${days_left} days${NC}"
                fi
            fi
        else
            echo -e "    Certificate ${YELLOW}○ Not issued${NC}"
        fi
    else
        echo -e "    Certificate ${GRAY}— Not configured${NC}"
    fi
    echo

    echo "  Manager"
    if load_config >/dev/null 2>&1; then
        echo -e "    Config      ${GREEN}✓${NC}"
    else
        echo -e "    Config      ${RED}✗${NC}"
    fi
    if jq empty "$SITES_DB" >/dev/null 2>&1; then
        echo -e "    Database    ${GREEN}✓${NC}"
    else
        echo -e "    Database    ${RED}✗ Broken${NC}"
    fi
    local db_perm
    db_perm=$(stat -c "%a" "$SITES_DB" 2>/dev/null)
    if [[ "$db_perm" == "600" ]]; then
        echo -e "    Permissions ${GREEN}✓${NC}"
    else
        echo -e "    Permissions ${YELLOW}! ${db_perm:-unknown}${NC}"
    fi

    pause
}
