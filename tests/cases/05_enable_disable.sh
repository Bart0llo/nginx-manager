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

t_reload_failure_reported_as_success() {
    known_defect "D2: systemctl reload result ignored"
    fixture_configured; load_app
    new_site app http; mock_rc systemctl-reload 1
    local out rc
    out=$(enable_site app 2>&1); rc=$?
    assert_eq 0 "$rc" "enable returns 0 although reload failed"
    assert_contains "$out" "Nginx reloaded" "reload reported as successful"
}
