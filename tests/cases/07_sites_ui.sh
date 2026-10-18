#!/bin/bash
# Site management screens, driven end-to-end through the real menus
# (main menu "1" = Sites). Each input ends by backing out with q.

BAD_BACKEND="nonexistent.invalid:80"

t_sites_menu_empty() {
    fixture_configured
    local out
    out=$(run_app '1\nq\nq\n')
    assert_contains "$out" "No sites configured yet" "empty list message"
    assert_contains "$out" "[A] Add       [E] Edit      [T] Toggle    [R] Regenerate" "action bar"
}

t_sites_table() {
    fixture_configured
    local long="verylongsubdomainname-abcdefgh.lan.example.com"
    seed "new_site app https; enable_site app; new_site web http; new_site zlong http $long"
    local out
    out=$(run_app '1\nq\nq\n')
    assert_matches "$out" '^  #   NAME +STATUS +TLS +DOMAIN +BACKEND$' "table header"
    assert_matches "$out" '^  1 +app +● ENABLED +HTTPS +app\.lan\.example\.com +127\.0\.0\.1:8080$' "enabled https row"
    assert_matches "$out" '^  2 +web +○ DISABLED +HTTP +web\.lan\.example\.com +127\.0\.0\.1:8080$' "disabled http row"
    assert_contains "$out" "${long:0:25}..." "long domain truncated to 28 columns"
    assert_matches "$out" '^  1   app              ● ENABLED   HTTPS ' "columns aligned (UTF-8 status padded)"
}

t_add_site_https_enable() {
    fixture_configured
    local out rc
    out=$(run_app '1\na\napp\napp.lan.example.com\n127.0.0.1:8080\n2\ny\n\nq\nq\n'); rc=$?
    assert_eq 0 "$rc" "app exits 0"
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
    assert_symlink "$SITES_ENABLED/app.conf"
    assert_db '.app == (.app | {domain,backend,tls,enabled,created})' "db entry has exactly the v3 fields"
    assert_db '.app.tls == "https" and .app.enabled == true' "db tls/enabled"
    assert_called "systemctl reload nginx" "reloaded"
    assert_contains "$out" "Configuration generated" "generation message"
    assert_contains "$out" "Site enabled" "enable message"
}

t_add_site_rejects_invalid_input() {
    fixture_configured
    seed "new_site web http"
    local out
    out=$(run_app '1\na\nbad name\nweb\napp\nnot_a_domain\napp.lan.example.com\nhost:080\nhost:70000\n127.0.0.1:8080\n4\n1\nn\n\nq\nq\n')
    assert_contains "$out" "Invalid name (letters, numbers, - and _ only)" "bad name rejected"
    assert_contains "$out" "A site named 'web' already exists" "duplicate rejected"
    assert_contains "$out" "Invalid domain" "bad domain rejected"
    assert_count "$out" "Invalid backend (expected host:port, 1-65535)" 2 "both bad backends rejected"
    assert_contains "$out" "Invalid selection" "bad TLS mode rejected"
    assert_contains "$out" "Site created (disabled)" "created disabled after 'n'"
    assert_no_symlink "$SITES_ENABLED/app.conf"
    assert_db '.app.enabled == false and .app.tls == "http"' "db disabled http"
    assert_not_called "systemctl reload" "no reload"
}

t_add_site_uncovered_domain_rolls_back() {
    fixture_configured
    local out
    out=$(run_app '1\na\napp\napp.other.com\n127.0.0.1:8080\n2\n\nq\nq\n')
    assert_contains "$out" "Could not create site" "failure reported"
    assert_contains "$out" "No changes were committed." "rollback explained"
    assert_db 'has("app") | not' "db entry rolled back"
    assert_no_file "$SITES_AVAILABLE/app.conf" "no config left"
}

t_edit_enabled_site() {
    fixture_configured
    seed "new_site app https; enable_site app"
    local out
    out=$(run_app '1\ne\n1\n\n127.0.0.1:9090\n\n\nq\nq\n')
    assert_contains "$(cat "$SITES_AVAILABLE/app.conf")" "proxy_pass http://127.0.0.1:9090;" "config updated"
    assert_db '.app.backend == "127.0.0.1:9090" and .app.tls == "https" and .app.enabled == true' "db updated, state kept"
    assert_called "systemctl reload nginx" "reloaded"
    assert_contains "$out" "Site updated" "success message"
    assert_eq 1 "$(ls "$MANAGER_DIR/backups" | wc -l)" "previous config backed up"
}

