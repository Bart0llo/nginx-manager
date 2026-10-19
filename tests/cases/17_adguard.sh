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
    assert_contains "$out" "Add rewrite" "add offered"
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
    # DNS, Connection, URL, user, password, IP, save, test; Back (7th once
    # configured), Quit.
    use_gum "0 #8" "0 #1" "0 https://dns.lan.example.com" "0 admin" "0 $PW" "0 192.168.1.10" \
        "0" "0" "0 #7" "0 #10"
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
# Rewrites (read-only): API
# ==========================================================
# Rewrites covering every case on the "Your sites' DNS" screen, plus one
# (nas.home.arpa) for a domain that is not a site.
agh_rewrites() {
    mkdir -p /tmp/agh
    cat > /tmp/agh/rewrites <<'EOF'
[{"domain":"app.lan.example.com","answer":"192.168.1.10","enabled":true},
 {"domain":"DUAL.lan.example.com.","answer":"192.168.1.11","enabled":true},
 {"domain":"dual.lan.example.com","answer":"fd00::11","enabled":true},
 {"domain":"dup.lan.example.com","answer":"192.168.1.12","enabled":true},
 {"domain":"dup.lan.example.com","answer":"192.168.1.12","enabled":true},
 {"domain":"clash.lan.example.com","answer":"192.168.1.13","enabled":true},
 {"domain":"clash.lan.example.com","answer":"192.168.1.99","enabled":true},
 {"domain":"off.lan.example.com","answer":"192.168.1.14","enabled":false},
 {"domain":"*.lan.example.com","answer":"192.168.1.1","enabled":true},
 {"domain":"*.deep.example.org","answer":"10.0.0.1","enabled":false},
 {"domain":"nas.home.arpa","answer":"192.168.1.50","enabled":true},
 {"domain":"old.lan.example.com","answer":"192.168.1.15"}]
EOF
}

# A configured, logged-in connection with the rewrites above.
agh_setup() {
    fixture_configured; fixture_adguard https://dns.lan.example.com admin "$PW"
    use_adguard "admin:$PW"
    agh_rewrites
}

# The fetched rewrites, one "domain answer state" line each.
rw_dump() {
    local i
    for i in "${!AG_RW_DOMAIN[@]}"; do
        echo "${AG_RW_DOMAIN[i]} ${AG_RW_ANSWER[i]} ${AG_RW_STATE[i]}"
    done
}

# Fails unless every request so far was a GET of a read-only endpoint.
assert_read_only() { # what
    local line bad=""
    while IFS= read -r line; do
        [[ "$line" =~ ^GET\ (status|rewrite/list|rewrite/settings)\  ]] || bad+="$line; "
    done < <(agh_requests)
    assert_eq "" "$bad" "$1: only GET status, rewrite/list, rewrite/settings"
    assert_not_called " -X " "$1: no other method"
    assert_not_called "--data-binary" "$1: no request body"
}

t_fetch_rewrites() {
    agh_setup
    load_app
    adguard_load_config
    adguard_fetch_rewrites; assert_eq 0 $? "fetched"
    assert_eq "v0.107.79" "$AG_VERSION" "version read from status"
    assert_eq 12 "${#AG_RW_DOMAIN[@]}" "every record"
    assert_eq 0 "$AG_RW_SKIPPED" "none skipped"
    assert_eq true "$AG_RW_GLOBAL" "global switch read"
    assert_eq "" "$AG_ERROR" "no error left"
    local dump
    dump=$(rw_dump)
    assert_eq "*.deep.example.org 10.0.0.1 false" "${dump%%$'\n'*}" "sorted by domain"
    assert_contains "$dump" "app.lan.example.com 192.168.1.10 true" "enabled record"
    assert_contains "$dump" "off.lan.example.com 192.168.1.14 false" "disabled record"
    assert_contains "$dump" "old.lan.example.com 192.168.1.15 unknown" "no enabled field: unknown, not disabled"
    assert_contains "$dump" "DUAL.lan.example.com. 192.168.1.11 true" "domain kept as AdGuard Home has it"
    assert_eq $'GET status auth=ok\nGET rewrite/list auth=ok\nGET rewrite/settings auth=ok' "$(agh_requests)" \
        "three GET requests, logged in"
    assert_read_only "fetch"
    assert_no_leak "$dump" "fetch"
}

t_fetch_rewrites_records() {
    agh_setup
    load_app
    adguard_load_config
    local body
    for body in '[]' 'null'; do
        printf '%s' "$body" > /tmp/agh/rewrites
        adguard_fetch_rewrites; assert_eq 0 $? "empty list ($body)"
        assert_eq "0|0" "${#AG_RW_DOMAIN[@]}|$AG_RW_SKIPPED" "no records ($body)"
    done

    cat > /tmp/agh/rewrites <<'EOF'
[1, "x", null, {}, [], {"domain":"a.example.com"}, {"domain":5,"answer":"1.2.3.4"},
 {"domain":"b.example.com","answer":"1.2.3.4","enabled":"yes"},
 {"domain":"","answer":"1.2.3.4"}, {"domain":"\u0007","answer":"1.2.3.4"},
 {"domain":"c.example.com","answer":"1.2.3.4","enabled":null},
 {"domain":"e\u001b[31mvil.example.com\tx","answer":"1.2.3.4\n5","enabled":true,"extra":1}]
EOF
    adguard_fetch_rewrites; assert_eq 0 $? "list with bad records still read"
    assert_eq 10 "$AG_RW_SKIPPED" "unusable records counted"
    assert_eq $'c.example.com 1.2.3.4 unknown\ne[31mvil.example.comx 1.2.3.45 true' "$(rw_dump)" \
        "usable records kept; control characters removed; null enabled is unknown"

    local setup expected
    while IFS='|' read -r setup expected; do
        reset_agh; agh_setup; adguard_load_config
        eval "$setup"
        adguard_fetch_rewrites; assert_eq 1 $? "fails: $setup"
        assert_contains "$AG_ERROR" "$expected" "reason for: $setup"
        assert_eq 0 "${#AG_RW_DOMAIN[@]}" "no records kept: $setup"
        assert_not_contains "$(agh_requests)" "rewrite/settings" "stops there: $setup"
    done <<'EOF'
printf '<html>hi</html>' > /tmp/agh/rewrites|rewrite list from https://dns.lan.example.com is not valid JSON
printf '' > /tmp/agh/body.rewrite_list|is not valid JSON
printf '[1,' > /tmp/agh/rewrites|is not valid JSON
printf '{"rewrites":[]}' > /tmp/agh/rewrites|has an unexpected form (expected a JSON list)
printf '"text"' > /tmp/agh/rewrites|has an unexpected form
printf '[] []' > /tmp/agh/rewrites|has an unexpected form
EOF
}

