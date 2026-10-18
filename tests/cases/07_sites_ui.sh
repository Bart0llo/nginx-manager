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

t_delete_proceeds_without_backup() {
    known_defect "D9: delete continues after a failed backup and reports success"
    fixture_configured
    seed "new_site app http"
    rm -rf "$MANAGER_DIR/backups"; touch "$MANAGER_DIR/backups"
    local out
    out=$(run_app '1\nd\n1\napp\n\nq\nq\n')
    assert_contains "$out" "Failed to create backup" "backup failure shown"
    assert_no_file "$SITES_AVAILABLE/app.conf" "config deleted anyway"
    assert_contains "$out" "Site 'app' deleted" "reported as deleted"
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

t_toggle_uses_db_not_symlink() {
    known_defect "D6: toggle reads the db flag; list/details read the symlink"
    fixture_configured
    seed "new_site app http; enable_site app; db_update_enabled app false"
    local out
    out=$(run_app '1\nt\n1\nn\n\nq\nq\n')
    assert_contains "$out" "● ENABLED" "list shows the site enabled"
    assert_contains "$out" "Enable site 'app'?" "toggle offers to enable it"
}

t_edit_skips_validation_when_db_stale() {
    known_defect "D6: edit trusts a stale db flag and changes a live config without nginx -t"
    fixture_configured
    seed "new_site app http; enable_site app; db_update_enabled app false"
    local out
    out=$(run_app "1\ne\n1\n\n$BAD_BACKEND\n\n\nq\nq\n")
    assert_contains "$out" "Site updated (disabled, not reloaded)" "treated as disabled"
    assert_symlink "$SITES_ENABLED/app.conf" "but it is live"
    nginx -t >/dev/null 2>&1; assert_eq 1 $? "live nginx config left invalid"
}
