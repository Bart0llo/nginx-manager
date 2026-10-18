#!/bin/bash
# Start-up: first-run setup, dependency check, lock, init side effects.

t_first_run_creates_config() {
    local out rc
    out=$(run_app 'lan.example.com\nadmin@example.com\nxq\n'); rc=$?
    assert_eq 0 "$rc" "app exits 0 after quitting"
    assert_contains "$out" "Initial setup completed" "first-run setup completes"
    assert_eq "DOMAIN=lan.example.com
CERT_NAME=lan.example.com
CERTBOT_EMAIL=admin@example.com
DEFAULT_TLS=https
SETUP_DONE=true" "$(cat "$MANAGER_DIR/config.conf")" "config.conf content"
    assert_eq "{}" "$(cat "$MANAGER_DIR/sites.json")" "empty sites.json created"
    assert_mode "$MANAGER_DIR/sites.json" 600
    assert_file /etc/nginx/snippets/proxy-common.conf
    assert_file /etc/nginx/snippets/tls-common.conf
    if [[ -d /var/log/nginx-manager && -d "$MANAGER_DIR/backups" ]]; then
        pass "log and backup directories created"
    else
        fail "log and backup directories created"
    fi
}

t_first_run_revalidates_input() {
    local out
    out=$(run_app 'not a domain\nlan.example.com\nnope\nadmin@example.com\nxq\n')
    assert_contains "$out" "Invalid domain" "invalid domain re-prompts"
    assert_contains "$out" "Invalid email" "invalid email re-prompts"
    assert_contains "$(cat "$MANAGER_DIR/config.conf")" "SETUP_DONE=true" "setup still completes"
}

t_configured_start_shows_dashboard() {
    fixture_configured
    local out rc
    out=$(run_app 'q\n'); rc=$?
    assert_eq 0 "$rc" "app exits 0"
    assert_not_contains "$out" "FIRST RUN SETUP" "setup skipped when SETUP_DONE=true"
    assert_contains "$out" "Nginx          ✓ Running" "dashboard: nginx running"
    assert_contains "$out" "Configuration  ✓ Valid" "dashboard: config valid"
    assert_contains "$out" "Sites          0 enabled / 0 total" "dashboard: site count"
    assert_contains "$out" "Certificate    ✓ Valid (" "dashboard: certificate valid"
}

t_lock_prevents_second_instance() {
    fixture_configured
    mkdir -p /run/lock
    exec 9>/run/lock/nginx-manager.lock
    flock -n 9
    local out rc
    out=$(run_app 'q\n'); rc=$?
    assert_eq 1 "$rc" "second instance exits 1"
    assert_contains "$out" "Manager already running" "lock message"
}

t_missing_jq_exits() {
    fixture_configured
    mv /usr/bin/jq /usr/bin/jq.off
    local out rc
    out=$(run_app 'q\n'); rc=$?
    mv /usr/bin/jq.off /usr/bin/jq
    assert_eq 1 "$rc" "exits 1 without jq"
    assert_contains "$out" "Missing required dependency: jq" "names the missing dependency"
    assert_contains "$out" "apt update && apt install -y jq nginx" "suggests the install command"
}

t_starts_without_certbot() {
    fixture_configured
    remove_mock certbot
    local out rc
    out=$(run_app 'q\n'); rc=$?
    assert_eq 0 "$rc" "starts without certbot (HTTP-only use stays possible)"
}

t_source_with_no_main_has_no_side_effects() {
    local out
    out=$(NM_NO_MAIN=1 bash -c 'source "$1" && declare -F main_menu first_run_setup >/dev/null && echo loaded' \
        _ "$APP" </dev/null 2>&1)
    assert_eq loaded "$out" "functions defined, nothing printed"
    assert_no_file "$MANAGER_DIR" "no manager directory created"
    assert_no_file /var/log/nginx-manager "no log directory created"
    assert_no_file /run/lock/nginx-manager.lock "no lock file"
    assert_no_file /etc/nginx/snippets/proxy-common.conf "no snippets written"
    assert_eq "" "$(cat "$MOCK_LOG")" "no external commands run"
}

t_runs_through_symlink() {
    fixture_configured
    ln -s "$APP" /usr/local/bin/nginx-manager
    local out rc
    out=$(printf 'q\n' | timeout 20 /usr/local/bin/nginx-manager 2>&1); rc=$?
    assert_eq 0 "$rc" "starts via symlink and quits"
    assert_contains "$out" "NGINX MANAGER PRO" "shows the dashboard"
}