t_fetch_rewrite_settings() {
    agh_setup
    load_app
    local setup global note
    while IFS='|' read -r setup global note; do
        reset_agh; agh_setup; adguard_load_config
        eval "$setup"
        adguard_fetch_rewrites; assert_eq 0 $? "list read: $setup"
        assert_eq 12 "${#AG_RW_DOMAIN[@]}" "records kept: $setup"
        assert_eq "$global" "$AG_RW_GLOBAL" "global switch: $setup"
        if [[ -n "$note" ]]; then
            assert_contains "$AG_RW_GLOBAL_NOTE" "$note" "why unknown: $setup"
        else
            assert_eq "" "$AG_RW_GLOBAL_NOTE" "no note: $setup"
        fi
        assert_eq 3 "$(agh_requests | grep -c .)" "asked once: $setup"
    done <<'EOF'
:|true|
echo '{"enabled":false}' > /tmp/agh/rewrite-settings|false|
echo v0.107.67 > /tmp/agh/version|unknown|no global rewrite switch (added in v0.107.68)
echo '{"enabled":"no"}' > /tmp/agh/rewrite-settings|unknown|unexpected answer from /control/rewrite/settings
echo '{}' > /tmp/agh/rewrite-settings|unknown|unexpected answer
echo '[true]' > /tmp/agh/rewrite-settings|unknown|unexpected answer
echo '<html>' > /tmp/agh/rewrite-settings|unknown|unexpected answer
echo 500 > /tmp/agh/status.rewrite_settings|unknown|server error (HTTP 500)
EOF
}

t_fetch_rewrites_failures() {
    fixture_configured; load_app
    local setup expected requests
    while IFS='|' read -r setup expected requests; do
        reset_agh; agh_setup; adguard_load_config
        eval "$setup"
        adguard_fetch_rewrites; assert_eq 1 $? "fails: $setup"
        assert_contains "$AG_ERROR" "$expected" "reason for: $setup"
        assert_eq "$requests" "$(agh_requests | grep -c .)" "no retry, nothing more sent: $setup"
        assert_no_leak "$AG_ERROR" "$setup"
    done <<'EOF'
echo admin:other > /tmp/agh/auth|login failed: wrong username or password|1
echo 28 > /tmp/agh/curl-rc|timed out|1
echo 60 > /tmp/agh/curl-rc|is not trusted or does not match its name|1
echo 7 > /tmp/agh/curl-rc|could not connect|1
echo 500 > /tmp/agh/status.status|server error (HTTP 500)|1
printf '{"version":5}' > /tmp/agh/body.status|did not answer like AdGuard Home|1
echo 401 > /tmp/agh/status.rewrite_list|login failed|2
printf '502' > /tmp/agh/status.rewrite_list; printf 'bad gateway' > /tmp/agh/body.rewrite_list|server error (HTTP 502): bad gateway|2
echo 404 > /tmp/agh/status.rewrite_list|not found (HTTP 404)|2
EOF
}

t_match_domains() {
    fixture_configured; load_app
    AG_RW_DOMAIN=("*.lan.example.com" "app.lan.example.com" "APP.lan.example.com." "*" "a.*.example.com"
        "*.example.com" "lan.example.com" "*.")
    local domain expected
    while IFS='|' read -r domain expected; do
        adguard_match "$domain"
        assert_eq "$expected" "${AG_EXACT[*]}/${AG_WILD[*]}" "matches for $domain"
    done <<'EOF'
app.lan.example.com|1 2/0 5
APP.LAN.EXAMPLE.COM.|1 2/0 5
x.y.lan.example.com|/0 5
LAN.example.com|6/5
evil-lan.example.com|/5
example.com|/
a.b.example.com|/5
other.org|/
EOF
}

t_answer_conflicts() {
    fixture_configured; load_app
    AG_RW_ANSWER=(192.168.1.1 192.168.1.1 fd00::1 192.168.1.2 host.example.com AAAA A FD00::1)
    local idx expected
    while IFS='|' read -r idx expected; do
        assert_eq "$expected" "$(adguard_answers $idx)" "answers $idx"
    done <<'EOF'
0|single
0 1|duplicate
0 2|dual
2 7|duplicate
0 1 2|duplicate
0 3|conflict
0 4|conflict
4|single
0 5|dual
6 2|dual
0 6|conflict
0 3 2|conflict
EOF
}

# ==========================================================
# Rewrites (read-only): screens
# ==========================================================
# Sites for every case in agh_rewrites, straight into the database.
agh_sites() {
    local s
    for s in app:app.lan.example.com dual:dual.lan.example.com dup:dup.lan.example.com \
        clash:clash.lan.example.com off:off.lan.example.com wild:wild.lan.example.com \
        deep:a.b.deep.example.org apex:deep.example.org old:old.lan.example.com bad:bad_domain; do
        db_save "${s%%:*}" "${s#*:}" 127.0.0.1:8080 http false >/dev/null 2>&1
    done
}

# The lines shown under one site on the "Your sites' DNS" screen.
site_block() { # output domain
    printf '%s\n' "$1" | strip_ansi | awk -v d="  $2  (site " \
        'index($0, d) == 1 { on = 1; next } on && /^  [^ ]/ { exit } on'
}

