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

t_snippets_overwritten_on_start() {
    known_defect "D4: snippets overwritten on every start, no backup"
    fixture_configured
    mkdir -p /etc/nginx/snippets
    echo "# local customisation" > /etc/nginx/snippets/proxy-common.conf
    run_app 'q\n' >/dev/null
    assert_not_contains "$(cat /etc/nginx/snippets/proxy-common.conf)" "local customisation" \
        "customised snippet replaced"
    assert_eq "" "$(ls "$MANAGER_DIR/backups")" "no backup of the replaced snippet"
}

t_config_is_executed_when_loaded() {
    known_defect "D8: config.conf is sourced; email validation lets shell syntax through"
    local out
    out=$(run_app 'lan.example.com\nx$(touch /tmp/pwned)@example.com\nxq\n')
    assert_contains "$out" "Initial setup completed" "email with \$(...) accepted"
    assert_file /tmp/pwned "command substitution in config ran on load"
}
