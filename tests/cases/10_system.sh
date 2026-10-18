#!/bin/bash
# System check, dashboard, backups, logs, root re-exec.

t_system_check_healthy() {
    fixture_configured; load_app
    local out
    out=$(system_check <<< $'\n' 2>&1)
    assert_contains "$out" "jq        ✓" "jq"
    assert_contains "$out" "nginx     ✓" "nginx"
    assert_contains "$out" "certbot   ✓" "certbot"
    assert_contains "$out" "openssl   ✓" "openssl"
    assert_contains "$out" "Service     ✓ Running" "service"
    assert_contains "$out" "Config      ✓ Valid" "nginx config"
    assert_contains "$out" "Certificate ✓ Present" "certificate"
    assert_contains "$out" "Expiration  ✓ " "expiration"
    assert_contains "$out" "Database    ✓" "database"
    assert_contains "$out" "Permissions ✓" "permissions"
}

t_system_check_problems() {
    fixture_configured; load_app
    remove_mock certbot
    mock_rc systemctl-is-active 3
    chmod 644 "$MANAGER_DIR/sites.json"
    echo 'server { broken; }' > "$SITES_ENABLED/broken.conf"
    local out
    out=$(system_check <<< $'\n' 2>&1)
    assert_contains "$out" "certbot   ○ optional" "certbot optional"
    assert_contains "$out" "Service     ✗ Not running" "service down"
    assert_contains "$out" "Config      ✗ Invalid" "nginx config invalid"
    assert_contains "$out" "Permissions ! 644" "loose permissions"
    echo '{bad' > "$MANAGER_DIR/sites.json"
    out=$(system_check <<< $'\n' 2>&1)
    assert_contains "$out" "Database    ✗ Broken" "broken database"
}

t_dashboard_counts() {
    fixture_configured; fixture_sites_v3
    local out
    out=$(run_app 'q\n')
    assert_contains "$out" "Sites          1 enabled / 2 total" "counts from v3 fixture"
}

t_dashboard_counts_db_flag() {
    known_defect "D6: dashboard counts the db flag, not the live symlink"
    fixture_configured
    seed "new_site app http; enable_site app; db_update_enabled app false"
    assert_contains "$(run_app 'q\n')" "Sites          0 enabled / 1 total" "live site counted as disabled"
}

t_show_backups() {
    fixture_configured; load_app
    assert_contains "$(show_backups <<< $'\n' 2>&1)" "No backups yet" "empty"
    new_site app http; generate_site app >/dev/null 2>&1
    assert_matches "$(show_backups <<< $'\n' 2>&1)" "^$MANAGER_DIR/backups/app\.conf_[0-9]+\.bak$" "backup listed"
}

t_show_logs() {
    fixture_configured; load_app
    assert_contains "$(show_logs <<< $'\n' 2>&1)" "No logs yet" "no log file"
    log "hello from test"
    assert_matches "$(show_logs <<< $'\n' 2>&1)" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} hello from test$' "log line format"
}

t_main_menu_navigation() {
    fixture_configured
    local out
    out=$(run_app '2\nq\n3\n\n4\n\n5\n\nq\n')
    assert_contains "$out" "TLS MANAGER" "2 -> TLS"
    assert_contains "$out" "SYSTEM CHECK" "3 -> system check"
    assert_contains "$out" "BACKUPS" "4 -> backups"
    assert_contains "$out" "LOGS" "5 -> logs"
}

t_non_root_reexecs_with_sudo() {
    fixture_configured
    local out rc
    out=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$APP" </dev/null 2>&1); rc=$?
    assert_contains "$out" "Run as root" "message"
    assert_contains "$out" "sudo" "tries sudo (absent in the test image)"
    assert_eq 127 "$rc" "exec sudo fails with 127 when sudo is missing"
}