t_sites_screen() {
    agh_setup; load_app; agh_sites
    local out b
    out=$(adguard_menu <<< $'s\n\nq\n' 2>&1)
    assert_contains "$out" "DNS (AdGuard Home) › Your sites' DNS" "screen opened"
    assert_contains "$out" "Contacting https://dns.lan.example.com..." "contact announced"
    assert_contains "$out" "https://dns.lan.example.com (AdGuard Home v0.107.79)" "server and version"
    assert_matches "$out" "Rewrites +12 in AdGuard Home" "count"
    assert_matches "$out" "Rewriting +● Enabled" "global switch on"

    b=$(site_block "$out" app.lan.example.com)
    assert_contains "$b" "✓ Exact rewrite" "app: exact"
    assert_contains "$b" "→ 192.168.1.10" "app: answer"
    assert_contains "$b" "Also covered by a wildcard rewrite (the exact rewrite takes precedence)" "app: wildcard noted"
    assert_contains "$b" "*.lan.example.com → 192.168.1.1" "app: which wildcard"

    b=$(site_block "$out" dual.lan.example.com)
    assert_contains "$b" "✓ Exact rewrites (IPv4 and IPv6)" "dual: not a conflict"
    assert_contains "$b" "→ 192.168.1.11" "dual: IPv4 (other case, final dot)"
    assert_contains "$b" "→ fd00::11" "dual: IPv6"

    b=$(site_block "$out" dup.lan.example.com)
    assert_contains "$b" "! 2 exact rewrites, some repeated (duplicates)" "dup: duplicates"
    assert_count "$b" "→ 192.168.1.12" 2 "dup: both listed"

    b=$(site_block "$out" clash.lan.example.com)
    assert_contains "$b" "! 2 exact rewrites with conflicting answers" "clash: conflict"
    assert_contains "$b" "→ 192.168.1.13" "clash: first answer"
    assert_contains "$b" "→ 192.168.1.99" "clash: second answer"

    b=$(site_block "$out" off.lan.example.com)
    assert_contains "$b" "○ Exact rewrite, disabled in AdGuard Home" "off: disabled exact"
    assert_contains "$b" "→ 192.168.1.14 ○ disabled" "off: answer marked disabled"
    assert_contains "$b" "Wildcard rewrites that may match instead:" "off: wildcard may apply"

    b=$(site_block "$out" wild.lan.example.com)
    assert_contains "$b" "? No exact rewrite - a wildcard rewrite may match" "wild: wildcard only"
    assert_contains "$b" "*.lan.example.com → 192.168.1.1" "wild: which wildcard"
    assert_not_contains "$b" "Exact rewrite" "wild: not shown as exact"

    b=$(site_block "$out" a.b.deep.example.org)
    assert_contains "$b" "a wildcard rewrite may match" "deep: wildcard at any depth"
    assert_contains "$b" "*.deep.example.org → 10.0.0.1 ○ disabled" "deep: disabled wildcard marked"

    b=$(site_block "$out" deep.example.org)
    assert_contains "$b" "— No rewrite found" "apex: *.deep.example.org does not cover deep.example.org"

    b=$(site_block "$out" old.lan.example.com)
    assert_contains "$b" "✓ Exact rewrite" "old: no enabled field still counts"
    assert_contains "$b" "→ 192.168.1.15 (enabled state not reported)" "old: state unknown, not disabled"
    assert_not_contains "$b" "disabled" "old: never called disabled"

    b=$(site_block "$out" bad_domain)
    assert_contains "$b" "✗ Not a valid domain name - not looked up" "invalid domain in the database"

    assert_not_contains "$out" "nas.home.arpa" "rewrites for other domains not listed here"
    assert_contains "$out" "Read only: nothing was changed in AdGuard Home or nginx." "read-only stated"
    assert_eq 3 "$(agh_requests | grep -c .)" "fetched once"
    assert_read_only "sites screen"
    assert_no_leak "$out" "sites screen"
}

t_sites_screen_global_switch() {
    agh_setup; load_app; agh_sites
    local out
    echo '{"enabled":false}' > /tmp/agh/rewrite-settings
    out=$(adguard_menu <<< $'s\n\nq\n' 2>&1)
    assert_matches "$out" "Rewriting +! Disabled" "global switch off"
    assert_contains "$out" "Rewrites are turned off in AdGuard Home: the records below are not applied now" "warned"
    assert_contains "$(site_block "$out" app.lan.example.com)" "✓ Exact rewrite" "records still listed"

    # An older AdGuard Home: no switch, no per-record state.
    echo v0.107.55 > /tmp/agh/version
    jq -c 'map(del(.enabled))' /tmp/agh/rewrites > /tmp/agh/r && mv /tmp/agh/r /tmp/agh/rewrites
    out=$(adguard_menu <<< $'s\n\nq\n' 2>&1)
    assert_matches "$out" "Rewriting +\? Unknown" "unknown, not on or off"
    assert_contains "$out" "cannot be determined: this AdGuard Home version has no global rewrite switch (added in v0.107.68)" "why"
    assert_not_contains "$out" "turned off" "unknown is not disabled"
    assert_not_contains "$out" "Exact rewrite, disabled" "no record called disabled"
    assert_contains "$(site_block "$out" off.lan.example.com)" "✓ Exact rewrite" "without a state the record counts"
    assert_contains "$(site_block "$out" app.lan.example.com)" "(enabled state not reported)" "state shown as unknown"
    assert_read_only "older server"
}

t_sites_screen_no_sites() {
    agh_setup; load_app
    local out
    out=$(adguard_menu <<< $'s\n\nq\n' 2>&1)
    assert_contains "$out" "No sites configured yet - no domain to look up." "explained"
    assert_eq "" "$(agh_requests)" "nothing sent"

    echo '{broken' > "$MANAGER_DIR/sites.json"
    out=$(adguard_menu <<< $'s\n\nq\n' 2>&1)
    assert_contains "$out" "cannot be read (invalid JSON)" "broken database reported"
    assert_eq "" "$(agh_requests)" "nothing sent"
}

