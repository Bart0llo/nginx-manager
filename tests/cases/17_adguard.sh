#!/bin/bash
# AdGuard Home integration (lib/adguard.sh): validation, the saved
# connection and password, the API client against the mock
# (tests/mocks/curl-adguard), and the DNS menu in both interfaces.

PW="S3cr3t-pw"
# What the Authorization header carries for admin:$PW.
PW_B64=$(printf 'admin:%s' "$PW" | base64 -w0)
CONF="$MANAGER_DIR/adguard.conf"
SECRET="$MANAGER_DIR/secrets/adguard.password"

# Fails if the password, or the header value that encodes it, shows up in
# the given text, the mock's argument log or the manager log.
assert_no_leak() { # text what
    local where
    for where in "$1" "$(cat "$MOCK_LOG" 2>/dev/null)" "$(cat /var/log/nginx-manager/manager.log 2>/dev/null)"; do
        assert_not_contains "$where" "$PW" "$2: password not exposed"
        assert_not_contains "$where" "$PW_B64" "$2: encoded login not exposed"
    done
}

# ==========================================================
# Validation
# ==========================================================
t_validators() {
    fixture_configured; load_app
    local v
    for v in 0.0.0.0 192.168.1.10 255.255.255.255 10.0.0.1; do
        validate_ipv4 "$v"; assert_eq 0 $? "ipv4 ok: $v"
    done
    for v in 256.1.1.1 1.2.3 1.2.3.4.5 01.2.3.4 1.2.3.04 "" a.b.c.d " 1.2.3.4" 1.2.3.4/24; do
        validate_ipv4 "$v"; assert_eq 1 $? "ipv4 rejected: '$v'"
    done
    for v in ::1 :: fd00::10 2001:db8::1 2001:0db8:0000:0000:0000:0000:0000:0001 \
        1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:: ::2:3:4:5:6:7:8 ::ffff:192.168.1.10 FE80::ABCD; do
        validate_ipv6 "$v"; assert_eq 0 $? "ipv6 ok: $v"
    done
    for v in 1:2:3:4:5:6:7 1:2:3:4:5:6:7:8:9 1::2::3 :1:2:3:4:5:6:7 1:2:3:4:5:6:7: \
        ::: 12345::1 g::1 fe80::1%eth0 1.2.3.4 ::ffff:256.1.1.1 1:2:3:4:5:6:7:8::; do
        validate_ipv6 "$v"; assert_eq 1 $? "ipv6 rejected: '$v'"
    done
    for v in http://dns https://dns.lan.example.com http://192.168.1.2:3000 \
        https://h.example.com:8443/adguard http://[fd00::1]:80 https://dns.lan.example.com/; do
        validate_http_url "$v"; assert_eq 0 $? "url ok: $v"
    done
    for v in ftp://dns dns.lan.example.com http:// "http://a b" http://user:pw@dns http://dns?x=1 \
        http://dns#x http://dns:0 http://dns:65536 http://dns:080 http://-dns http://[fd00::g] \
        'http://dns/$(id)' "http://dns/a'b" "https://dns\n"; do
        validate_http_url "$v"; assert_eq 1 $? "url rejected: '$v'"
    done
}

# ==========================================================
# Saved connection
# ==========================================================
t_config_not_configured() {
    fixture_configured; load_app
    adguard_load_config; assert_eq 2 $? "no file: not configured"
    assert_eq "" "$AG_URL" "nothing loaded"
    local out
    out=$(adguard_test 2>&1); assert_eq 2 $? "test refused"
    assert_contains "$out" "not configured" "reason shown"
}

