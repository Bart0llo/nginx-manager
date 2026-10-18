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