t_all_rewrites_screen() {
    agh_setup; load_app; agh_sites
    local out
    out=$(adguard_menu <<< $'a\n\nq\n' 2>&1)
    assert_contains "$out" "DNS (AdGuard Home) › All rewrites" "screen opened"
    assert_matches "$out" "DOMAIN +ANSWER +STATE" "table header"
    assert_matches "$out" "nas\.home\.arpa +192\.168\.1\.50 +● ENABLED" "record for another domain listed"
    assert_matches "$out" "off\.lan\.example\.com +192\.168\.1\.14 +○ DISABLED" "disabled record"
    assert_matches "$out" "old\.lan\.example\.com +192\.168\.1\.15 +\? NOT REPORTED" "state not reported"
    assert_matches "$out" "\*\.lan\.example\.com +192\.168\.1\.1 +● ENABLED" "wildcard record"
    assert_count "$out" "dup.lan.example.com" 2 "duplicates both listed"
    assert_contains "$out" "this AdGuard Home version does not say whether a rewrite is enabled" "unknown explained"
    assert_contains "$out" "does not mean NGINX Manager created it" "no ownership implied"
    assert_not_contains "$out" "Delete" "no delete action"
    assert_not_contains "$out" "Edit" "no edit action"
    assert_read_only "all rewrites"
    assert_no_leak "$out" "all rewrites"

    printf '[]' > /tmp/agh/rewrites
    out=$(adguard_menu <<< $'a\n\nq\n' 2>&1)
    assert_contains "$out" "No rewrites in AdGuard Home" "empty list"
    assert_not_contains "$out" "NOT REPORTED" "no table"

    printf '[{"domain":"x.example.com","answer":"1.2.3.4","enabled":true}, 7]' > /tmp/agh/rewrites
    out=$(adguard_menu <<< $'a\n\nq\n' 2>&1)
    assert_contains "$out" "1 record(s) skipped: not a domain and answer as expected" "bad record reported"
    assert_contains "$out" "x.example.com" "good record shown"
}

t_views_errors() {
    fixture_configured; load_app
    local setup expected requests screen out
    for screen in s a; do
        while IFS='|' read -r setup expected requests; do
            reset_agh; agh_setup; agh_sites
            : > /var/log/nginx-manager/manager.log
            eval "$setup"
            out=$(adguard_menu <<< "$screen"$'\n\nq\n' 2>&1)
            assert_contains "$out" "AdGuard Home: " "$screen: error shown: $setup"
            assert_contains "$out" "$expected" "$screen: message for: $setup"
            assert_not_contains "$out" "Rewriting" "$screen: nothing listed: $setup"
            assert_contains "$(cat /var/log/nginx-manager/manager.log)" "AdGuard Home rewrites not read: " "$screen: logged: $setup"
            assert_no_leak "$out" "$screen: $setup"
            assert_read_only "$screen: $setup"
            assert_eq "$requests" "$(agh_requests | grep -c .)" "$screen: no retry: $setup"
        done <<'EOF'
echo admin:other > /tmp/agh/auth|login failed|1
echo 28 > /tmp/agh/curl-rc|timed out|1
echo 60 > /tmp/agh/curl-rc|update-ca-certificates|1
printf '503' > /tmp/agh/status.rewrite_list|server error (HTTP 503)|2
printf '{"a":1}' > /tmp/agh/rewrites|unexpected form|2
printf 'nope' > /tmp/agh/rewrites|not valid JSON|2
EOF
    done
}

t_views_not_configured() {
    fixture_configured; use_adguard; load_app; agh_sites
    local out
    out=$(adguard_menu <<< $'s\na\nn\nq\n' 2>&1)
    assert_not_contains "$out" "Your sites' DNS" "views not offered"
    assert_not_contains "$out" "Add rewrite" "add not offered"
    assert_count "$out" "Invalid option" 3 "their keys refused"
    printf 'URL=http://admin:hunter2@dns\n' > "$CONF"
    out=$(adguard_menu <<< $'s\nn\nq\n' 2>&1)
    assert_not_contains "$out" "All rewrites" "not offered with an invalid file"
    assert_not_contains "$out" "Add rewrite" "add not offered with an invalid file"
    assert_not_called "curl" "nothing sent"

    # Called directly anyway: refused before contacting anything.
    rm -f "$CONF"
    out=$(adguard_rewrites_screen 2>&1 </dev/null)
    assert_contains "$out" "not configured" "refused"
    out=$(adguard_add_screen 2>&1 </dev/null)
    assert_contains "$out" "not configured" "add refused"
    assert_not_called "curl" "nothing sent"
}

t_views_non_interactive() {
    agh_setup; load_app; agh_sites
    UI_NONINTERACTIVE=1
    local out rc
    out=$(adguard_sites_screen 2>&1 </dev/null); rc=$?
    assert_eq 0 "$rc" "sites view finishes without waiting"
    assert_contains "$out" "✓ Exact rewrite" "shown"
    out=$(adguard_rewrites_screen 2>&1 </dev/null); rc=$?
    assert_eq 0 "$rc" "all rewrites finishes without waiting"
    assert_contains "$out" "nas.home.arpa" "shown"
    assert_read_only "non-interactive"
}