t_edit_disabled_site_not_reloaded() {
    fixture_configured
    seed "new_site web http"
    local out
    out=$(run_app '1\ne\n1\n\n127.0.0.1:9090\n\n\nq\nq\n')
    assert_contains "$out" "Site updated (disabled, not reloaded)" "disabled message"
    assert_no_symlink "$SITES_ENABLED/web.conf" "edit does not enable"
    assert_db '.web.enabled == false and .web.backend == "127.0.0.1:9090"' "db updated, still disabled"
    assert_not_called "systemctl reload" "no reload"
}

t_edit_invalid_rolls_back() {
    fixture_configured
    seed "new_site app http; enable_site app"
    local original out
    original=$(cat "$SITES_AVAILABLE/app.conf")
    out=$(run_app "1\ne\n1\n\n$BAD_BACKEND\n\n\nq\nq\n")
    assert_contains "$out" "New configuration invalid" "failure reported"
    assert_contains "$out" "Previous configuration restored and reloaded" "restore reported"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "config restored"
    assert_db '.app.backend == "127.0.0.1:8080" and .app.enabled == true' "db restored"
    nginx -t >/dev/null 2>&1; assert_eq 0 $? "nginx valid"
}

t_edit_generation_failure_restores_db() {
    fixture_configured
    seed "new_site web http web.other.com; enable_site web"
    local original out
    original=$(cat "$SITES_AVAILABLE/web.conf")
    out=$(run_app '1\ne\n1\n\n\n2\n\nq\nq\n')
    assert_contains "$out" "Could not generate configuration, restoring previous settings" "failure reported"
    assert_db '.web.tls == "http"' "db restored"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/web.conf")" "config untouched"
}

t_delete_site() {
    fixture_configured
    seed "new_site app http; enable_site app"
    local out
    out=$(run_app '1\nd\n1\napp\n\nq\nq\n')
    assert_contains "$out" "Site 'app' deleted" "success message"
    assert_no_file "$SITES_AVAILABLE/app.conf" "config removed"
    assert_no_symlink "$SITES_ENABLED/app.conf" "symlink removed"
    assert_db 'has("app") | not' "db entry removed"
    assert_matches "$(ls "$MANAGER_DIR/backups")" '^app\.conf_[0-9]+\.bak$' "backup kept"
    assert_called "systemctl reload nginx" "reloaded"
}

t_delete_requires_exact_name() {
    fixture_configured
    seed "new_site app http; enable_site app"
    local out
    out=$(run_app '1\nd\n1\nApp\n\nq\nq\n')
    assert_contains "$out" "Cancelled (name did not match)" "cancel message"
    assert_file "$SITES_AVAILABLE/app.conf" "config kept"
    assert_symlink "$SITES_ENABLED/app.conf" "symlink kept"
    assert_db 'has("app")' "db kept"
}

# D9: no backup, no delete - config, symlink and db entry all stay.
t_delete_aborts_when_backup_fails() {
    fixture_configured
    seed "new_site app http; enable_site app"
    rm -rf "$MANAGER_DIR/backups"; touch "$MANAGER_DIR/backups"
    local original before out
    original=$(cat "$SITES_AVAILABLE/app.conf")
    before=$(cat "$MANAGER_DIR/sites.json")
    out=$(run_app '1\nd\n1\napp\n\nq\nq\n')
    assert_contains "$out" "Failed to create backup" "backup failure shown"
    assert_contains "$out" "Site 'app' was NOT deleted: its configuration could not be backed up" "abort reported"
    assert_not_contains "$out" "Site 'app' deleted" "not reported as deleted"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "config intact"
    assert_symlink "$SITES_ENABLED/app.conf" "symlink intact"
    assert_eq "$before" "$(cat "$MANAGER_DIR/sites.json")" "db entry intact"
    assert_not_called "systemctl reload" "no reload"
}

t_toggle_from_list() {
    fixture_configured
    seed "new_site app http; enable_site app"
    local out
    out=$(run_app '1\nt\n1\n\n\nq\nq\n')
    assert_contains "$out" "Disable site 'app'? [Y/n]" "asks, default yes"
    assert_no_symlink "$SITES_ENABLED/app.conf" "disabled"
    assert_db '.app.enabled == false' "db disabled"
}

