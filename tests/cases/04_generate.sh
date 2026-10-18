#!/bin/bash
# NGINX config generation: golden output per TLS mode, wildcard coverage,
# validators and backups of overwritten configs.

t_golden_http() {
    fixture_configured; load_app
    new_site web http web.lan.example.com 127.0.0.1:3000
    golden_compare http.conf "$SITES_AVAILABLE/web.conf"
}

t_golden_https() {
    fixture_configured; load_app
    new_site app https app.lan.example.com 127.0.0.1:8080
    golden_compare https.conf "$SITES_AVAILABLE/app.conf"
}

t_golden_both() {
    fixture_configured; load_app
    new_site mix both mix.lan.example.com 10.0.0.7:9000
    golden_compare both.conf "$SITES_AVAILABLE/mix.conf"
}

t_golden_snippets() {
    fixture_configured; load_app
    golden_compare proxy-common.conf /etc/nginx/snippets/proxy-common.conf
    golden_compare tls-common.conf /etc/nginx/snippets/tls-common.conf
}

t_generated_configs_pass_nginx_t() {
    fixture_configured; load_app
    new_site web http
    new_site app https
    new_site mix both
    local n
    for n in web app mix; do ln -s "$SITES_AVAILABLE/$n.conf" "$SITES_ENABLED/$n.conf"; done
    nginx -t >/dev/null 2>&1
    assert_eq 0 $? "real nginx -t accepts http, https and both configs together"
}

t_wildcard_coverage() {
    fixture_configured; load_app
    local d
    for d in lan.example.com app.lan.example.com A-1.lan.example.com; do
        domain_covered_by_wildcard "$d" lan.example.com
        assert_eq 0 $? "covered: $d"
    done
    for d in a.b.lan.example.com app.other.com xlan.example.com evil-lan.example.com \
            lan.example.com.evil.com applan.example.com; do
        domain_covered_by_wildcard "$d" lan.example.com
        assert_eq 1 $? "not covered: $d"
    done
}

t_https_rejects_uncovered_domain() {
    fixture_configured; load_app
    local mode out rc
    for mode in https both; do
        db_save "s$mode" "s.other.com" 127.0.0.1:8080 "$mode" false >/dev/null
        out=$(generate_site "s$mode" 2>&1); rc=$?
        assert_eq 1 "$rc" "$mode: generation fails for uncovered domain"
        assert_contains "$out" "is not covered by the configured wildcard certificate" "$mode: reason shown"
        assert_no_file "$SITES_AVAILABLE/s$mode.conf" "$mode: no config written"
    done
}

t_http_allows_any_domain() {
    fixture_configured; load_app
    new_site ext http app.other.com
    assert_file "$SITES_AVAILABLE/ext.conf" "http config written for a domain outside the wildcard"
}

