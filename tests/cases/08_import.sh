#!/bin/bash
# Importing existing configs from sites-available.

write_conf() { # name body
    printf '%s\n' "$2" > "$SITES_AVAILABLE/$1.conf"
}

t_import_basic() {
    fixture_configured; load_app
    write_conf plain 'server {
    listen 80;
    server_name plain.example.com;
    location / {
        proxy_pass http://10.0.0.1:3000;
    }
}'
    write_conf secure 'server {
    listen 443 ssl;
    server_name secure.example.com;
    location / {
        proxy_pass http://10.0.0.2:4000;
    }
}'
    local out
    out=$(import_sites <<< $'\n' 2>&1)
    assert_contains "$out" "Imported: plain" "plain imported"
    assert_contains "$out" "Imported: secure" "secure imported"
    assert_db '.plain | .domain == "plain.example.com" and .backend == "10.0.0.1:3000" and .tls == "http" and .enabled == false' "plain fields"
    assert_db '.secure | .domain == "secure.example.com" and .backend == "10.0.0.2:4000" and .tls == "https"' "listen 443 -> https"
    assert_eq "server {" "$(head -1 "$SITES_AVAILABLE/plain.conf")" "config file not modified by import"
}

t_import_skips() {
    fixture_configured; load_app
    new_site app http
    write_conf nodomain 'server { listen 80; location / { proxy_pass http://10.0.0.1:1; } }'
    local before out
    before=$(cat "$MANAGER_DIR/sites.json")
    out=$(import_sites <<< $'\n' 2>&1)
    assert_contains "$out" "No new sites found to import." "nothing to import"
    assert_eq "$before" "$(cat "$MANAGER_DIR/sites.json")" "db unchanged (managed site and no-server_name config skipped)"
}

# D7: a config without an http:// host:port proxy_pass cannot be managed;
# it is skipped with a reason instead of being stored with backend "unknown".
t_import_skips_config_without_proxy() {
    fixture_configured; load_app
    write_conf static 'server {
    listen 80;
    server_name static.example.com;
    root /var/www;
}'
    local out
    out=$(import_sites <<< $'\n' 2>&1)
    assert_db 'has("static") | not' "not imported"
    assert_contains "$out" "Skipped static: no proxy_pass backend found" "reason shown"
    assert_contains "$out" "No new sites found to import." "nothing imported"
}

# D7: an https:// upstream cannot be expressed as host:port (the templates
# always write http://), so it is skipped instead of stored with its scheme.
t_import_skips_https_backend() {
    fixture_configured; load_app
    write_conf tlsback 'server {
    listen 80;
    server_name tb.example.com;
    location / {
        proxy_pass https://10.0.0.3:8443;
    }
}'
    local out
    out=$(import_sites <<< $'\n' 2>&1)
    assert_db 'has("tlsback") | not' "not imported"
    assert_contains "$out" "Skipped tlsback: backend 'https://10.0.0.3:8443' is not http://host:port" "reason shown"
}

# D7: plain HTTP and HTTPS servers side by side are BOTH; HTTP that only
# redirects to HTTPS is HTTPS.
t_import_detects_both_and_https() {
    fixture_configured; load_app
    write_conf dual 'server {
    listen 80;
    server_name d.lan.example.com;
    location / {
        proxy_pass http://10.0.0.4:80;
    }
}
server {
    listen 443 ssl;
    server_name d.lan.example.com;
    location / {
        proxy_pass http://10.0.0.4:80;
    }
}'
    write_conf redir 'server {
    listen 80;
    server_name r.lan.example.com;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name r.lan.example.com;
    location / {
        proxy_pass http://10.0.0.8:80;
    }
}'
    import_sites <<< $'\n' >/dev/null 2>&1
    assert_db '.dual.tls == "both"' "http + https servers -> both"
    assert_db '.redir.tls == "https"' "http redirect + https server -> https"
}

# D7: directives are read per statement, not per line.
t_import_single_line_server_block() {
    fixture_configured; load_app
    write_conf oneline 'server { listen 80; server_name one.example.com; location / { proxy_pass http://10.0.0.5:80; } }'
    import_sites <<< $'\n' >/dev/null 2>&1
    assert_db '.oneline | .domain == "one.example.com" and .backend == "10.0.0.5:80" and .tls == "http"' "single-line block parsed"
}

t_import_inline_proxy_pass() {
    fixture_configured; load_app
    write_conf inline 'server {
    server_name in.example.com;
    location / { proxy_pass http://10.0.0.6:80; }
}'
    import_sites <<< $'\n' >/dev/null 2>&1
    assert_db '.inline.backend == "10.0.0.6:80"' "proxy_pass after 'location / {' parsed"
}

t_import_ignores_comments() {
    fixture_configured; load_app
    write_conf commented '# server_name old.example.com;
server {
    listen 80;
    # proxy_pass http://10.0.0.1:1;
    server_name new.example.com; # main name
    location / {
        proxy_pass http://10.0.0.7:80;
    }
}'
    import_sites <<< $'\n' >/dev/null 2>&1
    assert_db '.commented | .domain == "new.example.com" and .backend == "10.0.0.7:80"' "commented-out directives ignored"
}

# D7: regenerating an imported config would replace it with the template;
# when that would drop hand-written directives it is refused and the file
# is left exactly as it was.
HANDWRITTEN='server {
    listen 80;
    server_name hw.lan.example.com;
    client_max_body_size 100m;
    location / {
        proxy_pass http://127.0.0.1:8080;
    }
    location /api {
        proxy_pass http://127.0.0.1:9000;
    }
}'

