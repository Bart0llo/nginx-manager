#!/bin/bash
# Non-interactive site operations (lib/site_ops.sh), called directly with
# explicit arguments, plus checks that the menus still go through them.
# Return codes: 0 success, 1 operation failed, 2 input rejected.

BAD_BACKEND="nonexistent.invalid:80"
SPY_LOG="/tmp/spy.log"

# Runs a command with a sentinel line on stdin and checks it is left unread.
assert_stdin_untouched() { # message command...
    local msg="$1" rest
    shift
    rest=$( { "$@" >/dev/null 2>&1; cat; } <<< "UNREAD" )
    assert_eq UNREAD "$rest" "$msg"
}

# Wraps a function so each call's arguments are appended to $SPY_LOG.
spy() { # function
    eval "_spied_$(declare -f "$1")"
    eval "$1() { echo \"$1 \$*\" >> \"$SPY_LOG\"; _spied_$1 \"\$@\"; }"
}

db_snapshot() { cat "$MANAGER_DIR/sites.json"; }

# ==========================================================
# site_create
# ==========================================================
t_site_create_generates_golden_configs() {
    fixture_configured; load_app
    local rc
    site_create web web.lan.example.com 127.0.0.1:3000 http </dev/null >/dev/null 2>&1; rc=$?
    assert_eq 0 "$rc" "http site created"
    golden_compare http.conf "$SITES_AVAILABLE/web.conf"
    site_create app app.lan.example.com 127.0.0.1:8080 https </dev/null >/dev/null 2>&1; rc=$?
    assert_eq 0 "$rc" "https site created"
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
    site_create mix mix.lan.example.com 10.0.0.7:9000 both </dev/null >/dev/null 2>&1; rc=$?
    assert_eq 0 "$rc" "both site created"
    golden_compare both.conf "$SITES_AVAILABLE/mix.conf"
}

t_site_create_saves_disabled_site() {
    fixture_configured; load_app; : > "$MOCK_LOG"
    assert_stdin_untouched "site_create does not read stdin" \
        site_create app app.lan.example.com 127.0.0.1:8080 https
    assert_db '.app == (.app | {domain,backend,tls,enabled,created})' "db entry has exactly the v3 fields"
    assert_db '.app | .domain == "app.lan.example.com" and .backend == "127.0.0.1:8080" and .tls == "https" and .enabled == false' "db fields, created disabled"
    assert_db '.app.enabled | type == "boolean"' "enabled stored as boolean"
    assert_no_symlink "$SITES_ENABLED/app.conf" "not enabled"
    assert_not_called "systemctl reload" "no reload"
}

