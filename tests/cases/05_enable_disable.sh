#!/bin/bash
# Transactional enable/disable against real nginx -t (systemctl mocked).

t_enable_valid_site() {
    fixture_configured; load_app
    new_site app https; : > "$MOCK_LOG"
    local out rc
    out=$(enable_site app 2>&1); rc=$?
    assert_eq 0 "$rc" "enable returns 0"
    assert_symlink "$SITES_ENABLED/app.conf"
    assert_eq "$SITES_AVAILABLE/app.conf" "$(readlink "$SITES_ENABLED/app.conf")" "symlink target"
    assert_db '.app.enabled == true' "db enabled=true"
    assert_called "systemctl reload nginx" "nginx reloaded"
    assert_contains "$out" "Site enabled" "success message"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Site enabled: app" "logged"
}

t_enable_missing_config() {
    fixture_configured; load_app
    db_save app app.lan.example.com 127.0.0.1:8080 http false >/dev/null; : > "$MOCK_LOG"
    local out rc
    out=$(enable_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "enable fails"
    assert_contains "$out" "Cannot enable 'app': configuration file missing" "reason shown"
    assert_no_symlink "$SITES_ENABLED/app.conf"
    assert_not_called "systemctl reload" "no reload"
}

t_enable_invalid_config_rolls_back() {
    fixture_configured; load_app
    db_save app app.lan.example.com 127.0.0.1:8080 http false >/dev/null
    echo 'server { this_is_not_a_directive; }' > "$SITES_AVAILABLE/app.conf"
    : > "$MOCK_LOG"
    local out rc
    out=$(enable_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "enable fails"
    assert_no_symlink "$SITES_ENABLED/app.conf" "symlink removed again"
    assert_db '.app.enabled == false' "db still disabled"
    assert_not_called "systemctl reload" "no reload"
    assert_contains "$out" "The site was NOT enabled." "rollback explained"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "nginx -t invalid, rolled back" "logged"
    nginx -t >/dev/null 2>&1; assert_eq 0 $? "nginx left valid"
}

t_enable_invalid_keeps_preexisting_link() {
    fixture_configured; load_app
    db_save app app.lan.example.com 127.0.0.1:8080 http false >/dev/null
    echo 'server { this_is_not_a_directive; }' > "$SITES_AVAILABLE/app.conf"
    ln -s "$SITES_AVAILABLE/app.conf" "$SITES_ENABLED/app.conf"
    enable_site app >/dev/null 2>&1
    assert_eq 1 $? "enable fails"
    assert_symlink "$SITES_ENABLED/app.conf" "pre-existing link is not removed"
}

t_disable_site() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1; : > "$MOCK_LOG"
    local out rc
    out=$(disable_site app 2>&1); rc=$?
    assert_eq 0 "$rc" "disable returns 0"
    assert_no_symlink "$SITES_ENABLED/app.conf"
    assert_file "$SITES_AVAILABLE/app.conf" "config kept in sites-available"
    assert_db '.app.enabled == false' "db enabled=false"
    assert_called "systemctl reload nginx" "nginx reloaded"
    assert_contains "$out" "Site disabled" "success message"
}

t_disable_with_unrelated_broken_site() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1
    echo 'server { this_is_not_a_directive; }' > "$SITES_ENABLED/broken.conf"
    : > "$MOCK_LOG"
    local out rc
    out=$(disable_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "disable reports failure"
    assert_no_symlink "$SITES_ENABLED/app.conf" "site still disabled"
    assert_db '.app.enabled == false' "db updated"
    assert_not_called "systemctl reload" "no reload while invalid"
    assert_contains "$out" "Site disabled, but nginx configuration is still invalid" "warning shown"
}

# D2: a failing "systemctl reload nginx" must not be reported as a reload.
t_reload_nginx_reports_reload_failure() {
    fixture_configured; load_app
    mock_rc systemctl-reload 1
    local out rc
    out=$(reload_nginx 2>&1); rc=$?
    assert_eq 1 "$rc" "reload_nginx returns 1"
    assert_contains "$out" "Nginx reload failed (systemctl exit 1)" "failure reported"
    assert_not_contains "$out" "Nginx reload OK" "no success claimed"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "nginx reload failed (systemctl exit 1)" "failure logged"
    rm -f "$MOCK_RC/systemctl-reload"
    out=$(reload_nginx 2>&1); rc=$?
    assert_eq 0 "$rc" "reload_nginx returns 0 when the reload works"
    assert_contains "$out" "Nginx reload OK" "success reported"
}

t_enable_reload_failure_reported() {
    fixture_configured; load_app
    new_site app http; mock_rc systemctl-reload 1; : > "$MOCK_LOG"
    local out rc
    out=$(enable_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "enable returns 1"
    assert_called "systemctl reload nginx" "reload attempted"
    assert_contains "$out" "Nginx reload failed (systemctl exit 1)" "failure reported"
    assert_not_contains "$out" "Nginx reloaded" "no reload claimed"
    assert_contains "$out" "Site enabled, but nginx was not reloaded" "partial result explained"
    assert_symlink "$SITES_ENABLED/app.conf" "valid config stays enabled"
    assert_db '.app.enabled == true' "db matches the symlink"
}

t_disable_reload_failure_reported() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1; mock_rc systemctl-reload 1
    local out rc
    out=$(disable_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "disable returns 1"
    assert_contains "$out" "Nginx reload failed (systemctl exit 1)" "failure reported"
    assert_not_contains "$out" "Nginx reloaded" "no reload claimed"
    assert_contains "$out" "Site disabled, but nginx was not reloaded" "partial result explained"
    assert_no_symlink "$SITES_ENABLED/app.conf" "site stays disabled"
    assert_db '.app.enabled == false' "db matches the symlink"
}

# D6: only a symlink in sites-enabled is ours to create or remove; anything
# else found there is reported and left alone.
t_enable_refuses_unexpected_object() {
    fixture_configured; load_app
    new_site app http
    echo "# hand-made" > "$SITES_ENABLED/app.conf"
    local out rc
    out=$(enable_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "regular file in the way: enable fails"
    assert_contains "$out" "$SITES_ENABLED/app.conf is not a symlink" "reason shown"
    assert_eq "# hand-made" "$(cat "$SITES_ENABLED/app.conf")" "file left alone"
    assert_db '.app.enabled == false' "db unchanged"

    rm -f "$SITES_ENABLED/app.conf"
    new_site other http
    ln -s "$SITES_AVAILABLE/other.conf" "$SITES_ENABLED/app.conf"
    out=$(enable_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "symlink to another file: enable fails"
    assert_contains "$out" "points to $SITES_AVAILABLE/other.conf" "reason shown"
    assert_eq "$SITES_AVAILABLE/other.conf" "$(readlink "$SITES_ENABLED/app.conf")" "symlink left alone"
}

t_disable_refuses_unexpected_object() {
    fixture_configured; load_app
    new_site app http
    echo "# hand-made" > "$SITES_ENABLED/app.conf"
    local out rc
    out=$(disable_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "disable fails"
    assert_contains "$out" "$SITES_ENABLED/app.conf is not a symlink" "reason shown"
    assert_eq "# hand-made" "$(cat "$SITES_ENABLED/app.conf")" "file left alone"
}
