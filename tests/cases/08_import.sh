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

t_import_lossy_results() {
    known_defect "D7: import stores unusable/lossy values"
    fixture_configured; load_app
    write_conf static 'server {
    listen 80;
    server_name static.example.com;
    root /var/www;
}'
    write_conf tlsback 'server {
    listen 80;
    server_name tb.example.com;
    location / {
        proxy_pass https://10.0.0.3:8443;
    }
}'
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
    write_conf oneline 'server { listen 80; server_name one.example.com; location / { proxy_pass http://10.0.0.5:80; } }'
    write_conf inline 'server {
    server_name in.example.com;
    location / { proxy_pass http://10.0.0.6:80; }
}'
    import_sites <<< $'\n' >/dev/null 2>&1
    assert_db '.static.backend == "unknown"' "missing proxy_pass stored as 'unknown'"
    assert_db '.oneline.domain == "{" and .oneline.backend == "{"' "single-line server block parsed as '{'"
    assert_db '.inline.backend == "/"' "proxy_pass not at line start parsed as '/'"
    assert_db '.tlsback.backend == "https://10.0.0.3:8443"' "https backend stored with scheme"
    assert_db '.dual.tls == "https"' "http+https config imported as https, not both"
    regenerate_site_safe tlsback >/dev/null 2>&1
    assert_contains "$(cat "$SITES_AVAILABLE/tlsback.conf")" "proxy_pass http://https://10.0.0.3:8443;" \
        "regenerating it writes a broken proxy_pass"
}

t_import_ignores_enabled_state() {
    known_defect "D6/D7: an imported site that is live is stored as enabled=false"
    fixture_configured; load_app
    write_conf live 'server { listen 80; server_name live.example.com; location / { proxy_pass http://10.0.0.1:80; } }'
    ln -s "$SITES_AVAILABLE/live.conf" "$SITES_ENABLED/live.conf"
    import_sites <<< $'\n' >/dev/null 2>&1
    assert_db '.live.enabled == false' "db says disabled while the symlink exists"
}