t_config_parsing() {
    fixture_configured; load_app
    printf '%s\n' "# comment" "URL='https://dns.lan.example.com/'" "USERNAME=admin" \
        "DEFAULT_ANSWER=fd00::10" > "$CONF"
    adguard_load_config; assert_eq 0 $? "valid file loads"
    assert_eq "https://dns.lan.example.com|admin|fd00::10" "$AG_URL|$AG_USER|$AG_ANSWER" \
        "values loaded, trailing / dropped"

    local content expected
    while IFS='|' read -r content expected; do
        printf '%b\n' "$content" > "$CONF"
        adguard_load_config; assert_eq 1 $? "rejected: $content"
        assert_eq "$expected" "$AG_CONFIG_ERROR" "reason for: $content"
        assert_eq "" "$AG_URL" "nothing kept: $content"
    done <<'EOF'
URL=http://admin:hunter2@dns|invalid URL
URL=http://dns\nPASSWORD=hunter2|unknown setting PASSWORD
URL=http://dns\nURL=http://other|line 2: URL repeated
export URL=http://dns|line 1: expected KEY=VALUE
URL=$(touch /tmp/pwned)|invalid URL
USERNAME=admin|URL is missing
URL=http://dns\nUSERNAME=a:b|invalid USERNAME
URL=http://dns\nDEFAULT_ANSWER=192.168.1.256|invalid DEFAULT_ANSWER
URL=https://dns\nCA_FILE=/etc/ssl/private-ca.pem|unknown setting CA_FILE
EOF
    assert_no_file /tmp/pwned "file content never executed"

    local out
    printf 'URL=http://admin:hunter2@dns\n' > "$CONF"
    out=$(adguard_menu <<< 'q' 2>&1)
    assert_contains "$out" "Invalid $CONF" "menu reports an invalid file"
    assert_not_contains "$out" "hunter2" "values never shown"
}

