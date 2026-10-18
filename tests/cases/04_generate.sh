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

t_new_site_creates_no_backup() {
    fixture_configured; load_app
    new_site app http
    assert_eq "" "$(ls "$MANAGER_DIR/backups")" "no backup when nothing was overwritten"
}

t_backup_same_second_collision() {
    known_defect "D12: backups of the same file within one second overwrite each other"
    fixture_configured; load_app
    date() { if [[ "$1" == "+%s" ]]; then echo 1700000000; else command date "$@"; fi; }
    echo one > /tmp/f.conf; backup_file /tmp/f.conf
    echo two > /tmp/f.conf; backup_file /tmp/f.conf
    assert_eq 1 "$(ls "$MANAGER_DIR/backups" | wc -l)" "only one backup file survives"
    assert_eq two "$(cat "$MANAGER_DIR/backups/f.conf_1700000000.bak")" "earlier backup lost"
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