t_missing_modules_reported() {
    if ! grep -q 'NM_LIB_DIR' "$APP"; then
        pass "single-file bundle has no module directory"
        return
    fi
    cp "$APP" /tmp/nm-lonely.sh
    local out rc
    out=$(bash /tmp/nm-lonely.sh </dev/null 2>&1); rc=$?
    rm -f /tmp/nm-lonely.sh
    assert_eq 1 "$rc" "exits 1 without lib/"
    assert_contains "$out" "modules not found in /tmp/lib" "names the missing directory"
}

SNIP=/etc/nginx/snippets/proxy-common.conf

# D4: a snippet that already has the managed content is not rewritten.
t_snippets_unchanged_not_rewritten() {
    fixture_configured; load_app
    touch -d '2020-01-01 00:00:00' "$SNIP"
    local before
    before=$(stat -c '%i %Y' "$SNIP")
    run_app 'q\n' >/dev/null
    assert_eq "$before" "$(stat -c '%i %Y' "$SNIP")" "same inode and mtime after start"
    assert_eq "" "$(ls "$MANAGER_DIR/backups")" "no backup for an unchanged snippet"
}

# D4: a customised snippet is backed up, then atomically replaced keeping its
# mode, and the replacement is reported and logged.
t_custom_snippet_backed_up_before_replace() {
    fixture_configured
    mkdir -p /etc/nginx/snippets
    echo "# local customisation" > "$SNIP"; chmod 640 "$SNIP"
    local out
    out=$(run_app 'q\n')
    golden_compare proxy-common.conf "$SNIP"
    assert_mode "$SNIP" 640 "mode kept"
    assert_eq "# local customisation" "$(cat "$MANAGER_DIR"/backups/proxy-common.conf_*.bak)" "custom content backed up"
    assert_contains "$out" "differed from the managed version and was replaced (backup: $MANAGER_DIR/backups/proxy-common.conf_" "replacement reported"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Snippet replaced: $SNIP (backup: " "replacement logged"
    assert_eq "" "$(ls -A /etc/nginx/snippets | grep '^\.')" "no temp files left"
}

# Customised snippet + loaded app, for the failure-path tests below.
custom_snippet() {
    fixture_configured; load_app
    echo "# local customisation" > "$SNIP"
}

t_snippet_backup_failure_keeps_custom() {
    custom_snippet
    rm -rf "$MANAGER_DIR/backups"; touch "$MANAGER_DIR/backups"
    local out rc
    out=$(create_snippets 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_eq "# local customisation" "$(cat "$SNIP")" "custom snippet kept"
    assert_contains "$out" "could not be backed up; left unchanged" "reason shown"
    golden_compare tls-common.conf /etc/nginx/snippets/tls-common.conf
}

t_snippet_temp_file_failure_keeps_custom() {
    custom_snippet
    mktemp() { return 1; }
    local out rc
    out=$(create_snippets 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_eq "# local customisation" "$(cat "$SNIP")" "custom snippet kept"
    assert_contains "$out" "Failed to write snippet $SNIP" "reason shown"
}

t_snippet_replace_failure_keeps_custom() {
    custom_snippet
    mv() { return 1; }
    local out rc
    out=$(create_snippets 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_eq "# local customisation" "$(cat "$SNIP")" "custom snippet kept"
    assert_contains "$out" "Failed to replace snippet $SNIP" "reason shown"
    assert_eq "" "$(ls -A /etc/nginx/snippets | grep '^\.')" "temp file removed"
}

t_snippet_symlink_left_alone() {
    custom_snippet
    rm -f "$SNIP"; echo "# shared" > /etc/victim.conf; ln -s /etc/victim.conf "$SNIP"
    local out
    out=$(create_snippets 2>&1 </dev/null)
    assert_symlink "$SNIP" "symlink kept"
    assert_eq "# shared" "$(cat /etc/victim.conf)" "link target untouched"
    assert_contains "$out" "is not a regular file; left unchanged" "reason shown"
}

# D8: first-run setup refuses an email containing shell syntax, so it never
# reaches config.conf, and loading the config never runs anything.
t_first_run_rejects_shell_in_email() {
    local out
    out=$(run_app 'lan.example.com\nx$(touch /tmp/pwned)@example.com\nadmin@example.com\nxq\n')
    assert_contains "$out" "Invalid email" "email with \$(...) rejected"
    assert_contains "$out" "Initial setup completed" "setup completes with a valid email"
    assert_contains "$(cat "$MANAGER_DIR/config.conf")" "CERTBOT_EMAIL=admin@example.com" "valid email stored"
    run_app '2\nq\nq\n' >/dev/null
    assert_no_file /tmp/pwned "nothing executed"
}

# D8: config.conf is read as data. Each crafted line makes loading fail
# safely, and none of them runs a command.
t_config_is_not_executed() {
    fixture_configured; load_app
    local line out rc i=0
    for line in 'DOMAIN=$(touch /tmp/pwned1)' 'DOMAIN=`touch /tmp/pwned2`' \
            'CERTBOT_EMAIL=x$(touch /tmp/pwned3)@example.com' 'touch /tmp/pwned4' \
            'DOMAIN=lan.example.com; touch /tmp/pwned5' 'CERT_NAME="$(touch /tmp/pwned6)"' \
            'PATH=/tmp/pwned7' 'DOMAIN=lan.example.com && touch /tmp/pwned8'; do
        ((i++))
        fixture_configured; echo "$line" >> "$MANAGER_DIR/config.conf"
        out=$(load_config 2>&1); rc=$?
        assert_eq 1 "$rc" "rejected: $line"
        assert_contains "$out" "Invalid config $MANAGER_DIR/config.conf line 6" "line reported: $line"
    done
    fixture_configured; echo 'CERTBOT_EMAIL=x$(touch /tmp/pwned9)@example.com' >> "$MANAGER_DIR/config.conf"
    run_app 'q\n' >/dev/null
    out=$(run_app '2\n2\n\nq\nq\n')
    assert_eq "" "$(ls /tmp | grep '^pwned')" "no command ran (load_config, dashboard, TLS manager)"
    assert_not_called "certbot certonly" "certbot not run with a rejected config"
}

t_config_parser_reads_supported_format() {
    fixture_configured; load_app
    printf '%s\n' '# NGINX Manager config' '' '  # indented comment' \
        'DOMAIN="lan.example.com"' "CERT_NAME='lan.example.com'" \
        'CERTBOT_EMAIL=admin@example.com' '  DEFAULT_TLS=both  ' 'SETUP_DONE=true' \
        > "$MANAGER_DIR/config.conf"
    load_config; assert_eq 0 $? "loads"
    assert_eq "lan.example.com|lan.example.com|admin@example.com|both|true" \
        "$DOMAIN|$CERT_NAME|$CERTBOT_EMAIL|$DEFAULT_TLS|$SETUP_DONE" "values (quotes removed)"

    printf 'DOMAIN=other.example.com\r\nCERT_NAME=\r\n' > "$MANAGER_DIR/config.conf"
    load_config; assert_eq 0 $? "CRLF file loads"
    assert_eq "other.example.com||" "$DOMAIN|$CERT_NAME|$CERTBOT_EMAIL" "CR stripped, missing keys empty, nothing stale"

    fixture_configured
    printf 'DOMAIN=lan.example.com\nSETUP_DONE=true' > "$MANAGER_DIR/config.conf"
    load_config; assert_eq 0 $? "no final newline"
    assert_eq true "$SETUP_DONE" "last line read"
}

t_config_parser_rejects_bad_entries() {
    fixture_configured; load_app
    local line out rc
    for line in 'FOO=bar|unknown setting FOO' 'DOMAIN = x|expected KEY=VALUE' \
            'export DOMAIN=lan.example.com|expected KEY=VALUE' 'DEFAULT_TLS=ftp|invalid DEFAULT_TLS' \
            'CERT_NAME=../../etc|invalid CERT_NAME' 'SETUP_DONE=yes|invalid SETUP_DONE' \
            'DOMAIN="lan.example.com|invalid DOMAIN' 'CERTBOT_EMAIL=nope|invalid CERTBOT_EMAIL'; do
        printf 'DOMAIN=lan.example.com\nCERT_NAME=lan.example.com\n%s\n' "${line%%|*}" > "$MANAGER_DIR/config.conf"
        out=$(load_config 2>&1); rc=$?
        assert_eq 1 "$rc" "rejected: ${line%%|*}"
        assert_contains "$out" "line 3: ${line#*|}" "reason: ${line%%|*}"
    done
    printf 'DOMAIN=lan.example.com\nCERT_NAME=lan.example.com\nFOO=bar\n' > "$MANAGER_DIR/config.conf"
    load_config >/dev/null 2>&1
    assert_eq "|" "$DOMAIN|$CERT_NAME" "nothing kept from a rejected config"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Config rejected: $MANAGER_DIR/config.conf line 3: unknown setting FOO" "rejection logged"
}

t_validate_email() {
    fixture_configured; load_app
    local v
    for v in admin@example.com first.last+tag@sub.example.org a_b-c@x.io; do
        validate_email "$v"; assert_eq 0 $? "valid email: $v"
    done
    for v in "" nope a@b @example.com 'x$(id)@example.com' 'x`id`@example.com' 'a b@example.com' \
            'a@example.com;id' 'a@example' "a@example.com
b"; do
        validate_email "$v"; assert_eq 1 $? "invalid email: '$v'"
    done
}
