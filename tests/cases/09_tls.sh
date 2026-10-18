#!/bin/bash
# TLS manager: Cloudflare credentials, certbot calls (mocked), cert status.

CF="/etc/nginx-manager/secrets/cloudflare.ini"

t_cloudflare_credentials_check() {
    fixture_configured; load_app
    cloudflare_credentials_ok; assert_eq 1 $? "missing file -> not ok"
    mkdir -p "$(dirname "$CF")"; : > "$CF"
    cloudflare_credentials_ok; assert_eq 1 $? "empty file -> not ok"
    echo "something_else = 1" > "$CF"
    cloudflare_credentials_ok; assert_eq 1 $? "file without token key -> not ok"
    fixture_cloudflare
    cloudflare_credentials_ok; assert_eq 0 $? "token present -> ok"
}

t_save_cloudflare_token() {
    fixture_configured; load_app
    local out
    out=$(create_cloudflare_token <<< $'super-secret-token\n\n' 2>&1)
    assert_eq "dns_cloudflare_api_token = super-secret-token" "$(cat "$CF")" "credentials file content"
    assert_mode "$CF" 600
    assert_mode "$(dirname "$CF")" 700
    assert_not_contains "$out" "super-secret-token" "token not echoed"
    assert_not_contains "$(cat /var/log/nginx-manager/manager.log)" "super-secret-token" "token not logged"
    assert_contains "$out" "Cloudflare credentials saved" "success message"
}

t_cloudflare_token_overwrite_declined() {
    fixture_configured; fixture_cloudflare; load_app
    local out
    out=$(create_cloudflare_token <<< $'n\n\n' 2>&1)
    assert_contains "$out" "Overwrite existing token? [y/N]" "asks before overwriting"
    assert_eq "dns_cloudflare_api_token = test-token" "$(cat "$CF")" "existing token kept"
}

t_cloudflare_empty_token() {
    fixture_configured; load_app
    local out
    out=$(create_cloudflare_token <<< $'\nn\n' 2>&1)
    assert_contains "$out" "Token cannot be empty" "empty rejected"
    assert_no_file "$CF" "nothing written"
}

t_create_certificate() {
    fixture_configured; fixture_cloudflare; load_app
    local out
    out=$(create_certificate <<< $'\n' 2>&1)
    assert_called "certbot certonly --dns-cloudflare --dns-cloudflare-credentials $CF --dns-cloudflare-propagation-seconds 30 --cert-name lan.example.com -d *.lan.example.com -d lan.example.com --agree-tos --non-interactive -m admin@example.com" \
        "certbot DNS-01 wildcard request"
    assert_contains "$out" "Certificate created" "success message"
}

t_create_certificate_prompts_for_missing_email() {
    fixture_configured; fixture_cloudflare
    sed -i 's/^CERTBOT_EMAIL=.*/CERTBOT_EMAIL=/' "$MANAGER_DIR/config.conf"
    load_app
    create_certificate <<< $'me@example.org\n\n' >/dev/null 2>&1
    assert_called "-m me@example.org" "prompted email used"
}

# D8: the email typed at the prompt is validated before certbot sees it.
t_create_certificate_rejects_invalid_email() {
    fixture_configured; fixture_cloudflare
    sed -i 's/^CERTBOT_EMAIL=.*/CERTBOT_EMAIL=/' "$MANAGER_DIR/config.conf"
    load_app
    local out rc
    out=$(create_certificate <<< $'x$(touch /tmp/pwned)@example.com\n\n' 2>&1); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "Invalid email" "reason shown"
    assert_not_called "certbot certonly" "certbot not run"
    assert_no_file /tmp/pwned "nothing executed"
}

t_create_certificate_failure_reported() {
    fixture_configured; fixture_cloudflare; load_app
    # certbot that fails with its own diagnostics on stderr (D1).
    cat > "$MOCK_BIN/certbot" <<'EOF'
#!/bin/bash
echo "certbot $*" >> /tmp/mock-calls.log
echo "An unexpected error occurred: DNS problem" >&2
exit 1
EOF
    local out rc
    out=$(create_certificate <<< $'\n' 2>&1); rc=$?
    assert_called "certbot certonly" "certbot invoked"
    assert_not_contains "$out" "Certificate created" "no success claimed"
    assert_contains "$out" "Certificate request failed (certbot exit 1)" "failure reported"
    assert_contains "$out" "An unexpected error occurred: DNS problem" "certbot error output kept"
    assert_eq 1 "$rc" "nonzero return"
    local logf
    logf=$(cat /var/log/nginx-manager/manager.log)
    assert_not_contains "$logf" "Certificate created" "success not logged"
    assert_contains "$logf" "Certificate creation failed for lan.example.com (certbot exit 1)" "failure logged"
}