t_site_details_screen() {
    fixture_configured
    seed "new_site app https; enable_site app"
    local out
    out=$(run_app '1\n1\nq\nq\nq\n')
    assert_contains "$out" "SITE: app" "title"
    assert_contains "$out" "Domain       app.lan.example.com" "domain"
    assert_contains "$out" "Backend      http://127.0.0.1:8080" "backend"
    assert_contains "$out" "TLS          HTTPS" "tls"
    assert_contains "$out" "Status       ✓ Enabled" "status"
    assert_contains "$out" "Config       ✓ Valid" "config check"
    assert_contains "$out" "Certificate  *.lan.example.com (lan.example.com)" "certificate"
    assert_contains "$out" "[T] Disable" "toggle label follows state"
}

t_view_config() {
    fixture_configured
    seed "new_site app http"
    local out
    out=$(run_app '1\n1\nc\n\nq\nq\nq\n')
    assert_contains "$out" "CONFIG: app" "title"
    assert_contains "$out" "proxy_pass http://127.0.0.1:8080;" "config shown"
}

t_invalid_menu_input() {
    fixture_configured
    local out
    out=$(run_app 'z\n\n1\nz\n\nq\nq\n')
    assert_count "$out" "Invalid option" 2 "main and sites menu reject unknown keys"
    out=$(run_app '1\ne\nq\nq\nq\n')
    assert_contains "$out" "No sites configured yet" "select_site with no sites"
    seed "new_site app http"
    out=$(run_app '1\ne\n9\nq\nq\n')
    assert_contains "$out" "Invalid selection" "out-of-range selection"
}

# D6: the sites-enabled symlink decides whether a site is enabled; a stale
# db flag is corrected (and logged), never acted on.
t_toggle_follows_symlink_db_says_disabled() {
    fixture_configured
    seed "new_site app http; enable_site app; db_update_enabled app false"
    local out
    out=$(run_app '1\nt\n1\n\n\nq\nq\n')
    assert_contains "$out" "● ENABLED" "list shows the site enabled"
    assert_contains "$out" "Disable site 'app'? [Y/n]" "toggle offers to disable the live site"
    assert_not_contains "$out" "Enable site 'app'?" "does not offer to enable it"
    assert_no_symlink "$SITES_ENABLED/app.conf" "disabled"
    assert_db '.app.enabled == false' "db matches"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "State corrected for app: db enabled=false, symlink says true" "correction logged"
}

t_toggle_follows_symlink_db_says_enabled() {
    fixture_configured
    seed "new_site app http; db_update_enabled app true"
    local out
    out=$(run_app '1\nt\n1\nn\n\nq\nq\n')
    assert_contains "$out" "○ DISABLED" "list shows the site disabled"
    assert_contains "$out" "Enable site 'app'? [Y/n]" "toggle offers to enable it"
    assert_no_symlink "$SITES_ENABLED/app.conf" "declining changes nothing on disk"
    assert_db '.app.enabled == false' "stale db flag corrected"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "State corrected for app: db enabled=true, symlink says false" "correction logged"
}

# D6: editing a live site whose db flag says disabled must still validate
# with nginx -t and roll back an invalid config.
t_edit_validates_live_site_with_stale_db() {
    fixture_configured
    seed "new_site app http; enable_site app; db_update_enabled app false"
    local original out
    original=$(cat "$SITES_AVAILABLE/app.conf")
    out=$(run_app "1\ne\n1\n\n$BAD_BACKEND\n\n\nq\nq\n")
    assert_not_contains "$out" "Site updated (disabled, not reloaded)" "not treated as disabled"
    assert_contains "$out" "New configuration invalid" "validated with nginx -t"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "previous config restored"
    assert_symlink "$SITES_ENABLED/app.conf" "still enabled"
    nginx -t >/dev/null 2>&1; assert_eq 0 $? "live nginx config left valid"
    assert_db '.app.enabled == true and .app.backend == "127.0.0.1:8080"' "db restored and matches the symlink"
}

t_edit_disabled_site_with_stale_db() {
    fixture_configured
    seed "new_site app http; db_update_enabled app true"
    local out
    out=$(run_app '1\ne\n1\n\n127.0.0.1:9090\n\n\nq\nq\n')
    assert_contains "$out" "Site updated (disabled, not reloaded)" "treated as disabled"
    assert_no_symlink "$SITES_ENABLED/app.conf" "edit does not enable"
    assert_not_called "systemctl reload" "no reload"
    assert_db '.app.enabled == false and .app.backend == "127.0.0.1:9090"' "db updated and matches the symlink"
}
