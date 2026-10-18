#!/bin/bash
# regenerate_site_safe / regenerate_all: backup, validate, rollback.
# An unresolvable upstream host (containers run without network) is used to
# make nginx -t reject an otherwise well-formed generated config.

BAD_BACKEND="nonexistent.invalid:80"

t_regenerate_disabled_site_no_reload() {
    fixture_configured; load_app
    new_site app http
    db_save app app.lan.example.com 127.0.0.1:9999 http false >/dev/null; : > "$MOCK_LOG"
    regenerate_site_safe app >/dev/null 2>&1
    assert_eq 0 $? "returns 0"
    assert_contains "$(cat "$SITES_AVAILABLE/app.conf")" "proxy_pass http://127.0.0.1:9999;" "config regenerated"
    assert_not_called "systemctl reload" "disabled site: no reload"
    assert_eq 1 "$(ls "$MANAGER_DIR/backups" | wc -l)" "backup created"
}

t_regenerate_enabled_site_reloads() {
    fixture_configured; load_app
    new_site app https; enable_site app >/dev/null 2>&1
    db_save app app.lan.example.com 127.0.0.1:9999 https true >/dev/null; : > "$MOCK_LOG"
    local out
    out=$(regenerate_site_safe app 2>&1)
    assert_eq 0 $? "returns 0"
    assert_contains "$(cat "$SITES_AVAILABLE/app.conf")" "proxy_pass http://127.0.0.1:9999;" "config regenerated"
    assert_called "systemctl reload nginx" "nginx reloaded"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Regenerated and reloaded: app" "logged"
}

t_regenerate_invalid_rolls_back() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1
    local original out rc
    original=$(cat "$SITES_AVAILABLE/app.conf")
    db_save app app.lan.example.com "$BAD_BACKEND" http true >/dev/null; : > "$MOCK_LOG"
    out=$(regenerate_site_safe app 2>&1); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "previous config restored"
    assert_contains "$out" "Previous configuration restored" "restore reported"
    assert_called "systemctl reload nginx" "reloaded with the restored config"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Rollback restored previous config for app" "logged"
    nginx -t >/dev/null 2>&1; assert_eq 0 $? "nginx valid after rollback"
}

# D5: the rollback puts the backup back with a rename as well, keeping
# the file mode, and leaves no temp files behind.
t_regenerate_rollback_restores_atomically() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1; chmod 640 "$SITES_AVAILABLE/app.conf"
    local original
    original=$(cat "$SITES_AVAILABLE/app.conf")
    db_save app app.lan.example.com "$BAD_BACKEND" http true >/dev/null
    cp() { [[ "$2" == "$SITES_AVAILABLE/app.conf" ]] && { echo "in-place copy" >&2; return 1; }; command cp "$@"; }
    regenerate_site_safe app >/dev/null 2>&1
    unset -f cp
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "previous config restored"
    assert_mode "$SITES_AVAILABLE/app.conf" 640 "mode kept"
    assert_eq "" "$(ls -A "$SITES_AVAILABLE" | grep '^\.')" "no temp files left"
    nginx -t >/dev/null 2>&1; assert_eq 0 $? "nginx valid after rollback"
}

# D5 review: if the backup cannot be put back, say so - the invalid new
# config is still on disk - and do not reload.
t_regenerate_restore_failure_reported() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1
    db_save app app.lan.example.com "$BAD_BACKEND" http true >/dev/null; : > "$MOCK_LOG"
    # generate_site's own mktemp runs before the backup; fail only the restore's.
    mktemp() { [[ -n "$LAST_BACKUP" ]] && return 1; command mktemp "$@"; }
    local out rc
    out=$(regenerate_site_safe app 2>&1); rc=$?
    unset -f mktemp
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "Failed to restore $SITES_AVAILABLE/app.conf" "restore failure reported"
    assert_contains "$out" "invalid new configuration is still in $SITES_AVAILABLE/app.conf" "remaining state explained"
    assert_not_contains "$out" "Previous configuration restored" "no restore claimed"
    assert_not_called "systemctl reload" "no reload"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Restore FAILED" "logged"
}

t_regenerate_invalid_without_backup() {
    fixture_configured; load_app
    db_save app app.lan.example.com "$BAD_BACKEND" http true >/dev/null
    ln -s "$SITES_AVAILABLE/app.conf" "$SITES_ENABLED/app.conf"   # dangling: config missing
    local out rc
    out=$(regenerate_site_safe app 2>&1); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "No backup available to restore for app" "missing backup reported"
}

t_regenerate_generation_failure_keeps_file() {
    fixture_configured; load_app
    new_site app https; enable_site app >/dev/null 2>&1
    local original out rc
    original=$(cat "$SITES_AVAILABLE/app.conf")
    db_save app app.other.com 127.0.0.1:8080 https true >/dev/null; : > "$MOCK_LOG"
    out=$(regenerate_site_safe app 2>&1); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "[app] Configuration generation failed" "failure reported"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "existing config untouched"
    assert_not_called "systemctl reload" "no reload"
}

# D2: a valid regenerated config whose reload fails is not "reloaded".
t_regenerate_reload_failure_reported() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1
    db_save app app.lan.example.com 127.0.0.1:9999 http true >/dev/null
    mock_rc systemctl-reload 1
    local out rc
    out=$(regenerate_site_safe app 2>&1); rc=$?
    assert_eq 3 "$rc" "returns 3 (config in place, reload failed)"
    assert_contains "$out" "Nginx reload failed (systemctl exit 1)" "failure reported"
    assert_not_contains "$out" "Nginx reloaded" "no reload claimed"
    assert_contains "$(cat "$SITES_AVAILABLE/app.conf")" "proxy_pass http://127.0.0.1:9999;" "valid new config kept"
    assert_not_contains "$(cat /var/log/nginx-manager/manager.log)" "Regenerated and reloaded: app" "success not logged"
    out=$(regenerate_config app <<< $'y\n\n' 2>&1)
    assert_not_contains "$out" "The new configuration was rejected." "not described as rejected"
    assert_contains "$out" "nginx was not reloaded" "menu explains the result"
}

t_regenerate_all_reports_partial() {
    fixture_configured; load_app
    new_site good http
    new_site bad https; db_save bad bad.other.com 127.0.0.1:8080 https false >/dev/null
    local out
    out=$(regenerate_all <<< $'y\n\n' 2>&1)
    assert_contains "$out" "1 succeeded, 1 failed" "summary counts"
    assert_matches "$out" '^Successful:' "success list header"
    assert_matches "$out" '^  good$' "good listed"
    assert_matches "$out" '^  bad$' "bad listed"
}

t_regenerate_all_cancel() {
    fixture_configured; load_app
    new_site app http
    regenerate_all <<< $'n\n' >/dev/null 2>&1
    assert_eq "" "$(ls "$MANAGER_DIR/backups")" "nothing regenerated after 'n'"
}

t_regenerate_config_prompt() {
    fixture_configured; load_app
    new_site app http
    local out
    out=$(regenerate_config app <<< $'y\n\n' 2>&1)
    assert_contains "$out" "Regenerate configuration for 'app'? [y/N]" "asks, default no"
    assert_contains "$out" "Configuration regenerated" "success message"
}
