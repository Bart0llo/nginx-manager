#!/bin/bash
# sites.json operations and v3 data compatibility.

t_db_save_and_get() {
    fixture_configured; load_app
    db_save app app.lan.example.com 127.0.0.1:8080 https true
    assert_eq 0 $? "db_save returns 0"
    assert_eq app.lan.example.com "$(db_get app domain)" "domain"
    assert_eq 127.0.0.1:8080 "$(db_get app backend)" "backend"
    assert_eq https "$(db_get app tls)" "tls"
    assert_eq true "$(db_get app enabled)" "enabled"
    assert_db '.app.enabled | type == "boolean"' "enabled stored as boolean"
    assert_db '.app.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "created is an ISO timestamp"
    assert_mode "$MANAGER_DIR/sites.json" 600
    assert_eq "" "$(ls "$MANAGER_DIR" | grep '^tmp\.')" "no temp files left behind"
}

t_db_exists_and_missing_field() {
    fixture_configured; load_app
    db_save app app.lan.example.com 127.0.0.1:8080 http false
    db_exists app; assert_eq 0 $? "db_exists true for saved site"
    db_exists nope; assert_eq 1 $? "db_exists false for unknown site"
    assert_eq null "$(db_get app missing)" "missing field reads as 'null'"
}

t_db_update_enabled() {
    fixture_configured; load_app
    db_save app app.lan.example.com 127.0.0.1:8080 http true
    db_update_enabled app false
    assert_db '.app.enabled == false' "enabled set to false"
    assert_db '.app.domain == "app.lan.example.com"' "other fields kept"
    assert_mode "$MANAGER_DIR/sites.json" 600
}

t_db_remove() {
    fixture_sites_v3; fixture_configured; load_app
    db_remove legacy
    assert_db 'has("legacy") | not' "site removed"
    assert_db 'has("app")' "other site kept"
}

t_db_write_refused_on_corrupt_db() {
    fixture_configured; load_app
    echo '{broken' > "$MANAGER_DIR/sites.json"
    local out rc
    out=$(db_save app app.lan.example.com 127.0.0.1:8080 http false 2>&1); rc=$?
    assert_eq 1 "$rc" "db_save fails on corrupt db"
    assert_contains "$out" "Failed to update database" "error reported"
    assert_eq '{broken' "$(cat "$MANAGER_DIR/sites.json")" "corrupt db left untouched"
    assert_eq "" "$(ls "$MANAGER_DIR" | grep '^tmp\.')" "temp file cleaned up"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "db_save failed: jq error for site app" "failure logged"
}

t_v3_database_readable() {
    fixture_sites_v3; fixture_configured; load_app
    assert_eq app.lan.example.com "$(db_get app domain)" "v3 app domain"
    assert_eq https "$(db_get app tls)" "v3 app tls"
    assert_eq 10.0.0.5:80 "$(db_get legacy backend)" "v3 legacy backend"
    assert_eq false "$(db_get legacy enabled)" "v3 legacy enabled"
    assert_eq 2025-01-01T00:00:00Z "$(db_get app created)" "v3 created kept on load"
}

# D3: updating a site keeps its original creation time.
t_db_save_preserves_created() {
    fixture_sites_v3; fixture_configured; load_app
    db_save app app.lan.example.com 127.0.0.1:9090 https true
    assert_db '.app.created == "2025-01-01T00:00:00Z"' "created kept on update"
    assert_db '.app.backend == "127.0.0.1:9090"' "changed field written"
    assert_db '.legacy.created == "2025-02-01T12:30:00Z"' "other site untouched"
    db_save new new.lan.example.com 127.0.0.1:1 http false
    assert_db '.new.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "new site gets a created timestamp"
    assert_db '.new == (.new | {domain,backend,tls,enabled,created})' "new site has exactly the v3 fields"
}

# Site entry with fields unknown to this version, incl. nested plugin data.
EXTRA_DB='{"app":{"domain":"app.lan.example.com","backend":"127.0.0.1:8080","tls":"http","enabled":false,"created":"2025-01-01T00:00:00Z","plugins":{"x":{"k":"v","list":[1,{"deep":true}]}},"note":"hand-added"},"other":{"domain":"o.lan.example.com","backend":"127.0.0.1:2","tls":"http","enabled":false,"created":"2025-03-01T00:00:00Z","plugins":{"y":1}}}'
EXTRA_KEEP='.app.plugins == {"x":{"k":"v","list":[1,{"deep":true}]}} and .app.note == "hand-added" and .app.created == "2025-01-01T00:00:00Z"'

# D3: db_save keeps fields it does not know about.
t_db_save_preserves_unknown_fields() {
    fixture_configured
    mkdir -p "$MANAGER_DIR"; echo "$EXTRA_DB" > "$MANAGER_DIR/sites.json"
    load_app
    db_save app app.lan.example.com 127.0.0.1:9090 https true
    assert_db "$EXTRA_KEEP" "unknown and nested fields kept"
    assert_db '.app | .backend == "127.0.0.1:9090" and .tls == "https" and .enabled == true' "known fields updated"
    assert_db '.app | keys == ["backend","created","domain","enabled","note","plugins","tls"]' "no fields invented"
    assert_db '.other.plugins == {"y":1}' "other site untouched"
}

t_db_update_enabled_preserves_metadata() {
    fixture_configured
    mkdir -p "$MANAGER_DIR"; echo "$EXTRA_DB" > "$MANAGER_DIR/sites.json"
    load_app
    db_update_enabled app true
    assert_db "$EXTRA_KEEP" "unknown fields and created kept"
    assert_db '.app.enabled == true' "enabled updated"
}