t_site_create_rejects_input() {
    fixture_configured; load_app
    new_site web http
    local before out rc
    before=$(db_snapshot)

    out=$(site_create 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "no arguments rejected"
    assert_contains "$out" "Invalid name" "missing name reported"
    out=$(site_create "bad name" app.lan.example.com 127.0.0.1:8080 http 2>&1); rc=$?
    assert_eq 2 "$rc" "invalid name rejected"
    out=$(site_create ../../victim app.lan.example.com 127.0.0.1:8080 http 2>&1); rc=$?
    assert_eq 2 "$rc" "path in name rejected"
    out=$(site_create web web.lan.example.com 127.0.0.1:8080 http 2>&1); rc=$?
    assert_eq 2 "$rc" "duplicate rejected"
    assert_contains "$out" "A site named 'web' already exists" "duplicate reported"
    out=$(site_create app not_a_domain 127.0.0.1:8080 http 2>&1); rc=$?
    assert_eq 2 "$rc" "invalid domain rejected"
    assert_contains "$out" "Invalid domain" "domain error reported"
    out=$(site_create app app.lan.example.com host:080 http 2>&1); rc=$?
    assert_eq 2 "$rc" "invalid backend rejected"
    assert_contains "$out" "Invalid backend (expected host:port, 1-65535)" "backend error reported"
    out=$(site_create app app.lan.example.com 127.0.0.1:8080 HTTPS 2>&1); rc=$?
    assert_eq 2 "$rc" "invalid tls mode rejected"
    assert_contains "$out" "Invalid TLS mode: HTTPS" "tls error reported"
    out=$(site_create app app.lan.example.com 127.0.0.1:8080 2>&1); rc=$?
    assert_eq 2 "$rc" "missing tls mode rejected"

    assert_eq "$before" "$(db_snapshot)" "db unchanged"
    assert_no_file "$SITES_AVAILABLE/app.conf" "no config written"
}

t_site_create_generation_failure_rolls_back() {
    fixture_configured; load_app
    local out rc
    out=$(site_create app app.other.com 127.0.0.1:8080 https 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "Could not create site" "failure reported"
    assert_db 'has("app") | not' "db entry rolled back"
    assert_no_file "$SITES_AVAILABLE/app.conf" "no config left"
}

t_site_create_db_failure() {
    fixture_configured; load_app
    echo '{broken' > "$MANAGER_DIR/sites.json"
    local out rc
    out=$(site_create app app.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "Failed to save site to database" "failure reported"
    assert_eq '{broken' "$(db_snapshot)" "db untouched"
    assert_no_file "$SITES_AVAILABLE/app.conf" "no config written"
}

# ==========================================================
# site_update
# ==========================================================
t_site_update_disabled_site() {
    fixture_configured; load_app
    new_site web http; : > "$MOCK_LOG"
    assert_stdin_untouched "site_update does not read stdin" \
        site_update web web.lan.example.com 127.0.0.1:3000 http
    golden_compare http.conf "$SITES_AVAILABLE/web.conf"
    assert_db '.web | .backend == "127.0.0.1:3000" and .enabled == false' "db updated, still disabled"
    assert_db '.web == (.web | {domain,backend,tls,enabled,created})' "db entry has exactly the v3 fields"
    assert_no_symlink "$SITES_ENABLED/web.conf" "update does not enable"
    assert_not_called "systemctl reload" "no reload"
    assert_eq 1 "$(ls "$MANAGER_DIR/backups" | wc -l)" "previous config backed up"
}

t_site_update_enabled_site() {
    fixture_configured; load_app
    new_site mix http mix.lan.example.com 127.0.0.1:1; enable_site mix >/dev/null 2>&1
    : > "$MOCK_LOG"
    local out rc
    out=$(site_update mix mix.lan.example.com 10.0.0.7:9000 both 2>&1 </dev/null); rc=$?
    assert_eq 0 "$rc" "returns 0"
    golden_compare both.conf "$SITES_AVAILABLE/mix.conf"
    assert_db '.mix | .tls == "both" and .backend == "10.0.0.7:9000" and .enabled == true' "db updated, state kept"
    assert_called "systemctl reload nginx" "reloaded"
    assert_contains "$out" "Site updated" "success message"
}

t_site_update_invalid_config_rolls_back() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1
    local original out rc
    original=$(cat "$SITES_AVAILABLE/app.conf")
    out=$(site_update app app.lan.example.com "$BAD_BACKEND" http 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "Previous configuration restored and reloaded" "restore reported"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "config restored"
    assert_db '.app.backend == "127.0.0.1:8080" and .app.enabled == true' "db restored"
}

t_site_update_generation_failure() {
    fixture_configured; load_app
    new_site web http web.other.com
    local original rc
    original=$(cat "$SITES_AVAILABLE/web.conf")
    site_update web web.other.com 127.0.0.1:8080 https </dev/null >/dev/null 2>&1; rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_db '.web.tls == "http"' "db restored"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/web.conf")" "config untouched"
}

t_site_update_rejects_input() {
    fixture_configured; load_app
    new_site app http
    local before out rc
    before=$(db_snapshot)
    out=$(site_update nope nope.lan.example.com 127.0.0.1:8080 http 2>&1); rc=$?
    assert_eq 2 "$rc" "unknown site rejected"
    assert_contains "$out" "Site 'nope' not found" "unknown site reported"
    out=$(site_update ../app app.lan.example.com 127.0.0.1:8080 http 2>&1); rc=$?
    assert_eq 2 "$rc" "invalid name rejected"
    assert_contains "$out" "Invalid site name: '../app'" "invalid name reported"
    site_update 2>/dev/null; assert_eq 2 $? "no arguments rejected"
    site_update app "" 127.0.0.1:8080 http >/dev/null 2>&1; assert_eq 2 $? "empty domain rejected"
    site_update app app.lan.example.com 127.0.0.1:0 http >/dev/null 2>&1; assert_eq 2 $? "invalid backend rejected"
    site_update app app.lan.example.com 127.0.0.1:8080 tls >/dev/null 2>&1; assert_eq 2 $? "invalid tls rejected"
    assert_eq "$before" "$(db_snapshot)" "db unchanged"
    assert_eq 0 "$(ls "$MANAGER_DIR/backups" | wc -l)" "nothing regenerated"
}

# ==========================================================
# site_delete
# ==========================================================
t_site_delete() {
    fixture_configured; load_app
    new_site app http; enable_site app >/dev/null 2>&1; : > "$MOCK_LOG"
    assert_stdin_untouched "site_delete does not read stdin (no confirmation prompt)" \
        site_delete app
    assert_no_file "$SITES_AVAILABLE/app.conf" "config removed"
    assert_no_symlink "$SITES_ENABLED/app.conf" "symlink removed"
    assert_db 'has("app") | not' "db entry removed"
    assert_matches "$(ls "$MANAGER_DIR/backups")" '^app\.conf_[0-9]+\.bak$' "backup kept"
    assert_called "systemctl reload nginx" "reloaded"

    new_site web http
    site_delete web >/dev/null 2>&1; assert_eq 0 $? "returns 0"
}

t_site_delete_rejects_input() {
    fixture_configured; load_app
    new_site app http
    echo keep > /etc/victim.conf
    local before out rc
    before=$(db_snapshot)
    out=$(site_delete nope 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "unknown site rejected"
    assert_contains "$out" "Site 'nope' not found" "unknown site reported"
    site_delete ../../victim >/dev/null 2>&1; assert_eq 2 $? "path in name rejected"
    assert_file /etc/victim.conf "file outside nginx dirs not removed"
    site_delete >/dev/null 2>&1; assert_eq 2 $? "no arguments rejected"
    assert_eq "$before" "$(db_snapshot)" "db unchanged"
    assert_file "$SITES_AVAILABLE/app.conf" "other config kept"
    assert_not_called "systemctl reload" "no reload"
}

t_site_delete_reports_reload_failure() {
    fixture_configured; load_app
    new_site app http
    echo 'server { this_is_not_a_directive; }' > "$SITES_ENABLED/broken.conf"
    local out rc
    out=$(site_delete app 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "returns 1 when nginx cannot be reloaded"
    assert_contains "$out" "Nginx config invalid" "reload failure shown"
    assert_no_file "$SITES_AVAILABLE/app.conf" "site still removed"
    assert_db 'has("app") | not' "db entry removed"
}

# ==========================================================
# enable_site / disable_site
# ==========================================================
t_enable_disable_non_interactive() {
    fixture_configured; load_app
    new_site app http
    assert_stdin_untouched "enable_site does not read stdin" enable_site app
    assert_symlink "$SITES_ENABLED/app.conf" "enabled"
    assert_stdin_untouched "disable_site does not read stdin" disable_site app
    assert_no_symlink "$SITES_ENABLED/app.conf" "disabled"
}

t_enable_disable_reject_unknown_site() {
    fixture_configured; load_app
    new_site app http
    echo 'server { listen 80; server_name x.example.com; }' > "$SITES_AVAILABLE/unmanaged.conf"
    echo keep > /etc/victim.conf
    : > "$MOCK_LOG"
    local before out rc
    before=$(db_snapshot)
    out=$(enable_site unmanaged 2>&1 </dev/null); rc=$?
    assert_eq 2 "$rc" "enable of unmanaged config rejected"
    assert_contains "$out" "Site 'unmanaged' not found" "reported"
    assert_no_symlink "$SITES_ENABLED/unmanaged.conf" "not linked"
    disable_site unmanaged >/dev/null 2>&1; assert_eq 2 $? "disable of unknown site rejected"
    disable_site ../../victim >/dev/null 2>&1; assert_eq 2 $? "path in name rejected"
    assert_file /etc/victim.conf "file outside nginx dirs not removed"
    enable_site >/dev/null 2>&1; assert_eq 2 $? "enable without name rejected"
    assert_eq "$before" "$(db_snapshot)" "no partial db entries created"
    assert_not_called "systemctl reload" "no reload"
}

# ==========================================================
# site_import
# ==========================================================
t_site_import() {
    fixture_configured; load_app
    new_site app http
    printf '%s\n' 'server {' '    listen 443 ssl;' '    server_name secure.example.com;' \
        '    location / { ' '        proxy_pass http://10.0.0.2:4000;' '    }' '}' > "$SITES_AVAILABLE/secure.conf"
    echo 'server { listen 80; location / { proxy_pass http://10.0.0.1:1; } }' > "$SITES_AVAILABLE/nodomain.conf"
    local original rc
    original=$(cat "$SITES_AVAILABLE/secure.conf")

    assert_stdin_untouched "site_import does not read stdin" site_import "$SITES_AVAILABLE/secure.conf"
    assert_db '.secure | .domain == "secure.example.com" and .backend == "10.0.0.2:4000" and .tls == "https" and .enabled == false' "imported fields"
    assert_db '.secure == (.secure | {domain,backend,tls,enabled,created})' "db entry has exactly the v3 fields"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/secure.conf")" "config file not modified"

    local before
    before=$(db_snapshot)
    site_import "$SITES_AVAILABLE/secure.conf" >/dev/null 2>&1; assert_eq 2 $? "already imported: skipped"
    site_import "$SITES_AVAILABLE/app.conf" >/dev/null 2>&1; assert_eq 2 $? "managed site: skipped"
    site_import "$SITES_AVAILABLE/nodomain.conf" >/dev/null 2>&1; assert_eq 2 $? "no server_name: skipped"
    site_import "$SITES_AVAILABLE/missing.conf" >/dev/null 2>&1; assert_eq 2 $? "missing file: skipped"
    site_import >/dev/null 2>&1; assert_eq 2 $? "no arguments rejected"
    assert_eq "$before" "$(db_snapshot)" "db unchanged by skips"
}

t_site_import_db_failure() {
    fixture_configured; load_app
    echo 'server { listen 80;' > "$SITES_AVAILABLE/plain.conf"
    printf '%s\n' '    server_name plain.example.com;' '    location / { proxy_pass http://10.0.0.1:3000; }' '}' \
        >> "$SITES_AVAILABLE/plain.conf"
    echo '{broken' > "$MANAGER_DIR/sites.json"
    local out rc
    out=$(site_import "$SITES_AVAILABLE/plain.conf" 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "Failed to update database" "failure reported"
    assert_not_contains "$out" "Imported: plain" "not reported as imported"
    assert_eq '{broken' "$(db_snapshot)" "db untouched"
}

# ==========================================================
# CLI -> operations
# ==========================================================
t_cli_add_calls_site_create() {
    fixture_configured; load_app; rm -f "$SPY_LOG"
    spy site_create; spy enable_site
    add_site <<< $'app\napp.lan.example.com\n127.0.0.1:8080\n2\ny\n\n' >/dev/null 2>&1
    assert_eq "site_create app app.lan.example.com 127.0.0.1:8080 https
enable_site app" "$(cat "$SPY_LOG")" "add -> site_create, then enable_site after confirm"
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
}

t_cli_edit_calls_site_update() {
    fixture_configured; load_app; rm -f "$SPY_LOG"
    new_site app https
    spy site_update
    edit_site app <<< $'\n127.0.0.1:9090\n3\n\n' >/dev/null 2>&1
    assert_eq "site_update app app.lan.example.com 127.0.0.1:9090 both" "$(cat "$SPY_LOG")" \
        "edit -> site_update with prompted values and defaults"
}

t_cli_delete_calls_site_delete_after_confirm() {
    fixture_configured; load_app; rm -f "$SPY_LOG"
    new_site app http
    spy site_delete
    delete_site app <<< $'App\n\n' >/dev/null 2>&1
    assert_no_file "$SPY_LOG" "wrong confirmation: site_delete not called"
    assert_file "$SITES_AVAILABLE/app.conf" "config kept"
    delete_site app <<< $'app\n\n' >/dev/null 2>&1
    assert_eq 0 $? "delete_site returns 0 after deleting"
    assert_eq "site_delete app" "$(cat "$SPY_LOG")" "matching confirmation: site_delete called"
}

t_cli_import_calls_site_import() {
    fixture_configured; load_app; rm -f "$SPY_LOG"
    local n
    for n in a b; do
        printf '%s\n' 'server {' '    listen 80;' "    server_name $n.example.com;" \
            '    location / {' '        proxy_pass http://10.0.0.1:1;' '    }' '}' > "$SITES_AVAILABLE/$n.conf"
    done
    spy site_import
    local out
    out=$(import_sites <<< $'\n' 2>&1)
    assert_eq "site_import $SITES_AVAILABLE/a.conf
site_import $SITES_AVAILABLE/b.conf" "$(cat "$SPY_LOG")" "import -> site_import per config"
    assert_contains "$out" "Imported: a" "a imported"
    assert_not_contains "$out" "No new sites found to import." "count reflects imports"
}

# ==========================================================
# Imported sites named after their config file (example.com)
# ==========================================================
DOTTED="example.com"

# Writes $SITES_AVAILABLE/example.com.conf and imports it.
import_dotted() {
    printf '%s\n' 'server {' '    listen 80;' "    server_name $DOTTED;" \
        '    location / {' '        proxy_pass http://127.0.0.1:8080;' '    }' '}' \
        > "$SITES_AVAILABLE/$DOTTED.conf"
    seed "site_import $SITES_AVAILABLE/$DOTTED.conf"
}

t_dotted_import_enable_disable() {
    fixture_configured; import_dotted
    assert_db 'has("example.com")' "imported as example.com"
    local out
    out=$(run_app '1\nt\n1\n\n\nq\nq\n')
    assert_contains "$out" "Enable site 'example.com'? [Y/n]" "toggle offers enable"
    assert_not_contains "$out" "Invalid site name" "name accepted"
    assert_symlink "$SITES_ENABLED/$DOTTED.conf" "enabled from the menu"
    assert_db '.["example.com"].enabled == true' "db enabled"
    assert_called "systemctl reload nginx" "reloaded"
    out=$(run_app '1\nt\n1\n\n\nq\nq\n')
    assert_contains "$out" "Disable site 'example.com'? [Y/n]" "toggle offers disable"
    assert_no_symlink "$SITES_ENABLED/$DOTTED.conf" "disabled from the menu"
    assert_db '.["example.com"].enabled == false' "db disabled"

    load_app
    enable_site "$DOTTED" </dev/null >/dev/null 2>&1; assert_eq 0 $? "enable_site returns 0"
    disable_site "$DOTTED" </dev/null >/dev/null 2>&1; assert_eq 0 $? "disable_site returns 0"
}

t_dotted_import_edit() {
    fixture_configured; import_dotted
    local out
    out=$(run_app '1\ne\n1\n\n127.0.0.1:9090\n1\n\nq\nq\n')
    assert_contains "$out" "Site updated (disabled, not reloaded)" "edited from the menu"
    assert_not_contains "$out" "Invalid site name" "name accepted"
    assert_db '.["example.com"] | .backend == "127.0.0.1:9090" and .enabled == false' "db updated"
    assert_contains "$(cat "$SITES_AVAILABLE/$DOTTED.conf")" "proxy_pass http://127.0.0.1:9090;" "config regenerated"

    load_app
    site_update "$DOTTED" "$DOTTED" 127.0.0.1:9191 http </dev/null >/dev/null 2>&1
    assert_eq 0 $? "site_update returns 0"
    assert_db '.["example.com"].backend == "127.0.0.1:9191"' "db updated directly"
}

t_dotted_import_delete() {
    fixture_configured; import_dotted
    local out
    out=$(run_app '1\nd\n1\nexample.com\n\nq\nq\n')
    assert_contains "$out" "Site 'example.com' deleted" "deleted from the menu"
    assert_no_file "$SITES_AVAILABLE/$DOTTED.conf" "config removed"
    assert_db 'has("example.com") | not' "db entry removed"

    import_dotted; load_app
    site_delete "$DOTTED" </dev/null >/dev/null 2>&1; assert_eq 0 $? "site_delete returns 0"
    assert_no_file "$SITES_AVAILABLE/$DOTTED.conf" "config removed directly"
}

# Even names present in the db are refused when they would leave the
# nginx directories.
t_unsafe_names_rejected_even_if_in_db() {
    fixture_configured
    mkdir -p "$MANAGER_DIR"
    echo '{"../../victim":{"domain":"v.lan.example.com","backend":"127.0.0.1:1","tls":"http","enabled":true,"created":"2025-01-01T00:00:00Z"},
"..":{"domain":"d.lan.example.com","backend":"127.0.0.1:1","tls":"http","enabled":true,"created":"2025-01-01T00:00:00Z"},
".":{"domain":"e.lan.example.com","backend":"127.0.0.1:1","tls":"http","enabled":true,"created":"2025-01-01T00:00:00Z"},
"":{"domain":"f.lan.example.com","backend":"127.0.0.1:1","tls":"http","enabled":true,"created":"2025-01-01T00:00:00Z"}}' \
        > "$MANAGER_DIR/sites.json"
    load_app
    echo keep > /etc/victim.conf
    : > "$MOCK_LOG"
    local before n op out rc
    before=$(db_snapshot)
    for n in ../../victim .. . ""; do
        for op in site_delete enable_site disable_site; do
            out=$($op "$n" 2>&1 </dev/null); rc=$?
            assert_eq 2 "$rc" "$op '$n' rejected"
            assert_contains "$out" "Invalid site name: '$n'" "$op '$n' reported"
        done
        site_update "$n" v.lan.example.com 127.0.0.1:2 http >/dev/null 2>&1
        assert_eq 2 $? "site_update '$n' rejected"
    done
    assert_eq keep "$(cat /etc/victim.conf)" "file outside nginx dirs untouched"
    assert_eq "$before" "$(db_snapshot)" "db unchanged"
    assert_eq 0 "$(ls "$MANAGER_DIR/backups" | wc -l)" "nothing backed up or regenerated"
    assert_not_called "systemctl reload" "no reload"
}

t_site_create_keeps_strict_names() {
    fixture_configured; load_app
    local n out rc
    for n in example.com "my site" 'a$b' a/b . ..; do
        out=$(site_create "$n" app.lan.example.com 127.0.0.1:8080 http 2>&1 </dev/null); rc=$?
        assert_eq 2 "$rc" "site_create '$n' rejected"
        assert_contains "$out" "Invalid name (letters, numbers, - and _ only)" "site_create '$n' reported"
    done
    assert_eq '{}' "$(db_snapshot)" "db unchanged"
    assert_eq "" "$(ls "$SITES_AVAILABLE" | grep '\.conf$')" "no config written"
    out=$(run_app '1\na\nexample.com\napp\napp.lan.example.com\n127.0.0.1:8080\n1\nn\n\nq\nq\n')
    assert_contains "$out" "Invalid name (letters, numbers, - and _ only)" "add prompt rejects dotted name"
    assert_db '(has("example.com") | not) and has("app")' "only the valid name was created"
}
