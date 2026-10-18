#!/bin/bash
# Status (system check), dashboard, backups, logs, root re-exec.

t_system_check_healthy() {
    fixture_configured; load_app
    PLUGIN_DIR=/src/plugins   # the checkout's, also when testing the bundle
    local out
    out=$(system_check <<< $'\n' 2>&1)
    assert_matches "$out" '^  jq +✓ Installed$' "jq"
    assert_matches "$out" '^  nginx +✓ Installed$' "nginx"
    assert_matches "$out" '^  certbot +✓ Installed$' "certbot"
    assert_matches "$out" '^  openssl +✓ Installed$' "openssl"
    assert_matches "$out" '^  gum +○ Not installed \(enhanced interface\)$' "gum optional"
    assert_matches "$out" '^  Service +✓ Running$' "service"
    assert_matches "$out" '^  Configuration +✓ Valid$' "nginx config"
    assert_matches "$out" '^  Certificate +✓ Valid \([0-9]+ days left\)$' "certificate"
    assert_matches "$out" '^  Expires +[0-9]{4}-[0-9]{2}-[0-9]{2}$' "expiration"
    assert_matches "$out" '^  Config file +✓ Valid$' "manager config"
    assert_matches "$out" '^  Database +✓ Valid$' "database"
    assert_matches "$out" '^  Permissions +✓ 600$' "permissions"
    assert_matches "$out" '^  Installed +1$' "plugins counted"
}

t_system_check_problems() {
    fixture_configured; load_app
    remove_mock certbot
    mock_rc systemctl-is-active 3
    chmod 644 "$MANAGER_DIR/sites.json"
    echo 'server { broken; }' > "$SITES_ENABLED/broken.conf"
    local out
    out=$(system_check <<< $'\n' 2>&1)
    assert_matches "$out" '^  certbot +○ Not installed \(needed for certificates\)$' "certbot optional"
    assert_matches "$out" '^  Service +✗ Not running$' "service down"
    assert_matches "$out" '^  Configuration +✗ Invalid' "nginx config invalid"
    assert_matches "$out" '^  Permissions +! 644 \(expected 600\)$' "loose permissions"
    echo '{bad' > "$MANAGER_DIR/sites.json"
    echo 'FOO=bar' >> "$MANAGER_DIR/config.conf"
    out=$(system_check <<< $'\n' 2>&1)
    assert_matches "$out" '^  Database +✗ Broken' "broken database"
    assert_matches "$out" '^  Config file +✗ Invalid$' "invalid manager config"
    assert_contains "$out" "line 6: unknown setting FOO" "config problem named"
    assert_matches "$out" '^  Certificate +\? Unknown' "certificate unknown, not guessed"
}

# Without systemctl the service state is unknown, not "not running".
t_status_unknown_without_systemctl() {
    fixture_configured; load_app
    remove_mock systemctl   # the image has no real systemctl
    local out
    out=$(render_dashboard_status 2>&1)
    assert_matches "$out" '^  NGINX service +\? Unknown \(systemctl not available\)$' "dashboard: unknown"
    assert_not_contains "$out" "nginx is not running" "no false warning"
}

t_dashboard_counts() {
    fixture_configured; fixture_sites_v3
    seed "generate_site app; ln -s $SITES_AVAILABLE/app.conf $SITES_ENABLED/app.conf"
    local out
    out=$(run_app 'q\n')
    assert_contains "$out" "1 enabled, 1 disabled (2 total)" "counts from v3 fixture"
}

# D6: the dashboard counts live symlinks, whatever the db flags say.
t_dashboard_counts_live_symlinks() {
    fixture_configured
    seed "new_site a http; enable_site a; db_update_enabled a false
          new_site b http; enable_site b; db_update_enabled b false
          new_site c http; db_update_enabled c true"
    local out
    out=$(run_app 'q\n')
    assert_contains "$out" "2 enabled, 1 disabled (3 total)" "live sites counted, stale flags ignored"
    assert_contains "$out" "3 site(s) need attention: see Sites" "stale flags reported as warnings"
}

# The dashboard is checked once, then reused until something changes.
t_dashboard_status_is_cached() {
    fixture_configured; load_app
    local calls
    render_dashboard_status >/dev/null 2>&1
    render_dashboard_status >/dev/null 2>&1
    calls=$(grep -c '^systemctl is-active' "$MOCK_LOG")
    assert_eq 1 "$calls" "second draw reuses the check"
    ui_run true
    render_dashboard_status >/dev/null 2>&1
    calls=$(grep -c '^systemctl is-active' "$MOCK_LOG")
    assert_eq 2 "$calls" "an operation makes the next draw check again"
}

t_show_backups() {
    fixture_configured; load_app
    assert_contains "$(show_backups <<< $'\n' 2>&1)" "No backups yet" "empty"
    new_site app http; generate_site app >/dev/null 2>&1
    local out
    out=$(show_backups <<< $'\n' 2>&1)
    assert_contains "$out" "Newest first, in $MANAGER_DIR/backups:" "location shown"
    assert_matches "$out" '^  [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}  app\.conf_[0-9]+\.bak$' "backup listed"
    assert_contains "$out" "run nginx -t before reloading nginx" "manual restore explained"
}

t_show_logs() {
    fixture_configured; load_app
    assert_contains "$(show_logs <<< $'\n' 2>&1)" "No logs yet" "no log file"
    log "hello from test"
    assert_matches "$(show_logs <<< $'\n' 2>&1)" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} hello from test$' "log line format"
}

t_nginx_test_screen() {
    fixture_configured; load_app
    local out
    out=$(nginx_test_screen <<< $'\n' 2>&1)
    assert_contains "$out" "syntax is ok" "nginx -t output shown"
    assert_contains "$out" "nginx configuration is valid" "result"
    echo 'server { broken; }' > "$SITES_ENABLED/broken.conf"
    out=$(nginx_test_screen <<< $'\n' 2>&1)
    assert_contains "$out" "nginx configuration test failed (nginx -t exit 1)" "failure reported"
    assert_contains "$out" "broken.conf" "nginx's reason shown"
}

t_main_menu_navigation() {
    fixture_configured
    local out
    out=$(run_app '4\nq\n1\n\n7\n2\n\n1\n\n3\n\nq\n6\n\nh\n\nq\n')
    assert_contains "$out" "NGINX Manager Pro › TLS & certificates" "4 -> TLS"
    assert_contains "$out" "NGINX Manager Pro › Status" "1 -> status"
    assert_contains "$out" "Logs & diagnostics › Backups" "7, 2 -> backups"
    assert_contains "$out" "Logs & diagnostics › Manager log" "7, 1 -> log"
    assert_contains "$out" "Logs & diagnostics › Test nginx configuration" "7, 3 -> nginx -t"
    assert_contains "$out" "NGINX Manager Pro › Settings" "6 -> settings"
    assert_contains "$out" "NGINX Manager Pro › Help" "h -> help"
}

t_non_root_reexecs_with_sudo() {
    fixture_configured
    local out rc
    out=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$APP" </dev/null 2>&1); rc=$?
    assert_contains "$out" "Run as root" "message"
    assert_contains "$out" "sudo" "tries sudo (absent in the test image)"
    assert_eq 127 "$rc" "exec sudo fails with 127 when sudo is missing"
}