t_save_config() {
    fixture_configured; load_app
    local out rc
    ( umask 000; adguard_save_config https://dns.lan.example.com/control/ admin 192.168.1.10 >/dev/null 2>&1 )
    assert_eq 0 $? "saved"
    assert_mode "$CONF" 600 "mode 600 even with umask 000"
    adguard_load_config
    assert_eq "https://dns.lan.example.com|admin|192.168.1.10" "$AG_URL|$AG_USER|$AG_ANSWER" \
        "round trip; /control and trailing / dropped"
    assert_eq "URL USERNAME DEFAULT_ANSWER" "$(grep -v '^#' "$CONF" | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')" \
        "only the three keys written"
    assert_eq "" "$(temp_files "$MANAGER_DIR")" "no temporary files left"

    local args
    for args in "ftp://dns||" "http://dns|a:b|" "http://dns|admin|1.2.3"; do
        IFS='|' read -r -a parts <<< "$args"
        out=$(adguard_save_config "${parts[@]}" 2>&1); rc=$?
        assert_eq 2 "$rc" "invalid input refused: $args"
    done
    adguard_load_config
    assert_eq "https://dns.lan.example.com" "$AG_URL" "file unchanged after refusals"
}

temp_files() { ls -A "$1" | grep -E '^tmp\.'; }

t_password_storage() {
    fixture_configured; load_app
    local out rc
    out=$( (umask 000; printf '%s' "$PW" | adguard_password_set) 2>&1); rc=$?
    assert_eq 0 "$rc" "saved"
    assert_mode "$MANAGER_DIR/secrets" 700
    assert_mode "$SECRET" 600
    assert_eq "$PW" "$(cat "$SECRET")" "stored exactly"
    assert_eq "adguard.password" "$(ls -A "$MANAGER_DIR/secrets")" "no temporary files left"
    printf '' | adguard_password_set >/dev/null 2>&1; assert_eq 2 $? "empty value refused"
    assert_eq "$PW" "$(cat "$SECRET")" "previous value kept"
    assert_no_leak "$out" "save"

    rm -rf "$MANAGER_DIR/secrets"
    mkdir -p /tmp/agh-elsewhere; ln -s /tmp/agh-elsewhere "$MANAGER_DIR/secrets"
    printf 'x' | adguard_password_set >/dev/null 2>&1; assert_eq 1 $? "symlinked secrets directory refused"
    assert_eq "" "$(ls -A /tmp/agh-elsewhere)" "nothing written through the symlink"
    rm -rf /tmp/agh-elsewhere
}

# ==========================================================
# API client
# ==========================================================
t_test_connection_ok() {
    fixture_configured; fixture_adguard https://dns.lan.example.com admin "$PW"
    use_adguard "admin:$PW"
    load_app
    local out rc
    out=$(adguard_test 2>&1); rc=$?
    assert_eq 0 "$rc" "connected"
    assert_contains "$out" "Connected to AdGuard Home v0.107.79" "version shown"
    assert_matches "$out" "DNS server +✓ Running" "DNS state shown"
    assert_eq "GET status auth=ok" "$(agh_requests)" "one request, logged in"
    assert_called "https://dns.lan.example.com/control/status" "URL built from the setting"
    assert_called "-q -s --proto =http,https" "~/.curlrc ignored, http(s) only"
    assert_called "-K -" "login passed on stdin"
    assert_not_called "Authorization" "no header in the arguments"
    assert_not_called " -u " "no -u"
    assert_not_called " -L" "redirects not followed"
    local opt
    for opt in " -k " "--insecure" "--cacert" "--capath" "--ca-native" "--proxy-insecure"; do
        assert_not_called "$opt" "certificates verified with the system store: no $opt"
    done
    assert_no_leak "$out" "test"
    assert_eq "" "$(ls /tmp | grep nm-adguard)" "temporary answer file removed"

    echo false > /tmp/agh/running
    out=$(adguard_test 2>&1)
    assert_matches "$out" "DNS server +! Not running" "stopped DNS server reported"
}

t_test_connection_no_login() {
    fixture_configured; fixture_adguard http://192.168.1.2:3000
    use_adguard
    load_app
    local out
    out=$(adguard_test 2>&1); assert_eq 0 $? "no users: no login needed"
    assert_eq "GET status auth=none" "$(agh_requests)" "no Authorization sent"

    echo "admin:$PW" > /tmp/agh/auth
    out=$(adguard_test 2>&1); assert_eq 1 $? "users exist: refused"
    assert_contains "$out" "AdGuard Home requires a login" "explained"
}

t_test_connection_errors() {
    fixture_configured; load_app
    local out rc setup expected
    while IFS='|' read -r setup expected; do
        reset_agh
        fixture_adguard https://dns.lan.example.com admin "$PW"
        use_adguard "admin:$PW"
        eval "$setup"
        out=$(adguard_test 2>&1); rc=$?
        assert_eq 1 "$rc" "fails: $setup"
        assert_contains "$out" "$expected" "message for: $setup"
        assert_no_leak "$out" "$setup"
        assert_contains "$(cat /var/log/nginx-manager/manager.log)" "AdGuard Home connection test failed" "logged: $setup"
        assert_eq 1 "$(agh_requests | grep -c .)" "no retry: $setup"
    done <<'EOF'
echo admin:other > /tmp/agh/auth|login failed: wrong username or password
echo 7 > /tmp/agh/curl-rc|could not connect to https://dns.lan.example.com
echo 6 > /tmp/agh/curl-rc|could not resolve the host name
echo 28 > /tmp/agh/curl-rc|timed out
echo 60 > /tmp/agh/curl-rc|add it to this system's trusted certificates (update-ca-certificates)
echo 51 > /tmp/agh/curl-rc|is not trusted or does not match its name
echo 35 > /tmp/agh/curl-rc|TLS connection to https://dns.lan.example.com failed (curl exit 35)
echo 77 > /tmp/agh/curl-rc|this system's trusted certificates could not be read
echo 404 > /tmp/agh/status|not found (HTTP 404): check the URL
echo 302 > /tmp/agh/status|redirected (HTTP 302)
echo 403 > /tmp/agh/status|access denied
echo 429 > /tmp/agh/status|too many failed login attempts
printf '500' > /tmp/agh/status; printf 'boom\nsecond line' > /tmp/agh/body|server error (HTTP 500): boom
printf '<html>hi</html>' > /tmp/agh/body|did not answer like AdGuard Home
printf '{"version":5}' > /tmp/agh/body|did not answer like AdGuard Home
EOF
    assert_not_contains "$out" "second line" "only the first line of a server message"

    reset_agh
    fixture_adguard https://dns.lan.example.com admin
    use_adguard "admin:$PW"
    out=$(adguard_test 2>&1); assert_eq 1 $? "user without a saved password"
    assert_contains "$out" "no password saved for 'admin'" "explained"
    assert_eq "" "$(agh_requests)" "nothing sent"
}

reset_agh() { rm -rf /tmp/agh "$CONF" "$SECRET"; : > "$MOCK_LOG"; }

t_server_text_cleaned() {
    fixture_configured; load_app
    # ESC and BEL go, so nothing can drive the terminal; "[31m" is plain text.
    assert_eq "a[31mbc" "$(adguard_clean_text $'a\x1b[31mb\x07c\nnext')" "control characters and later lines dropped"
    local long
    long=$(printf 'x%.0s' {1..300})
    assert_eq 200 "$(adguard_clean_text "$long" | wc -c)" "shortened to 200 characters"
    assert_eq "no details" "$(adguard_clean_text "")" "empty message"
}

# ==========================================================
# Inactive until used
# ==========================================================
t_no_network_until_used() {
    fixture_configured; fixture_adguard https://dns.lan.example.com admin "$PW"
    use_adguard "admin:$PW"
    local out
    out=$(run_app '1\n\n8\nq\nq\n')
    assert_contains "$out" "DNS (AdGuard Home)" "DNS screen opened"
    assert_contains "$out" "https://dns.lan.example.com" "connection shown"
    assert_not_called "curl" "start, status and the DNS screen send nothing"

    seed 'site_create app app.lan.example.com 127.0.0.1:8080 http; enable_site app;
          site_update app app2.lan.example.com 127.0.0.1:8081 http; disable_site app; site_delete app'
    run_app 'q\n' >/dev/null
    assert_eq "" "$(agh_requests)" "site changes never touch AdGuard Home"
}

# ==========================================================
# Menu (basic interface)
# ==========================================================
t_menu_set_connection() {
    fixture_configured; use_adguard "admin:$PW"
    load_app
    local out
    out=$(adguard_menu <<< $'c\nhttps://dns.lan.example.com/control/\nadmin\n'"$PW"$'\n192.168.1.10\ny\ny\n\nq\n' 2>&1)
    assert_contains "$out" "AdGuard Home connection saved" "saved"
    assert_contains "$out" "Connected to AdGuard Home v0.107.79" "tested on request"
    assert_contains "$out" "admin (new password)" "summary shown"
    assert_contains "$out" "The certificate must be trusted by this system" "HTTPS: system trust explained"
    assert_not_contains "$out" "CA file" "no CA question"
    adguard_load_config
    assert_eq "https://dns.lan.example.com|admin|192.168.1.10" "$AG_URL|$AG_USER|$AG_ANSWER" "settings stored"
    assert_eq "$PW" "$(cat "$SECRET")" "password stored"
    assert_mode "$CONF" 600
    assert_mode "$SECRET" 600
    assert_no_leak "$out" "menu"
    assert_not_contains "$(cat "$CONF")" "$PW" "password not in the settings file"
}

t_menu_keep_password_and_no_login() {
    fixture_configured; fixture_adguard https://dns.lan.example.com admin "$PW"
    use_adguard
    load_app
    local out
    # Enter keeps every value, including the saved password; no test.
    out=$(adguard_menu <<< $'c\n\n\n\n\n\nn\n\nq\n' 2>&1)
    assert_contains "$out" "saved password kept" "keeping offered"
    assert_eq "$PW" "$(cat "$SECRET")" "password unchanged"
    assert_eq "" "$(agh_requests)" "no test unless asked"

    out=$(adguard_menu <<< $'c\n\na:b\n\n' 2>&1)
    assert_contains "$out" "Invalid username" "invalid user name refused"

    # An empty user name has no login: the saved password goes.
    sed -i 's/^USERNAME=.*/USERNAME=/' "$CONF"
    out=$(adguard_menu <<< $'c\n\n\n\ny\nn\n\nq\n' 2>&1)
    assert_contains "$out" "The saved password will be deleted" "announced"
    assert_no_file "$SECRET" "password removed"
}

t_menu_http_warning() {
    fixture_configured; use_adguard
    load_app
    local out
    out=$(adguard_menu <<< $'c\nhttp://dns.lan.example.com\nn\nhttp://192.168.1.2:3000\ny\n\n\ny\nn\n\nq\n' 2>&1)
    assert_count "$out" "travel unencrypted" 3 "warned at each HTTP URL and on the screen"
    adguard_load_config
    assert_eq "http://192.168.1.2:3000" "$AG_URL" "declined URL asked again; accepted one saved"
    assert_not_contains "$out" "trusted by this system" "no certificate hint for HTTP"
}

t_menu_cancel_changes_nothing() {
    fixture_configured; use_adguard
    load_app
    local out
    out=$(adguard_menu <<< $'c\nhttps://dns.lan.example.com\nadmin\n' 2>&1)
    assert_contains "$out" "Input closed" "end of input at the password"
    assert_no_file "$CONF" "no settings"
    assert_no_file "$SECRET" "no password"

    out=$(adguard_menu <<< $'c\nhttps://dns.lan.example.com\nadmin\n'"$PW"$'\n\nn\n\nq\n' 2>&1)
    assert_contains "$out" "Cancelled - nothing was changed" "summary declined"
    assert_no_file "$CONF" "no settings"
    assert_no_file "$SECRET" "no password"

    UI_NONINTERACTIVE=1
    out=$(adguard_connection_prompt 2>&1 </dev/null)
    assert_contains "$out" "Non-interactive mode" "non-interactive: stops"
    assert_no_file "$CONF" "no settings"
    assert_eq "" "$(agh_requests)" "nothing sent"
}

t_menu_remove_connection() {
    fixture_configured; fixture_adguard https://dns.lan.example.com admin "$PW"
    load_app
    local out
    out=$(adguard_menu <<< $'r\nn\n\nq\n' 2>&1)
    assert_file "$CONF" "declined: settings kept"
    out=$(adguard_menu <<< $'r\ny\n\nq\n' 2>&1)
    assert_contains "$out" "AdGuard Home connection removed" "removed"
    assert_no_file "$CONF" "settings gone"
    assert_no_file "$SECRET" "password gone"
    assert_contains "$out" "Not configured" "back to not configured"
}

t_menu_test_screen() {
    fixture_configured; fixture_adguard https://dns.lan.example.com admin "$PW"
    use_adguard "admin:other"
    load_app
    local out
    out=$(adguard_menu <<< $'t\n\nq\n' 2>&1)
    assert_contains "$out" "DNS (AdGuard Home) › Test connection" "test screen"
    assert_contains "$out" "login failed" "failure shown"
    assert_no_leak "$out" "test screen"
}

# ==========================================================
# Menu (gum)
# ==========================================================
t_gum_set_connection() {
    fixture_configured; use_adguard "admin:$PW"
    # DNS, Connection, URL, user, password, IP, save, test; Back, Quit.
    use_gum "0 #8" "0 #1" "0 https://dns.lan.example.com" "0 admin" "0 $PW" "0 192.168.1.10" \
        "0" "0" "0 #4" "0 #10"
    local out rc
    out=$(printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
    assert_eq 0 "$rc" "exits 0"
    assert_contains "$out" "Connected to AdGuard Home v0.107.79" "tested"
    assert_eq "$PW" "$(cat "$SECRET")" "password stored"
    local calls
    calls=$(gum_calls)
    assert_contains "$calls" "gum input | --header=Password (not shown) | --prompt=>  | --password" "password typed hidden"
    assert_contains "$calls" "gum confirm | --default=true | -- | Save these settings?" "summary confirmed"
    assert_not_contains "$calls" "$PW" "password never a gum argument"
    assert_no_leak "$out" "gum"
}

t_gum_cancel_changes_nothing() {
    fixture_configured; use_adguard
    # DNS, Connection, URL, then Esc at the user name; Back, Quit.
    use_gum "0 #8" "0 #1" "0 https://dns.lan.example.com" "1" "0 #2" "0 #10"
    local out rc
    out=$(printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
    assert_eq 0 "$rc" "exits 0"
    assert_contains "$out" "Cancelled - nothing was changed" "cancel reported"
    assert_no_file "$CONF" "no settings"
    assert_eq "" "$(agh_requests)" "nothing sent"
}

# ==========================================================
# Real TLS: the real curl against openssl s_server on the container's
# loopback (no network needed). Certificates come from a throwaway CA.
# ==========================================================
TLS=/tmp/agh-tls

# tls_cert <name> <subjectAltName>  -- server certificate from the test CA.
tls_cert() {
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" \
        -keyout "$TLS/$1.key" -out "$TLS/$1.csr" >/dev/null 2>&1
    openssl x509 -req -in "$TLS/$1.csr" -CA "$TLS/ca.pem" -CAkey "$TLS/ca.key" -CAcreateserial \
        -days 1 -extfile <(printf 'subjectAltName=%s\n' "$2") -out "$TLS/$1.pem" >/dev/null 2>&1
}

# tls_serve <name> <port>  -- serves $TLS/www over HTTPS with that
# certificate; TLS_PIDS collects the servers. Returns 1 if it never listens.
tls_serve() {
    (cd "$TLS/www" && exec openssl s_server -quiet -WWW -accept "$2" \
        -cert "$TLS/$1.pem" -key "$TLS/$1.key") </dev/null >"$TLS/$1.log" 2>&1 &
    TLS_PIDS+=($!)
    local i
    for i in $(seq 50); do
        (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

t_tls_certificate_verification() {
    fixture_configured; load_app
    TLS_PIDS=()
    rm -rf "$TLS"
    mkdir -p "$TLS/www/control"
    jq -nc '{version:"v0.107.79", running:true, protection_enabled:true}' > "$TLS/www/control/status"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
        -subj "/CN=NM Test CA" -keyout "$TLS/ca.key" -out "$TLS/ca.pem" >/dev/null 2>&1
    tls_cert good IP:127.0.0.1
    tls_cert wrongname DNS:other.example.com
    if ! tls_serve good 8443 || ! tls_serve wrongname 8444; then
        fail "test HTTPS servers did not start: $(cat "$TLS"/*.log 2>/dev/null)"
        kill "${TLS_PIDS[@]}" 2>/dev/null
        return
    fi
    assert_eq 0 "$(grep -c . "$MOCK_LOG")" "real curl used, not a mock"

    local out rc curlrc="${HOME:-/root}/.curlrc"
    fixture_adguard https://127.0.0.1:8443
    # A ~/.curlrc asking to skip verification is ignored (curl -q).
    echo insecure > "$curlrc"
    out=$(adguard_test 2>&1); rc=$?
    rm -f "$curlrc"
    assert_eq 1 "$rc" "CA not in the system store: refused"
    assert_contains "$out" "certificate of https://127.0.0.1:8443 is not trusted" "untrusted certificate reported"
    assert_contains "$out" "update-ca-certificates" "system trust store advised"
    assert_not_contains "$out" "Connected" "no connection over an untrusted certificate"

    cp "$TLS/ca.pem" /usr/local/share/ca-certificates/nm-test-ca.crt
    update-ca-certificates >/dev/null 2>&1
    out=$(adguard_test 2>&1); rc=$?
    assert_eq 0 "$rc" "CA added to the system store: verified"
    assert_contains "$out" "Connected to AdGuard Home v0.107.79" "connected over verified HTTPS"

    fixture_adguard https://127.0.0.1:8444
    out=$(adguard_test 2>&1); rc=$?
    assert_eq 1 "$rc" "trusted CA but another name: refused"
    assert_contains "$out" "does not match its name" "name mismatch reported"

    rm -f /usr/local/share/ca-certificates/nm-test-ca.crt
    update-ca-certificates --fresh >/dev/null 2>&1
    kill "${TLS_PIDS[@]}" 2>/dev/null
}
