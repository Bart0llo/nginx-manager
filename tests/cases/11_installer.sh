#!/bin/bash
# install.sh in isolation: apt-get and curl are mocked, the "download" is a
# local file chosen via MOCK_CURL_FILE. No network is used.

INSTALLER=/src/install.sh
TARGET=/usr/local/bin/nginx-manager

run_installer() { # file-to-serve
    use_mock curl
    MOCK_CURL_FILE="$1" timeout 30 bash "$INSTALLER" 2>&1
}

t_fresh_install() {
    local out rc
    out=$(run_installer /src/nginx-site.sh); rc=$?
    assert_eq 0 "$rc" "installer exits 0"
    assert_contains "$out" "Installation completed successfully" "success message"
    assert_eq "$(sha256sum < /src/nginx-site.sh)" "$(sha256sum < "$TARGET")" "installed file identical to source"
    assert_mode "$TARGET" 755
    assert_no_file /tmp/nginx-manager.sh "temp file removed"
    assert_called "curl -fsSL https://gist.githubusercontent.com/Bart0llo/e746ec66324473d20a72f13588f9d3b3/raw/nginx-site.sh -o /tmp/nginx-manager.sh" \
        "downloads from the gist"
    assert_called "apt-get update" "apt-get update"
}

t_installs_certbot_by_default() {
    known_defect "D10: installer always installs certbot (decision: TLS deps optional)"
    run_installer /src/nginx-site.sh >/dev/null
    assert_called "apt-get install -y curl jq nginx certbot python3-certbot-dns-cloudflare openssl" "certbot in default packages"
}

t_installed_app_runs() {
    run_installer /src/nginx-site.sh >/dev/null
    fixture_configured
    local out rc
    out=$(printf 'q\n' | timeout 20 "$TARGET" 2>&1); rc=$?
    assert_eq 0 "$rc" "installed nginx-manager starts and quits"
    assert_contains "$out" "NGINX MANAGER PRO" "shows the dashboard"
}

t_update_preserves_data() {
    fixture_configured; fixture_sites_v3; fixture_cloudflare
    mkdir -p "$MANAGER_DIR/backups"; echo old > "$MANAGER_DIR/backups/app.conf_1.bak"
    echo "#!/bin/bash
echo old version" > "$TARGET"; chmod 755 "$TARGET"
    local before
    before=$(cd "$MANAGER_DIR" && find . -type f -exec sha256sum {} + | sort)
    run_installer /src/nginx-site.sh >/dev/null
    assert_eq 0 $? "update exits 0"
    assert_eq "$before" "$(cd "$MANAGER_DIR" && find . -type f -exec sha256sum {} + | sort)" \
        "config, sites.json, secrets and backups untouched"
    assert_eq "$(sha256sum < /src/nginx-site.sh)" "$(sha256sum < "$TARGET")" "binary replaced"
}

t_download_failure() {
    echo old > "$TARGET"
    mock_rc curl 22
    local out rc
    out=$(run_installer /src/nginx-site.sh); rc=$?
    assert_eq 22 "$rc" "installer fails with curl's status"
    assert_not_contains "$out" "Installation completed" "no success message"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
}

t_invalid_syntax_rejected() {
    echo old > "$TARGET"
    printf '#!/bin/bash\nif then fi\n' > /tmp/broken-download.sh
    local out rc
    out=$(run_installer /tmp/broken-download.sh); rc=$?
    rm -f /tmp/broken-download.sh
    assert_eq 1 "$rc" "installer exits 1"
    assert_contains "$out" "downloaded script has invalid Bash syntax" "reason shown"
    assert_eq old "$(cat "$TARGET")" "existing install untouched"
    assert_no_file /tmp/nginx-manager.sh "temp file removed"
}

t_apt_failure_aborts() {
    mock_rc apt-get-install 100
    local out rc
    out=$(run_installer /src/nginx-site.sh); rc=$?
    assert_eq 100 "$rc" "installer aborts (set -e)"
    assert_no_file "$TARGET" "nothing installed"
}

t_requires_root() {
    local out rc
    out=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$INSTALLER" 2>&1); rc=$?
    assert_eq 1 "$rc" "exits 1"
    assert_contains "$out" "Please run this installer with sudo." "message"
}

t_download_not_verified() {
    known_defect "D10: fixed temp path in /tmp, no checksum (only bash -n)"
    assert_contains "$(cat "$INSTALLER")" 'TMP="/tmp/nginx-manager.sh"' "predictable temp path"
    assert_not_contains "$(cat "$INSTALLER")" "sha256" "no checksum verification"
}