t_gum_views() {
    agh_setup
    seed agh_sites
    # DNS, Your sites' DNS, All rewrites, Back (7th), Quit.
    use_gum "0 #8" "0 #1" "0 #2" "0 #7" "0 #10"
    local out rc calls
    out=$(printf '\n\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
    assert_eq 0 "$rc" "exits 0"
    calls=$(gum_calls)
    assert_contains "$calls" "Your sites' DNS" "sites view offered"
    assert_contains "$calls" "All rewrites" "all rewrites offered"
    assert_contains "$(site_block "$out" clash.lan.example.com)" "conflicting answers" "sites view shown"
    assert_matches "$out" "nas\.home\.arpa +192\.168\.1\.50" "all rewrites shown"
    assert_eq 6 "$(agh_requests | grep -c .)" "one fetch per view"
    assert_read_only "gum"
    assert_no_leak "$out" "gum"
}

t_gum_views_cancel() {
    agh_setup
    seed agh_sites
    # DNS, then Esc in its menu (back to the main menu); Quit.
    use_gum "0 #8" "1" "0 #10"
    local out rc
    out=$(printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
    assert_eq 0 "$rc" "exits 0"
    assert_contains "$out" "DNS (AdGuard Home)" "DNS screen opened"
    assert_eq "" "$(agh_requests)" "Esc sends nothing"
}

# ==========================================================
# Add rewrite
# ==========================================================
# The rewrites before any change, compact.
RW_BEFORE=""
agh_add_setup() {
    agh_setup; load_app; agh_sites
    RW_BEFORE=$(jq -c . /tmp/agh/rewrites)
}

posts() { agh_requests | grep -c '^POST'; }
add_bodies() { cat /tmp/agh/bodies.log 2>/dev/null; }
# The mock's rewrites, compact (as stored when not JSON).
rw_now() { jq -c . /tmp/agh/rewrites 2>/dev/null || cat /tmp/agh/rewrites; }

# Fails if anything was written to AdGuard Home.
assert_no_write() { # what
    assert_eq 0 "$(posts)" "$1: no POST"
    assert_eq "" "$(add_bodies)" "$1: no request body"
    assert_eq "$RW_BEFORE" "$(rw_now)" "$1: rewrites unchanged"
}

# Fails unless the original records are still there, unchanged and first.
assert_others_kept() { # what
    assert_eq "$RW_BEFORE" "$(jq -c ".[0:$(jq length <<< "$RW_BEFORE")]" /tmp/agh/rewrites)" \
        "$1: other records unchanged"
}

t_add_rewrite_ipv4() {
    agh_add_setup
    local out
    # Add rewrite, site apex (deep.example.org: no rewrite), Enter keeps the
    # default IP, confirm.
    out=$(adguard_menu <<< $'n\napex\n\ny\n\nq\n' 2>&1)
    assert_contains "$out" "DNS (AdGuard Home) › Add rewrite" "screen opened"
    assert_contains "$out" "IP address [192.168.1.10]: " "default IP offered"
    assert_matches "$out" "Domain +deep\.example\.org" "the site's domain"
    assert_matches "$out" "IP address +192\.168\.1\.10" "summary"
    assert_not_contains "$out" "For this rewrite only" "default kept: no note"
    assert_contains "$out" "Rewrite added: deep.example.org → 192.168.1.10" "added"
    assert_eq $'GET status auth=ok\nGET rewrite/list auth=ok\nGET rewrite/settings auth=ok\nGET rewrite/list auth=ok\nPOST rewrite/add auth=ok\nGET rewrite/list auth=ok' \
        "$(agh_requests)" "check, re-check, one POST, read back"
    assert_eq $'rewrite/add\tapplication/json\t{"domain":"deep.example.org","answer":"192.168.1.10"}' \
        "$(add_bodies)" "path, content type and JSON body"
    assert_called "-X POST" "POST method"
    assert_called "-H Content-Type: application/json" "content type header"
    assert_called "-K -" "login on stdin"
    assert_not_called " -L" "redirects not followed"
    assert_eq 13 "$(jq length /tmp/agh/rewrites)" "one record more"
    assert_eq '{"domain":"deep.example.org","answer":"192.168.1.10","enabled":true}' \
        "$(jq -c '.[-1]' /tmp/agh/rewrites)" "the new record"
    assert_others_kept "ipv4"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" \
        "AdGuard Home rewrite deep.example.org -> 192.168.1.10 added and confirmed" "logged"
    assert_no_leak "$out" "ipv4"
}

t_add_rewrite_ipv6_override() {
    agh_add_setup
    local out
    out=$(adguard_menu <<< $'n\napex\nFD00::20\ny\n\nq\n' 2>&1)
    assert_contains "$out" "For this rewrite only: the default IP stays 192.168.1.10." "override explained"
    assert_contains "$out" "Rewrite added: deep.example.org → FD00::20" "added"
    assert_contains "$(add_bodies)" '{"domain":"deep.example.org","answer":"FD00::20"}' "IPv6 sent as typed"
    adguard_load_config
    assert_eq "192.168.1.10" "$AG_ANSWER" "default IP not changed"
    assert_others_kept "ipv6"

    # The next run offers the default again; that answer now conflicts.
    : > /tmp/agh/requests.log; rm -f /tmp/agh/bodies.log
    RW_BEFORE=$(jq -c . /tmp/agh/rewrites)
    out=$(adguard_menu <<< $'n\napex\n\n\nq\n' 2>&1)
    assert_contains "$out" "IP address [192.168.1.10]: " "default offered again"
    assert_contains "$out" "deep.example.org already has a rewrite with another answer" "conflict"
    assert_no_write "conflict after override"

    # Another spelling of the same IPv6 address is the same answer.
    out=$(adguard_menu <<< $'n\napex\nfd00:0:0::20\n\nq\n' 2>&1)
    assert_contains "$out" "The rewrite already exists - nothing to add" "same address"
    assert_no_write "same address, other spelling"
}

t_add_rewrite_invalid_ip() {
    agh_add_setup
    local out
    # (<<< adds the final newline: input ends at the next prompt.)
    out=$(adguard_menu <<< $'n\napex\n1.2.3\nfd00::g\napp.example.com\n192.168.1.256' 2>&1)
    assert_count "$out" "Invalid IP address - enter an IPv4 or IPv6 address" 4 "each invalid answer refused"
    assert_contains "$out" "Input closed" "then input ended"
    assert_eq "" "$(agh_requests)" "nothing sent"

    # Without a default IP an empty answer is refused too.
    sed -i 's/^DEFAULT_ANSWER=.*/DEFAULT_ANSWER=/' "$CONF"
    out=$(adguard_menu <<< $'n\napex\n' 2>&1)
    assert_contains "$out" "IP address: " "no default offered"
    assert_contains "$out" "Invalid IP address" "empty refused"
    assert_eq "" "$(agh_requests)" "nothing sent"
}

t_add_rewrite_existing() {
    agh_add_setup
    local site ip expected out
    while IFS='|' read -r site ip expected; do
        : > /tmp/agh/requests.log
        out=$(adguard_menu <<< $'n\n'"$site"$'\n'"$ip"$'\n\nq\n' 2>&1)
        assert_contains "$out" "$expected" "$site $ip: explained"
        assert_contains "$out" "Nothing was sent: Add rewrite never changes existing records." "$site $ip: nothing sent"
        assert_not_contains "$out" "Add this rewrite?" "$site $ip: not offered"
        assert_eq 3 "$(agh_requests | grep -c .)" "$site $ip: only the check"
        assert_no_write "$site $ip"
    done <<'EOF'
app|192.168.1.10|The rewrite already exists - nothing to add
app|192.168.1.99|app.lan.example.com already has a rewrite with another answer - it was not changed
app|fd00::10|already has a rewrite with another answer
off|192.168.1.14|The rewrite already exists, but is disabled in AdGuard Home
off|192.168.1.20|already has a rewrite with another answer
old|192.168.1.15|The rewrite already exists - nothing to add
dup|192.168.1.12|dup.lan.example.com already has 2 exact rewrites - they need a manual review
dual|192.168.1.11|dual.lan.example.com already has 2 exact rewrites - they need a manual review
clash|192.168.1.50|clash.lan.example.com already has 2 exact rewrites
EOF

    out=$(adguard_menu <<< $'n\napp\n192.168.1.99\n\nq\n' 2>&1)
    assert_contains "$out" "app.lan.example.com → 192.168.1.10" "existing record shown"
    assert_contains "$out" "edit it in" "pointed to editing"
    out=$(adguard_menu <<< $'n\noff\n192.168.1.14\n\nq\n' 2>&1)
    assert_contains "$out" "off.lan.example.com → 192.168.1.14 ○ disabled" "disabled record shown"
    assert_contains "$out" "enable it in" "pointed to enabling"
    out=$(adguard_menu <<< $'n\ndual\n192.168.1.11\n\nq\n' 2>&1)
    assert_contains "$out" "DUAL.lan.example.com. → 192.168.1.11" "every record shown, as stored"
    assert_contains "$out" "dual.lan.example.com → fd00::11" "every record shown"
    assert_contains "$out" "necessarily created by NGINX Manager" "no ownership assumed"
}

t_add_rewrite_wildcard() {
    agh_add_setup
    local out
    out=$(adguard_menu <<< $'n\nwild\n\nn\n\nq\n' 2>&1)
    assert_contains "$out" "No exact rewrite for wild.lan.example.com, but a wildcard rewrite may already answer for it:" "explained"
    assert_contains "$out" "*.lan.example.com → 192.168.1.1" "which wildcard"
    assert_contains "$out" "Add an exact rewrite anyway? [y/N]" "asked, default no"
    assert_contains "$out" "Cancelled - nothing was changed" "declined"
    assert_not_contains "$out" "already exists" "a wildcard is not an exact record"
    assert_no_write "wildcard declined"

    # Enter at the wildcard question is no as well.
    out=$(adguard_menu <<< $'n\nwild\n\n\n\nq\n' 2>&1)
    assert_no_write "wildcard default"

    out=$(adguard_menu <<< $'n\nwild\n\ny\ny\n\nq\n' 2>&1)
    assert_contains "$out" "Rewrite added: wild.lan.example.com → 192.168.1.10" "added after both confirmations"
    assert_eq 1 "$(posts)" "one POST"
    assert_others_kept "wildcard"
}

t_add_rewrite_cancel() {
    agh_add_setup
    local out
    out=$(adguard_menu <<< $'n\n\n\nq\n' 2>&1)
    assert_contains "$out" "Cancelled - nothing was changed" "no site picked"
    assert_eq "" "$(agh_requests)" "nothing sent"

    # (<<< adds the final newline: input ends at the next prompt.)
    out=$(adguard_menu <<< $'n\napex' 2>&1)
    assert_contains "$out" "Input closed" "input ended at the IP"
    assert_eq "" "$(agh_requests)" "nothing sent"

    out=$(adguard_menu <<< $'n\napex\n\nn\n\nq\n' 2>&1)
    assert_contains "$out" "Add this rewrite? [Y/n]" "summary asked"
    assert_contains "$out" "Cancelled - nothing was changed" "summary declined"
    assert_no_write "summary declined"

    out=$(adguard_menu <<< $'n\napex\n' 2>&1)
    assert_contains "$out" "Add this rewrite? [Y/n]" "input ended at the summary"
    assert_no_write "input ended at the summary"

    UI_NONINTERACTIVE=1
    : > /tmp/agh/requests.log
    out=$(adguard_add_screen 2>&1 </dev/null)
    assert_contains "$out" "Non-interactive mode" "non-interactive: stops"
    assert_eq "" "$(agh_requests)" "non-interactive: nothing sent"
}

t_add_rewrite_no_sites() {
    agh_setup; load_app
    local out
    out=$(adguard_menu <<< $'n\n\nq\n' 2>&1)
    assert_contains "$out" "No sites configured yet - no domain to add a rewrite for." "explained"
    assert_eq "" "$(agh_requests)" "nothing sent"

    db_save bad bad_domain 127.0.0.1:8080 http false >/dev/null 2>&1
    out=$(adguard_menu <<< $'n\nbad\n\nq\n' 2>&1)
    assert_contains "$out" "Site bad has no valid domain name" "invalid domain refused"
    assert_eq "" "$(agh_requests)" "nothing sent"
}

t_add_rewrite_normalization() {
    agh_add_setup
    db_save mixed Mixed.Example.NET 127.0.0.1:8080 http false >/dev/null 2>&1
    local out
    out=$(adguard_menu <<< $'n\nmixed\nFD00:0:0::30\ny\n\nq\n' 2>&1)
    assert_contains "$out" "AdGuard Home stores the domain in lowercase: mixed.example.net" "explained"
    assert_contains "$(add_bodies)" '{"domain":"Mixed.Example.NET","answer":"FD00:0:0::30"}' "the site's domain as configured"
    assert_contains "$(jq -c '.[-1]' /tmp/agh/rewrites)" '"domain":"mixed.example.net"' "stored lowercase"
    assert_contains "$out" "Rewrite added: Mixed.Example.NET → FD00:0:0::30" "confirmed despite the lowercasing"

    # Existing records match whatever the letter case.
    db_save upper APP.Lan.Example.com 127.0.0.1:8080 http false >/dev/null 2>&1
    rm -f /tmp/agh/bodies.log; : > /tmp/agh/requests.log
    RW_BEFORE=$(jq -c . /tmp/agh/rewrites)
    out=$(adguard_menu <<< $'n\nupper\n192.168.1.10\n\nq\n' 2>&1)
    assert_contains "$out" "The rewrite already exists" "case-insensitive match"
    assert_no_write "other letter case"
}

t_add_ip_key() {
    fixture_configured; load_app
    local a b expected
    while IFS='|' read -r a b expected; do
        adguard_same_answer "$a" "$b"; assert_eq "$expected" $? "same answer: $a / $b"
    done <<'EOF'
192.168.1.10|192.168.1.10|0
192.168.1.10|192.168.1.1|1
fd00::1|FD00:0000::0001|0
fd00::1|fd00:0:0:0:0:0:0:1|0
::|0:0:0:0:0:0:0:0|0
::ffff:192.168.1.10|::ffff:c0a8:10a|0
fd00::1|fd00::10|1
1::|1:0:0:0:0:0:0:0|0
::1|1::|1
192.168.1.10|::ffff:192.168.1.10|1
host.example.com|HOST.example.com|0
EOF
    assert_eq "fd00:0000:0000:0000:0000:0000:0000:0001" "$(adguard_ip_key FD00::1)" "full form"
}

# adguard_create_rewrite directly: what reaches AdGuard Home and the
# result, with the list from agh_rewrites.
t_add_create_results() {
    fixture_configured; load_app
    local setup rc expected out
    while IFS='|' read -r setup rc expected; do
        reset_agh; agh_setup; adguard_load_config
        RW_BEFORE=$(jq -c . /tmp/agh/rewrites)
        : > /var/log/nginx-manager/manager.log
        eval "$setup"
        out=$(adguard_create_rewrite deep.example.org 192.168.1.10 2>&1)
        assert_eq "$rc" $? "status: $setup"
        assert_contains "$out" "$expected" "message: $setup"
        assert_eq 1 "$(posts)" "sent once, never retried: $setup"
        assert_others_kept "$setup"
        assert_no_leak "$out" "$setup"
        case "$rc" in
            1)
                assert_contains "$out" "The rewrite was not added" "not claimed: $setup"
                assert_eq "$RW_BEFORE" "$(jq -c . /tmp/agh/rewrites)" "nothing stored: $setup"
                assert_eq 2 "$(agh_requests | grep -c .)" "nothing read after: $setup"
                ;;
            3)
                assert_not_contains "$out" "Rewrite added" "not claimed: $setup"
                assert_contains "$out" "AdGuard Home does not refuse duplicates" "warned: $setup"
                assert_contains "$(cat /var/log/nginx-manager/manager.log)" "deep.example.org -> 192.168.1.10" "logged: $setup"
                ;;
        esac
    done <<'EOF'
:|0|Rewrite added: deep.example.org → 192.168.1.10
printf '[]' > /tmp/agh/add-store|3|AdGuard Home accepted the rewrite, but deep.example.org → 192.168.1.10 is not in its list
printf '[{"domain":"deep.example.org","answer":"192.168.1.77","enabled":true}]' > /tmp/agh/add-store|3|is not in its list
printf '[{"domain":"other.example.org","answer":"192.168.1.10","enabled":true}]' > /tmp/agh/add-store|3|is not in its list
printf '[{"domain":"deep.example.org","answer":"192.168.1.10","enabled":false}]' > /tmp/agh/add-store|3|is not in its list
printf '[{"domain":"deep.example.org.","answer":"192.168.1.10","enabled":true}]' > /tmp/agh/add-store|3|is not in its list
mkdir -p /tmp/agh/after-add; echo 500 > /tmp/agh/after-add/status.rewrite_list|3|accepted the rewrite, but it could not be confirmed: AdGuard Home server error (HTTP 500)
mkdir -p /tmp/agh/after-add; printf 'nope' > /tmp/agh/after-add/body.rewrite_list|3|could not be confirmed: the rewrite list from https://dns.lan.example.com is not valid JSON
mkdir -p /tmp/agh/after-add; echo 28 > /tmp/agh/after-add/curl-rc.rewrite_list|3|could not be confirmed: no answer from https://dns.lan.example.com within 15s (timed out)
echo 401 > /tmp/agh/status.rewrite_add|1|login failed
printf '400' > /tmp/agh/status.rewrite_add; printf 'json.Decode: unexpected EOF' > /tmp/agh/body.rewrite_add|1|AdGuard Home rejected the request: json.Decode: unexpected EOF
echo 404 > /tmp/agh/status.rewrite_add|1|this AdGuard Home version does not support the request
echo 405 > /tmp/agh/status.rewrite_add|1|not found (HTTP 405)
echo 403 > /tmp/agh/status.rewrite_add|1|access denied
echo 302 > /tmp/agh/status.rewrite_add|1|redirected (HTTP 302)
echo 7 > /tmp/agh/curl-rc.rewrite_add|1|could not connect
echo 60 > /tmp/agh/curl-rc.rewrite_add|1|is not trusted or does not match its name
echo 35 > /tmp/agh/curl-rc.rewrite_add|1|TLS connection to https://dns.lan.example.com failed
printf '500' > /tmp/agh/status.rewrite_add; printf 'cannot write config' > /tmp/agh/body.rewrite_add|3|server error (HTTP 500): cannot write config
echo 28 > /tmp/agh/curl-rc.rewrite_add|3|timed out
echo 52 > /tmp/agh/curl-rc.rewrite_add|3|broke off without an answer
EOF

    # A 200 with an unexpected body is not success on its own: the record
    # must be in the list.
    reset_agh; agh_setup; adguard_load_config
    printf '{"error":"x"}' > /tmp/agh/body.rewrite_add
    out=$(adguard_create_rewrite deep.example.org 192.168.1.10 2>&1)
    assert_eq 3 $? "200 without the record: not confirmed"
    assert_contains "$out" "is not in its list" "explained"
}