t_https_requires_cert_name() {
    fixture_configured
    sed -i 's/^CERT_NAME=.*/CERT_NAME=/' "$MANAGER_DIR/config.conf"
    load_app
    db_save app app.lan.example.com 127.0.0.1:8080 https false >/dev/null
    local out rc
    out=$(generate_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "generation fails without CERT_NAME"
    assert_contains "$out" "CERT_NAME missing" "reason shown"
    assert_no_file "$SITES_AVAILABLE/app.conf" "no config written"
}

t_unknown_tls_mode() {
    fixture_configured; load_app
    db_save odd odd.lan.example.com 127.0.0.1:8080 weird false >/dev/null
    local out rc
    out=$(generate_site odd 2>&1); rc=$?
    assert_eq 1 "$rc" "unknown mode fails"
    assert_contains "$out" "Unknown TLS mode: weird" "reason shown"
}

t_regeneration_backs_up_previous_config() {
    fixture_configured; load_app
    new_site app http app.lan.example.com 127.0.0.1:8080
    db_save app app.lan.example.com 127.0.0.1:9090 http false >/dev/null
    generate_site app >/dev/null 2>&1
    local backups
    backups=$(ls "$MANAGER_DIR/backups")
    assert_matches "$backups" '^app\.conf_[0-9]+\.bak$' "backup named <file>_<epoch>.bak"
    assert_contains "$(cat "$MANAGER_DIR/backups/"app.conf_*.bak)" "proxy_pass http://127.0.0.1:8080;" \
        "backup holds the previous config"
    assert_contains "$(cat "$SITES_AVAILABLE/app.conf")" "proxy_pass http://127.0.0.1:9090;" "new config written"
    assert_contains "$(cat /var/log/nginx-manager/manager.log)" "Backup created: $SITES_AVAILABLE/app.conf" "backup logged"
}

no_temp_files() { ls -A "$SITES_AVAILABLE" | grep '^\.'; }

# D5: the new config is generated in a temp file next to the target and
# renamed over it, so the target is never seen half-written.
t_generate_replaces_atomically() {
    fixture_configured; load_app
    new_site app http; chmod 640 "$SITES_AVAILABLE/app.conf"
    local inode
    inode=$(stat -c %i "$SITES_AVAILABLE/app.conf")
    db_save app app.lan.example.com 127.0.0.1:9090 http false >/dev/null
    generate_site app >/dev/null 2>&1
    assert_eq 0 $? "returns 0"
    assert_contains "$(cat "$SITES_AVAILABLE/app.conf")" "proxy_pass http://127.0.0.1:9090;" "new config in place"
    [[ "$(stat -c %i "$SITES_AVAILABLE/app.conf")" != "$inode" ]] \
        && pass "replaced by rename, not rewritten in place" || fail "replaced by rename, not rewritten in place"
    assert_mode "$SITES_AVAILABLE/app.conf" 640 "mode kept"
    assert_eq "" "$(no_temp_files)" "no temp files left"
    new_site web http
    assert_mode "$SITES_AVAILABLE/web.conf" 644 "new config is 644"
}

# D5: a write that fails part-way must not touch the existing config.
t_generate_write_failure_keeps_original() {
    fixture_configured; load_app
    new_site app http
    local original rc
    original=$(cat "$SITES_AVAILABLE/app.conf")
    db_save app app.lan.example.com 127.0.0.1:9090 http false >/dev/null
    cat() { return 1; }
    generate_site app >/dev/null 2>&1; rc=$?
    unset -f cat
    assert_eq 1 "$rc" "returns 1"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "existing config intact"
    assert_eq "" "$(no_temp_files)" "temp file removed"
}

t_generate_replace_failure_keeps_original() {
    fixture_configured; load_app
    new_site app http
    local original out rc
    original=$(cat "$SITES_AVAILABLE/app.conf")
    db_save app app.lan.example.com 127.0.0.1:9090 http false >/dev/null
    mv() { return 1; }
    out=$(generate_site app 2>&1); rc=$?
    unset -f mv
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "Failed to write configuration $SITES_AVAILABLE/app.conf" "reason shown"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "existing config intact"
    assert_eq "" "$(no_temp_files)" "temp file removed"
}

# D5: without a backup there is no way back, so nothing is replaced.
t_generate_backup_failure_keeps_original() {
    fixture_configured; load_app
    new_site app http
    local original out rc
    original=$(cat "$SITES_AVAILABLE/app.conf")
    db_save app app.lan.example.com 127.0.0.1:9090 http false >/dev/null
    rm -rf "$MANAGER_DIR/backups"; touch "$MANAGER_DIR/backups"
    out=$(generate_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "Failed to create backup" "reason shown"
    assert_eq "$original" "$(cat "$SITES_AVAILABLE/app.conf")" "existing config intact"
    assert_eq "" "$(no_temp_files)" "temp file removed"
}

t_generate_refuses_non_regular_target() {
    fixture_configured; load_app
    echo keep > /etc/victim.conf
    db_save app app.lan.example.com 127.0.0.1:8080 http false >/dev/null
    ln -s /etc/victim.conf "$SITES_AVAILABLE/app.conf"
    local out rc
    out=$(generate_site app 2>&1); rc=$?
    assert_eq 1 "$rc" "returns 1"
    assert_contains "$out" "is not a regular file" "reason shown"
    assert_symlink "$SITES_AVAILABLE/app.conf" "symlink kept"
    assert_eq keep "$(cat /etc/victim.conf)" "link target untouched"
}

t_new_site_creates_no_backup() {
    fixture_configured; load_app
    new_site app http
    assert_eq "" "$(ls "$MANAGER_DIR/backups")" "no backup when nothing was overwritten"
}

# D12: backups made within the same second all survive: the first keeps the
# <file>_<epoch>.bak name, later ones get a _<n> suffix.
t_backup_same_second_no_collision() {
    fixture_configured; load_app
    date() { if [[ "$1" == "+%s" ]]; then echo 1700000000; else command date "$@"; fi; }
    local b="$MANAGER_DIR/backups/f.conf_1700000000" i
    for i in one two three; do echo "$i" > /tmp/f.conf; backup_file /tmp/f.conf; done
    assert_eq 3 "$(ls "$MANAGER_DIR/backups" | wc -l)" "three backups kept"
    assert_eq one "$(cat "$b.bak")" "first backup intact"
    assert_eq two "$(cat "${b}_1.bak")" "second backup intact"
    assert_eq three "$(cat "${b}_2.bak")" "third backup intact"
    assert_eq "${b}_2.bak" "$LAST_BACKUP" "LAST_BACKUP names the newest"
    rm -f /tmp/f.conf
}

t_backup_rapid_real_clock() {
    fixture_configured; load_app
    local i
    for i in 1 2 3 4 5 6; do echo "v$i" > /tmp/f.conf; backup_file /tmp/f.conf; done
    assert_eq 6 "$(ls "$MANAGER_DIR/backups" | wc -l)" "six quick backups kept"
    assert_eq "v1 v2 v3 v4 v5 v6" "$(cat "$MANAGER_DIR"/backups/* | sort | tr '\n' ' ' | sed 's/ $//')" "every version present"
    rm -f /tmp/f.conf
}

# D12: whatever already sits at a candidate name is never overwritten.
t_backup_never_overwrites_existing() {
    fixture_configured; load_app
    date() { if [[ "$1" == "+%s" ]]; then echo 1700000000; else command date "$@"; fi; }
    local b="$MANAGER_DIR/backups/f.conf_1700000000"
    echo precious > "$b.bak"; echo precious1 > "${b}_1.bak"
    echo new > /tmp/f.conf; chmod 640 /tmp/f.conf
    backup_file /tmp/f.conf
    assert_eq 0 $? "returns 0"
    assert_eq precious "$(cat "$b.bak")" "existing backup kept"
    assert_eq precious1 "$(cat "${b}_1.bak")" "existing suffixed backup kept"
    assert_eq new "$(cat "${b}_2.bak")" "new backup under the next free name"
    assert_mode "${b}_2.bak" 640 "backup keeps the file's mode"
    rm -f /tmp/f.conf
}

t_validate_name() {
    fixture_configured; load_app
    local v
    for v in app my-site my_site Site01; do validate_name "$v"; assert_eq 0 $? "valid name: $v"; done
    for v in "" "my site" "a.b" "../x" "a/b" 'a$b'; do validate_name "$v"; assert_eq 1 $? "invalid name: '$v'"; done
}

t_validate_domain() {
    fixture_configured; load_app
    local v
    for v in example.com app.lan.example.com xn--bcher-kva.example.com; do
        validate_domain "$v"; assert_eq 0 $? "valid domain: $v"
    done
    # example.xn--p1ai: punycode TLD rejected (current behaviour, minor note)
    for v in "" localhost "a b.com" "*.example.com" "example.c" example.xn--p1ai "http://a.com"; do
        validate_domain "$v"; assert_eq 1 $? "invalid domain: '$v'"
    done
}

t_validate_backend() {
    fixture_configured; load_app
    local v
    for v in 127.0.0.1:80 10.0.0.5:8080 host:1 my-host.lan:65535; do
        validate_backend "$v"; assert_eq 0 $? "valid backend: $v"
    done
    # [::1]:80 and http:// prefixes are rejected (current behaviour, minor note)
    for v in "" host host: :80 host:0 host:65536 host:080 host:00 "[::1]:80" "http://host:80" "host:80/x"; do
        validate_backend "$v"; assert_eq 1 $? "invalid backend: '$v'"
    done
}