t_import_warns_about_handwritten_directives() {
    fixture_configured; load_app
    write_conf hw "$HANDWRITTEN"
    local out
    out=$(import_sites <<< $'\n' 2>&1)
    assert_contains "$out" "Imported: hw" "imported"
    assert_contains "$out" "hw has directives NGINX Manager cannot reproduce" "warning shown"
    assert_contains "$out" "    client_max_body_size 100m" "directive listed"
    assert_contains "$out" "    location /api" "extra location listed"
    assert_db '.hw | .backend == "127.0.0.1:8080" and .domain == "hw.lan.example.com"' "first backend recorded"
}

t_regenerate_refuses_handwritten_directives() {
    fixture_configured; load_app
    write_conf hw "$HANDWRITTEN"
    import_sites <<< $'\n' >/dev/null 2>&1
    ln -s "$SITES_AVAILABLE/hw.conf" "$SITES_ENABLED/hw.conf"
    local out rc
    out=$(regenerate_site_safe hw 2>&1); rc=$?
    assert_eq 1 "$rc" "regenerate refused"
    assert_contains "$out" "was not generated by NGINX Manager and has directives regeneration would discard" "reason shown"
    assert_contains "$out" "    client_max_body_size 100m" "directive listed"
    assert_eq "$HANDWRITTEN" "$(cat "$SITES_AVAILABLE/hw.conf")" "file unchanged by regenerate"

    out=$(site_update hw hw.lan.example.com 127.0.0.1:9090 http 2>&1 </dev/null); rc=$?
    assert_eq 1 "$rc" "edit refused"
    assert_eq "$HANDWRITTEN" "$(cat "$SITES_AVAILABLE/hw.conf")" "file unchanged by edit"
    assert_db '.hw.backend == "127.0.0.1:8080"' "db restored after refused edit"
    assert_eq "" "$(ls "$MANAGER_DIR/backups")" "nothing replaced, nothing backed up"

    out=$(regenerate_all <<< $'y\n\n' 2>&1)
    assert_contains "$out" "0 succeeded, 1 failed" "regenerate all reports it"
    assert_eq "$HANDWRITTEN" "$(cat "$SITES_AVAILABLE/hw.conf")" "file unchanged by regenerate all"
}

# D7 review: comments are stripped before parsing, also inside quotes, so a
# quoted "#" could cut a line short and hide the directives after it. Valid
# nginx; regeneration must still refuse it.
t_regenerate_refuses_quoted_hash_bypass() {
    fixture_configured; load_app
    write_conf hw 'server {
    listen 80;
    server_name hw.lan.example.com;
    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}'
    import_sites <<< $'\n' >/dev/null 2>&1
    local edited out rc
    edited='server {
    listen 80;
    location / {
        proxy_pass http://127.0.0.1:8080;
    }
    server_name "hw.lan.example.com#"; client_max_body_size 100m;
}'
    write_conf hw "$edited"
    out=$(regenerate_site_safe hw 2>&1); rc=$?
    assert_eq 1 "$rc" "regenerate refused"
    assert_contains "$out" "has directives regeneration would discard" "reason shown"
    assert_eq "$edited" "$(cat "$SITES_AVAILABLE/hw.conf")" "file unchanged"
}

# D7 review: every statement here is one the templates write, but the
# layout is not: the port-80 server proxies nothing. Regenerating it as
# BOTH would start proxying the backend over plain HTTP.
t_regenerate_refuses_different_layout() {
    fixture_configured; load_app
    local layout='server {
    listen 80;
    server_name s.lan.example.com;
}
server {
    listen 443 ssl;
    server_name s.lan.example.com;
    ssl_certificate /etc/letsencrypt/live/lan.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/lan.example.com/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}'
    write_conf s "$layout"
    local out rc
    out=$(import_sites <<< $'\n' 2>&1)
    assert_contains "$out" "s has directives NGINX Manager cannot reproduce" "warned at import"
    out=$(regenerate_site_safe s 2>&1); rc=$?
    assert_eq 1 "$rc" "regenerate refused"
    assert_contains "$out" "2 server blocks, but only 1 with a 'location /' proxy or an HTTPS redirect" "layout reported"
    assert_eq "$layout" "$(cat "$SITES_AVAILABLE/s.conf")" "file unchanged"
}

# D7: an imported config that only holds what the template writes may be
# regenerated; that turns it into a managed config.
t_regenerate_simple_imported_config() {
    fixture_configured; load_app
    write_conf web 'server {
    listen 80;
    server_name web.lan.example.com;
    location / {
        proxy_pass http://127.0.0.1:3000;
    }
}'
    import_sites <<< $'\n' >/dev/null 2>&1
    regenerate_site_safe web >/dev/null 2>&1
    assert_eq 0 $? "regenerated"
    golden_compare http.conf "$SITES_AVAILABLE/web.conf"
}
# D6: an imported site records whether it is actually live.
t_import_records_live_state() {
    fixture_configured; load_app
    write_conf live 'server {
    listen 80;
    server_name live.example.com;
    location / {
        proxy_pass http://10.0.0.1:80;
    }
}'
    write_conf idle 'server {
    listen 80;
    server_name idle.example.com;
    location / {
        proxy_pass http://10.0.0.1:81;
    }
}'
    ln -s "$SITES_AVAILABLE/live.conf" "$SITES_ENABLED/live.conf"
    import_sites <<< $'\n' >/dev/null 2>&1
    assert_db '.live.enabled == true' "live site imported as enabled"
    assert_db '.idle.enabled == false' "unlinked site imported as disabled"
    assert_symlink "$SITES_ENABLED/live.conf" "symlink untouched"
    assert_no_symlink "$SITES_ENABLED/idle.conf" "nothing enabled by import"
}