t_add_create_refusals() {
    fixture_configured; load_app
    local out
    # An exact rewrite there by the time of sending: nothing sent.
    agh_setup; adguard_load_config
    out=$(adguard_create_rewrite APP.lan.example.com 192.168.1.10 2>&1)
    assert_eq 2 $? "exact rewrite: refused"
    assert_contains "$out" "An exact rewrite for APP.lan.example.com exists by now - nothing was sent" "explained"
    assert_eq 0 "$(posts)" "no POST"

    # The re-check itself fails: nothing sent, no retry.
    local setup
    for setup in "echo admin:other > /tmp/agh/auth" "echo 28 > /tmp/agh/curl-rc" "printf '{}' > /tmp/agh/rewrites"; do
        reset_agh; agh_setup; adguard_load_config
        eval "$setup"
        out=$(adguard_create_rewrite deep.example.org 192.168.1.10 2>&1)
        assert_eq 1 $? "re-check failed: $setup"
        assert_contains "$out" "Nothing was sent: the rewrites could not be checked" "explained: $setup"
        assert_eq 1 "$(agh_requests | grep -c .)" "one request only: $setup"
        assert_no_leak "$out" "$setup"
    done
}

# The screen with failures at the check or the POST.
t_add_screen_errors() {
    agh_add_setup
    local setup expected requests out
    while IFS='|' read -r setup expected requests; do
        reset_agh; agh_setup
        eval "$setup"
        RW_BEFORE=$(rw_now)
        out=$(adguard_menu <<< $'n\napex\n\ny\n\nq\n' 2>&1)
        assert_contains "$out" "$expected" "message: $setup"
        assert_not_contains "$out" "Rewrite added" "not claimed: $setup"
        assert_eq "$requests" "$(agh_requests | grep -c .)" "a failed check is not retried: $setup"
        assert_no_write "$setup"
        assert_no_leak "$out" "$setup"
    done <<'EOF'
echo admin:other > /tmp/agh/auth|login failed|1
echo 28 > /tmp/agh/curl-rc|timed out|1
echo 60 > /tmp/agh/curl-rc|update-ca-certificates|1
printf '503' > /tmp/agh/status.rewrite_list|server error (HTTP 503)|2
printf 'nope' > /tmp/agh/rewrites|not valid JSON|2
EOF

    reset_agh; agh_setup
    echo 401 > /tmp/agh/status.rewrite_add
    out=$(adguard_menu <<< $'n\napex\n\ny\n\nq\n' 2>&1)
    assert_contains "$out" "The rewrite was not added" "POST failure reported"
    assert_not_contains "$out" "Rewrite added" "not claimed"
    assert_eq 5 "$(agh_requests | grep -c .)" "nothing after the failed POST"
    assert_no_leak "$out" "POST 401"

    # Rewrites turned off: said in the summary.
    reset_agh; agh_setup
    echo '{"enabled":false}' > /tmp/agh/rewrite-settings
    out=$(adguard_menu <<< $'n\napex\n\ny\n\nq\n' 2>&1)
    assert_contains "$out" "this one applies once they are turned on" "global switch noted"
    assert_contains "$out" "Rewrite added" "still added"
}