t_create_certificate_preconditions() {
    fixture_configured; load_app
    local out
    out=$(create_certificate <<< $'\n' 2>&1)
    assert_contains "$out" "Cloudflare credentials not configured" "requires credentials"
    assert_not_called "certbot" "certbot not run without credentials"

    fixture_cloudflare; remove_mock certbot
    out=$(create_certificate <<< $'\n' 2>&1)
    assert_contains "$out" "Certbot is not installed. Run TLS Manager -> Install TLS dependencies." "requires certbot"

    install_mocks
    sed -i 's/^DOMAIN=.*/DOMAIN=/' "$MANAGER_DIR/config.conf"
    out=$(create_certificate <<< $'\n' 2>&1)
    assert_contains "$out" "DOMAIN is not set in configuration" "requires DOMAIN"
}

t_renew_certificate() {
    fixture_configured; load_app
    renew_certificate <<< $'\n' >/dev/null 2>&1
    assert_called "certbot renew --deploy-hook systemctl reload nginx" "renew with reload hook"
}

t_certificate_info() {
    fixture_configured; load_app
    local out
    out=$(certificate_info <<< $'\n' 2>&1)
    assert_contains "$out" "subject=CN=lan.example.com" "subject"
    assert_contains "$out" "DNS:*.lan.example.com" "SAN"
    assert_contains "$out" "notAfter=" "dates"
    sed -i 's/^CERT_NAME=.*/CERT_NAME=missing.example.com/' "$MANAGER_DIR/config.conf"
    out=$(certificate_info <<< $'\n' 2>&1)
    assert_contains "$out" "Certificate not found" "missing cert"
}

t_cert_days_left() {
    fixture_configured; load_app
    load_config   # _cert_days_left reads CERT_NAME set by load_config
    local d
    d=$(_cert_days_left)
    if [[ "$d" =~ ^[0-9]+$ ]] && ((d >= 28 && d <= 30)); then
        pass "30-day cert: days left in 28..30 ($d)"
    else
        fail "30-day cert: days left in 28..30 (got '$d')"
    fi
}

t_install_tls_dependencies() {
    fixture_configured; load_app
    local out
    out=$(install_tls <<< $'\n' 2>&1)
    assert_called "apt update" "apt update"
    assert_called "apt install -y certbot python3-certbot-dns-cloudflare jq curl" "packages"
    assert_contains "$out" "TLS dependencies installed" "success message"

    : > "$MOCK_LOG"; mock_rc apt-update 100
    out=$(install_tls <<< $'\n' 2>&1)
    assert_contains "$out" "apt update failed" "apt failure reported"
    assert_not_called "apt install" "install not attempted"
}

t_tls_menu_status() {
    fixture_configured; load_app
    local out
    out=$(tls_menu <<< $'q\n' 2>&1)
    assert_contains "$out" "Name         lan.example.com" "cert name"
    assert_contains "$out" "Status       ✓ Valid" "valid cert"
    assert_contains "$out" "Days left" "days left shown"
    assert_contains "$out" "Credentials  ✗ Not configured" "no credentials"
    fixture_cloudflare
    out=$(tls_menu <<< $'q\n' 2>&1)
    assert_contains "$out" "Credentials  ✓ Configured" "credentials configured"
}

t_tls_status_expiring_and_missing() {
    fixture_configured
    create_cert soon.example.com 5
    sed -i 's/lan\.example\.com/soon.example.com/' "$MANAGER_DIR/config.conf"
    load_app
    assert_contains "$(tls_menu <<< $'q\n' 2>&1)" "Status       ! Expires soon" "tls menu: < 14 days"
    assert_contains "$(render_dashboard_status 2>&1)" "Certificate    ! Expires in " "dashboard: < 14 days"
    sed -i 's/^CERT_NAME=.*/CERT_NAME=missing.example.com/' "$MANAGER_DIR/config.conf"
    assert_contains "$(tls_menu <<< $'q\n' 2>&1)" "Status       ○ Not issued" "tls menu: not issued"
    assert_contains "$(render_dashboard_status 2>&1)" "Certificate    ○ Not issued" "dashboard: not issued"
}