t_add_rewrite_old_version() {
    agh_add_setup
    echo v0.107.55 > /tmp/agh/version
    jq -c 'map(del(.enabled))' /tmp/agh/rewrites > /tmp/agh/r && mv /tmp/agh/r /tmp/agh/rewrites
    local out
    out=$(adguard_menu <<< $'n\napex\n\ny\n\nq\n' 2>&1)
    assert_contains "$out" "Rewrite added: deep.example.org → 192.168.1.10" "confirmed without an enabled field"
}

t_gum_add_rewrite() {
    agh_setup
    seed agh_sites
    # DNS, Add rewrite (3rd), site (1st: apex), IP typed, Add this rewrite?
    # yes; Back (7th), Quit.
    use_gum "0 #8" "0 #3" "0 #1" "0 fd00::30" "0" "0 #7" "0 #10"
    local out rc calls
    out=$(printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
    assert_eq 0 "$rc" "exits 0"
    calls=$(gum_calls)
    assert_contains "$calls" "Add rewrite" "offered"
    assert_matches "$calls" "gum filter \| --header=Site .*apex +deep\.example\.org" "site picked from the site list"
    assert_contains "$calls" "gum input | --header=IP address | --prompt=>  | --placeholder=IPv4 or IPv6 address deep.example.org should resolve to | --value=192.168.1.10" \
        "default IP prefilled"
    assert_contains "$calls" "gum confirm | --default=true | -- | Add this rewrite?" "summary confirmed"
    assert_contains "$out" "Rewrite added: deep.example.org → fd00::30" "added"
    assert_contains "$(add_bodies)" '{"domain":"deep.example.org","answer":"fd00::30"}' "body"
    assert_eq 1 "$(posts)" "one POST"
    assert_no_leak "$out" "gum add"
}

t_gum_add_rewrite_cancel() {
    agh_setup
    seed agh_sites
    local out rc answers
    RW_BEFORE=$(jq -c . /tmp/agh/rewrites)
    # Esc at: the site list, the IP, the summary, the wildcard question
    # (site wild, the 10th; last, so its gum calls are kept).
    for answers in '"1"' '"0 #1" "1"' '"0 #1" "0 " "1"' '"0 #10" "0 " "1"'; do
        rm -f /tmp/agh/requests.log /tmp/agh/bodies.log
        eval "use_gum \"0 #8\" \"0 #3\" $answers \"0 #7\" \"0 #10\""
        out=$(printf '\n' | NM_UI=gum timeout 20 bash "$APP" 2>&1); rc=$?
        assert_eq 0 "$rc" "exits 0: $answers"
        assert_contains "$out" "Cancelled - nothing was changed" "cancelled: $answers"
        assert_not_contains "$out" "gum failed" "gum not abandoned: $answers"
        assert_no_write "gum Esc $answers"
    done
    assert_contains "$(gum_calls)" "gum confirm | --default=false | -- | Add an exact rewrite anyway?" "wildcard asked, default no"
}

t_plain_add_rewrite() {
    agh_setup
    seed agh_sites
    use_gum
    local out
    # gum installed, but --plain: the basic interface.
    out=$(printf '8\nn\napex\n\ny\n\nq\nq\n' | NM_UI=gum timeout 20 bash "$APP" --plain 2>&1)
    assert_contains "$out" "[N] Add rewrite" "listed with its key"
    assert_contains "$out" "Rewrite added: deep.example.org → 192.168.1.10" "added"
    assert_not_contains "$(gum_calls)" "gum choose" "gum not used"
    assert_eq 1 "$(posts)" "one POST"
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
